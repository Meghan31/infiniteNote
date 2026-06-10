
import SwiftUI
import PencilKit

// MARK: - Drawing Tool Type

enum DrawingToolType: String, CaseIterable, Hashable {
    case pen, pencil, fountainPen, monoline, marker, crayon, watercolor, highlighter, eraser

    var label: String {
        switch self {
        case .pen:         return "Pen"
        case .pencil:      return "Pencil"
        case .fountainPen: return "Fountain"
        case .monoline:    return "Monoline"
        case .marker:      return "Marker"
        case .crayon:      return "Crayon"
        case .watercolor:  return "Watercolor"
        case .highlighter: return "Highlight"
        case .eraser:      return "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:         return "pencil.tip"
        case .pencil:      return "pencil"
        case .fountainPen: return "pencil.and.outline"
        case .monoline:    return "scribble"
        case .marker:      return "paintbrush.pointed.fill"
        case .crayon:      return "paintbrush.fill"
        case .watercolor:  return "drop.fill"
        case .highlighter: return "highlighter"
        case .eraser:      return "eraser.fill"
        }
    }

    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .pen:         return 1...20
        case .pencil:      return 1...20
        case .fountainPen: return 1...24
        case .monoline:    return 1...24
        case .marker:      return 5...50
        case .crayon:      return 4...40
        case .watercolor:  return 8...60
        case .highlighter: return 10...60
        case .eraser:      return 5...50
        }
    }

    var defaultSize: CGFloat {
        switch self {
        case .pen:         return 3
        case .pencil:      return 4
        case .fountainPen: return 5
        case .monoline:    return 4
        case .marker:      return 15
        case .crayon:      return 12
        case .watercolor:  return 26
        case .highlighter: return 25
        case .eraser:      return 20
        }
    }

    /// Tools that paint color (everything except the eraser) — used to decide
    /// whether to show the color picker.
    var isInk: Bool { self != .eraser }

    /// Asset-catalog image name for the custom tool icon. When the asset exists
    /// it's used (full color); otherwise the view falls back to `systemImage`.
    /// Names match the downloaded artwork.
    var assetName: String {
        switch self {
        case .pen:         return "pen"
        case .pencil:      return "pencil"
        case .fountainPen: return "feather-pen"
        case .monoline:    return "monoline"          // no art → SF fallback
        case .marker:      return "marker"
        case .crayon:      return "paint-brush"
        case .watercolor:  return "water-pen"
        case .highlighter: return "highlighter"
        case .eraser:      return "eraser"
        }
    }
}

// MARK: - Canvas Controller

@Observable
final class CanvasController {
    weak var canvasView: PKCanvasView?

    func undo() { canvasView?.undoManager?.undo() }
    func redo() { canvasView?.undoManager?.redo() }
    func clearPage() { canvasView?.drawing = PKDrawing() }
}

// MARK: - Custom Multi-Finger Double-Tap Gesture Recognizer
//
// WHY a custom GR instead of UITapGestureRecognizer:
//
// UITapGestureRecognizer is unreliable on PKCanvasView because PencilKit adds its
// own single-tap recognizers (2-touch = undo, 3-touch = redo) that share UIKit's
// tap state machine. For 2-finger double-tap this causes the first tap to be
// cancelled mid-flight by PencilKit. For 3-finger double-tap it's worse: UIKit
// delivers touches[0..1] to the undo recognizer before touch[2] arrives, breaking
// the timing window for our double-tap recognizer entirely.
//
// A custom UIGestureRecognizer that tracks raw touch events bypasses that state
// machine completely. It doesn't compete with PencilKit for "tap ownership" —
// it just counts fingers and measures intervals independently.
//
// Behaviour contract:
//   • Exactly `requiredTouchCount` fingers must be down simultaneously.
//   • Two touch-down → touch-up cycles within `maxInterval` seconds → .recognized.
//   • A finger count mismatch at any point → .failed immediately (so a 3-finger
//     gesture never accidentally triggers the 2-finger recognizer and vice-versa).
//   • cancelsTouchesInView = false so an active Pencil stroke is never interrupted.

final class MultiFingerDoubleTapGestureRecognizer: UIGestureRecognizer {

    var requiredTouchCount: Int
    var maxInterval: TimeInterval = 0.35   // max gap between tap 1 and tap 2
    var maxTapDuration: TimeInterval = 0.25 // max time a single tap may take

    private var tap1EndTime: TimeInterval = 0
    private var activeTouches: Set<UITouch> = []
    private var tapCount: Int = 0

