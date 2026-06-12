import Foundation
import CoreGraphics
import PencilKit

/// Applies a `CustomPen`'s stroke-behavior parameters to a COMPLETED stroke.
///
/// PencilKit doesn't expose its in-flight ink engine, so refinement runs the
/// moment a stroke is committed (`canvasViewDrawingDidChange`) — the standard
/// technique in handwriting apps. Everything operates on the stroke's
/// B-spline control points:
///
///   • stabilization      — jitter removal (weighted neighbor averaging)
///   • bezierSmoothing    — extra smoothing passes for rounder curves
///   • pressureSensitivity— width variation CLAMPED to ±sensitivity (a 7 %
///                          setting yields near-monoline ink with just a
///                          little life in it)
///   • velocitySensitivity— fast segments thin slightly, like real ink
///   • startTaper/endTaper— width ramps in/out at the stroke ends
///   • minWidth/maxWidth  — hard clamps
///
/// The function is PURE (stroke in → stroke out) and falls back to the
/// original stroke whenever the input is too short to refine safely.
enum StrokeRefiner {

    static func refine(_ stroke: PKStroke, with pen: CustomPen) -> PKStroke {
        let points = Array(stroke.path)
        guard points.count >= 4 else { return stroke }

        var locations = points.map(\.location)
        var widths = points.map { ($0.size.width + $0.size.height) / 2 }

        // ── 1. Stabilization + Bézier smoothing ──────────────────────────
        // Both are neighbor-averaging passes; stabilization weighs the blend,
        // smoothing adds passes. Endpoints stay fixed so the stroke never
        // shrinks or drifts.
        let passes = Int((pen.stabilization * 2 + pen.bezierSmoothing * 2).rounded())
        if passes > 0 {
            let blend = CGFloat(0.16 + 0.24 * max(pen.stabilization, pen.bezierSmoothing))
            for _ in 0..<passes {
                var smoothed = locations
                for i in 1..<(locations.count - 1) {
                    let mid = CGPoint(
                        x: (locations[i - 1].x + locations[i + 1].x) / 2,
                        y: (locations[i - 1].y + locations[i + 1].y) / 2
                    )
                    smoothed[i] = CGPoint(
                        x: locations[i].x + (mid.x - locations[i].x) * blend,
                        y: locations[i].y + (mid.y - locations[i].y) * blend
                    )
                }
                locations = smoothed
            }
        }

        // ── 2. Pressure clamp (monoline character) ───────────────────────
        // Width deviation from the mean is limited to ±pressureSensitivity.
        let meanWidth = max(0.1, widths.reduce(0, +) / CGFloat(widths.count))
        let band = CGFloat(max(0, min(0.2, pen.pressureSensitivity)))
        widths = widths.map { w in
            let deviation = (w - meanWidth) / meanWidth
            let clamped = min(max(deviation, -band), band)
            return meanWidth * (1 + clamped)
        }

        // ── 3. Velocity sensitivity ──────────────────────────────────────
        // Fast segments get slightly thinner. Speed is normalized against
        // the stroke's own median speed, so the effect is scale-free.
        let velocity = CGFloat(max(0, min(1, pen.velocitySensitivity)))
        if velocity > 0.01 {
            var speeds = [CGFloat](repeating: 0, count: points.count)
            for i in 1..<points.count {
                let dx = locations[i].x - locations[i - 1].x
                let dy = locations[i].y - locations[i - 1].y
                let dt = max(0.002, points[i].timeOffset - points[i - 1].timeOffset)
                speeds[i] = hypot(dx, dy) / CGFloat(dt)
            }
            speeds[0] = speeds.count > 1 ? speeds[1] : 0
            let sorted = speeds.sorted()
            let median = max(1, sorted[sorted.count / 2])
            for i in widths.indices {
                let ratio = min(3, speeds[i] / median)            // 0…3×
                let thinning = 1 - velocity * 0.3 * max(0, ratio - 1) / 2
                widths[i] *= max(0.55, thinning)
            }
        }

        // ── 4. Tapered start / end ───────────────────────────────────────
        // Taper length scales with the slider, up to ~22 % of the stroke.
        func applyTaper(_ amount: Double, fromStart: Bool) {
            guard amount > 0.01 else { return }
            let span = max(2, Int(Double(points.count) * 0.22 * amount))
            for offset in 0..<min(span, widths.count) {
                let index = fromStart ? offset : widths.count - 1 - offset
                let t = CGFloat(offset) / CGFloat(span)            // 0 at tip
                let scale = 0.18 + 0.82 * t * (2 - t)              // ease-out
                widths[index] *= min(1, scale)
            }
        }
        applyTaper(pen.startTaper, fromStart: true)
        applyTaper(pen.endTaper, fromStart: false)

        // ── 5. Hard width clamps ─────────────────────────────────────────
        let lower = CGFloat(max(0.25, pen.minWidth))
        let upper = CGFloat(max(pen.minWidth, pen.maxWidth))
        // Taper tips are allowed below minWidth — that's what a taper IS —
        // so the clamp floor eases off inside the taper spans.
        let startSpan = max(2, Int(Double(points.count) * 0.22 * pen.startTaper))
        let endSpan = max(2, Int(Double(points.count) * 0.22 * pen.endTaper))
        for i in widths.indices {
            let inStartTaper = pen.startTaper > 0.01 && i < startSpan
            let inEndTaper = pen.endTaper > 0.01 && i >= widths.count - endSpan
            let floorWidth = (inStartTaper || inEndTaper) ? lower * 0.3 : lower
            widths[i] = min(max(widths[i], floorWidth), upper)
        }

        // ── Rebuild ──────────────────────────────────────────────────────
        var refined: [PKStrokePoint] = []
        refined.reserveCapacity(points.count)
        for i in points.indices {
            let p = points[i]
            refined.append(PKStrokePoint(
                location: locations[i],
                timeOffset: p.timeOffset,
                size: CGSize(width: widths[i], height: widths[i]),
                opacity: p.opacity,
                force: p.force,
                azimuth: p.azimuth,
                altitude: p.altitude
            ))
        }
        let path = PKStrokePath(controlPoints: refined, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
    }
}
