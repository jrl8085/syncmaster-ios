import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    private init() {
        let model = Self.buildModel()
        container = NSPersistentContainer(name: "syncmaster", managedObjectModel: model)

        let storeURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("syncmaster.sqlite")

        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]

        container.loadPersistentStores { _, error in
            if let error { fatalError("CoreData load failed: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }

    private static func buildModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "SMUploadRecord"
        entity.managedObjectClassName = NSStringFromClass(SMUploadRecord.self)

        func attr(_ name: String, type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name; a.attributeType = type; a.isOptional = optional
            return a
        }

        entity.properties = [
            attr("identifier", type: .stringAttributeType),
            attr("filename", type: .stringAttributeType),
            attr("sha256", type: .stringAttributeType),
            attr("uploadedAt", type: .dateAttributeType),
            attr("sizeBytes", type: .integer64AttributeType),
            attr("mediaTypeRaw", type: .stringAttributeType),
            attr("serverURL", type: .stringAttributeType),
            attr("modificationDate", type: .dateAttributeType, optional: true)
        ]
        model.entities = [entity]
        return model
    }
}

@objc(SMUploadRecord)
final class SMUploadRecord: NSManagedObject {
    @NSManaged var identifier: String
    @NSManaged var filename: String
    @NSManaged var sha256: String
    @NSManaged var uploadedAt: Date
    @NSManaged var sizeBytes: Int64
    @NSManaged var mediaTypeRaw: String
    @NSManaged var serverURL: String
    @NSManaged var modificationDate: Date?

    static func fetchRequest() -> NSFetchRequest<SMUploadRecord> {
        NSFetchRequest<SMUploadRecord>(entityName: "SMUploadRecord")
    }

    static func entity(in context: NSManagedObjectContext) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: "SMUploadRecord", in: context)!
    }
}
