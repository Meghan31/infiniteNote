import Foundation
import PencilKit
import UIKit

/// Renders a `PKDrawing`'s strokes to a `UIImage` using ONLY Core Graphics —
/// no PencilKit rasterizer, so no dependency on the `handwritingd` daemon. This
/// is the cold-launch fallback: when `handwritingd` is unavailable (and both the
/// live `PKCanvasView` and offscreen `PKDrawing.image()` come back blank), this
/// still paints the saved ink so the user can see their page instead of a blank.
///
/// It is an APPROXIMATION — each stroke is drawn as a smoothed, constant-width
/// line in the ink's colour. Pen and ordinary handwriting look nearly identical;
/// textured inks (pencil/crayon/watercolour) and pressure taper are simplified.
/// It is display-only and never touches the saved drawing.
enum StrokeImageRenderer {

    /// Renders `drawing` at the page/canvas coordinate size. `darkTheme` mirrors
    /// PencilKit's automatic inversion of dark ink to light on a dark page.
    /// Returns nil for an empty drawing or a degenerate size.
    static func image(for drawing: PKDrawing, size: CGSize, darkTheme: Bool) -> UIImage? {
        guard !drawing.strokes.isEmpty,
              size.width > 1, size.height > 1,
              size.width.isFinite, size.height.isFinite else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in drawing.strokes {
                draw(stroke, in: cg, darkTheme: darkTheme)
            }
        }
    }

    private static func draw(_ stroke: PKStroke, in cg: CGContext, darkTheme: Bool) {
        // Collect the stroke's control points (location + width). This is the
        // same path data the app's StrokeRefiner already walks.
        var points: [(location: CGPoint, width: CGFloat)] = []
        for point in stroke.path {
            points.append((point.location, max(0.5, point.size.width)))
        }
        guard let first = points.first else { return }

        let color = displayColor(for: stroke.ink, darkTheme: darkTheme)
        // Representative width: the median keeps a few huge/tiny samples from
        // skewing the whole stroke.
        let width = medianWidth(points.map(\.width))

        cg.saveGState()
        cg.concatenate(stroke.transform)
        cg.setStrokeColor(color.cgColor)
        cg.setFillColor(color.cgColor)
        cg.setLineWidth(width)

        if points.count == 1 {
            // A single tap — draw a dot.
            let r = width / 2
            cg.fillEllipse(in: CGRect(x: first.location.x - r, y: first.location.y - r,
                                      width: width, height: width))
        } else {
            let path = CGMutablePath()
            path.move(to: first.location)
            if points.count == 2 {
                path.addLine(to: points[1].location)
            } else {
                // Smooth through the control points with quadratic curves to the
                // midpoints — turns a sparse polyline into a clean curve.
                for i in 1..<(points.count - 1) {
                    let current = points[i].location
                    let next = points[i + 1].location
                    let mid = CGPoint(x: (current.x + next.x) / 2,
                                      y: (current.y + next.y) / 2)
                    path.addQuadCurve(to: mid, control: current)
                }
                path.addLine(to: points[points.count - 1].location)
            }
            cg.addPath(path)
            cg.strokePath()
        }
        cg.restoreGState()
    }

    /// Mirrors PencilKit's behaviour of showing dark ink as light on a dark page.
    /// Only near-black ink is flipped (to white); coloured ink is left as-is.
    private static func displayColor(for ink: PKInk, darkTheme: Bool) -> UIColor {
        let base = ink.color
        guard darkTheme else { return base }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getRed(&r, green: &g, blue: &b, alpha: &a) else { return base }
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.25 ? UIColor(white: 1, alpha: a) : base
    }

    private static func medianWidth(_ widths: [CGFloat]) -> CGFloat {
        guard !widths.isEmpty else { return 2 }
        let sorted = widths.sorted()
        return sorted[sorted.count / 2]
    }
}