    init(touchCount: Int, target: Any?, action: Selector?) {
        self.requiredTouchCount = touchCount
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan  = false
        delaysTouchesEnded  = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        activeTouches.formUnion(touches)

        // If too many fingers → fail immediately.
        if activeTouches.count > requiredTouchCount {
            reset()
            state = .failed
            return
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)

        // Only act when the exact right number of fingers lifted together.
        guard activeTouches.count == requiredTouchCount else {
            activeTouches.subtract(touches)
            return
        }

        let now = event.timestamp

        switch tapCount {
        case 0:
            // First tap up: record the time, wait for a second tap.
            tap1EndTime = now
            tapCount = 1
            activeTouches.subtract(touches)

        case 1:
            // Second tap up: check it arrived within the interval.
            if now - tap1EndTime <= maxInterval {
                state = .recognized   // 🎉
            } else {
                // Too slow — treat this as a new first tap.
                tap1EndTime = now
                activeTouches.subtract(touches)
            }

        default:
            reset()
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        activeTouches.subtract(touches)
        reset()
        state = .failed
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
        tapCount = 0
        tap1EndTime = 0
    }
}

// MARK: - Managed Canvas View
//
// PKCanvasView subclass that intercepts every GR PencilKit adds (including lazy
// post-window ones) so we can make PencilKit's own 2-touch / 3-touch single-tap
// GRs require our custom recognizers to fail first.
// (Keeps PencilKit's built-in single-tap undo/redo working when our GRs don't fire.)

final class ManagedCanvasView: PKCanvasView {

    /// Our 2-finger double-tap recognizer (undo). Set before adding to window.
    weak var undoGesture: UIGestureRecognizer?
    /// Our 3-finger double-tap recognizer (redo). Set before adding to window.
    weak var redoGesture: UIGestureRecognizer?

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)

        // Only patch PencilKit's single-tap recognizers (numberOfTapsRequired == 1).
        // Our custom GRs are not UITapGestureRecognizers, so they're never matched here.
        guard let tap = gestureRecognizer as? UITapGestureRecognizer,
              tap.numberOfTapsRequired == 1 else { return }

        if tap.numberOfTouchesRequired == 2, let undoGR = undoGesture {
            tap.require(toFail: undoGR)
        } else if tap.numberOfTouchesRequired == 3, let redoGR = redoGesture {
            tap.require(toFail: redoGR)
        }
    }

    // Block UITextInteraction at the point of addition.
    // iOS adds UITextInteraction lazily (after the view enters the window), so
    // removing it once in makeUIView is not enough — it gets re-added. By
    // overriding addInteraction we silently drop every UITextInteraction the
    // moment the system tries to attach it. This prevents the "Select All /
    // Insert Space" menu that a 3-finger double-tap normally triggers through
    // the text interaction layer, without affecting PencilKit or our gestures.
    override func addInteraction(_ interaction: UIInteraction) {
        if interaction is UITextInteraction { return }
        super.addInteraction(interaction)
    }
}

// MARK: - Drawing Canvas View

