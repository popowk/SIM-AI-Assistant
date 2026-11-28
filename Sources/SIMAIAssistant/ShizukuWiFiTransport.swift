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

private final class WiFiPinDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let credentials: ShizukuWiFiCredentials
    init(_ credentials: ShizukuWiFiCredentials) { self.credentials = credentials }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, credentials.matches(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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
        guard let url = URL(string: "https://\(host):\(Self.port)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue(credentials.token, forHTTPHeaderField: "X-SIMAI-Token")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if method == "POST" {
            request.setValue(session, forHTTPHeaderField: "X-SIMAI-Expected-Session")
            request.setValue(String(sequence), forHTTPHeaderField: "X-SIMAI-Expected-Sequence")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.httpBody = Data()
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.httpCookieStorage = nil
        let delegate = WiFiPinDelegate(credentials)
        let client = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { client.finishTasksAndInvalidate() }
        let (data, response) = try await client.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
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

    static func connect(host: String, credentials: ShizukuWiFiCredentials) -> Int32? {
        let queue = DispatchQueue(label: "simai.shizuku.tls")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(credentials.matches(sec_trust_copy_ref(trust).takeRetainedValue()))
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: ShizukuWiFiTransport.port)!, using: parameters)
        let signal = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var didConnect = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock(); didConnect = true; lock.unlock(); signal.signal()
            case .failed, .cancelled: signal.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        let completed = signal.wait(timeout: .now() + 6) == .success
        lock.lock(); let connected = didConnect; lock.unlock()
        guard completed && connected else { connection.cancel(); return nil }
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
