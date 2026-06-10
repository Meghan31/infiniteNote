import Foundation
import UIKit
import GRDB

final class NotebookService: @unchecked Sendable {
    static let shared = NotebookService()
    private let db = DatabaseManager.shared
    private let storage = FileStorageManager.shared
    private let drawing = DrawingService.shared

    private init() {}

    func allNotebooks() throws -> [Notebook] {
        try db.dbQueue.read { db in try Notebook.orderByUpdated.fetchAll(db) }
    }

    // MARK: - Create

    @discardableResult
    func createNotebook(
        title: String,
        coverColorIndex: Int = Int.random(in: 0...7),
        coverImageData: Data? = nil,
        defaultPageStyle: PageStyle = .grid
    ) throws -> Notebook {
        var notebook = Notebook(
            title: title,
            coverColorIndex: coverColorIndex,
            coverImagePath: coverImageData != nil ? "cover.jpg" : nil,
            defaultPageStyle: defaultPageStyle
        )
        try db.dbQueue.write { db in try notebook.insert(db) }
        if let data = coverImageData {
            try storage.saveCoverImage(data, notebookId: notebook.id)
        }
        try drawing.addPage(to: notebook.id, style: defaultPageStyle)
        return notebook
    }

    // MARK: - Update

    func renameNotebook(_ notebook: Notebook, to newTitle: String) throws {
        var updated = notebook; updated.title = newTitle; updated.updatedAt = .now
        try db.dbQueue.write { db in try updated.update(db) }
    }

    func deleteNotebook(_ notebook: Notebook) throws {
        try storage.deleteNotebookFiles(notebookId: notebook.id)
        try db.dbQueue.write { db in try notebook.delete(db) }
    }

    func touchNotebook(_ notebook: Notebook) throws {
        var updated = notebook; updated.updatedAt = .now
        try db.dbQueue.write { db in try updated.update(db) }
    }

    // MARK: - Cover

    func updateCoverColor(_ colorIndex: Int, for notebook: Notebook) throws {
        storage.deleteCoverImage(notebookId: notebook.id)
        var updated = notebook
        updated.coverColorIndex = colorIndex
        updated.coverImagePath = nil
        updated.updatedAt = .now
        try db.dbQueue.write { db in try updated.update(db) }
    }

    func updateCoverImage(_ imageData: Data, for notebook: Notebook) throws {
        try storage.saveCoverImage(imageData, notebookId: notebook.id)
        var updated = notebook
        updated.coverImagePath = "cover.jpg"
        updated.updatedAt = .now
        try db.dbQueue.write { db in try updated.update(db) }
    }
}