struct DrawingCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var isRulerActive: Bool = false
    var toolType: DrawingToolType = .pen
    var color: UIColor = .black
    var lineWidth: CGFloat = 3
    /// Our in-app theme. A hosted PKCanvasView otherwise follows the *system*
    /// appearance, so PencilKit would invert ink based on the OS dark/light
    /// setting instead of our page color. Pinning the canvas's interface style
    /// to this makes ink inversion line up with the page: black on a white
    /// page, white on a black page.
    var isDarkTheme: Bool = false
    var canvasController: CanvasController
    var onErasePage: () -> Void
    var onNextPage:  () -> Void = {}   // 3-finger swipe up
    var onPrevPage:  () -> Void = {}   // 3-finger swipe down

    func makeUIView(context: Context) -> ManagedCanvasView {
        let canvas = ManagedCanvasView()
        canvas.drawing        = drawing
        canvas.isRulerActive  = isRulerActive
        canvas.backgroundColor = .clear
        // Align PencilKit's ink inversion with OUR theme (not the system one).
        canvas.overrideUserInterfaceStyle = isDarkTheme ? .dark : .light

        // Only Apple Pencil draws; fingers are reserved for gestures.
        canvas.drawingPolicy = .pencilOnly

        canvas.delegate       = context.coordinator
        // contentSize is pinned to bounds.size in updateUIView — no scrolling in any direction.
        canvas.alwaysBounceVertical           = false
        canvas.alwaysBounceHorizontal         = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator   = false
        canvas.isScrollEnabled                = false

        let coord = context.coordinator

        // ── Undo: 2-finger double-tap ────────────────────────────────────
        let undo = MultiFingerDoubleTapGestureRecognizer(
            touchCount: 2,
            target: coord,
            action: #selector(Coordinator.handleUndo))
        undo.delegate = coord

        // ── Redo: 3-finger double-tap ────────────────────────────────────
        let redo = MultiFingerDoubleTapGestureRecognizer(
            touchCount: 3,
            target: coord,
            action: #selector(Coordinator.handleRedo))
        redo.delegate = coord

        // NOTE: No require(toFail:) between undo and redo.
        // The custom GR's exact finger-count check (activeTouches.count > requiredTouchCount → .failed)
        // already makes them mutually exclusive. Adding require(toFail:) here would cause UIKit to
        // hold undo in a pending state, which triggers touchesCancelled on the redo GR before its
        // second tap can arrive — breaking redo entirely.

        // Register with ManagedCanvasView BEFORE adding so that if PencilKit
        // eagerly adds its own tap GRs during addGestureRecognizer / didMoveToWindow,
        // the require(toFail:) relationships are already set up.
        canvas.undoGesture = undo
        canvas.redoGesture = redo

        // Snapshot any GRs already present (added during PKCanvasView.init).
        let preExisting = canvas.gestureRecognizers ?? []

        canvas.addGestureRecognizer(undo)
        canvas.addGestureRecognizer(redo)

        // ── Erase page: 3-finger long-press (3 s) ───────────────────────
        let erase = UILongPressGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleErasePage(_:)))
        erase.numberOfTouchesRequired = 3
        erase.minimumPressDuration    = 3.0
        erase.cancelsTouchesInView    = false
        canvas.addGestureRecognizer(erase)

        // ── Next page / new page: 3-finger swipe up ─────────────────────
        let nextPage = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleSwipeUp))
        nextPage.numberOfTouchesRequired = 3
        nextPage.direction               = .up
        nextPage.cancelsTouchesInView    = false
        canvas.addGestureRecognizer(nextPage)

        // ── Previous page: 3-finger swipe down ──────────────────────────
        let prevPage = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleSwipeDown))
        prevPage.numberOfTouchesRequired = 3
        prevPage.direction               = .down
        prevPage.cancelsTouchesInView    = false
        canvas.addGestureRecognizer(prevPage)

        // Patch any PencilKit single-tap GRs that were already on the canvas.
        for gr in preExisting {
            guard let tap = gr as? UITapGestureRecognizer,
                  tap.numberOfTapsRequired == 1 else { continue }
            if tap.numberOfTouchesRequired == 2 { tap.require(toFail: undo) }
            if tap.numberOfTouchesRequired == 3 { tap.require(toFail: redo) }
        }

        coord.ourGestureRecognizers = [undo, redo, erase, prevPage, nextPage]
        canvasController.canvasView = canvas
        coord.canvasController      = canvasController

        applyTool(to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: ManagedCanvasView, context: Context) {
        // Only update drawing when it actually differs (e.g. page switch).
        // Unconditional assignment would erase strokes drawn during the debounce window.
        if canvas.drawing != drawing { canvas.drawing = drawing }

        canvas.isRulerActive        = isRulerActive
        canvas.overrideUserInterfaceStyle = isDarkTheme ? .dark : .light
        canvasController.canvasView = canvas
        context.coordinator.parent  = self

        // Pin contentSize to the view's own bounds so the canvas never scrolls.
        let bounds = canvas.bounds
        if bounds.width > 0 && canvas.contentSize != bounds.size {
            canvas.contentSize = bounds.size
        }

        applyTool(to: canvas)
    }

    private func applyTool(to canvas: PKCanvasView) {
        switch toolType {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
        case .pencil:
            canvas.tool = PKInkingTool(.pencil, color: color, width: lineWidth)
        case .marker:
            canvas.tool = PKInkingTool(.marker, color: color, width: lineWidth)
        case .highlighter:
            canvas.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.4), width: lineWidth)
        case .fountainPen:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.fountainPen, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
            }
        case .monoline:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.monoline, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
            }
        case .crayon:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.crayon, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.pencil, color: color, width: lineWidth)
            }
        case .watercolor:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.watercolor, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.marker, color: color, width: lineWidth)
            }
        case .eraser:
            if #available(iOS 16.4, *) {
                canvas.tool = PKEraserTool(.bitmap, width: lineWidth)
            } else {
                canvas.tool = PKEraserTool(.vector)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var parent: DrawingCanvasView
        var canvasController: CanvasController?
        /// All gesture recognizers we own — used in shouldRecognizeSimultaneously.
        var ourGestureRecognizers: [UIGestureRecognizer] = []
        private var debounceTask: Task<Void, Never>?

        init(_ parent: DrawingCanvasView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let newDrawing = canvasView.drawing
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                parent.drawing = newDrawing
            }
        }

        // MARK: UIGestureRecognizerDelegate

        /// Our gestures coexist freely with each other and with scroll/pinch.
        /// PencilKit's own GRs are handled via require(toFail:), not here.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if ourGestureRecognizers.contains(other) { return true }
            if other is UIPanGestureRecognizer || other is UIPinchGestureRecognizer { return true }
            return false
        }

        /// Allow our custom recognizers to begin even when another GR has already
        /// begun (e.g. PencilKit's scroll pan). Without this, the canvas's scroll
        /// pan can preempt our touch tracking.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        // MARK: Gesture Handlers

        @objc func handleUndo() { canvasController?.undo() }
        @objc func handleRedo() { canvasController?.redo() }

        @objc func handleErasePage(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            parent.onErasePage()
        }

        @objc func handleSwipeUp()   { parent.onNextPage() }   // 3-finger up → next / new
        @objc func handleSwipeDown() { parent.onPrevPage() }   // 3-finger down → previous
    }
}
