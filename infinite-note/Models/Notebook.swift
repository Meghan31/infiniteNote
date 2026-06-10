import Foundation
import GRDB

struct Notebook: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var coverColorIndex: Int
    /// Filename (relative to notebook directory) of the custom cover image.
    /// `nil` → use `coverColorIndex` instead.
    var coverImagePath: String?
    /// Default style applied to every new page added to this notebook.
    var defaultPageStyle: PageStyle
    /// Optional details shown on the exported PDF cover.
    /// (`noteDescription` to avoid clashing with `CustomStringConvertible`.)
    var noteDescription: String?
    var author: String?
    /// Last successful cloud sync. `nil` → never synced (no badge).
    var lastSyncedAt: Date?
    /// Pinned notebooks sort to the front of the book-sidebar.
    var isPinned: Bool = false

    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        coverColorIndex: Int = Int.random(in: 0...4), // keep in sync with Color.notebookCovers.count
        coverImagePath: String? = nil,
        defaultPageStyle: PageStyle = .grid,
        noteDescription: String? = nil,
        author: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverColorIndex = coverColorIndex
        self.coverImagePath = coverImagePath
        self.defaultPageStyle = defaultPageStyle
        self.noteDescription = noteDescription
        self.author = author
    }
}

// MARK: - GRDB Conformances

extension Notebook: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "notebooks"

    init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        coverColorIndex = row["cover_color_index"] ?? 0
        coverImagePath = row["cover_image_path"]
        let styleRaw: String = row["default_page_style"] ?? "grid"
        defaultPageStyle = PageStyle(rawValue: styleRaw) ?? .grid
        noteDescription = row["note_description"]
        author = row["author"]
        lastSyncedAt = row["last_synced_at"]
        isPinned = row["pinned"] ?? false
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["title"] = title
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["cover_color_index"] = coverColorIndex
        container["cover_image_path"] = coverImagePath
        container["default_page_style"] = defaultPageStyle.rawValue
        container["note_description"] = noteDescription
        container["author"] = author
        container["last_synced_at"] = lastSyncedAt
        container["pinned"] = isPinned
    }
}

// MARK: - Query Helpers

extension Notebook {
    /// Pinned first, then most recently updated.
    static let orderByUpdated = Notebook.order(Column("pinned").desc, Column("updated_at").desc)
}
