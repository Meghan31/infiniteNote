import Foundation
import UIKit
import GRDB

/// CRUD for placed page objects (rich-text boxes + photos). Metadata lives in
/// GRDB; photo bytes live on disk via `FileStorageManager`. Mirrors the
/// shared-singleton style of `DrawingService` / `CustomPenService`.
final class PageObjectService: @unchecked Sendable {
    static let shared = PageObjectService()

    private let db = DatabaseManager.shared
    private let storage = FileStorageManager.shared

    private init() {}

    // MARK: - Read

    func objects(for pageId: String) throws -> [PageObject] {
        try db.dbQueue.read { db in
            try PageObject.forPage(pageId).fetchAll(db)
        }
    }

    /// Highest z-index currently on the page (0 if empty) — callers add 1 to
    /// place a new object on top.
    func topZIndex(for pageId: String) throws -> Int {
        try db.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT MAX(z_index) FROM page_objects WHERE page_id = ?",
                arguments: [pageId]
            ) ?? 0
        }
    }

    // MARK: - Write

    @discardableResult
    func insert(_ object: PageObject) throws -> PageObject {
        var copy = object
        try db.dbQueue.write { db in try copy.insert(db) }
        return copy
    }

    func update(_ object: PageObject) throws {
        var copy = object
        copy.updatedAt = Date()
        try db.dbQueue.write { db in try copy.update(db) }
    }

    /// Persists a batch in one transaction — used when a move/resize/reorder
    /// touches several objects at once.
    func updateAll(_ objects: [PageObject]) throws {
        try db.dbQueue.write { db in
            for object in objects {
                var copy = object
                copy.updatedAt = Date()
                try copy.update(db)
            }
        }
    }

    func delete(_ object: PageObject, notebookId: String) throws {
        try db.dbQueue.write { db in _ = try object.delete(db) }
        if let file = object.imageFile {
            storage.deletePageObjectImage(notebookId: notebookId, fileName: file)
        }
    }

    /// Deletes ONLY the row, keeping the photo file on disk — so an undo can
    /// restore the object. (Orphan files are reclaimed when the page or
    /// notebook is deleted.)
    func deleteRow(_ object: PageObject) throws {
        try db.dbQueue.write { db in _ = try object.delete(db) }
    }

    /// Replaces every row for a page with `objects` in one transaction — used
    /// to restore an undo/redo snapshot.
    func replaceAll(forPage pageId: String, with objects: [PageObject]) throws {
        try db.dbQueue.write { db in
            try PageObject.filter(Column("page_id") == pageId).deleteAll(db)
            for var object in objects { try object.insert(db) }
        }
    }

    // MARK: - Photo helpers

    /// Saves photo bytes to disk and returns a fresh, unique filename to store
    /// on the object's `image_file`. Downsizes very large imports so a single
    /// photo can't bloat the notebook folder.
    func savePhoto(_ image: UIImage, notebookId: String) throws -> String {
        let prepared = Self.downsized(image, maxDimension: 2000)
        guard let data = prepared.jpegData(compressionQuality: 0.9) else {
            throw NSError(
                domain: "PageObjectService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the photo."]
            )
        }
        let fileName = "obj_\(UUID().uuidString).jpg"
        try storage.savePageObjectImage(data, notebookId: notebookId, fileName: fileName)
        return fileName
    }

    func loadPhoto(_ object: PageObject, notebookId: String) -> UIImage? {
        guard let file = object.imageFile else { return nil }
        return storage.loadPageObjectImage(notebookId: notebookId, fileName: file)
    }

    /// Aspect-preserving downscale so the longest edge ≤ `maxDimension`.
    static func downsized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale,
                             height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
