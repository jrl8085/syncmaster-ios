import Foundation
import Combine

@MainActor
final class SyncSettings: ObservableObject {
    private let keychain: KeychainService

    @Published var serverHost: String = "" {
        didSet { UserDefaults.standard.set(serverHost, forKey: Keys.serverHost) }
    }
    @Published var serverPort: Int = 8443 {
        didSet { UserDefaults.standard.set(serverPort, forKey: Keys.serverPort) }
    }
    @Published var sslFingerprint: String = "" {
        didSet { UserDefaults.standard.set(sslFingerprint, forKey: Keys.sslFingerprint) }
    }
    @Published var autoSyncEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: Keys.autoSyncEnabled) }
    }
    @Published var wifiOnlySync: Bool = true {
        didSet { UserDefaults.standard.set(wifiOnlySync, forKey: Keys.wifiOnlySync) }
    }
    @Published var syncOnCharging: Bool = false {
        didSet { UserDefaults.standard.set(syncOnCharging, forKey: Keys.syncOnCharging) }
    }
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date, forKey: Keys.lastSyncDate)
            }
        }
    }
    @Published var hasCompletedOnboarding: Bool = false {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    var serverURL: URL? {
        guard !serverHost.isEmpty else { return nil }
        return URL(string: "https://\(serverHost):\(serverPort)")
    }

    var apiKey: String {
        get { keychain.retrieve(key: KeychainService.Keys.apiKey) ?? "" }
        set { keychain.store(key: KeychainService.Keys.apiKey, value: newValue) }
    }

    init(keychain: KeychainService) {
        self.keychain = keychain
        loadFromDefaults()
    }

    private func loadFromDefaults() {
        let d = UserDefaults.standard
        serverHost = d.string(forKey: Keys.serverHost) ?? ""
        let port = d.integer(forKey: Keys.serverPort)
        serverPort = port == 0 ? 8443 : port
        sslFingerprint = d.string(forKey: Keys.sslFingerprint) ?? ""
        autoSyncEnabled = d.bool(forKey: Keys.autoSyncEnabled)
        wifiOnlySync = d.object(forKey: Keys.wifiOnlySync) as? Bool ?? true
        syncOnCharging = d.bool(forKey: Keys.syncOnCharging)
        lastSyncDate = d.object(forKey: Keys.lastSyncDate) as? Date
        hasCompletedOnboarding = d.bool(forKey: Keys.hasCompletedOnboarding)
    }

    private enum Keys {
        static let serverHost = "serverHost"
        static let serverPort = "serverPort"
        static let sslFingerprint = "sslFingerprint"
        static let autoSyncEnabled = "autoSyncEnabled"
        static let wifiOnlySync = "wifiOnlySync"
        static let syncOnCharging = "syncOnCharging"
        static let lastSyncDate = "lastSyncDate"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
}
