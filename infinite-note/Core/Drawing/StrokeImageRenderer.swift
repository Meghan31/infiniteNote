import Foundation
import PencilKit
import UIKit

/// Renders a `PKDrawing`'s strokes to a `UIImage` using ONLY Core Graphics —
/// no PencilKit rasterizer, so no dependency on the `handwritingd` daemon. This
/// is the cold-launch fallback: when `handwritingd` is unavailable (and both the
/// live `PKCanvasView` and offscreen `PKDrawing.image()` come back blank), this
/// still paints the saved ink so the user can see their page instead of a blank.
///
/// It is an approximation, but it uses each saved PencilKit sample's width and
/// opacity so pressure, fountain-pen taper, and highlighter alpha stay close to
/// the original. Textured inks (pencil/crayon/watercolour) are simplified.
/// Display-only and never touches the saved drawing.
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
        // Collect the stroke's control points. This is the same path data the
        // app's StrokeRefiner already walks; using each sample's width avoids
        // flattening fountain/custom pen strokes into a normal monoline pen.
        var points: [(location: CGPoint, width: CGFloat, opacity: CGFloat)] = []
        for point in stroke.path {
            points.append((
                point.location,
                max(0.5, point.size.width),
                max(0.05, min(1, CGFloat(point.opacity)))
            ))
        }
        guard let first = points.first else { return }

        let color = displayColor(for: stroke.ink, darkTheme: darkTheme)
        let baseAlpha = color.cgColor.alpha

        cg.saveGState()
        cg.concatenate(stroke.transform)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        if points.count == 1 {
            // A single tap — draw a dot.
            let width = first.width
            let r = width / 2
            cg.setFillColor(color.withAlphaComponent(baseAlpha * first.opacity).cgColor)
            cg.fillEllipse(in: CGRect(x: first.location.x - r, y: first.location.y - r,
                                      width: width, height: width))
        } else {
            drawVariableWidthStroke(points, color: color, baseAlpha: baseAlpha, in: cg)
        }
        cg.restoreGState()
    }

    /// Builds one filled outline for the whole stroke. This avoids the
    /// "beads"/stop-marks caused by drawing every PencilKit sample as a short
    /// rounded segment, and it keeps highlighter strokes from darkening
    /// themselves at every internal overlap.
    private static func drawVariableWidthStroke(
        _ points: [(location: CGPoint, width: CGFloat, opacity: CGFloat)],
        color: UIColor,
        baseAlpha: CGFloat,
        in cg: CGContext
    ) {
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)

        for index in points.indices {
            let previous = points[max(points.startIndex, index - 1)].location
            let next = points[min(points.index(before: points.endIndex), index + 1)].location
            let current = points[index].location
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            let length = hypot(dx, dy)
            if length > 0.001 {
                dx /= length
                dy /= length
            } else {
                dx = 1
                dy = 0
            }

            let halfWidth = points[index].width / 2
            let normal = CGPoint(x: -dy, y: dx)
            left.append(CGPoint(
                x: current.x + normal.x * halfWidth,
                y: current.y + normal.y * halfWidth
            ))
            right.append(CGPoint(
                x: current.x - normal.x * halfWidth,
                y: current.y - normal.y * halfWidth
            ))
        }

        guard left.count > 1, right.count > 1 else { return }

        let averageOpacity = points.map(\.opacity).reduce(0, +) / CGFloat(points.count)
        cg.setFillColor(color.withAlphaComponent(baseAlpha * averageOpacity).cgColor)

        let outline = CGMutablePath()
        addSmoothedPolyline(left, to: outline, moveToFirst: true)
        addSmoothedPolyline(right.reversed(), to: outline, moveToFirst: false)
        outline.closeSubpath()
        cg.addPath(outline)
        cg.fillPath()

        // Round caps. Filled separately so the main outline can stay smooth
        // without per-sample overlap artifacts.
        if let first = points.first, let last = points.last {
            drawCap(at: first.location, width: first.width, color: color,
                    alpha: baseAlpha * first.opacity, in: cg)
            drawCap(at: last.location, width: last.width, color: color,
                    alpha: baseAlpha * last.opacity, in: cg)
        }
    }

    private static func addSmoothedPolyline<S: Sequence>(
        _ sequence: S,
        to path: CGMutablePath,
        moveToFirst: Bool
    ) where S.Element == CGPoint {
        let points = Array(sequence)
        guard let first = points.first else { return }
        if moveToFirst {
            path.move(to: first)
        } else {
            path.addLine(to: first)
        }
        guard points.count > 1 else { return }
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2,
                              y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
    }

    private static func drawCap(
        at point: CGPoint,
        width: CGFloat,
        color: UIColor,
        alpha: CGFloat,
        in cg: CGContext
    ) {
        let radius = width / 2
        cg.setFillColor(color.withAlphaComponent(alpha).cgColor)
        cg.fillEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: width,
            height: width
        ))
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

}
