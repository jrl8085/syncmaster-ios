import Foundation
import OSLog

private let log = Logger(subsystem: "com.syncmaster", category: "SyncAPIClient")

enum APIError: LocalizedError {
    case noServerConfigured
    case unauthorized
    case serverError(Int, String)
    case networkError(Error)
    case invalidResponse
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .noServerConfigured: return "No server configured."
        case .unauthorized: return "Invalid API key."
        case .serverError(let c, let m): return "Server error \(c): \(m)"
        case .networkError(let e): return e.localizedDescription
        case .invalidResponse: return "Invalid server response."
        case .insufficientStorage: return "Server has insufficient storage."
        }
    }
}

struct HealthResponse: Decodable {
    let status: String
    let version: String
    let storagePath: String
    let storageFreeBytes: Int64
    enum CodingKeys: String, CodingKey {
        case status, version
        case storagePath = "storage_path"
        case storageFreeBytes = "storage_free_bytes"
    }
}

struct ManifestFile: Decodable {
    let identifier: String
    let sha256: String
    let sizeBytes: Int64
    let uploadedAt: String
    enum CodingKeys: String, CodingKey {
        case identifier, sha256
        case sizeBytes = "size_bytes"
        case uploadedAt = "uploaded_at"
    }
}

struct ManifestResponse: Decodable {
    let count: Int
    let files: [ManifestFile]
}

struct UploadResponse: Decodable {
    let status: String
    let identifier: String
    let storedPath: String
    let deduplicated: Bool
    enum CodingKeys: String, CodingKey {
        case status, identifier
        case storedPath = "stored_path"
        case deduplicated
    }
}

