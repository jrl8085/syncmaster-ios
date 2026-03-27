import Foundation
import Photos
import Combine

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

    // MARK: - Pipeline

    private func performSync() async {
        var session = SyncSession(startedAt: Date())
        currentSession = session
        status = .scanning

        do {
            // Backfill from server manifest
            if let manifest = try? await apiClient.fetchManifest() {
                await tracker.backfillFromServer(identifiers: manifest.files.map { $0.identifier })
            }
            await tracker.preload()

            // Fetch all assets
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            let fetchResult = await Task.detached(priority: .userInitiated) {
                PHAsset.fetchAssets(with: opts)
            }.value

            var allAssets: [PHAsset] = []
            fetchResult.enumerateObjects { a, _, _ in allAssets.append(a) }

            // Diff
            var toUpload: [PHAsset] = []
            for asset in allAssets {
                if Task.isCancelled { break }
                if !(await tracker.isUploaded(identifier: asset.localIdentifier)) {
                    toUpload.append(asset)
                }
            }

            guard !Task.isCancelled else { status = .paused; return }
            session.totalAssets = toUpload.count
            currentSession = session

            var uploaded = 0, skipped = 0, failed = 0
            var bytesTotal: Int64 = 0

            for (idx, asset) in toUpload.enumerated() {
                if Task.isCancelled { break }

                let mediaType = mediaLibrary.detectMediaType(for: asset)
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "media"
                status = .uploading(current: idx + 1, total: toUpload.count, filename: name)
                overallProgress = Double(idx) / Double(max(toUpload.count, 1))

                do {
                    let files = try await exporter.export(asset: asset, mediaType: mediaType)
                    for file in files {
                        if Task.isCancelled { break }
                        let isLiveVideo = file.mediaType == .livePhotoVideo
                        let uploadID = asset.localIdentifier + (isLiveVideo ? "-video" : "")
                        let response = try await apiClient.uploadFile(
                            fileURL: file.url, identifier: uploadID,
                            filename: file.filename, mediaType: file.mediaType,
                            creationDate: asset.creationDate,
                            sha256: file.sha256, sizeBytes: file.sizeBytes)

                        if response.deduplicated { skipped += 1 } else { uploaded += 1; bytesTotal += file.sizeBytes }
                        await tracker.markUploaded(identifier: uploadID, filename: file.filename,
                            sha256: file.sha256, sizeBytes: file.sizeBytes,
                            mediaType: file.mediaType,
                            serverURL: settings.serverURL?.absoluteString ?? "",
                            modificationDate: asset.modificationDate)
                        exporter.cleanupTempFile(at: file.url)
                    }
                } catch { failed += 1 }

                session.uploadedCount = uploaded
                session.skippedCount = skipped
                session.failedCount = failed
                session.bytesTransferred = bytesTotal
                currentSession = session
            }

            try? await apiClient.recordSyncSession(
                sessionId: session.id, startedAt: session.startedAt, completedAt: Date(),
                uploaded: uploaded, skipped: skipped, failed: failed, bytes: bytesTotal)

            settings.lastSyncDate = Date()
            session.completedAt = Date()
            currentSession = session
            status = .completed(uploaded: uploaded, skipped: skipped, failed: failed)
            overallProgress = 1.0
            BackgroundSyncScheduler.shared.scheduleNextSync()

        } catch {
            status = .failed(error: error.localizedDescription)
        }
    }
}
