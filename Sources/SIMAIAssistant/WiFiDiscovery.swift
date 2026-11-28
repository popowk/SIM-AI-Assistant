import Foundation
import Network
import SIMAICore

/// Bonjour is only an address hint. A candidate becomes trusted exclusively
/// after the existing pinned TLS certificate and bearer secret are verified.
@MainActor
final class BonjourWiFiScanner: ObservableObject {
    @Published private(set) var candidates: [WiFiDiscoveryCandidate] = []
    private var browser: NWBrowser?

    init() { start() }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_simai._tcp", domain: "local."), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let candidates = results.compactMap { result -> WiFiDiscoveryCandidate? in
                guard case .bonjour(let txt) = result.metadata,
                      let ip = txt.dictionary["ipv4"], let pin = txt.dictionary["pin"] else { return nil }
                return WiFiDiscoveryCandidate(host: ip, pin: pin)
            }
            Task { @MainActor [weak self] in self?.candidates = Array(Set(candidates)).sorted { $0.host < $1.host } }
        }
        b.start(queue: .main)
        browser = b
    }
    deinit { browser?.cancel() }
}
