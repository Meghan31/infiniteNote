import Foundation
import PencilKit
import PDFKit
import UIKit

final class PDFGenerator {
    static let shared = PDFGenerator()
    private init() {}

    private let pageSize = CGSize(width: 2048, height: 2732) // iPad Pro ratio

    func generatePDF(for notebook: Notebook) throws -> URL {
        let pages = try DrawingService.shared.pages(for: notebook.id)
        guard !pages.isEmpty else {
            throw PDFError.noPages
        }

        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, CGRect(origin: .zero, size: pageSize), nil)

        for page in pages {
            let drawing = try DrawingService.shared.loadDrawing(for: page)
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: pageSize), nil)

            guard let ctx = UIGraphicsGetCurrentContext() else { continue }

            // White background
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: pageSize))

            // Draw ruled lines
            drawRuledLines(in: ctx)

            // Draw PencilKit drawing
            let image = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: 1.0)
            image.draw(in: CGRect(origin: .zero, size: pageSize))

            // Page number footer
            drawPageNumber(page.pageNumber, totalPages: pages.count, in: ctx)
        }

        UIGraphicsEndPDFContext()

        let tempURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("\(notebook.title.sanitizedFilename).pdf")
        pdfData.write(to: tempURL, atomically: true)
        return tempURL
    }

    // MARK: - Helpers

    private func drawRuledLines(in ctx: CGContext) {
        ctx.setStrokeColor(UIColor.systemGray5.cgColor)
        ctx.setLineWidth(1)
        let spacing: CGFloat = 64
        var y: CGFloat = 200
        while y < pageSize.height - 100 {
            ctx.move(to: CGPoint(x: 120, y: y))
            ctx.addLine(to: CGPoint(x: pageSize.width - 80, y: y))
            y += spacing
        }
        // Margin line
        ctx.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.3).cgColor)
        ctx.move(to: CGPoint(x: 120, y: 100))
        ctx.addLine(to: CGPoint(x: 120, y: pageSize.height - 100))
        ctx.strokePath()
    }

    private func drawPageNumber(_ number: Int, totalPages: Int, in ctx: CGContext) {
        let text = "Page \(number) of \(totalPages)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .regular),
            .foregroundColor: UIColor.systemGray3
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: (pageSize.width - size.width) / 2, y: pageSize.height - 80),
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
