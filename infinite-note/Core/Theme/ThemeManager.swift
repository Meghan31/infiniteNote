import SwiftUI

// MARK: - App Theme
//
// The two global appearance modes for InfiniteNote.
//
//   Light: backgrounds #FFFFFF, notebook pages white, cards #F8F8F8, text #111111
//   Dark:  backgrounds #000000, notebook pages black, cards #111111, text #FFFFFF

enum AppTheme: String, CaseIterable {
    case light
    case dark

    /// Drives `.preferredColorScheme` so system chrome (nav bars, forms,
    /// materials, popovers) flips together with our custom surfaces —
    /// instantly, with no app restart.
    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    // MARK: Semantic surface tokens

    /// Screen / window background. #FFFFFF light, #000000 dark.
    var background: Color {
        self == .dark ? .themeBackgroundDark : .themeBackgroundLight
    }

    /// Notebook page (drawing canvas) surface. White light, black dark.
    var page: Color {
        self == .dark ? .themePageDark : .themePageLight
    }

    /// Cards, panels, sheets rows. #F8F8F8 light, #111111 dark.
    var card: Color {
        self == .dark ? .themeCardDark : .themeCardLight
    }

    /// Primary text. #111111 light, #FFFFFF dark.
    var textPrimary: Color {
        self == .dark ? .themeTextDark : .themeTextLight
    }

    /// Secondary text — derived from primary so no extra hex is needed.
    var textSecondary: Color {
        textPrimary.opacity(0.55)
    }

    /// Hairline borders and dividers.
    var border: Color {
        textPrimary.opacity(0.14)
    }

    /// Page grid / ruled / dot lines.
    var grid: Color {
        textPrimary.opacity(0.18)
    }

    // MARK: Cartoon tokens

    /// The signature heavy ink outline used around cards, buttons and the
    /// floating controls. Off-black on light, cream on dark.
    var outline: Color {
        self == .dark ? .inkOutlineDark : .inkOutlineLight
    }

    /// Color of the hard, blur-free drop shadow that gives elements their
    /// "sticker" lift. Tinted toward the outline so it reads as a bold edge.
    var hardShadow: Color {
        self == .dark ? Color.black.opacity(0.55) : Color.inkOutlineLight.opacity(0.9)
    }
}

// MARK: - Theme Manager
//
// Global ObservableObject singleton. Injected once at the app root via
// `.environmentObject(ThemeManager.shared)` so every view (including sheets
// and popovers, which inherit the environment) reactively re-renders the
// moment `theme` changes. No restart required.

@MainActor
final class ThemeManager: ObservableObject {

    static let shared = ThemeManager()

    private static let storageKey = "infiniteNote.appTheme"

    /// The single source of truth for the app's appearance.
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        self.theme = stored.flatMap(AppTheme.init(rawValue:)) ?? .light
    }

    var isDark: Bool { theme == .dark }

    func toggle() {
        theme = isDark ? .light : .dark
    }

    // MARK: Convenience passthroughs

    var colorScheme: ColorScheme { theme.colorScheme }
    var background: Color    { theme.background }
    var page: Color          { theme.page }
    var card: Color          { theme.card }
    var textPrimary: Color   { theme.textPrimary }
    var textSecondary: Color { theme.textSecondary }
    var border: Color        { theme.border }
    var grid: Color          { theme.grid }
    var outline: Color       { theme.outline }
    var hardShadow: Color    { theme.hardShadow }
}
