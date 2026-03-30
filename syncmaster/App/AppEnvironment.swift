import Foundation
import Combine
import Photos
import UIKit

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

        networkMonitor.configure(settings: settings)
        setupAutoSync()
        Task { await syncEngine.refreshSyncedCount() }
        setupServerCountRefresh()
        setupCertAutoValidation()
        Task {
            // Wait for reachability to resolve then do an initial server count fetch.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.networkMonitor.serverReachable else { return }
            await self.syncEngine.refreshAndIndexIfNeeded()
        }
        // Populate photo/video counts immediately if permission was already granted.
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .authorized || authStatus == .limited {
            Task { await mediaLibrary.loadAssets() }
        }
    }

    private func setupServerCountRefresh() {
        // Fires every time the app becomes active AND the server is already reachable.
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.networkMonitor.serverReachable else { return }
                Task { await self.syncEngine.refreshAndIndexIfNeeded() }
            }
            .store(in: &cancellables)

        // Fires every time the server transitions to reachable (covers cold launch
        // where the active notification may have fired before reachability resolved).
        networkMonitor.$serverReachable
            .filter { $0 }
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.syncEngine.refreshAndIndexIfNeeded() }
            }
            .store(in: &cancellables)
    }

    private func setupCertAutoValidation() {
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let serverURL = self.settings.serverURL else { return }
                Task {
                    guard let fp = try? await FingerprintCapturingDelegate.capture(from: serverURL),
                          !fp.isEmpty, fp != self.settings.sslFingerprint else { return }
                    self.settings.sslFingerprint = fp
                    await self.syncEngine.apiClient.invalidateSession()
                }
            }
            .store(in: &cancellables)
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
