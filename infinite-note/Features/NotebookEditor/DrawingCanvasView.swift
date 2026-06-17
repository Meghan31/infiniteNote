
import SwiftUI
import PencilKit

enum EraserMode: String, CaseIterable, Hashable {
    case stroke
    case bitmap

    var label: String {
        switch self {
        case .stroke: return "Stroke Eraser"
        case .bitmap: return "Pixel Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .stroke: return "scribble.variable"
        case .bitmap: return "eraser.line.dashed.fill"
        }
    }
}

// MARK: - Drawing Tool Type

enum DrawingToolType: String, CaseIterable, Hashable {
    case pen, customPen, pencil, fountainPen, monoline, marker, crayon, watercolor, highlighter, shape, lasso, eraser

    var label: String {
        switch self {
        case .pen:         return "Pen"
        case .customPen:   return "Custom Pen"
        case .pencil:      return "Pencil"
        case .fountainPen: return "Fountain"
        case .monoline:    return "Monoline"
        case .marker:      return "Marker"
        case .crayon:      return "Crayon"
        case .watercolor:  return "Watercolor"
        case .highlighter: return "Highlight"
        case .shape:       return "Shape"
        case .lasso:       return "Lasso"
        case .eraser:      return "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:         return "pencil.tip"
        case .customPen:   return "pencil.tip.crop.circle.badge.plus"
        case .pencil:      return "pencil"
        case .fountainPen: return "pencil.and.outline"
        case .monoline:    return "scribble"
        case .marker:      return "paintbrush.pointed.fill"
        case .crayon:      return "paintbrush.fill"
        case .watercolor:  return "drop.fill"
        case .highlighter: return "highlighter"
        case .shape:       return "square.on.circle"
        case .lasso:       return "lasso"
        case .eraser:      return "eraser.fill"
        }
    }

    /// The lasso is a SELECTION tool, not an ink tool — the Pencil doesn't
    /// draw while it's active; finger/Pencil gestures select & edit instead.
    var isSelectionTool: Bool { self == .lasso }

    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .pen:         return 1...20
        case .customPen:   return 1...24
        case .pencil:      return 1...20
        case .fountainPen: return 1...24
        case .monoline:    return 1...24
        case .marker:      return 5...50
        case .crayon:      return 4...40
        case .watercolor:  return 8...60
        case .highlighter: return 10...60
        case .shape:       return 1...24
        case .lasso:       return 1...24
        case .eraser:      return 5...50
        }
    }

    var defaultSize: CGFloat {
        switch self {
        case .pen:         return 3
        case .customPen:   return 3
        case .pencil:      return 4
        case .fountainPen: return 5
        case .monoline:    return 4
        case .marker:      return 15
        case .crayon:      return 12
        case .watercolor:  return 26
        case .highlighter: return 25
        case .shape:       return 4
        case .lasso:       return 4
        case .eraser:      return 20
        }
    }

    /// Tools that paint color — used to decide whether to show the color
    /// picker. The eraser and the lasso (a selection tool) paint nothing.
    var isInk: Bool { self != .eraser && self != .lasso }

    // MARK: Strength (0–10)
    //
    // A tool-independent "strength" scale: 0 = the tool's finest line,
    // 10 = its thickest. The same number suits every pen because it maps
    // onto EACH tool's own size range (a strength-5 marker is much wider
    // in points than a strength-5 pen — as it should be).

    /// Point width for a 0–10 strength (clamped).
    func width(forStrength strength: Double) -> CGFloat {
        let unit = min(max(strength, 0), 10) / 10
        return sizeRange.lowerBound
            + CGFloat(unit) * (sizeRange.upperBound - sizeRange.lowerBound)
    }

    /// 0–10 strength for a point width (clamped into `sizeRange`).
    func strength(forWidth width: CGFloat) -> Double {
        let span = sizeRange.upperBound - sizeRange.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(width, sizeRange.lowerBound), sizeRange.upperBound)
        return Double((clamped - sizeRange.lowerBound) / span) * 10
    }

    /// The tool's tuned `defaultSize` expressed on the strength scale —
    /// surfaced as the "best" value in the strength input.
    var recommendedStrength: Double { strength(forWidth: defaultSize) }

    /// Asset-catalog image name for the custom tool icon. When the asset exists
    /// it's used (full color); otherwise the view falls back to `systemImage`.
    /// Names match the downloaded artwork.
    var assetName: String {
        switch self {
        case .pen:         return "pen"
        case .customPen:   return "custom-pen" // dedicated artwork in Assets
        case .pencil:      return "pencil"
        case .fountainPen: return "feather-pen"
        case .monoline:    return "monoline"          // no art → SF fallback
        case .marker:      return "marker"
        case .crayon:      return "paint-brush"
        case .watercolor:  return "water-pen"
        case .highlighter: return "highlighter"
        case .shape:       return "shape"
        case .lasso:       return "lasso"            // no art → SF fallback
        case .eraser:      return "eraser"
        }
    }
}

