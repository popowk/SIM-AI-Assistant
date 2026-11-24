import Foundation
import Network

@MainActor
final class BonjourWiFiScanner: ObservableObject {
    @Published var discoveredDeviceName: String? = nil
    @Published var discoveredIP: String? = nil
    private var browser: NWBrowser?
    private var resolverConnection: NWConnection?

    init() {
        start()
    }

    func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_simai._tcp", domain: "local.")
        let parameters = NWParameters()
        let b = NWBrowser(for: descriptor, using: parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        self.discoveredDeviceName = name
                        // 1. Prefer IPv4 advertised in Bonjour TXT record
                        if case let .bonjour(txt) = result.metadata {
                            let dict = txt.dictionary
                            if let ip = dict["ipv4"], !ip.isEmpty,
                               !ip.contains(":"), !ip.contains("%"),
                               !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                                self.discoveredIP = ip
                                return
                            }
                        }
                        // 2. Resolve endpoint with IPv4 restriction
                        self.resolve(endpoint: result.endpoint)
                        return
                    }
                }
            }
        }
        b.start(queue: .main)
        self.browser = b
    }

    private func resolve(endpoint: NWEndpoint) {
        resolverConnection?.cancel()
        let params = NWParameters.tcp
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        resolverConnection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            if case .ready = state {
                if let path = conn?.currentPath,
                   let remote = path.remoteEndpoint,
                   case let .hostPort(host, _) = remote {
                    var candidateIP: String? = nil
                    switch host {
                    case let .ipv4(v4):
                        let ip = "\(v4)"
                        if !ip.isEmpty && !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !ip.contains(":") {
                            candidateIP = ip
                        }
                    default:
                        // Strictly drop IPv6 and link-local addresses
                        break
                    }
                    if let ip = candidateIP {
                        Task { @MainActor [weak self] in
                            self?.discoveredIP = ip
                        }
                    }
                }
                conn?.cancel()
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolverConnection?.cancel()
        resolverConnection = nil
    }

    deinit {
        browser?.cancel()
        resolverConnection?.cancel()
    }
}

enum LocalNetworkScanner {
    static func extractLocalIPs() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-an"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let pattern = #"\(([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            var results: [String] = []
            for match in matches {
                if let range = Range(match.range(at: 1), in: text) {
                    let ip = String(text[range])
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !ip.hasPrefix("224.") && !ip.hasPrefix("239.") && !ip.hasSuffix(".255") {
                        results.append(ip)
                    }
                }
            }
            return results
        } catch {
            return []
        }
    }

    static func probeCompanion(on ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip):18764/ping") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return String(data: data, encoding: .utf8)?.contains("pong") == true
        } catch {
            return false
        }
    }
}
