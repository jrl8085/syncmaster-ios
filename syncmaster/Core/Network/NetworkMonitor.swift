import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isWiFi = false
    @Published private(set) var isConnectedToLocalNetwork = false
    @Published private(set) var serverReachable = false

    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.syncmaster.network", qos: .utility)
    private var settings: SyncSettings?

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.isWiFi = path.usesInterfaceType(.wifi)
                self.isConnectedToLocalNetwork = self.isConnected && self.isWiFi
                if self.isConnectedToLocalNetwork {
                    await self.checkServerReachability()
                } else {
                    self.serverReachable = false
                }
            }
        }
        pathMonitor.start(queue: queue)
    }

    func configure(settings: SyncSettings) {
        self.settings = settings
    }

    func checkServerReachability() async {
        guard let settings, let url = settings.serverURL else {
            serverReachable = false
            return
        }
        do {
            var req = URLRequest(url: url.appendingPathComponent("health"))
            req.timeoutInterval = 3
            req.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
            let session = URLSession(configuration: .ephemeral,
                                     delegate: SSLPinningDelegate(fingerprint: settings.sslFingerprint),
                                     delegateQueue: nil)
            let (_, response) = try await session.data(for: req)
            serverReachable = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            serverReachable = false
        }
    }
}