// MARK: - Shape Recognition

private enum RecognizedShape {
    case line(CGPoint, CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case triangle([CGPoint])
}

private enum ShapeRecognitionEngine {
    static func recognizedStroke(from stroke: PKStroke) -> PKStroke? {
        let points = cleaned(stroke.path.map { $0.location })
        guard points.count >= 4 else { return nil }

        let bounds = boundingRect(points)
        let diagonal = distance(bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY))
        guard diagonal >= 24 else { return nil }

        let closedVertices = isClosed(points, diagonal: diagonal)
            ? simplifiedClosedVertices(points, tolerance: max(12, diagonal * 0.1))
            : []

        let shape = recognizeLine(points, diagonal: diagonal)
            ?? recognizeTriangle(closedVertices, diagonal: diagonal)
            ?? recognizeRectangle(points, bounds: bounds, diagonal: diagonal)
            ?? recognizeEllipse(points, bounds: bounds, diagonal: diagonal)

        guard let shape else { return nil }
        return makeStroke(for: shape, matching: stroke)
    }

    private static func recognizeLine(_ points: [CGPoint], diagonal: CGFloat) -> RecognizedShape? {
        guard let first = points.first, let last = points.last else { return nil }
        let direct = distance(first, last)
        guard direct >= 30 else { return nil }

        let total = pathLength(points)
        let averageError = points
            .map { distanceFromLine(point: $0, start: first, end: last) }
            .reduce(0, +) / CGFloat(points.count)

        guard total / direct <= 1.22, averageError <= max(8, diagonal * 0.055) else { return nil }
        return .line(first, last)
    }

