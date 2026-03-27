import Foundation
import Photos
import Combine
import OSLog

private let log = Logger(subsystem: "com.syncmaster", category: "SyncEngine")

enum SyncStatus: Equatable {
    case idle
    case scanning
    case uploading(current: Int, total: Int, filename: String)
    case paused
    case completed(uploaded: Int, skipped: Int, failed: Int)
    case failed(error: String)

    var isActive: Bool {
        switch self { case .scanning, .uploading: return true; default: return false }
    }

    var displayText: String {
        switch self {
        case .idle: return "Ready to sync"
        case .scanning: return "Scanning library…"
        case .uploading(let cur, let tot, let name): return "Uploading \(cur) of \(tot): \(name)"
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
    @Published private(set) var syncedCount: Int = 0

    private let settings: SyncSettings
    private let networkMonitor: NetworkMonitor
    let mediaLibrary: MediaLibraryService
    private let tracker: IncrementalTracker
    let apiClient: SyncAPIClient
    private let exporter: AssetExporter
    private var syncTask: Task<Void, Never>?

    init(settings: SyncSettings, networkMonitor: NetworkMonitor,
         mediaLibrary: MediaLibraryService, tracker: IncrementalTracker,
         apiClient: SyncAPIClient, exporter: AssetExporter) {
        self.settings = settings; self.networkMonitor = networkMonitor
        self.mediaLibrary = mediaLibrary; self.tracker = tracker
        self.apiClient = apiClient; self.exporter = exporter
    }

    func refreshSyncedCount() async {
        syncedCount = await tracker.syncedAssetCount()
    }

    func refreshSyncedCountFromServer() async {
        guard let manifest = try? await apiClient.fetchManifest() else { return }
        await tracker.reconcileWithServer(identifiers: manifest.files.map { $0.identifier })
        syncedCount = manifest.files.filter { !$0.identifier.hasSuffix("-video") }.count
    }

    func startSync() async {
        guard !status.isActive else { return }
        guard networkMonitor.isConnected else { status = .failed(error: "No network"); return }
        guard settings.serverURL != nil else { status = .failed(error: "No server configured"); return }
        syncTask = Task { await performSync() }
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
        stopSync()
        try? await apiClient.resetServerManifest()
        await tracker.reset()
        syncedCount = 0
    }

    // MARK: - Pipeline

    private func performSync() async {
        log.info("▶ Sync started")
        var session = SyncSession(startedAt: Date())
        currentSession = session
        status = .scanning

        do {
            // Ask server to prune entries for files deleted from disk, then fetch fresh manifest.
            if let pruned = try? await apiClient.reconcileServerManifest(), pruned > 0 {
                log.info("Server reconcile: pruned \(pruned) stale manifest entry(s)")
            }

            // Reconcile local tracker with server manifest — server is source of truth.
            await tracker.preload()
            if let manifest = try? await apiClient.fetchManifest() {
                log.info("Server manifest: \(manifest.count) file(s) already on server")
                await tracker.reconcileWithServer(identifiers: manifest.files.map { $0.identifier })
                syncedCount = manifest.files.filter { !$0.identifier.hasSuffix("-video") }.count
            } else {
                log.warning("Could not fetch server manifest — using local tracker")
                syncedCount = await tracker.syncedAssetCount()
            }
            let baseSyncedCount = syncedCount
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

            // Diff — for live photos both image AND video must be present to skip.
            var toUpload: [PHAsset] = []
            for asset in allAssets {
                if Task.isCancelled { break }
                let isLive = asset.mediaSubtypes.contains(.photoLive)
                if !(await tracker.isFullyUploaded(identifier: asset.localIdentifier, isLivePhoto: isLive)) {
                    toUpload.append(asset)
                }
            }

            guard !Task.isCancelled else { status = .paused; return }
            log.info("Diff complete: \(toUpload.count) asset(s) need uploading")
            session.totalAssets = toUpload.count
            currentSession = session

            var uploaded = 0, skipped = 0, failed = 0
            var bytesTotal: Int64 = 0

            for (idx, asset) in toUpload.enumerated() {
                if Task.isCancelled { break }

                let (mediaType, name) = await Task.detached(priority: .userInitiated) {
                    let type = MediaLibraryService.detectMediaType(for: asset)
                    let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "media"
                    return (type, name)
                }.value
                log.info("[\(idx + 1)/\(toUpload.count)] Exporting \(name) (\(mediaType.rawValue))")
                status = .uploading(current: idx + 1, total: toUpload.count, filename: name)
                overallProgress = Double(idx) / Double(max(toUpload.count, 1))

                do {
                    let files = try await exporter.export(asset: asset, mediaType: mediaType)
                    log.info("  Exported \(files.count) file(s) for \(name)")
                    defer { files.forEach { exporter.cleanupTempFile(at: $0.url) } }

                    // Upload all files for this asset; accumulate results before marking the tracker
                    // so a partial failure (e.g. live-photo video) doesn't permanently hide the asset.
                    struct UploadResult {
                        let file: ExportedFile; let uploadID: String; let deduplicated: Bool
                    }
                    var results: [UploadResult] = []
                    for file in files {
                        if Task.isCancelled { break }
                        let isLiveVideo = file.mediaType == .livePhotoVideo
                        let uploadID = asset.localIdentifier + (isLiveVideo ? "-video" : "")
                        log.info("  Uploading \(file.filename) (\(file.sizeBytes) bytes)")
                        let response = try await apiClient.uploadFile(
                            fileURL: file.url, identifier: uploadID,
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
                        }
                        syncedInSession += 1
                        syncedCount = baseSyncedCount + syncedInSession
                    }
                } catch {
                    failed += 1
                    log.error("  ✗ Failed \(name): \(error.localizedDescription)")
                }

                session.uploadedCount = uploaded
                session.skippedCount = skipped
                session.failedCount = failed
                session.bytesTransferred = bytesTotal
                currentSession = session
            }

            log.info("■ Sync complete — uploaded: \(uploaded), skipped: \(skipped), failed: \(failed)")
            try? await apiClient.recordSyncSession(
                sessionId: session.id, startedAt: session.startedAt, completedAt: Date(),
                uploaded: uploaded, skipped: skipped, failed: failed, bytes: bytesTotal)

            settings.lastSyncDate = Date()
            session.completedAt = Date()
            currentSession = session
            status = .completed(uploaded: uploaded, skipped: skipped, failed: failed)
            overallProgress = 1.0
            await apiClient.invalidateSession()   // release URLSession resources when idle
            BackgroundSyncScheduler.shared.scheduleNextSync()

        } catch {
            log.error("✗ Sync failed: \(error.localizedDescription)")
            status = .failed(error: error.localizedDescription)
        }
    }
}
