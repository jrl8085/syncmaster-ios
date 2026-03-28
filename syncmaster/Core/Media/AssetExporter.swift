import Foundation
@preconcurrency import Photos
import CryptoKit
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.syncmaster", category: "AssetExporter")

enum ExportError: LocalizedError {
    case exportFailed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .exportFailed(let m): return "Export failed: \(m)"
        case .cancelled: return "Export cancelled."
        }
    }
}

struct ExportedFile {
    let url: URL
    let filename: String
    let sha256: String
    let sizeBytes: Int64
    let mediaType: MediaType
}

final class AssetExporter {
    let tempDir: URL

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncmaster", isDirectory: true)
        // Remove any stale temp files left by a previous crash before starting fresh.
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func export(asset: PHAsset, mediaType: MediaType) async throws -> [ExportedFile] {
        switch asset.mediaType {
        case .image: return try await exportImage(asset: asset, mediaType: mediaType)
        case .video: return [try await exportVideo(asset: asset, mediaType: mediaType)]
        default: return []
        }
    }

    // MARK: - Helpers (background-thread resource access)

    /// Fetches asset resources on a background thread to avoid
    /// "Missing prefetched properties" warnings on the main queue.
    nonisolated private func fetchResources(for asset: PHAsset) async -> [PHAssetResource] {
        await Task.detached { PHAssetResource.assetResources(for: asset) }.value
    }

    // MARK: - Image

    private func exportImage(asset: PHAsset, mediaType: MediaType) async throws -> [ExportedFile] {
        var results: [ExportedFile] = []
        let resources = await fetchResources(for: asset)
        let id = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        log.debug("exportImage: \(resources.count) resource(s) for asset \(id)")

        if let primary = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            let filename = sanitize(primary.originalFilename)
            let dest = tempDir.appendingPathComponent("\(id)_\(filename)")
            try await writeResource(primary, to: dest)
            let (sha, size) = try hashAndSize(dest)
            results.append(ExportedFile(url: dest, filename: filename, sha256: sha, sizeBytes: size,
                                        mediaType: mediaType == .livePhotoImage ? .livePhotoImage : mediaType))
        }

        if mediaType == .livePhotoImage,
           let paired = resources.first(where: { $0.type == .pairedVideo }) {
            let filename = sanitize(paired.originalFilename)
            let dest = tempDir.appendingPathComponent("\(id)_live_\(filename)")
            try await writeResource(paired, to: dest)
            let (sha, size) = try hashAndSize(dest)
            results.append(ExportedFile(url: dest, filename: filename, sha256: sha, sizeBytes: size,
                                        mediaType: .livePhotoVideo))
        }
        return results
    }

    // MARK: - Video

    private func exportVideo(asset: PHAsset, mediaType: MediaType) async throws -> ExportedFile {
        let resources = await fetchResources(for: asset)
        let id = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        log.debug("exportVideo: \(resources.count) resource(s) for asset \(id)")

        if let resource = resources.first(where: { $0.type == .video }) {
            let filename = sanitize(resource.originalFilename)
            let dest = tempDir.appendingPathComponent("\(id)_\(filename)")
            try await writeResource(resource, to: dest)
            let (sha, size) = try hashAndSize(dest)
            return ExportedFile(url: dest, filename: filename, sha256: sha, sizeBytes: size, mediaType: mediaType)
        }

        // Fallback: AVAssetExportSession passthrough
        return try await withCheckedThrowingContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true  // allow iCloud download for cloud-only assets
            opts.deliveryMode = .highQualityFormat
            opts.version = .original
            PHImageManager.default().requestExportSession(
                forVideo: asset, options: opts, exportPreset: AVAssetExportPresetPassthrough
            ) { exportSession, _ in
                guard let exportSession else {
                    cont.resume(throwing: ExportError.exportFailed("No export session")); return
                }
                let filename = "video_\(id).mov"
                let dest = self.tempDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                exportSession.outputURL = dest
                exportSession.outputFileType = .mov
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        if let r = try? self.hashAndSize(dest) {
                            cont.resume(returning: ExportedFile(url: dest, filename: filename,
                                sha256: r.0, sizeBytes: r.1, mediaType: mediaType))
                        } else {
                            cont.resume(throwing: ExportError.exportFailed("Hash failed"))
                        }
                    case .cancelled: cont.resume(throwing: ExportError.cancelled)
                    default:
                        cont.resume(throwing: ExportError.exportFailed(
                            exportSession.error?.localizedDescription ?? "Unknown"))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true  // allow iCloud download for cloud-only assets
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { err in
                if let err {
                    log.error("writeResource failed for \(resource.originalFilename): \(err.localizedDescription)")
                    cont.resume(throwing: ExportError.exportFailed(err.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }

    func hashAndSize(_ url: URL) throws -> (String, Int64) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return (hash, size)
    }

    func cleanupTempFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func sanitize(_ name: String) -> String {
        let s = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
        return s.isEmpty ? "media_file" : s
    }
}
