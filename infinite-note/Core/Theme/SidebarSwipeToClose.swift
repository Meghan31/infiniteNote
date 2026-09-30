import SwiftUI
import UIKit

// MARK: - Swipe left to close the books sidebar
//
// The books sidebar is a NavigationSplitView column driven by a bound
// `columnVisibility`. On iPadOS 26 the floating sidebar could be dragged left
// but never actually closed — it snapped back (or hung half-way) because the
// system gesture doesn't reliably write `.detailOnly` back to the binding.
//
// This attaches one pan recognizer to the sidebar column's root view and, when
// a clearly-leftward swipe ends, calls `onSwipeLeft` — which sets the binding
// directly, so the close always sticks. It recognizes simultaneously with
// everything and never cancels touches, so scrolling, taps, context menus and
// the card "⋯" buttons behave exactly as before.

struct SidebarSwipeToClose: UIViewRepresentable {
    var onSwipeLeft: () -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onSwipeLeft = onSwipeLeft
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.onSwipeLeft = onSwipeLeft
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.detach()
    }

    final class AnchorView: UIView, UIGestureRecognizerDelegate {
        var onSwipeLeft: () -> Void = {}

        private weak var host: UIView?

        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { detach(); return }
            // The sidebar column's root: the nearest ancestor owned by a view
            // controller (the column's hosting controller view), so the swipe
            // works anywhere over the notebook list.
            var candidate = superview
            while let view = candidate, !(view.next is UIViewController) {
                candidate = view.superview
            }
            guard let target = candidate, target !== host else { return }
            detach()
            target.addGestureRecognizer(pan)
            host = target
        }

        func detach() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            // Clearly horizontal (so vertical scrolling never closes it) and
            // either far enough, or a quick flick.
            guard abs(translation.x) > abs(translation.y) * 1.4 else { return }
            if translation.x < -70 || (translation.x < -24 && velocity.x < -550) {
                onSwipeLeft()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
