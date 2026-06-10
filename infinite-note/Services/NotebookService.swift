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
        defaultPageStyle: PageStyle = .grid,
        description: String? = nil,
        author: String? = nil
    ) throws -> Notebook {
        var notebook = Notebook(
            title: title,
            coverColorIndex: coverColorIndex,
            coverImagePath: coverImageData != nil ? "cover.jpg" : nil,
            defaultPageStyle: defaultPageStyle,
            noteDescription: description,
            author: author
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
        try db.dbQueue.write { db in _ = try notebook.delete(db) }
    }

    func touchNotebook(_ notebook: Notebook) throws {
        var updated = notebook; updated.updatedAt = .now
        try db.dbQueue.write { db in try updated.update(db) }
    }

    /// Pins / unpins the notebook (pinned sort first in the sidebar).
    func setPinned(_ pinned: Bool, for notebook: Notebook) throws {
        var updated = notebook
        updated.isPinned = pinned
        try db.dbQueue.write { db in try updated.update(db) }
    }

    /// Stamps a successful cloud sync on the notebook.
    func markSynced(_ notebook: Notebook, at date: Date) throws {
        var updated = notebook
        updated.lastSyncedAt = date
        try db.dbQueue.write { db in try updated.update(db) }
    }

    /// Clears the sync stamp after an unsync (badge disappears).
    func clearSyncStamp(_ notebook: Notebook) throws {
        var updated = notebook
        updated.lastSyncedAt = nil
        try db.dbQueue.write { db in try updated.update(db) }
    }

    /// Updates the optional PDF-cover details (description / author).
    func updateDetails(description: String?, author: String?, for notebook: Notebook) throws {
        var updated = notebook
        updated.noteDescription = description
        updated.author = author
        updated.updatedAt = .now
        try db.dbQueue.write { db in try updated.update(db) }
    }

    /// 0-based position of `notebook` in creation order (oldest = 0).
    /// Drives the cycling default PDF cover art ("background 1"…"background 10").
    func creationOrderIndex(of notebook: Notebook) -> Int {
        let ids = (try? db.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notebooks ORDER BY created_at ASC, id ASC")
        }) ?? []
        return ids.firstIndex(of: notebook.id) ?? 0
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
