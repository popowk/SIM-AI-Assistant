#if os(macOS)
import Foundation
import Network
import Security
import CryptoKit
import Darwin
import SIMAICore

struct ShizukuWiFiCredentials: Codable {
    let pin: String
    let token: String
    init?(code: String) {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ String($0).range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { return nil }
        pin = String(parts[0]); token = String(parts[1])
    }
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.simai.assistant.secure-wifi",
         kSecAttrAccount as String: "paired-companion"]
    }
    static func load() -> Self? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return Self(code: decoded.pin + ":" + decoded.token)
    }
    func save() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        var attributes = Self.keychainQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }
    static func clear() { SecItemDelete(keychainQuery as CFDictionary) }
    func matches(_ trust: SecTrust) -> Bool {
        guard let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return false }
        let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
        return digest.map { String(format: "%02x", $0) }.joined() == pin
    }
}

enum WiFiControlError: String, LocalizedError {
    case invalidRequest, networkUnavailable, certificateMismatch, tlsHandshakeFailed, timedOut, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "无线请求无效"
        case .networkUnavailable: return "无法连接手机 TLS 端口（检查局域网权限、网络与手机服务）"
        case .certificateMismatch: return "手机 TLS 证书与已信任证书不一致，请重新建立信任"
        case .tlsHandshakeFailed: return "手机 TLS 握手失败，请查看手机诊断"
        case .timedOut: return "手机安全连接超时"
        case .invalidResponse: return "手机返回的状态数据无效"
        }
    }
}

struct ShizukuWiFiTransport {
    let host: String
    let credentials: ShizukuWiFiCredentials
    static let port: UInt16 = 18766
    init?(host: String, credentials: ShizukuWiFiCredentials?) {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BridgeRetryPolicy.validWirelessEndpoint(ip + ":18766"), let credentials else { return nil }
        self.host = ip; self.credentials = credentials
    }

    func request(_ path: String, method: String = "GET", session: String = "", sequence: Int = 0) async throws -> (Int, Data) {
        // Direct TLS, the same pinned connection policy as the PCM stream.
        // Avoid URLSession/ATS/proxy handling of an IP-address self-signed server.
        guard (method == "GET" || method == "POST"), path.hasPrefix("/"),
              path.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !session.contains("\r"), !session.contains("\n") else { throw WiFiControlError.invalidRequest }
        var header = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(Self.port)\r\nX-SIMAI-Token: \(credentials.token)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if method == "POST" {
            header += "X-SIMAI-Expected-Session: \(session)\r\nX-SIMAI-Expected-Sequence: \(sequence)\r\nContent-Length: 0\r\n"
        }
        header += "\r\n"
        let bytes = Data(header.utf8)
        return try await Task.detached(priority: .userInitiated) {
            try ShizukuTLSRelay.controlRequest(host: host, credentials: credentials, request: bytes)
        }.value
    }

    func openAudio(session: String, sequence: Int) -> (Int32, [UInt8])? {
        guard UUID(uuidString: session) != nil, sequence > 0 else { return nil }
        guard let fd = ShizukuTLSRelay.connect(host: host, credentials: credentials) else { return nil }
        let header = "POST /audio/open HTTP/1.1\r\nHost: \(host):\(Self.port)\r\nX-SIMAI-Token: \(credentials.token)\r\nX-SIMAI-Expected-Session: \(session)\r\nX-SIMAI-Expected-Sequence: \(sequence)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return (fd, Array(header.utf8))
    }
}

/// Local socket pair keeps the existing PCM frame reader/writer unchanged.
/// The only network connection is TLS with the physically approved pin.
private final class ShizukuTLSRelay {
    private let connection: NWConnection
    private let fd: Int32
    private let gate = NSLock()
    private var stopped = false

    private init(connection: NWConnection, fd: Int32) {
        self.connection = connection; self.fd = fd
    }

