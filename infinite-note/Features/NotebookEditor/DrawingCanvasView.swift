//
//import SwiftUI
//import PencilKit
//
//// MARK: - Drawing Tool Type
//
//enum DrawingToolType: String, CaseIterable, Hashable {
//    case pen, marker, highlighter, eraser
//
//    var label: String {
//        switch self {
//        case .pen:         return "Pen"
//        case .eraser:      return "Eraser"
//        case .marker:      return "Marker"
//        case .highlighter: return "Highlight"        }
//    }
//
//    var systemImage: String {
//        switch self {
//        case .pen:         return "pencil.tip"
//        case .eraser:      return "eraser.fill"
//        case .marker:      return "paintbrush.pointed.fill"
//        case .highlighter: return "highlighter"        }
//    }
//
//    var sizeRange: ClosedRange<CGFloat> {
//        switch self {
//        case .pen:         return 1...20
//        case .eraser:      return 5...50
//        case .marker:      return 5...50
//        case .highlighter: return 10...60
//        }
//    }
//
//    var defaultSize: CGFloat {
//        switch self {
//        case .pen:         return 3
//        case .eraser:      return 20
//        case .marker:      return 15
//        case .highlighter: return 25
//        }
//    }
//}
//
//// MARK: - Canvas Controller
//
//@Observable
//final class CanvasController {
//    weak var canvasView: PKCanvasView?
//
//    func undo() { canvasView?.undoManager?.undo() }
//    func redo() { canvasView?.undoManager?.redo() }
//    func clearPage() { canvasView?.drawing = PKDrawing() }
//}
//
//// MARK: - Custom Multi-Finger Double-Tap Gesture Recognizer
////
//// WHY a custom GR instead of UITapGestureRecognizer:
////
//// UITapGestureRecognizer is unreliable on PKCanvasView because PencilKit adds its
//// own single-tap recognizers (2-touch = undo, 3-touch = redo) that share UIKit's
//// tap state machine. For 2-finger double-tap this causes the first tap to be
//// cancelled mid-flight by PencilKit. For 3-finger double-tap it's worse: UIKit
//// delivers touches[0..1] to the undo recognizer before touch[2] arrives, breaking
//// the timing window for our double-tap recognizer entirely.
////
//// A custom UIGestureRecognizer that tracks raw touch events bypasses that state
//// machine completely. It doesn't compete with PencilKit for "tap ownership" —
//// it just counts fingers and measures intervals independently.
////
//// Behaviour contract:
////   • Exactly `requiredTouchCount` fingers must be down simultaneously.
////   • Two touch-down → touch-up cycles within `maxInterval` seconds → .recognized.
////   • A finger count mismatch at any point → .failed immediately (so a 3-finger
////     gesture never accidentally triggers the 2-finger recognizer and vice-versa).
////   • cancelsTouchesInView = false so an active Pencil stroke is never interrupted.
//
//final class MultiFingerDoubleTapGestureRecognizer: UIGestureRecognizer {
//
//    var requiredTouchCount: Int
//    var maxInterval: TimeInterval = 0.35   // max gap between tap 1 and tap 2
//    var maxTapDuration: TimeInterval = 0.25 // max time a single tap may take
//
//    private var tap1EndTime: TimeInterval = 0
//    private var activeTouches: Set<UITouch> = []
//    private var tapCount: Int = 0
//
//    init(touchCount: Int, target: Any?, action: Selector?) {
//        self.requiredTouchCount = touchCount
//        super.init(target: target, action: action)
//        cancelsTouchesInView = false
//        delaysTouchesBegan  = false
//        delaysTouchesEnded  = false
//    }
//
//    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
//        super.touchesBegan(touches, with: event)
//
//        activeTouches.formUnion(touches)
//
//        // If too many fingers → fail immediately.
//        if activeTouches.count > requiredTouchCount {
//            reset()
//            state = .failed
//            return
//        }
//    }
//
//    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
//        super.touchesEnded(touches, with: event)
//
//        // Only act when the exact right number of fingers lifted together.
//        guard activeTouches.count == requiredTouchCount else {
//            activeTouches.subtract(touches)
//            return
//        }
//
//        let now = event.timestamp
//
//        switch tapCount {
//        case 0:
//            // First tap up: record the time, wait for a second tap.
//            tap1EndTime = now
//            tapCount = 1
//            activeTouches.subtract(touches)
//
//        case 1:
//            // Second tap up: check it arrived within the interval.
//            if now - tap1EndTime <= maxInterval {
//                state = .recognized   // 🎉
//            } else {
//                // Too slow — treat this as a new first tap.
//                tap1EndTime = now
//                activeTouches.subtract(touches)
//            }
//
//        default:
//            reset()
//            state = .failed
//        }
//    }
//
//    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
//        super.touchesCancelled(touches, with: event)
//        activeTouches.subtract(touches)
//        reset()
//        state = .failed
//    }
//
//    override func reset() {
//        super.reset()
//        activeTouches.removeAll()
//        tapCount = 0
//        tap1EndTime = 0
//    }
//}
//
//// MARK: - Managed Canvas View
////
//// PKCanvasView subclass that intercepts every GR PencilKit adds (including lazy
//// post-window ones) so we can make PencilKit's own 2-touch / 3-touch single-tap
//// GRs require our custom recognizers to fail first.
//// (Keeps PencilKit's built-in single-tap undo/redo working when our GRs don't fire.)
//
//final class ManagedCanvasView: PKCanvasView {
//
//    /// Our 2-finger double-tap recognizer (undo). Set before adding to window.
//    weak var undoGesture: UIGestureRecognizer?
//    /// Our 3-finger double-tap recognizer (redo). Set before adding to window.
//    weak var redoGesture: UIGestureRecognizer?
//
//    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
//        super.addGestureRecognizer(gestureRecognizer)
//
//        // Only patch PencilKit's single-tap recognizers (numberOfTapsRequired == 1).
//        // Our custom GRs are not UITapGestureRecognizers, so they're never matched here.
//        guard let tap = gestureRecognizer as? UITapGestureRecognizer,
//              tap.numberOfTapsRequired == 1 else { return }
//
//        if tap.numberOfTouchesRequired == 2, let undoGR = undoGesture {
//            tap.require(toFail: undoGR)
//        } else if tap.numberOfTouchesRequired == 3, let redoGR = redoGesture {
//            tap.require(toFail: redoGR)
//        }
//    }
//}
//
//// MARK: - Drawing Canvas View
//
//struct DrawingCanvasView: UIViewRepresentable {
//    @Binding var drawing: PKDrawing
//    var isRulerActive: Bool = false
//    var toolType: DrawingToolType = .pen
//    var color: UIColor = .black
//    var lineWidth: CGFloat = 3
//    var canvasController: CanvasController
//    var onErasePage: () -> Void
//    var onNextPage:  () -> Void = {}
//    var onPrevPage:  () -> Void = {}
//    var onNewPage:   () -> Void = {}
//
//    func makeUIView(context: Context) -> ManagedCanvasView {
//        let canvas = ManagedCanvasView()
//        canvas.drawing        = drawing
//        canvas.isRulerActive  = isRulerActive
//        canvas.backgroundColor = .clear
//
//        // Only Apple Pencil draws; fingers are reserved for gestures.
//        canvas.drawingPolicy = .pencilOnly
//
//        canvas.delegate       = context.coordinator
//        // contentSize is pinned to bounds.size in updateUIView — no scrolling in any direction.
//        canvas.alwaysBounceVertical           = false
//        canvas.alwaysBounceHorizontal         = false
//        canvas.showsHorizontalScrollIndicator = false
//        canvas.showsVerticalScrollIndicator   = false
//        canvas.isScrollEnabled                = false
//
//        let coord = context.coordinator
//
//        // ── Undo: 2-finger double-tap ────────────────────────────────────
//        let undo = MultiFingerDoubleTapGestureRecognizer(
//            touchCount: 2,
//            target: coord,
//            action: #selector(Coordinator.handleUndo))
//        undo.delegate = coord
//
//        // ── Redo: 3-finger double-tap ────────────────────────────────────
//        let redo = MultiFingerDoubleTapGestureRecognizer(
//            touchCount: 3,
//            target: coord,
//            action: #selector(Coordinator.handleRedo))
//        redo.delegate = coord
//
//        // NOTE: No require(toFail:) between undo and redo.
//        // The custom GR's exact finger-count check (activeTouches.count > requiredTouchCount → .failed)
//        // already makes them mutually exclusive. Adding require(toFail:) here would cause UIKit to
//        // hold undo in a pending state, which triggers touchesCancelled on the redo GR before its
//        // second tap can arrive — breaking redo entirely.
//
//        // Register with ManagedCanvasView BEFORE adding so that if PencilKit
//        // eagerly adds its own tap GRs during addGestureRecognizer / didMoveToWindow,
//        // the require(toFail:) relationships are already set up.
//        canvas.undoGesture = undo
//        canvas.redoGesture = redo
//
//        // Snapshot any GRs already present (added during PKCanvasView.init).
//        let preExisting = canvas.gestureRecognizers ?? []
//
//        canvas.addGestureRecognizer(undo)
//        canvas.addGestureRecognizer(redo)
//
//        // ── Erase page: 3-finger long-press (3 s) ───────────────────────
//        let erase = UILongPressGestureRecognizer(
//            target: coord, action: #selector(Coordinator.handleErasePage(_:)))
//        erase.numberOfTouchesRequired = 3
//        erase.minimumPressDuration    = 3.0
//        erase.cancelsTouchesInView    = false
//        canvas.addGestureRecognizer(erase)
//
//        // ── Next page: 4-finger swipe left ──────────────────────────────
//        let nextPage = UISwipeGestureRecognizer(
//            target: coord, action: #selector(Coordinator.handleSwipeLeft))
//        nextPage.numberOfTouchesRequired = 4
//        nextPage.direction               = .left
//        nextPage.cancelsTouchesInView    = false
//        canvas.addGestureRecognizer(nextPage)
//
//        // ── Previous page: 4-finger swipe right ─────────────────────────
//        let prevPage = UISwipeGestureRecognizer(
//            target: coord, action: #selector(Coordinator.handleSwipeRight))
//        prevPage.numberOfTouchesRequired = 4
//        prevPage.direction               = .right
//        prevPage.cancelsTouchesInView    = false
//        canvas.addGestureRecognizer(prevPage)
//
//        // ── New page: 3-finger swipe right ──────────────────────────────
//        let newPage = UISwipeGestureRecognizer(
//            target: coord, action: #selector(Coordinator.handleNewPage))
//        newPage.numberOfTouchesRequired = 3
//        newPage.direction               = .right
//        newPage.cancelsTouchesInView    = false
//        canvas.addGestureRecognizer(newPage)
//
//        // Patch any PencilKit single-tap GRs that were already on the canvas.
//        for gr in preExisting {
//            guard let tap = gr as? UITapGestureRecognizer,
//                  tap.numberOfTapsRequired == 1 else { continue }
//            if tap.numberOfTouchesRequired == 2 { tap.require(toFail: undo) }
//            if tap.numberOfTouchesRequired == 3 { tap.require(toFail: redo) }
//        }
//
//        coord.ourGestureRecognizers = [undo, redo, erase, nextPage, prevPage, newPage]
//        canvasController.canvasView = canvas
//        coord.canvasController      = canvasController
//
//        applyTool(to: canvas)
//        return canvas
//    }
//
//    func updateUIView(_ canvas: ManagedCanvasView, context: Context) {
//        // Only update drawing when it actually differs (e.g. page switch).
//        // Unconditional assignment would erase strokes drawn during the debounce window.
//        if canvas.drawing != drawing { canvas.drawing = drawing }
//
//        canvas.isRulerActive        = isRulerActive
//        canvasController.canvasView = canvas
//        context.coordinator.parent  = self
//
//        // Pin contentSize to the view's own bounds so the canvas never scrolls.
//        let bounds = canvas.bounds
//        if bounds.width > 0 && canvas.contentSize != bounds.size {
//            canvas.contentSize = bounds.size
//        }
//
//        applyTool(to: canvas)
//    }
//
//    private func applyTool(to canvas: PKCanvasView) {
//        switch toolType {
//        case .pen:
//            canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
//        case .marker:
//            canvas.tool = PKInkingTool(.marker, color: color, width: lineWidth)
//        case .highlighter:
//            canvas.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.4), width: lineWidth)
//        case .eraser:
//            if #available(iOS 16.4, *) {
//                canvas.tool = PKEraserTool(.bitmap, width: lineWidth)
//            } else {
//                canvas.tool = PKEraserTool(.vector)
//            }
//        }
//    }
//
//    func makeCoordinator() -> Coordinator { Coordinator(self) }
//
//    // MARK: - Coordinator
//
//    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
//        var parent: DrawingCanvasView
//        var canvasController: CanvasController?
//        /// All gesture recognizers we own — used in shouldRecognizeSimultaneously.
//        var ourGestureRecognizers: [UIGestureRecognizer] = []
//        private var debounceTask: Task<Void, Never>?
//
//        init(_ parent: DrawingCanvasView) { self.parent = parent }
//
//        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
//            let newDrawing = canvasView.drawing
//            debounceTask?.cancel()
//            debounceTask = Task { @MainActor in
//                try? await Task.sleep(for: .milliseconds(400))
//                guard !Task.isCancelled else { return }
//                parent.drawing = newDrawing
//            }
//        }
//
//        // MARK: UIGestureRecognizerDelegate
//
//        /// Our gestures coexist freely with each other and with scroll/pinch.
//        /// PencilKit's own GRs are handled via require(toFail:), not here.
//        func gestureRecognizer(
//            _ gestureRecognizer: UIGestureRecognizer,
//            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
//        ) -> Bool {
//            if ourGestureRecognizers.contains(other) { return true }
//            if other is UIPanGestureRecognizer || other is UIPinchGestureRecognizer { return true }
//            return false
//        }
//
//        /// Allow our custom recognizers to begin even when another GR has already
//        /// begun (e.g. PencilKit's scroll pan). Without this, the canvas's scroll
//        /// pan can preempt our touch tracking.
//        func gestureRecognizer(
//            _ gestureRecognizer: UIGestureRecognizer,
//            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
//        ) -> Bool {
//            false
//        }
//
//        // MARK: Gesture Handlers
//
//        @objc func handleUndo() { canvasController?.undo() }
//        @objc func handleRedo() { canvasController?.redo() }
//
//        @objc func handleErasePage(_ g: UILongPressGestureRecognizer) {
//            guard g.state == .began else { return }
//            parent.onErasePage()
//        }
//
//        @objc func handleSwipeLeft()  { parent.onNextPage() }
//        @objc func handleSwipeRight() { parent.onPrevPage() }
//        @objc func handleNewPage()    { parent.onNewPage()  }
//    }
//}

