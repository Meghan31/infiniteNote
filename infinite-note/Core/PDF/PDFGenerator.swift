import Foundation
import PencilKit
import PDFKit
import UIKit

final class PDFGenerator {
    static let shared = PDFGenerator()
    private init() {}

    /// A4 portrait long edge in points at ~144 dpi. Short edge is derived from
    /// the canvas aspect ratio so the PDF page matches what was drawn on screen.
    private let a4LongSide: CGFloat = 1684          // 297mm
    private let a4ShortSide: CGFloat = 1190         // 210mm

    /// Fallback canvas size (A4 portrait proportions) when the live canvas
    /// size is unavailable.
    private let defaultCanvasSize = CGSize(width: 1190, height: 1684)

    /// Generates a PDF for `notebook`.
    /// - Parameter canvasSize: the on-screen drawing coordinate space (the
    ///   PKCanvasView bounds). Strokes live in this space, so it's needed to
    ///   scale them correctly onto the page. Defaults to A4 proportions.
    func generatePDF(for notebook: Notebook, canvasSize: CGSize? = nil) throws -> URL {
        let pages = try DrawingService.shared.pages(for: notebook.id)
        guard !pages.isEmpty else { throw PDFError.noPages }

        // Stroke coordinate space.
        let source = sanitizedCanvasSize(canvasSize)
        // PDF page keeps the canvas aspect ratio, scaled up to A4-ish resolution.
        let pageSize = a4PageSize(matching: source)
        let scale = pageSize.width / source.width   // uniform (aspect preserved)

        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, CGRect(origin: .zero, size: pageSize), nil)

        for page in pages {
            let drawing = try DrawingService.shared.loadDrawing(for: page)
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: pageSize), nil)
            guard let ctx = UIGraphicsGetCurrentContext() else { continue }

            // White page background.
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: pageSize))

            // Draw the page's actual style (plain draws nothing).
            drawBackground(for: page.pageStyle, in: ctx, pageSize: pageSize, scale: scale)

            // Render strokes in a forced-light trait so ink never inverts to
            // white on the white page, then scale to fill the page 1:1.
            let strokeImage = renderStrokeImage(drawing, source: source)
            strokeImage.draw(in: CGRect(origin: .zero, size: pageSize))

            drawPageNumber(page.pageNumber, totalPages: pages.count, in: ctx, pageSize: pageSize)
        }

        UIGraphicsEndPDFContext()

        let tempURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("\(notebook.title.sanitizedFilename).pdf")
        pdfData.write(to: tempURL, atomically: true)
        return tempURL
    }

    // MARK: - Sizing

    private func sanitizedCanvasSize(_ size: CGSize?) -> CGSize {
        guard let size, size.width > 1, size.height > 1 else { return defaultCanvasSize }
        return size
    }

    /// A page that preserves the canvas aspect ratio at A4-ish resolution.
    private func a4PageSize(matching source: CGSize) -> CGSize {
        let portrait = source.height >= source.width
        let longSide = a4LongSide
        let aspect = source.width / source.height
        if portrait {
            let height = longSide
            let width = height * aspect
            return CGSize(width: width, height: height)
        } else {
            let width = longSide
            let height = width / aspect
            return CGSize(width: width, height: height)
        }
    }

    /// Renders the drawing into a UIImage matching the source coordinate space,
    /// forcing a light appearance so ink colors aren't inverted.
    private func renderStrokeImage(_ drawing: PKDrawing, source: CGSize) -> UIImage {
        var image = UIImage()
        let render = {
            image = drawing.image(from: CGRect(origin: .zero, size: source), scale: 3.0)
        }
        if #available(iOS 13.0, *) {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent(render)
        } else {
            render()
        }
        return image
    }

    // MARK: - Page Style Backgrounds

    private func drawBackground(for style: PageStyle, in ctx: CGContext, pageSize: CGSize, scale: CGFloat) {
        let spacing: CGFloat = 28 * scale
        let line = UIColor.systemGray3.withAlphaComponent(0.55).cgColor
        let major = UIColor.systemGray2.withAlphaComponent(0.55).cgColor

        switch style {
        case .plain, .photo:
            break

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
        var errorDescription: String? {
            switch self {
            case .noPages: return "No pages to export."
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