    private static func openConnection(host: String, credentials: ShizukuWiFiCredentials) throws -> NWConnection {
        let queue = DispatchQueue(label: "simai.shizuku.tls")
        let tls = NWProtocolTLS.Options()
        let pinRejected = RelayResult()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let matches = credentials.matches(sec_trust_copy_ref(trust).takeRetainedValue())
            if !matches { pinRejected.set(true) }
            complete(matches)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: ShizukuWiFiTransport.port)!, using: parameters)
        let signal = DispatchSemaphore(value: 0)
        let connected = RelayResult()
        let tlsFailure = RelayResult()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: connected.set(true); signal.signal()
            case .failed(let error):
                if case .tls = error { tlsFailure.set(true) }
                signal.signal()
            case .waiting(let error):
                if case .tls = error { tlsFailure.set(true); signal.signal() }
            case .cancelled: signal.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        let completed = signal.wait(timeout: .now() + 5) == .success
        guard completed && connected.value else {
            connection.cancel()
            if pinRejected.value { throw WiFiControlError.certificateMismatch }
            if tlsFailure.value { throw WiFiControlError.tlsHandshakeFailed }
            throw completed ? WiFiControlError.networkUnavailable : WiFiControlError.timedOut
        }
        return connection
    }

    static func controlRequest(host: String, credentials: ShizukuWiFiCredentials, request: Data) throws -> (Int, Data) {
        let connection = try openConnection(host: host, credentials: credentials)
        defer { connection.cancel() }
        let deadline = DispatchTime.now() + 6
        let sent = DispatchSemaphore(value: 0)
        let sendOK = RelayResult()
        connection.send(content: request, completion: .contentProcessed { error in
            sendOK.set(error == nil); sent.signal()
        })
        guard sent.wait(timeout: deadline) == .success else { throw WiFiControlError.timedOut }
        guard sendOK.value else { throw WiFiControlError.networkUnavailable }
        var received = Data()
        let delimiter = Data([13, 10, 13, 10])
        while received.count <= 262144 {
            if let split = received.range(of: delimiter) {
                guard split.lowerBound <= 8192,
                      let header = String(data: received[..<split.lowerBound], encoding: .ascii) else { throw WiFiControlError.invalidResponse }
                let lines = header.components(separatedBy: "\r\n")
                guard let first = lines.first, first.hasPrefix("HTTP/1."),
                      let codeText = first.split(separator: " ").dropFirst().first,
                      let code = Int(codeText), (100...599).contains(code) else { throw WiFiControlError.invalidResponse }
                let lengths = lines.dropFirst().filter { $0.lowercased().hasPrefix("content-length:") }
                guard lengths.count == 1,
                      let length = Int(lengths[0].dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                      length >= 0, length <= 253952 else { throw WiFiControlError.invalidResponse }
                let bodyStart = split.upperBound
                if received.count - bodyStart >= length {
                    return (code, Data(received[bodyStart..<(bodyStart + length)]))
                }
            } else if received.count > 8192 { throw WiFiControlError.invalidResponse }
            let result = ReceiveResult()
            let signal = DispatchSemaphore(value: 0)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                result.set(data, more: error == nil && !complete); signal.signal()
            }
            guard signal.wait(timeout: deadline) == .success else { throw WiFiControlError.timedOut }
            let (data, more) = result.value
            if let data, !data.isEmpty {
                received.append(data)
            } else {
                throw WiFiControlError.invalidResponse
            }
            if !more && received.range(of: delimiter) == nil { throw WiFiControlError.invalidResponse }
        }
        throw WiFiControlError.invalidResponse
    }

    static func connect(host: String, credentials: ShizukuWiFiCredentials) -> Int32? {
        guard let connection = try? openConnection(host: host, credentials: credentials) else { return nil }
        var sockets: [Int32] = [-1, -1]
        guard sockets.withUnsafeMutableBufferPointer({ Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }) == 0 else {
            connection.cancel(); return nil
        }
        for socket in sockets {
            var noSigPipe: Int32 = 1
            _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 6, tv_usec: 0)
            _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(sockets[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let relay = ShizukuTLSRelay(connection: connection, fd: sockets[1])
        relay.start()
        return sockets[0]
    }

    private var isStopped: Bool { gate.lock(); defer { gate.unlock() }; return stopped }
    private func stop() {
        gate.lock()
        guard !stopped else { gate.unlock(); return }
        stopped = true
        gate.unlock()
        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
        connection.cancel()
    }
    private func start() {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { stop(); group.leave() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !isStopped {
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
                guard count > 0 else { break }
                let semaphore = DispatchSemaphore(value: 0)
                let result = RelayResult()
                connection.send(content: Data(buffer.prefix(count)), completion: .contentProcessed { error in
                    result.set(error == nil); semaphore.signal()
                })
                guard semaphore.wait(timeout: .now() + 6) == .success, result.value else { break }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { stop(); group.leave() }
            while !isStopped {
                let semaphore = DispatchSemaphore(value: 0)
                let result = ReceiveResult()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                    result.set(data, more: error == nil && !complete)
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + 7) == .success, !isStopped else { break }
                let (data, more) = result.value
                if let data, !data.isEmpty, !writeLocal(data) { break }
                if !more { break }
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self] in _ = Darwin.close(fd) }
    }
    private func writeLocal(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                guard n > 0 else { return false }; offset += n
            }
            return true
        }
    }
    private final class ReceiveResult {
        private let lock = NSLock()
        private var bytes: Data?
        private var more = false
        func set(_ data: Data?, more: Bool) { lock.lock(); bytes = data; self.more = more; lock.unlock() }
        var value: (Data?, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, more) }
    }
    private final class RelayResult {
        private let lock = NSLock()
        private var ok = false
        func set(_ value: Bool) { lock.lock(); ok = value; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return ok }
    }
}
#endif
