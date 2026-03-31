import Foundation
import Photos
import Combine
import OSLog

private let log = Logger(subsystem: "com.syncmaster", category: "SyncEngine")

enum SyncStatus: Equatable {
    case idle
    case indexing                                          // server scanning its filesystem
    case scanning                                          // iOS diffing local library
    case uploading(current: Int, total: Int, filename: String)
    case paused
    case completed(uploaded: Int, skipped: Int, failed: Int)
    case failed(error: String)

    var isActive: Bool {
        switch self { case .indexing, .scanning, .uploading: return true; default: return false }
    }

    var displayText: String {
        switch self {
        case .idle: return "Ready to sync"
        case .indexing: return "Server indexing…"
        case .scanning: return "Scanning library…"
        case .uploading(let cur, let tot, _): return "Uploading \(cur) of \(tot)"
        case .paused: return "Paused"
        case .completed(let u, let s, let f): return "Done — \(u) uploaded, \(s) skipped, \(f) failed"
        case .failed(let e): return "Error: \(e)"
        }
    }
}

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var currentSession: SyncSession?
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var syncedCount: Int = UserDefaults.standard.integer(forKey: "sm_syncedCount") {
        didSet { UserDefaults.standard.set(syncedCount, forKey: "sm_syncedCount") }
    }
    @Published private(set) var serverFileCount: Int = UserDefaults.standard.integer(forKey: "sm_serverFileCount") {
        didSet { UserDefaults.standard.set(serverFileCount, forKey: "sm_serverFileCount") }
    }
    /// Identifiers of assets that failed to upload during the most recent sync session.
    @Published private(set) var failedIdentifiers: Set<String> = []

    private let settings: SyncSettings
    private let networkMonitor: NetworkMonitor
    let mediaLibrary: MediaLibraryService
    private let tracker: IncrementalTracker
    let apiClient: SyncAPIClient
    private let exporter: AssetExporter
    private var syncTask: Task<Void, Never>?
    /// Local cache of uploaded identifiers — used to reapply states when allAssets reloads.
    private var uploadedIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    /// Prevents concurrent calls to refreshAndIndexIfNeeded / refreshSyncedCountFromServer.
    private var isRefreshing = false

    init(settings: SyncSettings, networkMonitor: NetworkMonitor,
         mediaLibrary: MediaLibraryService, tracker: IncrementalTracker,
         apiClient: SyncAPIClient, exporter: AssetExporter) {
        self.settings = settings; self.networkMonitor = networkMonitor
        self.mediaLibrary = mediaLibrary; self.tracker = tracker
        self.apiClient = apiClient; self.exporter = exporter

        // Re-apply upload states whenever the library reloads (e.g. user taps refresh).
        mediaLibrary.$allAssets
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.mediaLibrary.applyUploadStates(self.uploadedIDs)
            }
            .store(in: &cancellables)
    }

    func refreshSyncedCount() async {
        syncedCount = await tracker.syncedAssetCount()
    }

    func refreshSyncedCountFromServer() async {
        guard networkMonitor.serverReachable else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let manifest = try await apiClient.fetchManifest()
            log.info("Manifest fetched: \(manifest.files.count, privacy: .public) file(s) for this device folder")
            await tracker.reconcileWithServer(identifiers: manifest.files.map { $0.identifier })
            syncedCount = manifest.files.filter { isConfirmedAsset($0) }.count
            serverFileCount = manifest.files.filter { isConfirmedAsset($0) }.count
            log.info("serverFileCount updated to \(self.serverFileCount, privacy: .public)")
            uploadedIDs = await tracker.uploadedIdentifiers()
            mediaLibrary.applyUploadStates(uploadedIDs)
        } catch {
            log.error("Failed to fetch server manifest: \(String(describing: error), privacy: .public)")
        }
    }

    func refreshAndIndexIfNeeded() async {
        log.info("refreshAndIndexIfNeeded called (serverFileCount=\(self.serverFileCount, privacy: .public))")
        guard networkMonitor.serverReachable else { return }
        guard !status.isActive, !isRefreshing else { return }
        if serverFileCount == 0 {
            do {
                let result = try await apiClient.indexServerFiles()
                log.info("Server index: \(result.indexed, privacy: .public) new, \(result.alreadyKnown, privacy: .public) known")
            } catch {
                log.error("indexServerFiles failed: \(String(describing: error), privacy: .public)")
            }
        }
        await refreshSyncedCountFromServer()
    }

    /// True for manifest entries that represent a confirmed iOS asset —
    /// excludes live-photo video components and server-indexed placeholders.
    private func isConfirmedAsset(_ file: ManifestFile) -> Bool {
        !file.identifier.hasSuffix("-video") && !file.identifier.hasPrefix("__indexed__")
    }

    func startSync() async {
        guard !status.isActive else { return }
        guard networkMonitor.isConnected else { status = .failed(error: "No network"); return }
        guard networkMonitor.serverReachable else { status = .failed(error: "Server unreachable"); return }
        guard settings.serverURL != nil else { status = .failed(error: "No server configured"); return }
        syncTask = Task { await performSync() }
    }

    /// Runs sync to completion and awaits the result.
    /// Used by background task handlers that need to know when sync is truly done.
    func startSyncAndWait() async {
        guard !status.isActive else {
            await syncTask?.value; return
        }
        guard networkMonitor.isConnected else { status = .failed(error: "No network"); return }
        guard settings.serverURL != nil else { status = .failed(error: "No server configured"); return }
        await performSync()
    }

    func pauseSync() {
        syncTask?.cancel(); syncTask = nil
        if status.isActive { status = .paused }
    }

    func stopSync() {
        syncTask?.cancel(); syncTask = nil
        status = .idle; currentSession = nil; overallProgress = 0
    }

    func resetSyncRecords() async {
        let inflightTask = syncTask
        stopSync()
        // Wait for the cancelled sync to fully exit before touching the tracker,
        // so there's no race between tracker.reset() and tracker.markUploaded().
        await inflightTask?.value
        await tracker.reset()
        failedIdentifiers = []
        // Index the server filesystem before reading counts — ensures any files already on
        // disk are reflected in the manifest even if the manifest DB was previously cleared.
        _ = try? await apiClient.indexServerFiles()
        await refreshSyncedCountFromServer()
    }

    // MARK: - Pipeline

    private func performSync() async {
        log.info("▶ Sync started")
        failedIdentifiers = []
        var session = SyncSession(startedAt: Date())
        currentSession = session
        status = .scanning

        do {
            // Index the server's filesystem first so any files already on disk (but not yet
            // in the manifest) are discovered before we decide what needs uploading.
            // This ensures "Backed Up" is accurate even after a sync reset.
            status = .indexing
            if let result = try? await apiClient.indexServerFiles() {
                log.info("Server index: \(result.indexed) new file(s) found, \(result.alreadyKnown) already known")
            }

            // Ask server to prune entries for files deleted from disk, then fetch fresh manifest.
            if networkMonitor.serverReachable,
               let pruned = try? await apiClient.reconcileServerManifest(), pruned > 0 {
                log.info("Server reconcile: pruned \(pruned) stale manifest entry(s)")
            }

            // Reconcile local tracker with server manifest — server is source of truth.
            await tracker.preload()
            if let manifest = try? await apiClient.fetchManifest() {
                log.info("Server manifest: \(manifest.count) file(s) already on server")
                await tracker.reconcileWithServer(identifiers: manifest.files.map { $0.identifier })
                syncedCount = manifest.files.filter { isConfirmedAsset($0) }.count
                serverFileCount = manifest.files.filter { isConfirmedAsset($0) }.count
                uploadedIDs = await tracker.uploadedIdentifiers()
                mediaLibrary.applyUploadStates(uploadedIDs)
            } else {
                log.warning("Could not fetch server manifest — using local tracker")
                syncedCount = await tracker.syncedAssetCount()
                uploadedIDs = await tracker.uploadedIdentifiers()
                mediaLibrary.applyUploadStates(uploadedIDs)
            }
            let baseSyncedCount = syncedCount
            // Build a sha256 index of everything already on the server.
            // Used to skip file transfers for content that's already stored
            // (e.g. same photo under a different identifier after reinstall).
            let serverSHA256s: Set<String>
            if let manifest = try? await apiClient.fetchManifest() {
                serverSHA256s = Set(manifest.files.map { $0.sha256 })
            } else {
                serverSHA256s = []
            }
            var syncedInSession = 0

            // Fetch and enumerate off the main thread to avoid PHAssetOriginalMetadataProperties warnings.
            let allAssets: [PHAsset] = await Task.detached(priority: .userInitiated) {
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
                let result = PHAsset.fetchAssets(with: opts)
                var assets: [PHAsset] = []
                assets.reserveCapacity(result.count)
                result.enumerateObjects { a, _, _ in assets.append(a) }
                return assets
            }.value
            log.info("Photo library: \(allAssets.count) total asset(s)")

            // Diff — use the already-fetched uploadedIDs for a single-pass check off the main actor,
            // avoiding thousands of per-asset actor hops that would block the run loop.
            // Sort: photos (including live photos) before videos so large video files don't
            // block progress during short background execution windows.
            guard !Task.isCancelled else { return }
            let localUploadedIDs = uploadedIDs
            let toUpload: [PHAsset] = await Task.detached(priority: .userInitiated) {
                let pending = allAssets.filter { asset in
                    let isLive = asset.mediaSubtypes.contains(.photoLive)
                    return !localUploadedIDs.contains(asset.localIdentifier) ||
                           (isLive && !localUploadedIDs.contains(asset.localIdentifier + "-video"))
                }
                return pending.filter { $0.mediaType != .video } + pending.filter { $0.mediaType == .video }
            }.value
            guard !Task.isCancelled else { return }
            log.info("Diff complete: \(toUpload.count) asset(s) need uploading")
            session.totalAssets = toUpload.count
            currentSession = session

            var uploaded = 0, skipped = 0, failed = 0
            var bytesTotal: Int64 = 0
            var consecutiveNetworkFailures = 0

            for (idx, asset) in toUpload.enumerated() {
                if Task.isCancelled { break }

                // Abort if the server has been consistently unreachable — avoids
                // burning through hundreds of assets with timeout failures.
                if consecutiveNetworkFailures >= 3 {
                    log.warning("■ Aborting sync — server unreachable after \(consecutiveNetworkFailures) consecutive network failures")
                    status = .failed(error: "Server unreachable — sync will resume when server is back online")
                    return
                }

                let (mediaType, name) = await Task.detached(priority: .userInitiated) {
                    let type = MediaLibraryService.detectMediaType(for: asset)
                    let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "media"
                    return (type, name)
                }.value
                if Task.isCancelled { break }
                log.info("[\(idx + 1)/\(toUpload.count)] Exporting \(name) (\(mediaType.rawValue))")
                status = .uploading(current: idx + 1, total: toUpload.count, filename: name)
                overallProgress = Double(idx) / Double(max(toUpload.count, 1))

                // Retry each asset up to 3 times before counting it as failed.
                // Backoff: 5 s after attempt 1, 15 s after attempt 2.
                struct UploadResult {
                    let file: ExportedFile; let uploadID: String; let deduplicated: Bool
                }
                var lastError: Error? = nil
                var attempts = 0
                for attempt in 1...3 {
                    if Task.isCancelled { break }
                    do {
                        let files = try await exporter.export(asset: asset, mediaType: mediaType)
                        log.info("  Exported \(files.count) file(s) for \(name) (attempt \(attempt))")
                        defer { files.forEach { if let url = $0.url { exporter.cleanupTempFile(at: url) } } }

                        // Upload all files for this asset; accumulate results before marking the
                        // tracker so a partial failure doesn't permanently hide the asset.
                        var results: [UploadResult] = []
                        for file in files {
                            if Task.isCancelled { break }
                            let isLiveVideo = file.mediaType == .livePhotoVideo
                            let uploadID = asset.localIdentifier + (isLiveVideo ? "-video" : "")

                            // If the server already has this exact content (sha256 match),
                            // register the identifier without transferring any file bytes.
                            if serverSHA256s.contains(file.sha256) {
                                log.info("  ↩ Content already on server — registering \(file.filename) (no transfer)")
                                let registered = await apiClient.registerFile(
                                    identifier: uploadID, sha256: file.sha256,
                                    filename: file.filename, mediaType: file.mediaType,
                                    creationDate: asset.creationDate, sizeBytes: file.sizeBytes)
                                if registered {
                                    results.append(UploadResult(file: file, uploadID: uploadID,
                                                                deduplicated: true))
                                    continue
                                }
                                // Register failed (server may no longer have it) — fall through to full upload.
                                log.warning("  Register failed for \(file.filename) — falling back to upload")
                            }

                            log.info("  Uploading \(file.filename) (\(file.sizeBytes) bytes)")
                            guard let contentStream = file.openContentStream() else {
                                throw ExportError.exportFailed("No content stream for \(file.filename)")
                            }
                            let response = try await apiClient.uploadFile(
                                contentStream: contentStream, identifier: uploadID,
                                filename: file.filename, mediaType: file.mediaType,
                                creationDate: asset.creationDate,
                                sha256: file.sha256, sizeBytes: file.sizeBytes)
                            results.append(UploadResult(file: file, uploadID: uploadID,
                                                        deduplicated: response.deduplicated))
                        }

                        // Only mark tracker after ALL files for this asset succeed.
                        if !Task.isCancelled {
                            for r in results {
                                if r.deduplicated {
                                    skipped += 1
                                    log.info("  ↩ Deduplicated: \(r.file.filename)")
                                } else {
                                    uploaded += 1
                                    bytesTotal += r.file.sizeBytes
                                    log.info("  ✓ Uploaded: \(r.file.filename)")
                                }
                                await tracker.markUploaded(
                                    identifier: r.uploadID, filename: r.file.filename,
                                    sha256: r.file.sha256, sizeBytes: r.file.sizeBytes,
                                    mediaType: r.file.mediaType,
                                    serverURL: settings.serverURL?.absoluteString ?? "",
                                    modificationDate: asset.modificationDate)
                                uploadedIDs.insert(r.uploadID)
                            }
                            // Update the library item immediately so the UI reflects the change.
                            mediaLibrary.markUploaded(id: asset.localIdentifier)
                            syncedInSession += 1
                            syncedCount = baseSyncedCount + syncedInSession
                        }
                        lastError = nil
                        break // success — exit retry loop
                    } catch {
                        lastError = error
                        attempts = attempt
                        let wasCancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                        if wasCancelled { break }
                        if attempt < 3 {
                            let delay: UInt64 = attempt == 1 ? 5_000_000_000 : 15_000_000_000
                            log.warning("  ⚠ Attempt \(attempt)/3 failed for \(name, privacy: .public): \(String(describing: error), privacy: .public) — retrying in \(attempt == 1 ? 5 : 15)s")
                            try? await Task.sleep(nanoseconds: delay)
                        }
                    }
                }
                if let error = lastError {
                    failed += 1
                    failedIdentifiers.insert(asset.localIdentifier)
                    log.error("  ✗ Failed \(name, privacy: .public) (type: \(mediaType.rawValue, privacy: .public)) after \(attempts) attempt(s): \(String(describing: error), privacy: .public)")
                    let isNetworkError = (error as? URLError).map {
                        [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains($0.code)
                    } ?? false
                    if isNetworkError { consecutiveNetworkFailures += 1 } else { consecutiveNetworkFailures = 0 }
                } else {
                    consecutiveNetworkFailures = 0
                }

                session.uploadedCount = uploaded
                session.skippedCount = skipped
                session.failedCount = failed
                session.bytesTransferred = bytesTotal
                currentSession = session
            }

            guard !Task.isCancelled else { return }
            log.info("■ Sync complete — uploaded: \(uploaded), skipped: \(skipped), failed: \(failed)")

            // Completeness audit: log how many assets from the full library are now on the server.
            let totalLib = allAssets.count
            let coverage = syncedCount
            let remaining = max(0, totalLib - coverage)
            if remaining > 0 {
                log.warning("■ Coverage: \(coverage)/\(totalLib) — \(remaining) asset(s) not yet on server")
            } else {
                log.info("■ Coverage: \(coverage)/\(totalLib) — library fully backed up ✓")
            }

            try? await apiClient.recordSyncSession(
                sessionId: session.id, startedAt: session.startedAt, completedAt: Date(),
                uploaded: uploaded, skipped: skipped, failed: failed, bytes: bytesTotal)

            settings.lastSyncDate = Date()
            session.completedAt = Date()
            currentSession = session
            status = .completed(uploaded: uploaded, skipped: skipped, failed: failed)
            overallProgress = 1.0
            await apiClient.invalidateSession()   // release URLSession resources when idle

            // If any assets failed, schedule a retry in 15 min; otherwise use the normal 1-hour cadence.
            if failed > 0 {
                BackgroundSyncScheduler.shared.scheduleAggressiveRetry()
            } else {
                BackgroundSyncScheduler.shared.scheduleNextSync()
            }

        } catch {
            log.error("✗ Sync failed: \(String(describing: error), privacy: .public)")
            status = .failed(error: error.localizedDescription)
        }
    }
}
