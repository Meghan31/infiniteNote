import Foundation
import PencilKit
import UIKit

/// PencilKit rasterizes ink through `handwritingd`, a system service that
/// connects ASYNCHRONOUSLY a few seconds into a cold launch and is torn down
/// repeatedly while it settles (the console shows "Remote connection to
/// handwritingd was invalidated"). Until it's up, NEITHER a live `PKCanvasView`
/// NOR an offscreen `PKDrawing.image()` produces any pixels — so saved pages
/// open completely blank even though the strokes loaded fine.
///
/// This type does two things:
///   1. WARMS the service up as early as possible (call `ensureWarmupStarted()`
///      when the home screen appears), so it's normally ready before the user
///      opens a note and the very first render succeeds.
///   2. Reports the EXACT moment rasterizing starts working, by repeatedly
///      rendering a tiny throwaway stroke offscreen and checking whether any
///      ink pixels came out. The editor listens for `didBecomeReadyNotification`
///      so it can show saved strokes the instant it's possible.
///
/// It never touches user data — the probe uses a synthetic one-stroke drawing.
final class InkRenderReadiness: @unchecked Sendable {
    static let shared = InkRenderReadiness()

    /// Posted on the main thread the first time PencilKit can rasterize ink.
    static let didBecomeReadyNotification = Notification.Name("InkRenderReadiness.didBecomeReady")

    /// Whether PencilKit's ink rasterizer is up. Read/written on the main thread.
    private(set) var isReady = false

    private var started = false
    private let probeQueue = DispatchQueue(label: "InkRenderReadiness.probe", qos: .userInitiated)

    private init() {}

    /// Begins probing/warming the renderer. Idempotent and cheap to call from
    /// several places (home screen, editor) — only the first call does work.
    func ensureWarmupStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.started, !self.isReady else { return }
            self.started = true
            self.probe(attempt: 0)
        }
    }

    // Probe roughly every 0.25 s for ~40 s. Each attempt also nudges the daemon
    // to connect, so probing IS the warm-up.
    private func probe(attempt: Int) {
        let maxAttempts = 160
        probeQueue.async { [weak self] in
            guard let self else { return }
            if Self.canRasterizeInk() {
                DispatchQueue.main.async {
                    guard !self.isReady else { return }
                    self.isReady = true
                    NotificationCenter.default.post(name: Self.didBecomeReadyNotification, object: nil)
                }
                return
            }
            guard attempt < maxAttempts else { return }
            self.probeQueue.asyncAfter(deadline: .now() + 0.25) {
                self.probe(attempt: attempt + 1)
            }
        }
    }

    /// Renders a tiny synthetic stroke and reports whether any ink actually
    /// rasterized. Returns false while `handwritingd` is still unavailable.
    private static func canRasterizeInk() -> Bool {
        var points: [PKStrokePoint] = []
        for i in 0..<6 {
            let t = CGFloat(i) / 5
            points.append(PKStrokePoint(
                location: CGPoint(x: 3 + t * 18, y: 8),
                timeOffset: TimeInterval(t) * 0.1,
                size: CGSize(width: 6, height: 6),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        let drawing = PKDrawing(strokes: [stroke])
        let image = drawing.image(from: CGRect(x: 0, y: 0, width: 24, height: 16), scale: 1)
        return imageHasInk(image)
    }

    private static func imageHasInk(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Any pixel with meaningful alpha means a stroke actually rendered.
        var i = 3
        while i < pixels.count {
            if pixels[i] > 10 { return true }
            i += 4
        }
        return false
    }
}
