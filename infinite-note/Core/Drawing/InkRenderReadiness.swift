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
/// THREADING RULE (learned the hard way): the pixel probe touches PencilKit's
/// Metal renderer, and with the daemon wedged that call can stall or abort the
/// process. It must therefore ONLY ever run on the private background probe
/// queue — NEVER synchronously on the main thread, and never from inside a
/// SwiftUI update (makeUIView/updateUIView). UI code reads the cached
/// `isReadyAndFresh` flag and asks for `verifyReadiness(...)`, which probes
/// asynchronously and answers on the main queue.
///
/// CRASH-LOOP BREAKER: a sentinel is persisted around every probe. If the app
/// ever dies INSIDE a probe (Metal abort while the daemon is wedged), the next
/// launch sees the sentinel, disables probing for that whole session, and the
/// app runs safely on the Core Graphics fallback ink instead of crash-looping.
///
/// It never touches user data — the probe uses a synthetic one-stroke drawing.
final class InkRenderReadiness: @unchecked Sendable {
    static let shared = InkRenderReadiness()

    /// Posted on the main thread whenever a probe CONFIRMS PencilKit can
    /// rasterize ink (idempotent for observers — they re-check their own state).
    static let didBecomeReadyNotification = Notification.Name("InkRenderReadiness.didBecomeReady")

    /// Whether PencilKit's ink rasterizer was up at the LAST successful probe.
    /// Read/written on the main thread. Stale by definition — prefer
    /// `isReadyAndFresh` for gating anything user-visible.
    private(set) var isReady = false

    /// When the last successful probe ran. `isReady` latching true forever was
    /// the original bug: iOS tears the daemon down while the app is suspended,
    /// so a flag set this morning is a lie by tonight.
    private var lastConfirmedAt: Date = .distantPast

    /// Cheap main-thread gate: ready AND confirmed within the last 20 s.
    var isReadyAndFresh: Bool {
        isReady && Date().timeIntervalSince(lastConfirmedAt) < 20
    }

    /// True when the previous session died inside a probe — probing is skipped
    /// for this entire session and the CG fallback carries the ink display.
    private let probingDisabled: Bool

    private var started = false
    private var verifyInFlight = false
    private var pendingVerifyCompletions: [(Bool) -> Void] = []
    private let probeQueue = DispatchQueue(label: "InkRenderReadiness.probe", qos: .userInitiated)

    private static let crashSentinelKey = "InkRenderReadiness.probeInFlight"

    private init() {
        let defaults = UserDefaults.standard
        probingDisabled = defaults.bool(forKey: Self.crashSentinelKey)
        if probingDisabled {
            // One-shot: re-enable on the NEXT launch so a transient OS-level
            // wedge doesn't disable probing forever.
            defaults.set(false, forKey: Self.crashSentinelKey)
            NSLog("InkRenderReadiness: last session died inside a render probe — probing disabled this session; CG fallback will display saved ink.")
        }
    }

    /// Begins probing/warming the renderer. Idempotent and cheap to call from
    /// several places (home screen, editor) — only the first call does work.
    func ensureWarmupStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.probingDisabled, !self.started, !self.isReady else { return }
            self.started = true
            self.probe(attempt: 0)
        }
    }

    /// Re-verifies rasterization with a real pixel probe — ASYNCHRONOUSLY, on
    /// the probe queue, never blocking the caller. `completion` runs on the
    /// main queue with the result. Concurrent calls coalesce onto one probe.
    /// A failed probe demotes `isReady` and restarts the warm-up loop; a
    /// successful one refreshes the flag and (re-)posts the ready notification
    /// so any parked canvas wakes up.
    func verifyReadiness(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let completion { self.pendingVerifyCompletions.append(completion) }
            guard !self.verifyInFlight else { return }
            guard !self.probingDisabled else {
                self.finishVerify(ok: false)
                return
            }
            self.verifyInFlight = true
            self.probeQueue.async {
                let ok = Self.guardedCanRasterizeInk()
                DispatchQueue.main.async {
                    self.verifyInFlight = false
                    if ok {
                        self.isReady = true
                        self.lastConfirmedAt = Date()
                        NotificationCenter.default.post(name: Self.didBecomeReadyNotification, object: nil)
                    } else {
                        self.isReady = false
                        self.ensureWarmupStarted()
                    }
                    self.finishVerify(ok: ok)
                }
            }
        }
    }

    private func finishVerify(ok: Bool) {
        let completions = pendingVerifyCompletions
        pendingVerifyCompletions.removeAll()
        completions.forEach { $0(ok) }
    }

    // Probe roughly every 0.5 s for ~40 s. Each attempt also nudges the daemon
    // to connect, so probing IS the warm-up.
    private func probe(attempt: Int) {
        let maxAttempts = 80
        probeQueue.async { [weak self] in
            guard let self else { return }
            if Self.guardedCanRasterizeInk() {
                DispatchQueue.main.async {
                    self.lastConfirmedAt = Date()
                    guard !self.isReady else { return }
                    self.isReady = true
                    NotificationCenter.default.post(name: Self.didBecomeReadyNotification, object: nil)
                }
                return
            }
            guard attempt < maxAttempts else {
                // Attempts exhausted (daemon wedged hard). Un-latch `started`
                // so a later trigger (page load, app foreground) can start a
                // fresh probe cycle instead of silently never trying again.
                DispatchQueue.main.async { self.started = false }
                return
            }
            self.probeQueue.asyncAfter(deadline: .now() + 0.5) {
                self.probe(attempt: attempt + 1)
            }
        }
    }

    /// Runs the pixel probe with the crash sentinel armed: if PencilKit aborts
    /// the process mid-render (seen with a hard-wedged daemon), the sentinel is
    /// already on disk and the next launch skips probing entirely instead of
    /// crash-looping. The sentinel is cleared the moment the probe RETURNS —
    /// a blank result is a normal, non-fatal outcome.
    private static func guardedCanRasterizeInk() -> Bool {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: crashSentinelKey)
        // Force the mark to disk BEFORE touching PencilKit — if the render
        // call kills the process there is no later chance to persist it.
        defaults.synchronize()
        let ok = canRasterizeInk()
        defaults.set(false, forKey: crashSentinelKey)
        return ok
    }

    /// Renders a tiny synthetic stroke and reports whether any ink actually
    /// rasterized. Returns false while `handwritingd` is still unavailable.
    /// MUST only be called via `guardedCanRasterizeInk()` on `probeQueue`.
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
