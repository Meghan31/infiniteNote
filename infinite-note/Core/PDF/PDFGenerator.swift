import Foundation
import PencilKit
import PDFKit
import UIKit

/// The single, constant paper coordinate space used EVERYWHERE: the on-screen
/// canvas (every mode — normal, write-only, sidebar open/closed), thumbnails,
/// sync snapshots, and exported PDF pages. A4 portrait at ~144 dpi
/// (210mm × 297mm). Because every mode draws on this exact same fixed paper,
/// nothing written can ever fall outside an exported page.
enum PaperSpec {
    static let size = CGSize(width: 1190, height: 1684)
}

final class PDFGenerator {
    static let shared = PDFGenerator()
    private init() {}

    /// Generates a PDF for `notebook`. Every page is the constant A4 paper
    /// (`PaperSpec.size`) — the same coordinate space the canvas draws in, so
    /// the exported page is 1:1 with the screen.
    /// - Parameter canvasSize: legacy parameter, kept for call-site
    ///   compatibility. The page size is constant and no longer derived from
    ///   the live canvas bounds.
    func generatePDF(for notebook: Notebook, canvasSize: CGSize? = nil) throws -> URL {
        _ = canvasSize
        let pages = try DrawingService.shared.pages(for: notebook.id)
        guard !pages.isEmpty else { throw PDFError.noPages }

        // Constant paper — identical for all notebooks, modes, and devices.
        let pageSize = PaperSpec.size

        // Per-generation folder: two same-titled notebooks can never overwrite
        // each other's file. Cleanup removes only folders older than an hour —
        // wiping the whole root here could delete the temp PDF of a CONCURRENT
        // export (e.g. a sync and a share running at once).
        let fm = FileManager.default
        let exportRoot = fm.temporaryDirectory
            .appendingPathComponent("notebook-pdf-exports", isDirectory: true)
        Self.purgeStaleExports(in: exportRoot)
        let exportDir = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let baseName = notebook.title.sanitizedFilename
        let fileURL = exportDir
            .appendingPathComponent("\(baseName.isEmpty ? "Notebook" : baseName).pdf")

        // Stream the PDF straight to disk — the old ...ContextToData held the
        // entire document in memory, which spiked badly on big notebooks.
        guard UIGraphicsBeginPDFContextToFile(
            fileURL.path, CGRect(origin: .zero, size: pageSize), nil
        ) else {
            throw PDFError.contextCreationFailed
        }

        // Cover page — always the first page of the exported PDF.
        autoreleasepool {
            drawCoverPage(for: notebook, pageSize: pageSize, pageCount: pages.count)
        }

        do {
            for page in pages {
                // Per-page pool: stroke bitmaps are large (pageSize × 2 scale);
                // without this every page's bitmap stays alive until the end.
                try autoreleasepool {
                    let drawing = try DrawingService.shared.loadDrawing(for: page)
                    UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: pageSize), nil)
                    guard let ctx = UIGraphicsGetCurrentContext() else { return }

                    // White page background.
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fill(CGRect(origin: .zero, size: pageSize))

                    // The page's actual style — including a .photo background.
                    // Scale 1: the canvas and PDF share the same coordinate space.
                    drawBackground(for: page, in: ctx, pageSize: pageSize, scale: 1)

                    // Strokes live in paper coordinates, so they normally render 1:1.
                    // Legacy strokes (drawn before the fixed paper existed) may extend
                    // past the page — render from the union of paper and stroke bounds
                    // and fit it onto the page, so NOTHING is ever trimmed.
                    let bounds = drawing.bounds
                    let source = CGSize(
                        width: max(pageSize.width, bounds.isNull ? 0 : bounds.maxX),
                        height: max(pageSize.height, bounds.isNull ? 0 : bounds.maxY)
                    )
                    let fit = min(pageSize.width / source.width, pageSize.height / source.height)
                    // Render in a forced-light trait so ink never inverts to white.
                    let strokeImage = renderStrokeImage(drawing, source: source)
                    strokeImage.draw(in: CGRect(
                        origin: .zero,
                        size: CGSize(width: source.width * fit, height: source.height * fit)
                    ))

                    drawPageNumber(page.pageNumber, totalPages: pages.count, in: ctx, pageSize: pageSize)
                }
            }
        } catch {
            // A failed page load/render must still CLOSE the global PDF
            // context — leaving it open leaks the file handle and lets later
            // UIKit drawing land inside the orphaned context. The partial
            // file is removed; stale export folders are purged hourly anyway.
            UIGraphicsEndPDFContext()
            try? fm.removeItem(at: exportDir)
            throw error
        }

        UIGraphicsEndPDFContext()
        return fileURL
    }

    /// Best-effort cleanup of previous exports: removes per-generation
    /// folders older than an hour. Recent folders are left alone — they may
    /// belong to an export still in flight. (The system also purges tmp.)
    private static func purgeStaleExports(in root: URL) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date.now.addingTimeInterval(-3600)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    // MARK: - Cover Page
    //
    // Every exported PDF opens with a full cover:
    //   • Cover art: the user's cover photo if one was picked (at creation or
    //     via Edit Cover); otherwise the bundled artworks "background 1"…
    //     "background 10", cycled by notebook creation order (11th notebook
    //     wraps back to "background 1").
    //   • Text layout (drawn on BOTH photo and default covers), all on cartoon
    //     plates: very big title, optional description, optional author, then
    //     page count, created/downloaded dates, and links at the bottom.

    /// Light-theme cartoon ink colors, mirrored from Color+Extensions.
    private enum CoverPalette {
        static let ink   = UIColor(red: 0x1C / 255, green: 0x1B / 255, blue: 0x2E / 255, alpha: 1) // inkOutlineLight
        static let cream = UIColor(red: 0xFF / 255, green: 0xF7 / 255, blue: 0xE9 / 255, alpha: 1) // themeBackgroundLight
    }

    /// Number of bundled "background N" cover artworks in Assets.xcassets.
    private let defaultCoverArtCount = 10

    /// Footer links shown at the bottom of every cover.
    private let coverLinks = "www.meghan31.me   ·   linkedin.com/in/meghan31   ·   github.com/Meghan31"

    private func drawCoverPage(for notebook: Notebook, pageSize: CGSize, pageCount: Int) {
        let userCover = FileStorageManager.shared.loadCoverImage(notebookId: notebook.id)
        let coverImage = userCover ?? defaultCoverArt(for: notebook)

        UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: pageSize), nil)
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Base fill (visible only if the image is missing or transparent).
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pageSize))

        if let coverImage {
            drawAspectFill(coverImage, in: ctx, pageSize: pageSize)
        }

        drawCoverTexts(for: notebook, pageCount: pageCount, in: ctx, pageSize: pageSize)
    }

    /// "background 1"…"background 10", assigned by creation order and cycling
    /// back to 1 after 10.
    private func defaultCoverArt(for notebook: Notebook) -> UIImage? {
        let index = NotebookService.shared.creationOrderIndex(of: notebook)
        let assetNumber = (index % defaultCoverArtCount) + 1
        return UIImage(named: "background \(assetNumber)")
            ?? UIImage(named: "background") // legacy single-art fallback
    }

    /// Draws `image` scaled to completely fill the page (centered, edges
    /// cropped) — like SwiftUI's `.scaledToFill()`.
    private func drawAspectFill(_ image: UIImage, in ctx: CGContext, pageSize: CGSize, alpha: CGFloat = 1) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(pageSize.width / image.size.width, pageSize.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (pageSize.width - drawSize.width) / 2,
                             y: (pageSize.height - drawSize.height) / 2)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: pageSize))
        image.draw(in: CGRect(origin: origin, size: drawSize), blendMode: .normal, alpha: alpha)
        ctx.restoreGState()
    }

    /// Lays out all cover texts, using the whole page:
    ///
    ///   top    → TITLE (very big) → description → "by author"
    ///   bottom → page count ← dates ← links (anchored upward from the edge)
    private func drawCoverTexts(for notebook: Notebook, pageCount: Int, in ctx: CGContext, pageSize: CGSize) {
        let w = pageSize.width
        let h = pageSize.height

        // ── Top-down: title, description, author ─────────────────────
        var cursorY = h * 0.075

        let title = notebook.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            let rect = drawCoverPlate(
                title,
                font: roundedFont(size: w * 0.095, weight: .heavy),
                in: ctx, pageSize: pageSize,
                topY: cursorY, maxWidthFraction: 0.86, maxLines: 3
            )
            cursorY = rect.maxY + h * 0.028
        }

        if let description = notebook.noteDescription?.nilIfBlank {
            let rect = drawCoverPlate(
                description,
                font: roundedFont(size: w * 0.028, weight: .medium),
                in: ctx, pageSize: pageSize,
                topY: cursorY, maxWidthFraction: 0.74, maxLines: 5
            )
            cursorY = rect.maxY + h * 0.020
        }

        if let author = notebook.author?.nilIfBlank {
            drawCoverPlate(
                "by \(author)",
                font: roundedFont(size: w * 0.032, weight: .bold),
                in: ctx, pageSize: pageSize,
                topY: cursorY, maxWidthFraction: 0.70, maxLines: 1
            )
        }

        // ── Bottom-up: links, dates, page count ──────────────────────
        let linksRect = drawCoverPlate(
            coverLinks,
            font: roundedFont(size: w * 0.0165, weight: .semibold),
            in: ctx, pageSize: pageSize,
            bottomMaxY: h * 0.972, maxWidthFraction: 0.94, maxLines: 1
        )

        let dateStyle: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()
        let created = notebook.createdAt.formatted(dateStyle)
        let downloaded = Date.now.formatted(dateStyle)
        let datesRect = drawCoverPlate(
            "Created \(created)   •   Downloaded \(downloaded)",
            font: roundedFont(size: w * 0.0225, weight: .bold),
            in: ctx, pageSize: pageSize,
            bottomMaxY: linksRect.minY - h * 0.015, maxWidthFraction: 0.90, maxLines: 1
        )

        drawCoverPlate(
            "\(pageCount) \(pageCount == 1 ? "page" : "pages")",
            font: roundedFont(size: w * 0.021, weight: .heavy),
            in: ctx, pageSize: pageSize,
            bottomMaxY: datesRect.minY - h * 0.015, maxWidthFraction: 0.5, maxLines: 1
        )
    }

    /// Rounded system font ≈ the app's `.cartoon` face.
    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }

    /// Draws `text` centered on a cartoon "sticker" plate (cream fill, heavy
    /// ink outline, hard offset shadow), horizontally centered on the page.
    /// Anchor with either `topY` (plate top) or `bottomMaxY` (plate bottom).
    /// Returns the plate's frame so callers can stack blocks.
    @discardableResult
    private func drawCoverPlate(
        _ text: String,
        font: UIFont,
        in ctx: CGContext,
        pageSize: CGSize,
        topY: CGFloat? = nil,
        bottomMaxY: CGFloat? = nil,
        maxWidthFraction: CGFloat = 0.78,
        maxLines: CGFloat = 3
    ) -> CGRect {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CoverPalette.ink,
            .paragraphStyle: paragraph
        ]

        let padX = font.pointSize * 0.85
        let padY = font.pointSize * 0.55

        // Measure, wrapping inside the plate and capping the line count.
        let maxTextWidth = pageSize.width * maxWidthFraction - padX * 2
        let maxTextHeight = font.lineHeight * maxLines + 2
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: maxTextHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs,
            context: nil
        )
        let textSize = CGSize(width: ceil(measured.width),
                              height: min(ceil(measured.height), ceil(maxTextHeight)))

        let plateSize = CGSize(width: textSize.width + padX * 2,
                               height: textSize.height + padY * 2)
        let x = (pageSize.width - plateSize.width) / 2
        let y: CGFloat
        if let topY {
            y = topY
        } else if let bottomMaxY {
            y = bottomMaxY - plateSize.height
        } else {
            y = (pageSize.height - plateSize.height) / 2
        }
        let plateRect = CGRect(origin: CGPoint(x: x, y: y), size: plateSize)

        let cornerRadius = min(plateSize.height / 2.4, font.pointSize * 0.62)
        let outlineWidth = max(2.5, min(9, font.pointSize * 0.085))
        let shadowOffset = max(4, min(15, font.pointSize * 0.17))

        // Hard offset shadow (blur-free, solid ink) behind the plate.
        ctx.setFillColor(CoverPalette.ink.withAlphaComponent(0.9).cgColor)
        ctx.addPath(UIBezierPath(
            roundedRect: plateRect.offsetBy(dx: shadowOffset, dy: shadowOffset),
            cornerRadius: cornerRadius
        ).cgPath)
        ctx.fillPath()

        // Cream plate + heavy ink outline.
        let platePath = UIBezierPath(roundedRect: plateRect, cornerRadius: cornerRadius).cgPath
        ctx.setFillColor(CoverPalette.cream.cgColor)
        ctx.addPath(platePath)
        ctx.fillPath()
        ctx.setStrokeColor(CoverPalette.ink.cgColor)
        ctx.setLineWidth(outlineWidth)
        ctx.addPath(platePath)
        ctx.strokePath()

        // Text, centered on the plate.
        let textRect = CGRect(
            x: plateRect.minX + padX,
            y: plateRect.minY + (plateSize.height - textSize.height) / 2,
            width: plateSize.width - padX * 2,
            height: textSize.height
        )
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs,
            context: nil
        )
        return plateRect
    }

    // MARK: - Stroke Rendering

    /// Renders the drawing into a UIImage matching the source coordinate space,
    /// forcing a light appearance so ink colors aren't inverted.
    private func renderStrokeImage(_ drawing: PKDrawing, source: CGSize) -> UIImage {
        var image = UIImage()
        let render = {
            // Scale 2 (was 3): plenty for print sharpness at A4, and roughly
            // halves the per-page peak memory (a 1190×1684 page at 3× was a
            // ~70 MB bitmap; at 2× it's ~32 MB, freed per page by the pool).
            image = drawing.image(from: CGRect(origin: .zero, size: source), scale: 2.0)
        }
        if #available(iOS 13.0, *) {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent(render)
        } else {
            render()
        }
        return image
    }

    // MARK: - Page Style Backgrounds

    private func drawBackground(for page: Page, in ctx: CGContext, pageSize: CGSize, scale: CGFloat) {
        let spacing: CGFloat = 28 * scale
        let line = UIColor.systemGray3.withAlphaComponent(0.55).cgColor
        let major = UIColor.systemGray2.withAlphaComponent(0.55).cgColor

        switch page.pageStyle {
        case .plain:
            break

        case .photo:
            // The page's imported photo background — aspect-filled at the
            // same 35% opacity the on-screen canvas uses, under the ink.
            // (Previously skipped, so photo pages exported blank white.)
            if let photo = FileStorageManager.shared.loadPageBackground(
                notebookId: page.notebookId,
                pageId: page.id
            ) {
                drawAspectFill(photo, in: ctx, pageSize: pageSize, alpha: 0.35)
            }

        case .ruled:
            ctx.setStrokeColor(line)
            ctx.setLineWidth(max(1, 0.6 * scale))
            var y = spacing
            while y <= pageSize.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: pageSize.width, y: y))
                y += spacing
            }
            ctx.strokePath()
            // Left margin rule.
            let margin = 64 * scale
            ctx.setStrokeColor(UIColor.systemIndigo.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(max(1, 0.8 * scale))
            ctx.move(to: CGPoint(x: margin, y: 0))
            ctx.addLine(to: CGPoint(x: margin, y: pageSize.height))
            ctx.strokePath()

        case .dots:
            ctx.setFillColor(line)
            let r: CGFloat = max(1, 1.4 * scale)
            var y = spacing
            while y <= pageSize.height {
                var x = spacing
                while x <= pageSize.width {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += spacing
                }
                y += spacing
            }

        case .grid:
            ctx.setLineWidth(max(0.75, 0.4 * scale))
            var x: CGFloat = 0
            var col = 0
            while x <= pageSize.width {
                ctx.setStrokeColor(col % 4 == 0 ? major : line)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: pageSize.height))
                ctx.strokePath()
                x += spacing; col += 1
            }
            var y: CGFloat = 0
            var row = 0
            while y <= pageSize.height {
                ctx.setStrokeColor(row % 4 == 0 ? major : line)
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: pageSize.width, y: y))
                ctx.strokePath()
                y += spacing; row += 1
            }
        }
    }

    private func drawPageNumber(_ number: Int, totalPages: Int, in ctx: CGContext, pageSize: CGSize) {
        let text = "Page \(number) of \(totalPages)" as NSString
        let fontSize = max(12, pageSize.width * 0.018)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.systemGray2
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: (pageSize.width - size.width) / 2, y: pageSize.height - size.height - 24),
            withAttributes: attrs
        )
    }

    enum PDFError: LocalizedError {
        case noPages
        case contextCreationFailed
        var errorDescription: String? {
            switch self {
            case .noPages: return "No pages to export."
            case .contextCreationFailed: return "Couldn't create the PDF file. Check free storage."
            }
        }
    }
}

extension String {
    var sanitizedFilename: String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return components(separatedBy: invalid).joined(separator: "-")
    }
}
