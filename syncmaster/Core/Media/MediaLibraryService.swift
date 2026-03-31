import Foundation
import Photos
import Combine

@MainActor
final class MediaLibraryService: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var allAssets: [MediaItem] = []
    @Published private(set) var isLoading = false
    private var isUpdatingStates = false

    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await loadAssets()
        }
        return status
    }

    func loadAssets() async {
        isLoading = true
        defer { isLoading = false }
        // Fetch and enumerate off the main thread so PHAssetResource access
        // doesn't trigger "Missing prefetched properties" warnings.
        // Only Sendable types (String, MediaType) cross the task boundary.
        let pairs: [(String, MediaType)] = await Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            let result = PHAsset.fetchAssets(with: opts)
            var pairs: [(String, MediaType)] = []
            pairs.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                pairs.append((asset.localIdentifier, MediaLibraryService.detectMediaType(for: asset)))
            }
            return pairs
        }.value
        // Re-fetch PHAsset handles on the main thread, preserving sort order.
        var byID: [String: PHAsset] = Dictionary(minimumCapacity: pairs.count)
        PHAsset.fetchAssets(withLocalIdentifiers: pairs.map(\.0), options: nil)
            .enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        allAssets = pairs.compactMap { id, type in
            byID[id].map { MediaItem(id: id, asset: $0, mediaType: type) }
        }
    }

    nonisolated static func detectMediaType(for asset: PHAsset) -> MediaType {
        if asset.mediaSubtypes.contains(.photoLive) { return .livePhotoImage }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { return .depthEffect }
        if asset.mediaType == .video {
            if asset.mediaSubtypes.contains(.videoHighFrameRate) { return .slowMo }
            let resources = PHAssetResource.assetResources(for: asset)
            let isProRes = resources.contains {
                $0.uniformTypeIdentifier.contains("prores") ||
                $0.uniformTypeIdentifier == "com.apple.quicktime-movie"
            }
            return isProRes ? .proRes : .video
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let isRaw = resources.contains {
            $0.uniformTypeIdentifier.contains("raw") ||
            $0.uniformTypeIdentifier == "com.adobe.raw-image" ||
            $0.uniformTypeIdentifier == "com.apple.rawimage"
        }
        return isRaw ? .raw : .photo
    }

    /// Updates every item's uploadState based on the set of uploaded identifiers from the tracker.
    func applyUploadStates(_ uploadedIdentifiers: Set<String>) {
        guard !isUpdatingStates else { return }
        isUpdatingStates = true
        defer { isUpdatingStates = false }
        // Single assignment so @Published only fires once, preventing the
        // SyncEngine sink from re-entering this method on every element mutation.
        allAssets = allAssets.map { item in
            var copy = item
            copy.uploadState = uploadedIdentifiers.contains(item.id) ? .uploaded : .pending
            return copy
        }
    }

    /// Marks a single item as uploaded (called in real-time during sync).
    func markUploaded(id: String) {
        guard !isUpdatingStates, let i = allAssets.firstIndex(where: { $0.id == id }) else { return }
        isUpdatingStates = true
        defer { isUpdatingStates = false }
        allAssets[i].uploadState = .uploaded
    }

    /// Deletes all user-owned assets from the device photo library.
    /// Shared Photo Library, shared album, and iTunes-synced assets are excluded —
    /// PhotoKit does not allow third-party apps to delete those.
    /// Returns nil on success, or an error message string on failure.
    func deleteAllAssets() async -> String? {
        // Only typeUserLibrary assets can be deleted by third-party apps.
        // Including typeCloudShared or typeiTunesSynced causes error 3300 for the entire batch.
        let opts = PHFetchOptions()
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        let result = PHAsset.fetchAssets(with: opts)
        guard result.count > 0 else { return nil }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(result)
            }
            await loadAssets()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var totalCount: Int { allAssets.count }
    var photoCount: Int { allAssets.filter { !$0.isVideo }.count }
    var videoCount: Int { allAssets.filter { $0.isVideo }.count }
}
