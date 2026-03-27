import Foundation
import CoreData

actor IncrementalTracker {
    private let persistence: PersistenceController
    private var uploaded: Set<String> = []
    private var loaded = false

    init(persistenceController: PersistenceController) {
        self.persistence = persistenceController
    }

    func preload() async {
        guard !loaded else { return }
        let ctx = persistence.newBackgroundContext()
        // Collect identifiers inside the Sendable perform closure, then assign outside it
        let identifiers: Set<String> = await ctx.perform {
            let req = SMUploadRecord.fetchRequest()
            req.propertiesToFetch = ["identifier"]
            let records = (try? ctx.fetch(req)) ?? []
            return Set(records.map { $0.identifier })
        }
        uploaded = identifiers
        loaded = true
    }

    func isUploaded(identifier: String) async -> Bool {
        if !loaded { await preload() }
        return uploaded.contains(identifier)
    }

    func markUploaded(
        identifier: String,
        filename: String,
        sha256: String,
        sizeBytes: Int64,
        mediaType: MediaType,
        serverURL: String,
        modificationDate: Date?
    ) async {
        uploaded.insert(identifier)
        let ctx = persistence.newBackgroundContext()
        await ctx.perform {
            let r = SMUploadRecord(entity: SMUploadRecord.entity(in: ctx), insertInto: ctx)
            r.identifier = identifier
            r.filename = filename
            r.sha256 = sha256
            r.uploadedAt = Date()
            r.sizeBytes = sizeBytes
            r.mediaTypeRaw = mediaType.rawValue
            r.serverURL = serverURL
            r.modificationDate = modificationDate
            _ = try? ctx.save()
        }
    }

    func backfillFromServer(identifiers: [String]) async {
        for id in identifiers { uploaded.insert(id) }
    }

    func reset() async {
        uploaded.removeAll()
        let ctx = persistence.newBackgroundContext()
        await ctx.perform {
            let req = NSFetchRequest<NSFetchRequestResult>(entityName: "SMUploadRecord")
            _ = try? ctx.execute(NSBatchDeleteRequest(fetchRequest: req))
            _ = try? ctx.save()
        }
        loaded = false
    }

    func uploadedCount() async -> Int {
        if !loaded { await preload() }
        return uploaded.count
    }
}
