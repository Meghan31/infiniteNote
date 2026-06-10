import SwiftUI

// MARK: - InfiniteNote Cartoon Color System
//
// The single source of truth for every color in the app. No view should
// hardcode a hex value — use these named constants (or the semantic theme
// tokens on `ThemeManager` / `AppTheme`) instead.
//
// The visual language is "comic sticker book": punchy candy colors, a heavy
// ink outline, and hard offset shadows (see CartoonStyle.swift). The five
// brand constants below keep their original *names* so the rest of the app
// keeps compiling, but they now map to a bright, playful cartoon palette.

extension Color {

    // MARK: Brand Palette (cartoon candy)
    //
    // Usage rules (unchanged from before — only the hues got louder):
    //   burgundy     → primary CTA, selected notebooks, active tools,
    //                  current page indicator        (now: punch coral-red)
    //   lightBronze  → cards / cover tone, secondary  (now: sunny yellow)
    //   palmLeaf     → icons, toolbar accents, headers (now: mint teal)
    //   palmLeafDark → hover / selected fills, menus   (now: grape purple)
    //   pineTeal     → sync button, success states     (now: leaf green)

    static let burgundy     = Color(hex: "FF5277")   // punch coral-red (primary)
    static let lightBronze  = Color(hex: "FFC23C")   // sunny yellow (secondary)
    static let palmLeaf     = Color(hex: "20C5B8")   // mint teal (accents/icons)
    static let palmLeafDark = Color(hex: "7B6CF6")   // grape purple (selected/menus)
    static let pineTeal     = Color(hex: "27C26B")   // leaf green (sync/success)

    // Extra cartoon hue used to widen the cover rainbow.
    static let skyPop       = Color(hex: "37B6F0")   // sky blue

    // MARK: Ink Outline
    //
    // The signature heavy outline + hard-shadow color. Slightly off-black in
    // light mode so it reads as "ink" rather than pure black; a soft cream in
    // dark mode so outlines stay visible against the deep background.

    static let inkOutlineLight = Color(hex: "1C1B2E")
    static let inkOutlineDark  = Color(hex: "EDE7D9")

    // MARK: Theme Surfaces (consumed by AppTheme / ThemeManager)
    //
    //   Light: warm paper backgrounds, white cards, inky text.
    //   Dark:  deep blue-ink backgrounds, raised slate cards, cream text.

    static let themeBackgroundLight = Color(hex: "FFF7E9")   // warm cream paper
    static let themeBackgroundDark  = Color(hex: "232233")   // slate (lets hard shadows read)
    static let themePageLight       = Color(hex: "FFFFFF")   // pure white page (ink-friendly)
    static let themePageDark        = Color(hex: "000000")   // pure black page (ink-friendly)
    static let themeCardLight       = Color(hex: "FFFFFF")   // clean white card
    static let themeCardDark        = Color(hex: "302E45")   // raised slate card (lifts off bg)
    static let themeTextLight       = Color(hex: "1C1B2E")   // ink
    static let themeTextDark        = Color(hex: "FBF6EA")   // cream

    // MARK: Hex Init

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// MARK: - Notebook Cover Colors
//
// A full cartoon rainbow so a shelf of notebooks looks like a candy box.

extension Color {
    static let notebookCovers: [Color] = [
        .burgundy,      // coral-red
        .lightBronze,   // sunny yellow
        .palmLeaf,      // mint teal
        .skyPop,        // sky blue
        .palmLeafDark,  // grape purple
        .pineTeal,      // leaf green
    ]

    /// Safe accessor — wraps any stored index (including legacy 0...7
    /// indices from before the palette migration) onto the current covers.
    static func notebookCover(at index: Int) -> Color {
        notebookCovers[((index % notebookCovers.count) + notebookCovers.count) % notebookCovers.count]
    }
}
