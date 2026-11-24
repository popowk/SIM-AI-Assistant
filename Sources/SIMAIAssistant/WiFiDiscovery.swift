import Foundation
import Network

@MainActor
final class BonjourWiFiScanner: ObservableObject {
    @Published var discoveredDeviceName: String? = nil
    private var browser: NWBrowser?

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
                        return
                    }
                }
            }
        }
        b.start(queue: .main)
        self.browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    deinit {
        browser?.cancel()
    }
}
