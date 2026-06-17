import Foundation
import CoreGraphics
import GRDB

// MARK: - Page Object Kind

/// A placed object that lives ON a page, in the same fixed paper coordinate
/// space (`PaperSpec.size`) as ink — NOT a page background. Two kinds today:
/// a rich-text box and an imported photo. Both can be moved, resized and
/// rotated; ink always renders on top of them, so the Pencil writes "on" a
/// photo simply by drawing over it.
enum PageObjectKind: String, Codable, Hashable, Sendable {
    case text
    case photo
}

// MARK: - Page Object

struct PageObject: Identifiable, Hashable, Sendable {
    var id: String
    var pageId: String
    var kind: PageObjectKind

    /// Frame in PAPER coordinates (origin top-left), matching `PaperSpec.size`
    /// (1190 × 1684). The whole object layer is scaled to fit on screen, so
    /// these values are device-independent and align 1:1 with ink and exports.
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Clockwise rotation in radians about the object's centre.
    var rotation: Double

    /// Paint order — higher draws later (on top of lower objects). Ink always
    /// draws above every object regardless of z.
    var zIndex: Int

    /// Rich-text payload (RTF) for `.text` objects; nil for photos.
    var textRTF: Data?

    /// On-disk image filename (relative to the notebook folder) for `.photo`
    /// objects; nil for text.
    var imageFile: String?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        pageId: String,
        kind: PageObjectKind,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        rotation: Double = 0,
        zIndex: Int = 0,
        textRTF: Data? = nil,
        imageFile: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.pageId = pageId
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.zIndex = zIndex
        self.textRTF = textRTF
        self.imageFile = imageFile
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Convenience frame accessor in paper coordinates.
    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Double(newValue.origin.x)
            y = Double(newValue.origin.y)
            width = Double(newValue.size.width)
            height = Double(newValue.size.height)
        }
    }

    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }
}

// MARK: - GRDB Conformances

extension PageObject: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "page_objects"

    init(row: Row) throws {
        id = row["id"]
        pageId = row["page_id"]
        let kindRaw: String = row["kind"] ?? "text"
        kind = PageObjectKind(rawValue: kindRaw) ?? .text
        x = row["x"]
        y = row["y"]
        width = row["width"]
        height = row["height"]
        rotation = row["rotation"] ?? 0
        zIndex = row["z_index"] ?? 0
        textRTF = row["text_rtf"]
        imageFile = row["image_file"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["page_id"] = pageId
        container["kind"] = kind.rawValue
        container["x"] = x
        container["y"] = y
        container["width"] = width
        container["height"] = height
        container["rotation"] = rotation
        container["z_index"] = zIndex
        container["text_rtf"] = textRTF
        container["image_file"] = imageFile
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
}

// MARK: - Query Helpers

extension PageObject {
    static func forPage(_ pageId: String) -> QueryInterfaceRequest<PageObject> {
        PageObject
            .filter(Column("page_id") == pageId)
            .order(Column("z_index"), Column("created_at"))
    }
}
