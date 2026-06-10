import Foundation
import GRDB

// MARK: - Page Style

enum PageStyle: String, CaseIterable, Codable, Hashable {
    case plain
    case ruled
    case dots
    case grid
    case photo   // custom imported image background

    var label: String {
        switch self {
        case .plain: return "Plain"
        case .ruled: return "Ruled"
        case .dots:  return "Dots"
        case .grid:  return "Grid"
        case .photo: return "Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .plain: return "doc"
        case .ruled: return "text.alignleft"
        case .dots:  return "circle.grid.3x3"
        case .grid:  return "grid"
        case .photo: return "photo"
        }
    }
}

// MARK: - Page

struct Page: Identifiable, Hashable, Sendable {
    var id: String
    var notebookId: String
    var pageNumber: Int
    var pageStyle: PageStyle

    init(
        id: String = UUID().uuidString,
        notebookId: String,
        pageNumber: Int,
        pageStyle: PageStyle = .grid
    ) {
        self.id = id
        self.notebookId = notebookId
        self.pageNumber = pageNumber
        self.pageStyle = pageStyle
    }
}

// MARK: - GRDB Conformances

extension Page: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pages"

    init(row: Row) throws {
        id = row["id"]
        notebookId = row["notebook_id"]
        pageNumber = row["page_number"]
        let styleRaw: String = row["page_style"] ?? "grid"
        pageStyle = PageStyle(rawValue: styleRaw) ?? .grid
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["notebook_id"] = notebookId
        container["page_number"] = pageNumber
        container["page_style"] = pageStyle.rawValue
    }
}

// MARK: - Query Helpers

extension Page {
    static func forNotebook(_ notebookId: String) -> QueryInterfaceRequest<Page> {
        Page
            .filter(Column("notebook_id") == notebookId)
            .order(Column("page_number"))
    }
}
