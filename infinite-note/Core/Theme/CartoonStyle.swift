import SwiftUI

// MARK: - Cartoon Design Language
//
// The shared "comic sticker book" look for InfiniteNote: a heavy ink outline,
// a hard (blur-free) offset shadow that lifts every element off the page, and
// chunky continuous corners. Everything here is theme-aware via ThemeManager,
// so it flips instantly between light and dark with no restart.

// MARK: Rounded display font

extension Font {
    /// Friendly rounded system font — the cartoon voice of the app.
    static func cartoon(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Cartoon Surface (outline + hard shadow)

private struct CartoonSurface: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager

    var fill: Color
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var shadowOffset: CGFloat
    var outlineColor: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let ink = outlineColor ?? theme.outline
        return content
            // Fill sits directly behind the content…
            .background(shape.fill(fill))
            // …the heavy ink outline rides on top of the fill edge…
            .overlay(shape.strokeBorder(ink, lineWidth: lineWidth))
            // …and a solid offset block behind everything is the hard shadow.
            .background(
                shape
                    .fill(theme.hardShadow)
                    .offset(x: shadowOffset, y: shadowOffset)
            )
    }
}

extension View {
    /// Wraps the view as a chunky cartoon "sticker": filled, ink-outlined,
    /// and lifted by a hard offset shadow.
    func cartoonSurface(
        fill: Color,
        cornerRadius: CGFloat = 22,
        lineWidth: CGFloat = 2.5,
        shadowOffset: CGFloat = 6,
        outlineColor: Color? = nil
    ) -> some View {
        modifier(CartoonSurface(
            fill: fill,
            cornerRadius: cornerRadius,
            lineWidth: lineWidth,
            shadowOffset: shadowOffset,
            outlineColor: outlineColor
        ))
    }
}

// MARK: - Cartoon Button Style
//
// A springy, chunky button that physically presses down into its own hard
// shadow when tapped. Use the convenience initializers for primary (filled)
// and secondary (card-filled, colored text) variants.

struct CartoonButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var cornerRadius: CGFloat
    var lineWidth: CGFloat

    init(fill: Color = .burgundy,
         foreground: Color = .white,
         cornerRadius: CGFloat = 16,
         lineWidth: CGFloat = 2.5) {
        self.fill = fill
        self.foreground = foreground
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        CartoonButtonBody(configuration: configuration,
                          fill: fill,
                          foreground: foreground,
                          cornerRadius: cornerRadius,
                          lineWidth: lineWidth)
    }

    private struct CartoonButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        let foreground: Color
        let cornerRadius: CGFloat
        let lineWidth: CGFloat

        @EnvironmentObject private var theme: ThemeManager

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            return configuration.label
                .font(.cartoon(16, weight: .heavy))
                .foregroundStyle(foreground)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(theme.outline, lineWidth: lineWidth))
                // Hard shadow collapses as the button sinks into it.
                .background(
                    shape.fill(theme.hardShadow)
                        .offset(x: pressed ? 1 : 5, y: pressed ? 1 : 5)
                )
                .offset(x: pressed ? 4 : 0, y: pressed ? 4 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: pressed)
        }
    }
}

// MARK: - Press-scale style (kept for grid cards)

struct CartoonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .rotationEffect(.degrees(configuration.isPressed ? -1.2 : 0))
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
