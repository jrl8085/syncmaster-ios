import Foundation
import Photos
import Combine

@MainActor
final class MediaLibraryService: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var allAssets: [MediaItem] = []
    @Published private(set) var isLoading = false

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
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        let result = PHAsset.fetchAssets(with: opts)
        var items: [MediaItem] = []
        result.enumerateObjects { asset, _, _ in
            items.append(MediaItem(id: asset.localIdentifier, asset: asset,
                                   mediaType: self.detectMediaType(for: asset)))
        }
        allAssets = items
    }

    func detectMediaType(for asset: PHAsset) -> MediaType {
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

    var totalCount: Int { allAssets.count }
    var uploadedCount: Int { allAssets.filter { $0.isUploaded }.count }
    var pendingCount: Int { allAssets.filter { $0.isPending }.count }
}
