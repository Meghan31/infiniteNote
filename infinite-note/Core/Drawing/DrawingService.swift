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
        // One transaction for the row delete + renumbering, so a crash can
        // never leave gapped or duplicate page numbers. Files go last: an
        // orphaned file on disk is harmless; a page row whose drawing was
        // already deleted is not.
        try db.dbQueue.write { db in
            _ = try page.delete(db)
            var remaining = try Page.forNotebook(page.notebookId).fetchAll(db)
            for index in remaining.indices where remaining[index].pageNumber != index + 1 {
                remaining[index].pageNumber = index + 1
                try remaining[index].update(db)
            }
        }
        try? storage.deleteDrawing(notebookId: page.notebookId, pageId: page.id)
        storage.deletePageBackground(notebookId: page.notebookId, pageId: page.id)
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

    /// Renders the drawing for `page` into a small UIImage suitable for
    /// sidebar thumbnails — a true mini version of the page.
    /// Runs entirely off the main thread — call from a detached Task.
    ///
    /// - Parameters:
    ///   - canvasSize: the live PKCanvasView bounds. Strokes live in this
    ///     coordinate space, so it's required to scale them correctly
    ///     (the old hardcoded 2048×2732 space rendered strokes ~30× too
    ///     small — which is why thumbnails looked like blank pages).
    ///   - isDark: render for the dark theme — black page, and PencilKit
    ///     auto-inverts black ink to white under the dark trait.
    func renderThumbnail(
        for page: Page,
        size: CGSize = CGSize(width: 72, height: 95),
        canvasSize: CGSize? = nil,
        isDark: Bool = false
    ) -> UIImage {
        let drawing = (try? loadDrawing(for: page)) ?? PKDrawing()
        let hasObjects = ((try? PageObjectService.shared.objects(for: page.id))?.isEmpty == false)

        // Empty page (no ink AND no objects) → just the themed page background.
        // Skips the Metal stroke render entirely (PencilKit aborts on
        // degenerate textures).
        if drawing.strokes.isEmpty && !hasObjects {
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                (isDark ? UIColor.black : UIColor.white).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
        }

        // Stroke coordinate space: live canvas bounds → drawn extent → A4-ish.
        // IMPORTANT: every value must be finite and positive — an empty
        // drawing has bounds == CGRect.null (maxX/maxY == +Inf), and feeding
        // Inf/zero into the renderer crashes in Metal (texture height 0).
        let fallback = CGSize(width: 1190, height: 1684)
        var source = canvasSize ?? .zero
        if !source.width.isFinite || !source.height.isFinite
            || source.width < 1 || source.height < 1 {
            let bounds = drawing.bounds
            let usable = bounds.maxX.isFinite && bounds.maxY.isFinite
                && bounds.maxX > 1 && bounds.maxY > 1
            source = usable ? CGSize(width: bounds.maxX, height: bounds.maxY) : fallback
        }

        // Render strokes under an explicit trait so ink inversion matches
        // the in-app page (black-on-white light, white-on-black dark).
        // Skip the Metal render entirely when there's no ink (objects-only page).
        var strokeImage: UIImage?
        if !drawing.strokes.isEmpty {
            var img = UIImage()
            let render = {
                img = drawing.image(from: CGRect(origin: .zero, size: source), scale: 1.0)
            }
            UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
                .performAsCurrent(render)
            // While `handwritingd` is down, PencilKit renders NOTHING — the
            // sidebar then shows rows of blank pages even though every page
            // has ink. Detect the blank output and substitute the
            // daemon-independent Core Graphics approximation; the real render
            // replaces it on the next refresh once the daemon is back.
            if Self.imageIsEffectivelyBlank(img) {
                img = StrokeImageRenderer.image(for: drawing, size: source, darkTheme: isDark) ?? img
            }
            strokeImage = img
        }

        // Placed objects render beneath the ink, in the same source space.
        let objectsImage = PageObjectRenderer.renderImage(
            pageId: page.id, notebookId: page.notebookId, size: source)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Page background — mirrors themePageLight / themePageDark.
            (isDark ? UIColor.black : UIColor.white).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Aspect-fit the page into the thumbnail, centered.
            let s = min(size.width / source.width, size.height / source.height)
            let drawSize = CGSize(width: source.width * s, height: source.height * s)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2,
                                 y: (size.height - drawSize.height) / 2)
            let drawRect = CGRect(origin: origin, size: drawSize)
            objectsImage?.draw(in: drawRect)
            strokeImage?.draw(in: drawRect)
        }
    }

    /// Cheap "did PencilKit actually draw anything?" check: scales the render
    /// into a small buffer and scans alpha. All-transparent output is exactly
    /// what a downed `handwritingd` produces. Errs toward "blank" — the only
    /// consequence of a false positive is using the CG fallback, which still
    /// shows the ink.
    private static func imageIsEffectivelyBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = 96, h = 128
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var i = 3
        while i < pixels.count {
            if pixels[i] > 4 { return false }
            i += 4
        }
        return true
    }
}
