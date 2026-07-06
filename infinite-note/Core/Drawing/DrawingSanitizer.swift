import Foundation
import PencilKit

/// PencilKit expects a drawing's strokes to be ordered by their paths'
/// `creationDate`. Two of our own features legitimately break that invariant
/// in SAVED data:
///   • lasso lift/merge re-appends moved ink at the END of the stroke array
///     while it keeps its ORIGINAL (older) creation dates, and
///   • the Custom Pen's post-stroke refinement rebuilds paths preserving the
///     original date (identity tracking), so batch catch-up passes can leave
///     equal/out-of-order timestamps.
///
/// On load, PencilKit's normalizer then logs "Suspect normalizing of a drawing
/// where stroke order is flipped. Reverting." — and on bad days that pass
/// wedges the ink renderer (`handwritingd`) for the WHOLE app: the loaded page
/// renders blank, thumbnails never finish, and even brand-new strokes in other
/// notebooks stop drawing once the poisoned drawing has been loaded.
///
/// The repair keeps the stroke ARRAY (visual/z) order exactly as the user drew
/// and layered it, and rewrites ONLY the internal timestamps so they strictly
/// increase in array order. Control points, ink, transforms and masks are
/// preserved untouched — the page looks identical, but PencilKit no longer has
/// anything to "revert".
enum DrawingSanitizer {

    struct Result {
        let drawing: PKDrawing
        let repairedStrokeCount: Int
        var repaired: Bool { repairedStrokeCount > 0 }
    }

    /// Returns the drawing unchanged when its stroke timestamps are already
    /// strictly increasing (the overwhelmingly common case — a cheap scan).
    static func sanitize(_ drawing: PKDrawing) -> Result {
        let strokes = drawing.strokes
        guard strokes.count > 1 else {
            return Result(drawing: drawing, repairedStrokeCount: 0)
        }

        var needsRepair = false
        var previous = Date.distantPast
        for stroke in strokes {
            let date = stroke.path.creationDate
            if date <= previous {
                needsRepair = true
                break
            }
            previous = date
        }
        guard needsRepair else {
            return Result(drawing: drawing, repairedStrokeCount: 0)
        }

        // Space repaired dates 1 ms apart from the earliest date present, so
        // the drawing's apparent age stays plausible and the result is
        // strictly increasing (idempotent: a repaired drawing passes the scan
        // above and is never rewritten again).
        let base = strokes.map(\.path.creationDate).min() ?? Date()
        var repairedStrokes: [PKStroke] = []
        repairedStrokes.reserveCapacity(strokes.count)
        var repairedCount = 0
        for (index, stroke) in strokes.enumerated() {
            let newDate = base.addingTimeInterval(Double(index) * 0.001)
            if stroke.path.creationDate == newDate {
                repairedStrokes.append(stroke)
                continue
            }
            // Same control points, same ink, same transform, same mask —
            // only the path's creation date changes.
            let points = Array(stroke.path)
            let path = PKStrokePath(controlPoints: points, creationDate: newDate)
            repairedStrokes.append(
                PKStroke(ink: stroke.ink, path: path,
                         transform: stroke.transform, mask: stroke.mask))
            repairedCount += 1
        }
        return Result(drawing: PKDrawing(strokes: repairedStrokes),
                      repairedStrokeCount: repairedCount)
    }
}
