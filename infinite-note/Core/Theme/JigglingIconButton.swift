import SwiftUI

struct JigglingIconButton<Label: View>: View {
    var duration: TimeInterval = 1
    var action: () -> Void
    private let label: () -> Label

    @State private var isJiggling = false
    @State private var jiggleStartedAt = Date.distantPast

    init(
        duration: TimeInterval = 1,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.duration = duration
        self.action = action
        self.label = label
    }

    var body: some View {
        Button {
            guard !isJiggling else { return }

            jiggleStartedAt = Date()
            isJiggling = true

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                isJiggling = false
                action()
            }
        } label: {
            label()
                .modifier(IconJiggleEffect(
                    isActive: isJiggling,
                    startDate: jiggleStartedAt,
                    duration: duration
                ))
        }
    }
}

private struct IconJiggleEffect: ViewModifier {
    let isActive: Bool
    let startDate: Date
    let duration: TimeInterval

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            let transform = transform(at: timeline.date)

            content
                .rotationEffect(.degrees(transform.rotation))
                .offset(x: transform.x, y: transform.y)
                .scaleEffect(transform.scale)
        }
    }

    private func transform(at date: Date) -> (rotation: Double, x: CGFloat, y: CGFloat, scale: CGFloat) {
        guard isActive, duration > 0 else {
            return (0, 0, 0, 1)
        }

        let elapsed = min(max(date.timeIntervalSince(startDate), 0), duration)
        let progress = elapsed / duration
        let wave = sin(elapsed * .pi * 14)
        let amplitude = 7 * (1 - progress * 0.25)
        let nudge = CGFloat(sin(elapsed * .pi * 28))

        return (
            rotation: wave * amplitude,
            x: nudge * 1.2,
            y: abs(nudge) * -0.8,
            scale: 1 + CGFloat(abs(wave)) * 0.035
        )
    }
}