    private static func recognizeRectangle(
        _ points: [CGPoint],
        bounds: CGRect,
        diagonal: CGFloat
    ) -> RecognizedShape? {
        guard isClosed(points, diagonal: diagonal),
              bounds.width >= 24,
              bounds.height >= 24 else { return nil }

        let threshold = max(8, diagonal * 0.07)
        let cornerThreshold = max(8, diagonal * 0.1)
        var edgeHits = [false, false, false, false]
        var cornerHits = [false, false, false, false]
        var totalError: CGFloat = 0
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY)
        ]

        for point in points {
            let distances = [
                abs(point.x - bounds.minX),
                abs(point.x - bounds.maxX),
                abs(point.y - bounds.minY),
                abs(point.y - bounds.maxY)
            ]
            guard let minDistance = distances.min() else { continue }
            totalError += minDistance
            for index in distances.indices where distances[index] <= threshold {
                edgeHits[index] = true
            }
            for index in corners.indices where distance(point, corners[index]) <= cornerThreshold {
                cornerHits[index] = true
            }
        }

        let averageError = totalError / CGFloat(points.count)
        guard edgeHits.allSatisfy({ $0 }),
              cornerHits.allSatisfy({ $0 }),
              averageError <= threshold else { return nil }
        return .rectangle(bounds)
    }

    private static func recognizeTriangle(_ vertices: [CGPoint], diagonal: CGFloat) -> RecognizedShape? {
        guard vertices.count == 3 else { return nil }
        let perimeter = pathLength(vertices + [vertices[0]])
        let area = abs(polygonArea(vertices))
        guard perimeter >= diagonal * 1.8 else { return nil }
        guard area >= diagonal * diagonal * 0.08 else { return nil }
        return .triangle(vertices)
    }

    private static func recognizeEllipse(
        _ points: [CGPoint],
        bounds: CGRect,
        diagonal: CGFloat
    ) -> RecognizedShape? {
        guard isClosed(points, diagonal: diagonal),
              bounds.width >= 24,
              bounds.height >= 24 else { return nil }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        guard radiusX > 0, radiusY > 0 else { return nil }

        let averageError = points.map { point -> CGFloat in
            let x = (point.x - center.x) / radiusX
            let y = (point.y - center.y) / radiusY
            return abs(sqrt(x * x + y * y) - 1)
        }
        .reduce(0, +) / CGFloat(points.count)

        guard averageError <= 0.2 else { return nil }
        return .ellipse(bounds)
    }

    private static func makeStroke(for shape: RecognizedShape, matching stroke: PKStroke) -> PKStroke {
        let points = points(for: shape)
        let template = stroke.path.first ?? PKStrokePoint(
            location: points.first ?? .zero,
            timeOffset: 0,
            size: CGSize(width: 4, height: 4),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )

        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: Double(index) * 0.01,
                size: template.size,
                opacity: template.opacity,
                force: max(template.force, 1),
                azimuth: template.azimuth,
                altitude: template.altitude
            )
        }

        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: nil)
    }

    private static func points(for shape: RecognizedShape) -> [CGPoint] {
        switch shape {
        case .line(let start, let end):
            return sampledPolyline([start, end], closed: false)
        case .rectangle(let rect):
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]
            return sampledPolyline(corners, closed: true)
        case .ellipse(let rect):
            let count = 72
            return (0...count).map { index in
                let angle = CGFloat(index) / CGFloat(count) * .pi * 2
                return CGPoint(
                    x: rect.midX + cos(angle) * rect.width / 2,
                    y: rect.midY + sin(angle) * rect.height / 2
                )
            }
        case .triangle(let vertices):
            return sampledPolyline(vertices, closed: true)
        }
    }

    private static func sampledPolyline(
        _ vertices: [CGPoint],
        closed: Bool,
        spacing: CGFloat = 12
    ) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var result: [CGPoint] = []
        let edgeCount = closed ? vertices.count : vertices.count - 1

        for index in 0..<edgeCount {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            let length = distance(start, end)
            let steps = max(1, Int(ceil(length / spacing)))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                ))
            }
        }

        if closed, let first = result.first {
            result.append(first)
        } else if let last = vertices.last {
            result.append(last)
        }
        return result
    }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2,
              let first = points.first,
              let last = points.last else { return points }

        var maxDistance: CGFloat = 0
        var maxIndex = 0
        for index in 1..<(points.count - 1) {
            let distance = distanceFromLine(point: points[index], start: first, end: last)
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = index
            }
        }

        if maxDistance > tolerance {
            let left = simplify(Array(points[0...maxIndex]), tolerance: tolerance)
            let right = simplify(Array(points[maxIndex...]), tolerance: tolerance)
            return left.dropLast() + right
        }
        return [first, last]
    }

    private static func simplifiedClosedVertices(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var loop = points
        if let first = loop.first, let last = loop.last, distance(first, last) <= tolerance {
            loop.removeLast()
        }
        guard loop.count > 3 else { return loop }

        let split = farthestPair(in: loop)
        let firstChain = chain(from: split.0, to: split.1, in: loop)
        let secondChain = chain(from: split.1, to: split.0, in: loop)
        let simplifiedFirst = simplify(firstChain, tolerance: tolerance)
        let simplifiedSecond = simplify(secondChain, tolerance: tolerance)

        let combined = Array(simplifiedFirst.dropLast()) + Array(simplifiedSecond.dropLast())
        return removeNearbyVertices(combined, minDistance: max(8, tolerance * 0.7))
    }

    private static func farthestPair(in points: [CGPoint]) -> (Int, Int) {
        var best = (0, min(points.count - 1, 1))
        var bestDistance: CGFloat = 0

        for left in points.indices {
            for right in points.indices where right > left {
                let candidate = distance(points[left], points[right])
                if candidate > bestDistance {
                    bestDistance = candidate
                    best = (left, right)
                }
            }
        }
        return best
    }

    private static func chain(from start: Int, to end: Int, in points: [CGPoint]) -> [CGPoint] {
        guard points.indices.contains(start), points.indices.contains(end) else { return points }
        if start <= end {
            return Array(points[start...end])
        }
        return Array(points[start...]) + Array(points[...end])
    }

    private static func removeNearbyVertices(_ vertices: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = []
        for vertex in vertices {
            guard let last = result.last else {
                result.append(vertex)
                continue
            }
            if distance(last, vertex) >= minDistance {
                result.append(vertex)
            }
        }

        if result.count > 1,
           let first = result.first,
           let last = result.last,
           distance(first, last) < minDistance {
            result.removeLast()
        }
        return result
    }

    private static func cleaned(_ points: [CGPoint]) -> [CGPoint] {
        points.reduce(into: []) { result, point in
            guard let last = result.last else {
                result.append(point)
                return
            }
            if distance(last, point) > 1.5 {
                result.append(point)
            }
        }
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func isClosed(_ points: [CGPoint], diagonal: CGFloat) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        return distance(first, last) <= max(18, diagonal * 0.22)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).map(distance).reduce(0, +)
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var total: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            total += points[index].x * next.y - next.x * points[index].y
        }
        return total / 2
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private static func distanceFromLine(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let length = distance(start, end)
        guard length > 0 else { return distance(point, start) }
        let numerator = abs(
            (end.y - start.y) * point.x
            - (end.x - start.x) * point.y
            + end.x * start.y
            - end.y * start.x
        )
        return numerator / length
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
    /// Read-only mode: drawing and all editing gestures are disabled; the
    /// ONLY recognized gestures are 3-finger horizontal swipes —
    /// right→left = next page, left→right = previous page.
    var isReadOnly: Bool = false
    var eraserMode: EraserMode = .bitmap
    /// Active pen preset for the `.pen` tool — nil means the built-in
    /// Default Pen (handwriting-tuned). Drives both the live tool mapping
    /// and the post-stroke refinement.
    var penPreset: CustomPen? = nil
    /// Changes ONLY when the hosting view replaced `drawing` externally (page
    /// switch / erase / load). The canvas is refreshed from the binding solely
    /// when this differs from the last applied value — so an incidental
    /// re-render can never overwrite strokes still inside the autosave debounce.
    var loadToken: Int = 0
    var canvasController: CanvasController
    var onErasePage: () -> Void
    var onNextPage:  () -> Void = {}   // 3-finger swipe up (edit) / swipe left (read-only)
    var onPrevPage:  () -> Void = {}   // 3-finger swipe down (edit) / swipe right (read-only)

    func makeUIView(context: Context) -> ManagedCanvasView {
        let canvas = ManagedCanvasView()
        canvas.drawing        = drawing
        canvas.isRulerActive  = isRulerActive
        canvas.backgroundColor = .clear
        // Align PencilKit's ink inversion with OUR theme (not the system one).
        canvas.overrideUserInterfaceStyle = isDarkTheme ? .dark : .light

        // Only Apple Pencil draws; fingers are reserved for gestures.
        // SIMULATOR has no Pencil — without this escape hatch the mouse
        // draws nothing and every tool looks completely dead there.
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif

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

        // ── Read-only page turns: 3-finger horizontal swipes ────────────
        // right→left = next page; left→right = previous page.
        // Disabled in edit mode; the ONLY active gestures in read-only mode.
        let readNext = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleSwipeLeft))
        readNext.numberOfTouchesRequired = 3
        readNext.direction               = .left
        readNext.cancelsTouchesInView    = false
        readNext.isEnabled               = false
        canvas.addGestureRecognizer(readNext)

        let readPrev = UISwipeGestureRecognizer(
            target: coord, action: #selector(Coordinator.handleSwipeRight))
        readPrev.numberOfTouchesRequired = 3
        readPrev.direction               = .right
        readPrev.cancelsTouchesInView    = false
        readPrev.isEnabled               = false
        canvas.addGestureRecognizer(readPrev)

        // Patch any PencilKit single-tap GRs that were already on the canvas.
        for gr in preExisting {
            guard let tap = gr as? UITapGestureRecognizer,
                  tap.numberOfTapsRequired == 1 else { continue }
            if tap.numberOfTouchesRequired == 2 { tap.require(toFail: undo) }
            if tap.numberOfTouchesRequired == 3 { tap.require(toFail: redo) }
        }

        coord.ourGestureRecognizers = [undo, redo, erase, prevPage, nextPage, readNext, readPrev]
        coord.editingGestures = [undo, redo, erase, prevPage, nextPage]
        coord.readingGestures = [readNext, readPrev]
        canvasController.canvasView = canvas
        coord.canvasController      = canvasController

        applyReadOnlyState(to: canvas, coordinator: coord)
        applyTool(to: canvas)
        // The initial drawing is already on the canvas; record its token so the
        // first incidental update doesn't re-apply (or wipe) it.
        coord.appliedLoadToken = loadToken
        return canvas
    }

    func updateUIView(_ canvas: ManagedCanvasView, context: Context) {
        // Push the binding onto the canvas ONLY on an external replacement
        // (page switch / erase / load), detected by a change in `loadToken`.
        // Comparing `canvas.drawing != drawing` here was the bug: an incidental
        // SwiftUI re-render during the ~400 ms autosave debounce (when the
        // binding still holds the OLD drawing while the canvas already has the
        // newest stroke) would assign the stale value back and ERASE the stroke.
        if context.coordinator.appliedLoadToken != loadToken {
            context.coordinator.appliedLoadToken = loadToken
            if canvas.drawing != drawing {
                canvas.drawing = drawing
                // External replacement: everything now on the canvas is
                // pre-existing ink — it must never be swept into refinement.
                context.coordinator.resetPenRefinementTracking(for: canvas)
            }
        }

        canvas.isRulerActive        = isRulerActive
        canvas.overrideUserInterfaceStyle = isDarkTheme ? .dark : .light
        canvasController.canvasView = canvas
        context.coordinator.parent  = self

        // Pin contentSize to the view's own bounds so the canvas never scrolls.
        let bounds = canvas.bounds
        if bounds.width > 0 && canvas.contentSize != bounds.size {
            canvas.contentSize = bounds.size
        }

        applyReadOnlyState(to: canvas, coordinator: context.coordinator)
        applyTool(to: canvas)
    }

    /// Flips drawing + gesture availability between edit and read-only modes.
    /// The lasso tool also disables ink (drawing) while keeping the editing
    /// gestures (undo/redo/page-turn) live, so selection never lays down ink.
    private func applyReadOnlyState(to canvas: ManagedCanvasView, coordinator: Coordinator) {
        canvas.drawingGestureRecognizer.isEnabled = !isReadOnly && !toolType.isSelectionTool
        coordinator.editingGestures.forEach { $0.isEnabled = !isReadOnly }
        coordinator.readingGestures.forEach { $0.isEnabled = isReadOnly }
    }

    private func applyTool(to canvas: PKCanvasView) {
        switch toolType {
        case .pen:
            // The NORMAL pen — stock PencilKit ink, no refinement, no presets.
            canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
        case .customPen:
            // Custom Pen — Default (handwriting-tuned) or a saved preset.
            // Opacity/ink flow/softness live in the preset; stabilization,
            // smoothing, tapers and pressure clamping are applied post-stroke
            // by StrokeRefiner.
            canvas.tool = (penPreset ?? CustomPen.defaultPen)
                .inkingTool(color: color, width: lineWidth)
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
        case .shape:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.monoline, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
            }
        case .lasso:
            // Selection mode — no ink is laid down. The drawing gesture is
            // disabled in `applyReadOnlyState`; the SwiftUI selection overlay
            // handles all touches. Keep a harmless tool assigned.
            canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
        case .eraser:
            switch eraserMode {
            case .stroke:
                canvas.tool = PKEraserTool(.vector)
            case .bitmap:
                canvas.tool = PKEraserTool(.bitmap, width: lineWidth)
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
        /// Gestures that modify content — disabled in read-only mode.
        var editingGestures: [UIGestureRecognizer] = []
        /// Read-only page-turn swipes — enabled ONLY in read-only mode.
        var readingGestures: [UIGestureRecognizer] = []
        /// Last `loadToken` applied to the canvas — guards against re-applying
        /// (and wiping) the drawing on incidental re-renders.
        var appliedLoadToken: Int = -1
        private var debounceTask: Task<Void, Never>?
        private var shapeRecognitionTask: Task<Void, Never>?
        private var shapeStartStrokeCount: Int?
        private var pendingShapeRecognitionStartCount: Int?
        private var penRefinementTask: Task<Void, Never>?
        /// True from tool-down to tool-up. While a stroke is in flight the
        /// canvas drawing must NEVER be replaced — a programmatic
        /// `canvas.drawing =` assignment CANCELS the live stroke, which is
        /// exactly how fast handwriting was losing strokes.
        private var isStrokeInFlight = false
        /// Strokes already on the canvas when the latest custom-pen stroke
        /// began. The diff against this identifies EXACTLY what the user just
        /// drew — loaded pages, other tools' ink and eraser splits can never
        /// leak into refinement. Re-snapshotted on every pen-down and on
        /// every external drawing replacement (page switch).
        private var penBaselineDates = Set<Date>()
        /// Custom-pen strokes queued for refinement (identified by
        /// `path.creationDate`, which survives refinement rebuilds).
        private var pendingRefineDates = Set<Date>()
        /// Strokes already refined once — never refined a second time.
        private var refinedStrokeDates = Set<Date>()

        init(_ parent: DrawingCanvasView) { self.parent = parent }

        /// Hosting view replaced the drawing (page switch / reload):
        /// everything now on the canvas is pre-existing ink — drop any queued
        /// work and treat it all as off-limits for refinement.
        func resetPenRefinementTracking(for canvasView: PKCanvasView) {
            penRefinementTask?.cancel()
            pendingRefineDates.removeAll()
            penBaselineDates = Set(canvasView.drawing.strokes.map { $0.path.creationDate })
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isStrokeInFlight = true
            shapeStartStrokeCount = parent.toolType == .shape && !parent.isReadOnly
                ? canvasView.drawing.strokes.count
                : nil
            if parent.toolType == .customPen && !parent.isReadOnly {
                penBaselineDates = Set(canvasView.drawing.strokes.map { $0.path.creationDate })
            }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isStrokeInFlight = false
            if parent.toolType == .shape, let startCount = shapeStartStrokeCount {
                pendingShapeRecognitionStartCount = startCount
                scheduleShapeRecognition(on: canvasView)
            }
            if parent.toolType == .customPen {
                collectPendingPenStrokes(on: canvasView)
                schedulePenRefinement(on: canvasView)
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let newDrawing = canvasView.drawing
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                parent.drawing = newDrawing
            }
            if parent.toolType == .shape, pendingShapeRecognitionStartCount != nil {
                scheduleShapeRecognition(on: canvasView)
            }
            // A cancelled stroke (palm, system gesture) can skip
            // didEndUsingTool and leave the in-flight flag stuck — the
            // gesture recognizer is the ground truth, so self-heal here.
            if isStrokeInFlight {
                switch canvasView.drawingGestureRecognizer.state {
                case .began, .changed: break          // genuinely drawing
                default: isStrokeInFlight = false     // stale flag — clear it
                }
            }
            // A stroke can commit to `.drawing` AFTER didEndUsingTool —
            // pick it up here, but only while the pen is up.
            if parent.toolType == .customPen, !isStrokeInFlight {
                collectPendingPenStrokes(on: canvasView)
                if !pendingRefineDates.isEmpty {
                    schedulePenRefinement(on: canvasView)
                }
            }
        }

        // MARK: Custom Pen refinement
        //
        // STROKE-SAFE catch-up design: refinement only ever runs while no
        // stroke is in flight, and only on strokes the user demonstrably drew
        // with the Custom Pen (baseline diff). If the user writes fast, the
        // pass waits for the next pen-up and refines the batch — nothing is
        // ever dropped, and foreign ink is never touched.

        /// Queues strokes drawn since the last pen-down. By construction the
        /// queue can only ever contain custom-pen strokes from this session.
        private func collectPendingPenStrokes(on canvasView: PKCanvasView) {
            for stroke in canvasView.drawing.strokes {
                let date = stroke.path.creationDate
                if !penBaselineDates.contains(date), !refinedStrokeDates.contains(date) {
                    pendingRefineDates.insert(date)
                }
            }
        }

        private func schedulePenRefinement(on canvasView: PKCanvasView) {
            penRefinementTask?.cancel()
            penRefinementTask = Task { @MainActor [weak self, weak canvasView] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled,
                      let self,
                      let canvasView else { return }
                self.applyPenRefinementIfNeeded(on: canvasView)
            }
        }

        private func applyPenRefinementIfNeeded(on canvasView: PKCanvasView) {
            // Never touch the drawing mid-stroke; the next pen-up reschedules.
            guard parent.toolType == .customPen,
                  !isStrokeInFlight,
                  !pendingRefineDates.isEmpty else { return }
            // The Pencil can be back on the paper BEFORE PencilKit delivers
            // didBeginUsingTool — the drawing gesture recognizer knows first.
            // Replacing the drawing in that sliver cancels the new stroke.
            switch canvasView.drawingGestureRecognizer.state {
            case .began, .changed: return   // a stroke is starting; defer
            default: break
            }

            let pen = parent.penPreset ?? CustomPen.defaultPen
            var strokes = canvasView.drawing.strokes
            var changed = false
            for index in strokes.indices {
                let date = strokes[index].path.creationDate
                guard pendingRefineDates.contains(date) else { continue }
                strokes[index] = StrokeRefiner.refine(strokes[index], with: pen)
                refinedStrokeDates.insert(date)
                pendingRefineDates.remove(date)
                changed = true
            }
            guard changed else { return }
            replaceDrawing(on: canvasView, with: PKDrawing(strokes: strokes), actionName: "Refine Stroke")
        }

        private func scheduleShapeRecognition(on canvasView: PKCanvasView) {
            shapeRecognitionTask?.cancel()
            shapeRecognitionTask = Task { @MainActor [weak self, weak canvasView] in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled,
                      let self,
                      let canvasView else { return }
                self.applyShapeRecognitionIfNeeded(on: canvasView)
            }
        }

        private func applyShapeRecognitionIfNeeded(on canvasView: PKCanvasView) {
            guard let startCount = pendingShapeRecognitionStartCount else { return }
            defer {
                shapeStartStrokeCount = nil
                pendingShapeRecognitionStartCount = nil
            }

            guard parent.toolType == .shape else { return }
            var strokes = canvasView.drawing.strokes
            guard strokes.count > startCount,
                  let lastStroke = strokes.last,
                  let recognizedStroke = ShapeRecognitionEngine.recognizedStroke(from: lastStroke) else { return }

            strokes[strokes.count - 1] = recognizedStroke
            replaceDrawing(on: canvasView, with: PKDrawing(strokes: strokes), actionName: "Recognize Shape")
        }

        private func replaceDrawing(on canvasView: PKCanvasView, with newDrawing: PKDrawing, actionName: String) {
            guard canvasView.drawing != newDrawing else { return }
            let previousDrawing = canvasView.drawing
            canvasView.undoManager?.registerUndo(withTarget: self) { [weak canvasView] coordinator in
                guard let canvasView else { return }
                coordinator.replaceDrawing(on: canvasView, with: previousDrawing, actionName: actionName)
            }
            canvasView.undoManager?.setActionName(actionName)
            canvasView.drawing = newDrawing
            parent.drawing = newDrawing
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

        @objc func handleSwipeUp()    { parent.onNextPage() }  // 3-finger up → next / new
        @objc func handleSwipeDown()  { parent.onPrevPage() }  // 3-finger down → previous
        @objc func handleSwipeLeft()  { parent.onNextPage() }  // read-only: right→left → next
        @objc func handleSwipeRight() { parent.onPrevPage() }  // read-only: left→right → previous
    }
}
