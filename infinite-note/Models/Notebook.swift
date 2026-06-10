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

    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        coverColorIndex: Int = Int.random(in: 0...4), // keep in sync with Color.notebookCovers.count
        coverImagePath: String? = nil,
        defaultPageStyle: PageStyle = .grid
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverColorIndex = coverColorIndex
        self.coverImagePath = coverImagePath
        self.defaultPageStyle = defaultPageStyle
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
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["title"] = title
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["cover_color_index"] = coverColorIndex
        container["cover_image_path"] = coverImagePath
        container["default_page_style"] = defaultPageStyle.rawValue
    }
}

// MARK: - Query Helpers

extension Notebook {
    static let orderByUpdated = Notebook.order(Column("updated_at").desc)
}
