import Foundation
import Photos

enum MediaType: String, Codable {
    case photo
    case video
    case livePhotoImage = "live_photo_image"
    case livePhotoVideo = "live_photo_video"
    case raw
    case proRes = "prores"
    case slowMo = "slow_mo"
    case burst
    case depthEffect = "depth_effect"

    var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        case .livePhotoImage, .livePhotoVideo: return "Live Photo"
        case .raw: return "RAW"
        case .proRes: return "ProRes"
        case .slowMo: return "Slow-Mo"
        case .burst: return "Burst"
        case .depthEffect: return "Portrait"
        }
    }
}

enum UploadState: Equatable {
    case pending
    case uploading(progress: Double)
    case uploaded
    case failed(error: String)
    case skipped
}

struct MediaItem: Identifiable {
    let id: String
    let asset: PHAsset
    let mediaType: MediaType
    var uploadState: UploadState = .pending

    var creationDate: Date? { asset.creationDate }
    var modificationDate: Date? { asset.modificationDate }
    var isVideo: Bool { asset.mediaType == .video }

    var isPending: Bool {
        if case .pending = uploadState { return true }
        return false
    }
    var isUploaded: Bool {
        if case .uploaded = uploadState { return true }
        return false
    }
    var isUploading: Bool {
        if case .uploading = uploadState { return true }
        return false
    }
    var uploadProgress: Double {
        if case .uploading(let p) = uploadState { return p }
        return 0
    }
}

struct SyncSession: Identifiable {
    let id = UUID()
    let startedAt: Date
    var completedAt: Date?
    var totalAssets: Int = 0
    var uploadedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var bytesTransferred: Int64 = 0

    var progress: Double {
        guard totalAssets > 0 else { return 0 }
        return Double(uploadedCount + skippedCount) / Double(totalAssets)
    }
}
