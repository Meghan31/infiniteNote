import Foundation
import GRDB

/// A home-screen folder that groups notebooks. Adding a notebook to a folder
/// never moves or duplicates data — the notebook stays in the book-sidebar
/// and is simply *also* reachable from the folder. A notebook can be in a
/// folder at most once (enforced by the join table's primary key).
struct Folder: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Index into `Color.notebookCovers` for the folder tint.
    var colorIndex: Int
    /// Filename (relative to the folder's directory) of the custom image
    /// overlaid on the big folder icon. `nil` → plain colored folder.
    var imagePath: String?
    /// Optional author name shown on the folder.
    var author: String?
    /// Pinned folders sort to the front of the homepage grid.
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        colorIndex: Int = Int.random(in: 0..<Color_notebookCoversCount),
        imagePath: String? = nil,
        author: String? = nil,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.imagePath = imagePath
        self.author = author
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Mirror of `Color.notebookCovers.count` usable from non-UI code.
/// Keep in sync with Color+Extensions.
let Color_notebookCoversCount = 6

// MARK: - GRDB Conformances

extension Folder: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "folders"

    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        colorIndex = row["color_index"] ?? 0
        imagePath = row["image_path"]
        author = row["author"]
        isPinned = row["pinned"] ?? false
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["color_index"] = colorIndex
        container["image_path"] = imagePath
        container["author"] = author
        container["pinned"] = isPinned
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
}

// MARK: - Query Helpers

extension Folder {
    /// Pinned first, then most recently updated.
    static let orderByUpdated = Folder.order(Column("pinned").desc, Column("updated_at").desc)
}
