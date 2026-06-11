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
        coverColorIndex: Int = Int.random(in: 0..<Color_notebookCoversCount),
        coverImageData: Data? = nil,
        defaultPageStyle: PageStyle = .grid,
        pageBackgroundData: Data? = nil,
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
        let firstPage = try drawing.addPage(to: notebook.id, style: defaultPageStyle)
        // The photo picked for a .photo page style — previously discarded,
        // which left the page styled "photo" with no image.
        if defaultPageStyle == .photo, let background = pageBackgroundData {
            try storage.savePageBackground(background, notebookId: notebook.id, pageId: firstPage.id)
        }
        return notebook
    }

    // MARK: - Update
    //
    // Every update below is COLUMN-SCOPED: it writes only the columns it
    // owns instead of the whole row. Callers often hold stale `Notebook`
    // structs (e.g. the editor's copy after a rename in the sidebar), and a
    // full-row `update(db)` from such a struct silently reverted newer
    // values of unrelated columns.

    private func update(_ notebookId: String, _ assignments: [ColumnAssignment]) throws {
        try db.dbQueue.write { db in
            _ = try Notebook
                .filter(Column("id") == notebookId)
                .updateAll(db, assignments)
        }
    }

    func renameNotebook(_ notebook: Notebook, to newTitle: String) throws {
        try update(notebook.id, [
            Column("title").set(to: newTitle),
            Column("updated_at").set(to: Date.now)
        ])
    }

    /// DB row first (cascades pages + folder links), files after — if file
    /// cleanup fails we only orphan files on disk, never keep a notebook
    /// record whose content is already gone.
    func deleteNotebook(_ notebook: Notebook) throws {
        try db.dbQueue.write { db in _ = try notebook.delete(db) }
        try? storage.deleteNotebookFiles(notebookId: notebook.id)
    }

    func touchNotebook(_ notebook: Notebook) throws {
        try update(notebook.id, [Column("updated_at").set(to: Date.now)])
    }

    /// Pins / unpins the notebook (pinned sort first in the sidebar).
    func setPinned(_ pinned: Bool, for notebook: Notebook) throws {
        try update(notebook.id, [Column("pinned").set(to: pinned)])
    }

    /// Stamps a successful cloud sync on the notebook.
    func markSynced(_ notebook: Notebook, at date: Date) throws {
        try update(notebook.id, [Column("last_synced_at").set(to: date)])
    }

    /// Clears the sync stamp after an unsync (badge disappears).
    func clearSyncStamp(_ notebook: Notebook) throws {
        try update(notebook.id, [Column("last_synced_at").set(to: nil)])
    }

    /// Updates the optional PDF-cover details (description / author).
    func updateDetails(description: String?, author: String?, for notebook: Notebook) throws {
        try update(notebook.id, [
            Column("note_description").set(to: description),
            Column("author").set(to: author),
            Column("updated_at").set(to: Date.now)
        ])
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
        try update(notebook.id, [
            Column("cover_color_index").set(to: colorIndex),
            Column("cover_image_path").set(to: nil),
            Column("updated_at").set(to: Date.now)
        ])
    }

    func updateCoverImage(_ imageData: Data, for notebook: Notebook) throws {
        try storage.saveCoverImage(imageData, notebookId: notebook.id)
        try update(notebook.id, [
            Column("cover_image_path").set(to: "cover.jpg"),
            Column("updated_at").set(to: Date.now)
        ])
    }
}
