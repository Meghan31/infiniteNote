import SwiftUI

// MARK: - Floating Theme Toggle (sun / moon, pure shapes)
//
// A floating button pinned to the top-right corner, layered above all other
// content with a ZStack overlay (see `themeToggleOverlay()` below). It is
// applied at the app root — covering home and editor — and inside every
// sheet, so the toggle is visible on every screen including modals.
//
// The glyph is drawn from pure shapes (no emoji): a rayed sun for light mode,
// a crescent moon for dark, both wearing the cartoon ink outline + hard shadow.

struct ThemeToggleButton: View {
    /// Disc diameter — 46 for the floating overlay (sheets), smaller when
    /// embedded in a navigation bar next to the book-sidebar icon.
    var size: CGFloat = 46

    @EnvironmentObject private var themeManager: ThemeManager

    private var glyphColor: Color {
        themeManager.isDark ? .lightBronze : .burgundy
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
                themeManager.toggle()
            }
        } label: {
            ZStack {
                // Chunky disc with the signature outline + hard shadow.
                Circle().fill(themeManager.card)
                Circle().strokeBorder(themeManager.outline, lineWidth: 2.5)

                Group {
                    if themeManager.isDark {
                        CrescentMoon()
                            .fill(glyphColor)
                            .overlay(CrescentMoon().stroke(themeManager.outline, lineWidth: 1.4))
                            .frame(width: 18, height: 18)
                    } else {
                        SunBadge(rayColor: glyphColor, ink: themeManager.outline)
                            .frame(width: 24, height: 24)
                    }
                }
                .id(themeManager.theme)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
                .scaleEffect(size / 46)
            }
            .frame(width: size, height: size)
            .background(
                Circle().fill(themeManager.hardShadow)
                    .offset(x: size * 0.087, y: size * 0.087)
            )
            .rotationEffect(.degrees(themeManager.isDark ? 360 : 0))
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: themeManager.theme)
        }
        .buttonStyle(CartoonPressStyle())
        .accessibilityLabel(themeManager.isDark ? "Switch to light mode" : "Switch to dark mode")
    }
}

// MARK: - Pure-shape glyphs

/// A filled sun: a solid core ringed by eight tapered rays.
private struct SunBadge: View {
    var rayColor: Color
    var ink: Color

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(rayColor)
                    .frame(width: 2.6, height: 6)
                    .offset(y: -10)
                    .rotationEffect(.degrees(Double(i) / 8 * 360))
            }
            Circle()
                .fill(rayColor)
                .overlay(Circle().strokeBorder(ink, lineWidth: 1.4))
                .frame(width: 13, height: 13)
        }
    }
}

/// A crescent moon, carved as one filled circle minus an offset circle.
private struct CrescentMoon: Shape {
    func path(in rect: CGRect) -> Path {
        let full = Path(ellipseIn: rect)
        let biteRect = rect.offsetBy(dx: rect.width * 0.34, dy: -rect.height * 0.12)
        let bite = Path(ellipseIn: biteRect)
        return full.subtracting(bite)
    }
}

// MARK: - Overlay Modifier

private struct ThemeToggleOverlay: ViewModifier {
    /// Distance below the safe-area top, so the button floats just under
    /// navigation bars instead of covering their trailing buttons.
    var topPadding: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .topTrailing) {
            content
            ThemeToggleButton()
                .padding(.top, topPadding)
                .padding(.trailing, 14)
        }
    }
}

extension View {
    /// Pins the floating ☀/🌙 theme toggle to the top-right corner,
    /// above all other views.
    func themeToggleOverlay(topPadding: CGFloat = 52) -> some View {
        modifier(ThemeToggleOverlay(topPadding: topPadding))
    }
}
