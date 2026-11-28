import Foundation
import Network

@MainActor
final class BonjourWiFiScanner: ObservableObject {
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
                    if case .service = result.endpoint {
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
