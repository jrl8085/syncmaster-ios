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
    /// Non-nil when the file was written to a temp file on disk.
    let url: URL?
    let filename: String
    let sha256: String
    let sizeBytes: Int64
    let mediaType: MediaType
    /// Non-nil in streaming mode — creates a fresh InputStream from the Photos resource
    /// without requiring any disk space.
    private let _resource: PHAssetResource?

    init(url: URL, filename: String, sha256: String, sizeBytes: Int64, mediaType: MediaType) {
        self.url = url; self.filename = filename; self.sha256 = sha256
        self.sizeBytes = sizeBytes; self.mediaType = mediaType; self._resource = nil
    }

    init(resource: PHAssetResource, filename: String, sha256: String, sizeBytes: Int64, mediaType: MediaType) {
        self.url = nil; self.filename = filename; self.sha256 = sha256
        self.sizeBytes = sizeBytes; self.mediaType = mediaType; self._resource = resource
    }

    /// Returns a fresh InputStream for the file's raw bytes (no multipart framing).
    /// Callers must open the stream. For disk-backed files this reads the temp file;
    /// for streaming files it pipes directly from the Photos resource manager.
    func openContentStream() -> InputStream? {
        if let url { return InputStream(url: url) }
        guard let resource = _resource else { return nil }
        return AssetExporter.makeResourceStream(for: resource)
    }
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
            do {
                try await writeResource(resource, to: dest)
                let (sha, size) = try hashAndSize(dest)
                return ExportedFile(url: dest, filename: filename, sha256: sha, sizeBytes: size,
                                    mediaType: mediaType)
            } catch {
                // Disk full or write error — fall back to streaming mode which reads directly
                // from the Photos resource manager without writing anything to device storage.
                log.warning("writeResource failed (\(error.localizedDescription, privacy: .public)) — switching to streaming mode for \(filename, privacy: .public)")
                try? FileManager.default.removeItem(at: dest)
                let (sha, size) = try await hashFromResource(resource)
                return ExportedFile(resource: resource, filename: filename, sha256: sha, sizeBytes: size,
                                    mediaType: mediaType)
            }
        }

        // Fallback: AVAssetExportSession passthrough
        return try await withCheckedThrowingContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            opts.version = .original
            PHImageManager.default().requestExportSession(
                forVideo: asset, options: opts, exportPreset: AVAssetExportPresetPassthrough
            ) { exportSession, _ in
                guard let exportSession else {
                    cont.resume(throwing: ExportError.exportFailed("No export session")); return
                }
                // Prefer mp4 container; fall back to mov if unsupported.
                let outputType: AVFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
                let ext = outputType == .mp4 ? "mp4" : "mov"
                let filename = "video_\(id).\(ext)"
                let dest = self.tempDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                exportSession.outputURL = dest
                exportSession.outputFileType = outputType
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

    // MARK: - Streaming (no disk writes)

    /// Computes SHA-256 and byte count from a PHAssetResource using in-memory chunks.
    /// Does not write anything to disk — safe even when the device is full.
    private func hashFromResource(_ resource: PHAssetResource) async throws -> (sha256: String, sizeBytes: Int64) {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            var hasher = SHA256()
            var size: Int64 = 0
            PHAssetResourceManager.default().requestData(for: resource, options: opts) { chunk in
                hasher.update(data: chunk)
                size += Int64(chunk.count)
            } completionHandler: { error in
                if let error {
                    cont.resume(throwing: ExportError.exportFailed(error.localizedDescription))
                    return
                }
                let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                cont.resume(returning: (hex, size))
            }
        }
    }

    /// Creates an InputStream that pipes data from PHAssetResourceManager.requestData
    /// directly via a bound stream pair — zero disk writes.
    static func makeResourceStream(for resource: PHAssetResource) -> InputStream {
        var readRef: Unmanaged<CFReadStream>?
        var writeRef: Unmanaged<CFWriteStream>?
        CFStreamCreateBoundPair(kCFAllocatorDefault, &readRef, &writeRef, 256 * 1024)
        let inStream  = readRef!.takeRetainedValue()  as InputStream
        let outStream = writeRef!.takeRetainedValue() as OutputStream
        inStream.open()
        outStream.open()

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().requestData(for: resource, options: opts) { chunk in
            chunk.withUnsafeBytes { buf in
                guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var off = 0, rem = chunk.count
                while rem > 0 {
                    let n = outStream.write(ptr.advanced(by: off), maxLength: rem)
                    guard n > 0 else { return }
                    off += n; rem -= n
                }
            }
        } completionHandler: { _ in
            outStream.close()
        }
        return inStream
    }

    // MARK: - Disk helpers

    private func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { err in
                if let err {
                    log.error("writeResource failed for \(resource.originalFilename, privacy: .public): \(err.localizedDescription, privacy: .public) [\(String(describing: err), privacy: .public)]")
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
