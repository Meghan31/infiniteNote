import UIKit
import CoreGraphics

// MARK: - Page Object Renderer
//
// Draws a page's placed objects (photos + rich text) UNDER the ink, in the
// fixed paper coordinate space. Shared by the live canvas (via SwiftUI), the
// sidebar thumbnails and the exported PDF, so "what I placed" matches "what I
// downloaded" — the same invariant the strokes already honour.

enum PageObjectRenderer {

    /// Draws objects straight into the CURRENT UIGraphics context at paper
    /// coordinates (1:1). Used by the PDF generator, whose page context is
    /// already the paper size.
    static func draw(pageId: String, notebookId: String) {
        let objects = (try? PageObjectService.shared.objects(for: pageId)) ?? []
        drawObjects(objects, notebookId: notebookId)
    }

    /// Renders objects into a `size`-sized image (paper scaled to `size`), or
    /// nil when the page has no objects. Used by the thumbnail renderer, which
    /// composites this beneath the stroke image.
    static func renderImage(pageId: String, notebookId: String, size: CGSize) -> UIImage? {
        let objects = (try? PageObjectService.shared.objects(for: pageId)) ?? []
        guard !objects.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let scaleX = size.width / PaperSpec.size.width
        let scaleY = size.height / PaperSpec.size.height
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            context.cgContext.scaleBy(x: scaleX, y: scaleY)
            drawObjects(objects, notebookId: notebookId)
        }
    }

    // MARK: - Private

    private static func drawObjects(_ objects: [PageObject], notebookId: String) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for obj in objects.sorted(by: { $0.zIndex < $1.zIndex }) {
            let rect = obj.frame
            ctx.saveGState()
            if obj.rotation != 0 {
                let c = obj.center
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(obj.rotation))
                ctx.translateBy(x: -c.x, y: -c.y)
            }
            switch obj.kind {
            case .photo:
                if let file = obj.imageFile,
                   let image = FileStorageManager.shared.loadPageObjectImage(
                       notebookId: notebookId, fileName: file) {
                    // Aspect-fit inside the box (matches the on-screen .scaledToFit).
                    image.draw(in: aspectFit(imageSize: image.size, in: rect))
                }
            case .text:
                if let data = obj.textRTF,
                   let attr = RichText.attributedString(fromRTF: data) {
                    let textRect = rect.inset(by: RichText.textInset)
                    attr.draw(
                        with: textRect,
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    )
                }
            }
            ctx.restoreGState()
        }
    }

    /// Largest rect with `imageSize`'s aspect that fits centred inside `box`.
    private static func aspectFit(imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: box.midX - size.width / 2,
            y: box.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
