import SwiftUI
import UIKit

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

    /// The extra covers behind the ⌄ button in the cover picker (the 6 above
    /// always come first). Stored as `CoverColorCode.extendedBase + offset`.
    /// APPEND ONLY — a stored cover remembers its position in this list.
    static let notebookCoverExtras: [Color] = [
        // reds · pinks · oranges
        Color(hex: "E63946"), Color(hex: "C9184A"), Color(hex: "FF5D8F"), Color(hex: "FF8FA3"),
        Color(hex: "FFB4A2"), Color(hex: "FF8C42"), Color(hex: "FFD6A5"),
        // yellows · greens
        Color(hex: "F4A261"), Color(hex: "E9C46A"), Color(hex: "FFE066"), Color(hex: "CAFFBF"),
        Color(hex: "8AC926"), Color(hex: "52B788"), Color(hex: "1B4332"),
        // teals · blues · purples
        Color(hex: "2A9D8F"), Color(hex: "90E0EF"), Color(hex: "4CC9F0"), Color(hex: "A0C4FF"),
        Color(hex: "4361EE"), Color(hex: "1D3557"), Color(hex: "B388EB"),
        // purples · neutrals
        Color(hex: "E0AAFF"), Color(hex: "7209B7"), Color(hex: "A47148"), Color(hex: "D4A373"),
        Color(hex: "6C757D"), Color(hex: "2B2D42"),
    ]

    /// Safe accessor for a stored cover color (see `CoverColorCode`):
    /// the 6 signature covers, the extra palette, or a custom RGB color.
    /// Legacy out-of-range indices (the old 0...7 palette) still wrap onto
    /// the signature covers, exactly as before.
    static func notebookCover(at index: Int) -> Color {
        if let rgb = CoverColorCode.customRGB(from: index) {
            return Color(.sRGB,
                         red: Double((rgb >> 16) & 0xFF) / 255,
                         green: Double((rgb >> 8) & 0xFF) / 255,
                         blue: Double(rgb & 0xFF) / 255,
                         opacity: 1)
        }
        if let extra = CoverColorCode.extraOffset(from: index) {
            return notebookCoverExtras[extra]
        }
        return notebookCovers[((index % notebookCovers.count) + notebookCovers.count) % notebookCovers.count]
    }
}

// MARK: - Cover color codes
//
// A notebook's cover color is still ONE integer (`cover_color_index`), so no
// database migration is needed and backups / old app versions keep working:
//
//   0 ..< 6                → the signature covers (unchanged)
//   100 ..< 100 + extras   → `Color.notebookCoverExtras` (100+ so the legacy
//                            0...7 indices keep meaning what they always did)
//   0x1000000 + 0xRRGGBB   → a custom color picked with the color wheel

enum CoverColorCode {
    static let extendedBase = 100
    static let customBase = 0x1000000

    static func isCustom(_ index: Int) -> Bool { customRGB(from: index) != nil }

    static func customRGB(from index: Int) -> Int? {
        index >= customBase && index < customBase + 0x1000000 ? index - customBase : nil
    }

    static func extraOffset(from index: Int) -> Int? {
        let offset = index - extendedBase
        return Color.notebookCoverExtras.indices.contains(offset) ? offset : nil
    }

    /// True for any code this build can show exactly (not a legacy index).
    static func isKnown(_ index: Int) -> Bool {
        Color.notebookCovers.indices.contains(index) || extraOffset(from: index) != nil || isCustom(index)
    }

    /// Encodes any color as a custom cover code (opacity ignored).
    static func custom(_ color: Color) -> Int {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return customBase + (byte(red) << 16 | byte(green) << 8 | byte(blue))
    }
}