import SwiftUI
import PencilKit

// MARK: - Drawing Tool Type

enum DrawingToolType: String, CaseIterable, Hashable {
    case pen, marker, highlighter, eraser

    var label: String {
        switch self {
        case .pen:         return "Pen"
        case .marker:      return "Marker"
        case .highlighter: return "Highlight"
        case .eraser:      return "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:         return "pencil.tip"
        case .marker:      return "paintbrush.pointed.fill"
        case .highlighter: return "highlighter"
        case .eraser:      return "eraser.fill"
        }
    }

    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .pen:         return 1...20
        case .marker:      return 5...50
        case .highlighter: return 10...60
        case .eraser:      return 5...50
        }
    }

    var defaultSize: CGFloat {
        switch self {
        case .pen:         return 3
        case .marker:      return 15
        case .highlighter: return 25
        case .eraser:      return 20
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
    var canvasController: CanvasController
    var onErasePage: () -> Void
    var onNextPage:  () -> Void = {}
    var onPrevPage:  () -> Void = {}
    var onNewPage:   () -> Void = {}

    func makeUIView(context: Context) -> ManagedCanvasView {
        let canvas = ManagedCanvasView()
        canvas.drawing        = drawing
        canvas.isRulerActive  = isRulerActive
        canvas.backgroundColor = .clear

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

        // ── Next page: 4-finger swipe left ──────────────────────────────
        let nextPage = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleSwipeLeft))
        nextPage.numberOfTouchesRequired = 4
        nextPage.direction               = .left
        nextPage.cancelsTouchesInView    = false
        canvas.addGestureRecognizer(nextPage)

        // ── Previous page: 4-finger swipe right ─────────────────────────
        let prevPage = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleSwipeRight))
        prevPage.numberOfTouchesRequired = 4
        prevPage.direction               = .right
        prevPage.cancelsTouchesInView    = false
        canvas.addGestureRecognizer(prevPage)

        // ── New page: 3-finger swipe right ──────────────────────────────
        let newPage = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleNewPage))
        newPage.numberOfTouchesRequired = 3
        newPage.direction               = .right
        newPage.cancelsTouchesInView    = false
        canvas.addGestureRecognizer(newPage)

        // Patch any PencilKit single-tap GRs that were already on the canvas.
        for gr in preExisting {
            guard let tap = gr as? UITapGestureRecognizer,
                  tap.numberOfTapsRequired == 1 else { continue }
            if tap.numberOfTouchesRequired == 2 { tap.require(toFail: undo) }
            if tap.numberOfTouchesRequired == 3 { tap.require(toFail: redo) }
        }

        coord.ourGestureRecognizers = [undo, redo, erase, nextPage, prevPage, newPage]
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
        case .marker:
            canvas.tool = PKInkingTool(.marker, color: color, width: lineWidth)
        case .highlighter:
            canvas.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.4), width: lineWidth)
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

        @objc func handleSwipeLeft()  { parent.onNextPage() }
        @objc func handleSwipeRight() { parent.onPrevPage() }
        @objc func handleNewPage()    { parent.onNewPage()  }
    }
}