actor SyncAPIClient {
    private let settings: SyncSettings
    private let keychain: KeychainService
    private var _session: URLSession?

    init(settings: SyncSettings, keychain: KeychainService) {
        self.settings = settings
        self.keychain = keychain
    }

    // Rebuild session when fingerprint changes
    func invalidateSession() { _session = nil }

    private func session() async -> URLSession {
        if let s = _session { return s }
        let fp = await settings.sslFingerprint
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        let s = URLSession(configuration: cfg,
                           delegate: SSLPinningDelegate(fingerprint: fp),
                           delegateQueue: nil)
        _session = s
        return s
    }

    func healthCheck() async throws -> HealthResponse {
        try decode(HealthResponse.self, from: try await get("health"))
    }

    func fetchManifest(since: Date? = nil) async throws -> ManifestResponse {
        let folder = await settings.deviceFolder.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? ""
        var path = "manifest?device_folder=\(folder)"
        if let since {
            path += "&since=\(ISO8601DateFormatter().string(from: since))"
        }
        return try decode(ManifestResponse.self, from: try await get(path))
    }

    func uploadFile(
        fileURL: URL,
        identifier: String,
        filename: String,
        mediaType: MediaType,
        creationDate: Date?,
        sha256: String,
        sizeBytes: Int64
    ) async throws -> UploadResponse {
        guard let serverURL = await settings.serverURL else { throw APIError.noServerConfigured }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: serverURL.appendingPathComponent("upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(await settings.apiKey, forHTTPHeaderField: "X-API-Key")

        // Stream multipart body to a temp file to avoid loading large files into RAM.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: tempFile)

        func writeString(_ s: String) throws {
            try writer.write(contentsOf: Data(s.utf8))
        }
        let isoDate = creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        func writeField(_ name: String, _ value: String) throws {
            try writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        try writeField("identifier", identifier)
        try writeField("filename", filename)
        try writeField("media_type", mediaType.rawValue)
        try writeField("creation_date", isoDate)
        try writeField("sha256", sha256)
        try writeField("size_bytes", String(sizeBytes))
        try writeField("device_folder", await settings.deviceFolder)
        try writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")

        // Copy file payload in 1 MB chunks.
        let reader = try FileHandle(forReadingFrom: fileURL)
        let chunkSize = 1024 * 1024
        while true {
            let chunk = reader.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
        }
        try reader.close()
        try writeString("\r\n--\(boundary)--\r\n")
        try writer.close()

        let (data, response) = try await session().upload(for: req, fromFile: tempFile)
        try validateResponse(response, data: data)
        return try decode(UploadResponse.self, from: data)
    }

    /// Asks the server to scan its storage folder and index any untracked files.
    /// Returns (indexed, alreadyKnown) counts.
    func indexServerFiles() async throws -> (indexed: Int, alreadyKnown: Int) {
        let folder = await settings.deviceFolder
        let data = try await post("manifest/index", json: ["device_folder": folder])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0)
        }
        return (json["indexed"] as? Int ?? 0, json["already_known"] as? Int ?? 0)
    }

    /// Attempts to register an identifier against an already-stored file (by sha256).
    /// Returns true if the server confirmed it has the file and created a manifest entry.
    /// No file bytes are transferred.
    func registerFile(
        identifier: String,
        sha256: String,
        filename: String,
        mediaType: MediaType,
        creationDate: Date?,
        sizeBytes: Int64
    ) async -> Bool {
        let isoDate = creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        let body: [String: Any] = [
            "identifier": identifier,
            "sha256": sha256,
            "filename": filename,
            "media_type": mediaType.rawValue,
            "creation_date": isoDate,
            "size_bytes": sizeBytes,
            "device_folder": await settings.deviceFolder
        ]
        guard let data = try? await post("manifest/register", json: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registered = json["registered"] as? Bool else { return false }
        return registered
    }

    /// Tells the server to prune manifest entries whose files no longer exist on disk.
    /// Call at the start of sync so deleted-on-server assets are re-uploaded.
    func reconcileServerManifest() async throws -> Int {
        let folder = await settings.deviceFolder
        let data = try await post("manifest/reconcile", json: ["device_folder": folder])
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pruned = json["pruned"] as? Int { return pruned }
        return 0
    }

    func resetServerManifest() async throws {
        let folder = await settings.deviceFolder.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let serverURL = await settings.serverURL else { throw APIError.noServerConfigured }
        var req = URLRequest(url: serverURL.appendingPathComponent("manifest")
            .appending(queryItems: [URLQueryItem(name: "device_folder", value: folder)]))
        req.httpMethod = "DELETE"
        req.setValue(await settings.apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await session().data(for: req)
        try validateResponse(response, data: data)
    }

    func recordSyncSession(sessionId: UUID, startedAt: Date, completedAt: Date,
                           uploaded: Int, skipped: Int, failed: Int, bytes: Int64) async throws {
        let body: [String: Any] = [
            "session_id": sessionId.uuidString,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "completed_at": ISO8601DateFormatter().string(from: completedAt),
            "files_uploaded": uploaded, "skipped_duplicates": skipped,
            "errors": failed, "bytes_transferred": bytes
        ]
        _ = try await post("sync/complete", json: body)
    }

    // MARK: - Helpers

    private func get(_ path: String) async throws -> Data {
        guard let serverURL = await settings.serverURL else { throw APIError.noServerConfigured }
        var req = URLRequest(url: serverURL.appendingPathComponent(path))
        req.setValue(await settings.apiKey, forHTTPHeaderField: "X-API-Key")
        do {
            let (data, response) = try await session().data(for: req)
            try validateResponse(response, data: data)
            return data
        } catch let e as APIError { throw e
        } catch {
            log.error("GET \(path) failed: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
    }

    private func post(_ path: String, json: [String: Any]) async throws -> Data {
        guard let serverURL = await settings.serverURL else { throw APIError.noServerConfigured }
        var req = URLRequest(url: serverURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(await settings.apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session().data(for: req)
        try validateResponse(response, data: data)
        return data
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...201: return
        case 401, 403: throw APIError.unauthorized
        case 507: throw APIError.insufficientStorage
        default: throw APIError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.invalidResponse }
    }
}
