import SwiftUI

// MARK: - Shelf (books-sidebar toggle + ☀/🌙)
//
// The pair of cartoon buttons pinned top-leading on the home screen and in the
// editor. On iPadOS 26+ the system wraps toolbar items in a shared Liquid
// Glass capsule and clips their content to it — which cut off the icons'
// outlines and hard shadows ("the shelf cuts the icons"). These buttons are
// already self-styled chips, so the glass capsule is hidden and the pair gets
// room for its shadows. Earlier iOS versions keep the plain toolbar item.

struct ShelfButtons: View {
    var onToggleBooks: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            JigglingIconButton(duration: 0.2, action: onToggleBooks) {
                AssetIcon(
                    asset: "book-sidebar",
                    systemName: "sidebar.left",
                    size: 34,
                    fallbackTint: themeManager.iconTint
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle books sidebar")

            ThemeToggleButton(size: 38)

            // Local backup: save the whole library to one file / import one.
            BackupMenuButton(size: 38)
        }
        // Breathing room for the hard shadows, which are drawn down-right.
        .padding(.leading, 2)
        .padding(.trailing, 8)
    }
}

private struct ShelfToolbarModifier: ViewModifier {
    var onToggleBooks: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShelfButtons(onToggleBooks: onToggleBooks)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            legacyToolbar(content)
        }
        #else
        legacyToolbar(content)
        #endif
    }

    private func legacyToolbar(_ content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ShelfButtons(onToggleBooks: onToggleBooks)
            }
        }
    }
}

extension View {
    /// Adds the shelf (books-sidebar toggle + theme switch) to the leading
    /// side of the navigation bar, without the system glass capsule.
    func shelfToolbar(onToggleBooks: @escaping () -> Void) -> some View {
        modifier(ShelfToolbarModifier(onToggleBooks: onToggleBooks))
    }
}
