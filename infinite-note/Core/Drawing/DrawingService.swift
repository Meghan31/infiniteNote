import Foundation
import PencilKit
import UIKit
import GRDB

final class DrawingService: @unchecked Sendable {
    static let shared = DrawingService()
    private let db = DatabaseManager.shared
    private let storage = FileStorageManager.shared

    private init() {}

    // MARK: - Pages

    func pages(for notebookId: String) throws -> [Page] {
        try db.dbQueue.read { db in
            try Page.forNotebook(notebookId).fetchAll(db)
        }
    }

    @discardableResult
    func addPage(to notebookId: String, style: PageStyle = .grid) throws -> Page {
        let existing = try pages(for: notebookId)
        let nextNumber = (existing.map(\.pageNumber).max() ?? 0) + 1
        var page = Page(notebookId: notebookId, pageNumber: nextNumber, pageStyle: style)
        try db.dbQueue.write { db in
            try page.insert(db)
        }
        return page
    }

    func deletePage(_ page: Page) throws {
        try storage.deleteDrawing(notebookId: page.notebookId, pageId: page.id)
        storage.deletePageBackground(notebookId: page.notebookId, pageId: page.id)
        try db.dbQueue.write { db in try page.delete(db) }
        var remaining = try pages(for: page.notebookId)
        try db.dbQueue.write { db in
            for index in remaining.indices {
                remaining[index].pageNumber = index + 1
                try remaining[index].update(db)
            }
        }
    }

    func updatePageStyle(_ style: PageStyle, for page: Page) throws {
        var updated = page
        updated.pageStyle = style
        try db.dbQueue.write { db in try updated.update(db) }
    }

    /// Re-orders pages and persists the new page_number values to the DB.
    func movePages(_ pages: inout [Page], from source: IndexSet, to destination: Int) throws {
        pages.move(fromOffsets: source, toOffset: destination)
        try db.dbQueue.write { db in
            for index in pages.indices {
                pages[index].pageNumber = index + 1
                try pages[index].update(db)
            }
        }
    }

    // MARK: - Drawings

    func saveDrawing(_ drawing: PKDrawing, for page: Page) throws {
        try storage.saveDrawing(drawing, notebookId: page.notebookId, pageId: page.id)
    }

    func loadDrawing(for page: Page) throws -> PKDrawing {
        try storage.loadDrawing(notebookId: page.notebookId, pageId: page.id)
    }

    // MARK: - Thumbnails

    /// Renders the drawing for `page` into a small UIImage suitable for sidebar thumbnails.
    /// Runs entirely off the main thread — call from a detached Task.
    func renderThumbnail(for page: Page, size: CGSize = CGSize(width: 72, height: 95)) -> UIImage {
        let drawing = (try? loadDrawing(for: page)) ?? PKDrawing()
        // Draw the content into a small CGContext via UIGraphicsImageRenderer
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Fill white background
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // Scale the 2048×2732 drawing coordinate space down to thumbnail size
            let drawingW: CGFloat = 2048
            let drawingH: CGFloat = 2732
            let sx = size.width / drawingW
            let sy = size.height / drawingH
            let s = min(sx, sy)
            ctx.cgContext.scaleBy(x: s, y: s)
            // Render strokes
            let strokeImage = drawing.image(
                from: CGRect(x: 0, y: 0, width: drawingW, height: drawingH),
                scale: 1.0
            )
            strokeImage.draw(in: CGRect(x: 0, y: 0, width: drawingW, height: drawingH))
        }
    }
}
