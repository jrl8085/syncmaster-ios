import Foundation

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
        var path = "manifest"
        if let since {
            path += "?since=\(ISO8601DateFormatter().string(from: since))"
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

        let isoDate = creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("identifier", identifier)
        field("filename", filename)
        field("media_type", mediaType.rawValue)
        field("creation_date", isoDate)
        field("sha256", sha256)
        field("size_bytes", String(sizeBytes))
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session().data(for: req)
        try validateResponse(response, data: data)
        return try decode(UploadResponse.self, from: data)
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
        } catch { throw APIError.networkError(error) }
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
