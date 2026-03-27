import Foundation
import Combine

@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let settings: SyncSettings
    let networkMonitor: NetworkMonitor
    let mediaLibrary: MediaLibraryService
    let syncEngine: SyncEngine
    let keychain: KeychainService

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let keychain = KeychainService()
        let settings = SyncSettings(keychain: keychain)
        let networkMonitor = NetworkMonitor()
        let mediaLibrary = MediaLibraryService()
        let tracker = IncrementalTracker(persistenceController: PersistenceController.shared)
        let apiClient = SyncAPIClient(settings: settings, keychain: keychain)
        let exporter = AssetExporter()
        let syncEngine = SyncEngine(
            settings: settings,
            networkMonitor: networkMonitor,
            mediaLibrary: mediaLibrary,
            tracker: tracker,
            apiClient: apiClient,
            exporter: exporter
        )

        self.keychain = keychain
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.mediaLibrary = mediaLibrary
        self.syncEngine = syncEngine

        setupAutoSync()
    }

    private func setupAutoSync() {
        networkMonitor.$isConnectedToLocalNetwork
            .combineLatest(settings.$autoSyncEnabled)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] isLocal, autoEnabled in
                guard let self, autoEnabled, isLocal else { return }
                Task { await self.syncEngine.startSync() }
            }
            .store(in: &cancellables)
    }
}
