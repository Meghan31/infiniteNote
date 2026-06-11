import Foundation
import GRDB

/// CRUD + membership for home-screen folders.
/// Membership is a link, not a copy: notebooks always remain in the
/// book-sidebar and are merely also reachable from their folders.
final class FolderService: @unchecked Sendable {
    static let shared = FolderService()
    private let db = DatabaseManager.shared
    private let storage = FileStorageManager.shared

    private init() {}

    // MARK: - Fetch

    func allFolders() throws -> [Folder] {
        try db.dbQueue.read { db in try Folder.orderByUpdated.fetchAll(db) }
    }

    /// folderId → set of notebook ids, for fast membership checks and counts.
    func allMemberships() throws -> [String: Set<String>] {
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT folder_id, notebook_id FROM folder_notebooks")
            var result: [String: Set<String>] = [:]
            for row in rows {
                let folderId: String = row["folder_id"]
                let notebookId: String = row["notebook_id"]
                result[folderId, default: []].insert(notebookId)
            }
            return result
        }
    }

    /// Notebooks inside `folder`, newest-updated first.
    func notebooks(in folder: Folder) throws -> [Notebook] {
        try db.dbQueue.read { db in
            try Notebook.fetchAll(db, sql: """
                SELECT notebooks.* FROM notebooks
                JOIN folder_notebooks ON folder_notebooks.notebook_id = notebooks.id
                WHERE folder_notebooks.folder_id = ?
                ORDER BY notebooks.updated_at DESC
                """, arguments: [folder.id])
        }
    }

    // MARK: - Create / Update / Delete

    @discardableResult
    func createFolder(
        name: String,
        colorIndex: Int,
        imageData: Data? = nil,
        author: String? = nil
    ) throws -> Folder {
        var folder = Folder(
            name: name,
            colorIndex: colorIndex,
            imagePath: imageData != nil ? "cover.jpg" : nil,
            author: author
        )
        try db.dbQueue.write { db in try folder.insert(db) }
        if let data = imageData {
            try storage.saveFolderImage(data, folderId: folder.id)
        }
        return folder
    }

    /// Updates name / color / author, and optionally replaces the image
    /// (`imageData == nil` → keep the current image as-is).
    /// Column-scoped: only the edited columns are written, so a stale
    /// `Folder` struct can't revert other columns (e.g. `pinned`).
    func updateFolder(
        _ folder: Folder,
        name: String,
        colorIndex: Int,
        imageData: Data?,
        author: String?
    ) throws -> Folder {
        var updated = folder
        updated.name = name
        updated.colorIndex = colorIndex
        updated.author = author
        updated.updatedAt = .now
        var assignments: [ColumnAssignment] = [
            Column("name").set(to: name),
            Column("color_index").set(to: colorIndex),
            Column("author").set(to: author),
            Column("updated_at").set(to: updated.updatedAt)
        ]
        if let data = imageData {
            try storage.saveFolderImage(data, folderId: folder.id)
            updated.imagePath = "cover.jpg"
            assignments.append(Column("image_path").set(to: "cover.jpg"))
        }
        try update(folder.id, assignments)
        return updated
    }

    /// Pins / unpins the folder (pinned sort first on the homepage).
    func setPinned(_ pinned: Bool, for folder: Folder) throws {
        try update(folder.id, [Column("pinned").set(to: pinned)])
    }

    /// Deletes the folder and its links — never the notebooks themselves.
    /// DB row first (cascades the links), files after — a failed file
    /// cleanup only orphans an image on disk.
    func deleteFolder(_ folder: Folder) throws {
        try db.dbQueue.write { db in _ = try folder.delete(db) }
        storage.deleteFolderFiles(folderId: folder.id)
    }

    // MARK: - Membership

    /// Adds the notebook to the folder. Adding twice is a no-op — the join
    /// table's primary key allows one membership per (folder, notebook).
    func addNotebook(_ notebookId: String, to folder: Folder) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO folder_notebooks (folder_id, notebook_id) VALUES (?, ?)",
                arguments: [folder.id, notebookId]
            )
        }
        try touch(folder)
    }

    func removeNotebook(_ notebookId: String, from folder: Folder) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM folder_notebooks WHERE folder_id = ? AND notebook_id = ?",
                arguments: [folder.id, notebookId]
            )
        }
        try touch(folder)
    }

    private func touch(_ folder: Folder) throws {
        try update(folder.id, [Column("updated_at").set(to: Date.now)])
    }

    /// Column-scoped UPDATE on one folder row.
    private func update(_ folderId: String, _ assignments: [ColumnAssignment]) throws {
        try db.dbQueue.write { db in
            _ = try Folder
                .filter(Column("id") == folderId)
                .updateAll(db, assignments)
        }
    }
}
