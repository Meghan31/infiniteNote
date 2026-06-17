import UIKit

// MARK: - Rich Text Engine
//
// Helpers for the rich-text boxes placed on a page. Text is stored as RTF so
// every attribute the user applies (font family/size, bold/italic/underline,
// colour, highlight, alignment, lists, line spacing) round-trips through the
// database and out to the exported PDF.

enum RichText {

    /// Insets between a text object's frame and its text — keeps glyphs off the
    /// selection border. Used by the editor, the display label AND the export
    /// renderer so on-screen and on-paper wrapping match exactly.
    static let textInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    static let defaultFontSize: CGFloat = 34
    static let defaultFontName = "Helvetica"

    static func defaultFont(size: CGFloat = defaultFontSize) -> UIFont {
        UIFont(name: defaultFontName, size: size) ?? UIFont.systemFont(ofSize: size)
    }

    /// Base attributes for a brand-new, empty text box. `color` adapts to the
    /// page theme at creation time (black on a light page, white on a dark one)
    /// so the very first character is always visible.
    static func defaultAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping   // wrap, never one long line
        return [
            .font: defaultFont(),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    /// Makes a non-scrolling UITextView WRAP to its SwiftUI frame width instead
    /// of expanding to one long line. The container tracks the view width, and
    /// lowering horizontal compression resistance/hugging stops the text view's
    /// intrinsic single-line width from overriding the frame.
    static func pinWrapWidth(_ tv: UITextView, boxWidth: CGFloat) {
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    static func placeholder(color: UIColor) -> NSAttributedString {
        NSAttributedString(string: "", attributes: defaultAttributes(color: color))
    }

    // MARK: RTF <-> Attributed String

    static func rtf(from attributed: NSAttributedString) -> Data? {
        let range = NSRange(location: 0, length: attributed.length)
        return try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    static func attributedString(fromRTF data: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    /// A plain-text paste becomes an attributed string in the box's default
    /// style so pasted text looks consistent with typed text.
    static func attributedString(fromPlain string: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: defaultAttributes(color: color))
    }
}

// MARK: - Editing Controller
//
// Bridges the rich-text format bar to whichever UITextView is currently being
// edited. Formatting applies to the selected range, or — when the selection is
// empty — to the typing attributes so the NEXT characters pick up the change.

final class RichTextEditingController: ObservableObject {

    /// The text view currently being edited (nil when no box is in edit mode).
    weak var textView: UITextView?

    /// Mirrors the active selection's attributes so the toolbar can show the
    /// on/off state of bold, italic, etc. Republished on every selection move.
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderline = false
    @Published var fontSize: CGFloat = RichText.defaultFontSize
    @Published var fontFamily: String = RichText.defaultFontName
    @Published var alignment: NSTextAlignment = .left
    @Published var hasActiveEditor = false

    /// Called after any edit so the owner can persist the new RTF.
    var onChange: (() -> Void)?

    func bind(_ textView: UITextView) {
        self.textView = textView
        hasActiveEditor = true
        refreshState()
    }

    func unbind(_ textView: UITextView) {
        if self.textView === textView {
            self.textView = nil
            hasActiveEditor = false
        }
    }

    // MARK: State reflection

    func refreshState() {
        guard let tv = textView else { return }
        let attrs = currentAttributes(in: tv)
        if let font = attrs[.font] as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            isBold = traits.contains(.traitBold)
            isItalic = traits.contains(.traitItalic)
            fontSize = font.pointSize
            fontFamily = font.familyName
        }
        isUnderline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            alignment = para.alignment
        }
    }

    private func currentAttributes(in tv: UITextView) -> [NSAttributedString.Key: Any] {
        let range = tv.selectedRange
        if range.length > 0, range.location < tv.textStorage.length {
            return tv.textStorage.attributes(at: range.location, effectiveRange: nil)
        }
        if range.location > 0 {
            return tv.textStorage.attributes(at: range.location - 1, effectiveRange: nil)
        }
        return tv.typingAttributes
    }

    // MARK: Mutations

    /// Applies `transform` to the selected range, or sets typing attributes
    /// when nothing is selected. `transform` mutates the attribute dictionary
    /// in place for a given font (so callers can flip traits or set keys).
    private func applyAttributes(_ mutate: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let tv = textView else { return }
        let range = tv.selectedRange

        if range.length == 0 {
            var typing = tv.typingAttributes
            mutate(&typing)
            tv.typingAttributes = typing
            refreshState()
            return
        }

        let storage = tv.textStorage
        storage.beginEditing()
        storage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            var copy = attrs
            mutate(&copy)
            storage.setAttributes(copy, range: subRange)
        }
        storage.endEditing()
        onChange?()
        refreshState()
    }

    func toggleBold() { toggleTrait(.traitBold) }
    func toggleItalic() { toggleTrait(.traitItalic) }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        applyAttributes { attrs in
            let base = (attrs[.font] as? UIFont) ?? RichText.defaultFont()
            var traits = base.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                attrs[.font] = UIFont(descriptor: descriptor, size: base.pointSize)
            }
        }
    }

    func toggleUnderline() {
        applyAttributes { attrs in
            let on = (attrs[.underlineStyle] as? Int ?? 0) != 0
            attrs[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
        }
    }

    func setFontSize(_ size: CGFloat) {
        applyAttributes { attrs in
            let base = (attrs[.font] as? UIFont) ?? RichText.defaultFont()
            attrs[.font] = UIFont(descriptor: base.fontDescriptor, size: size)
        }
    }

    func setFontFamily(_ family: String) {
        applyAttributes { attrs in
            let base = (attrs[.font] as? UIFont) ?? RichText.defaultFont()
            let traits = base.fontDescriptor.symbolicTraits
            var descriptor = UIFontDescriptor(name: family, size: base.pointSize)
            if let withTraits = descriptor.withSymbolicTraits(traits) { descriptor = withTraits }
            attrs[.font] = UIFont(descriptor: descriptor, size: base.pointSize)
        }
    }

    func setTextColor(_ color: UIColor) {
        applyAttributes { attrs in attrs[.foregroundColor] = color }
    }

    func setHighlight(_ color: UIColor?) {
        applyAttributes { attrs in
            if let color { attrs[.backgroundColor] = color }
            else { attrs.removeValue(forKey: .backgroundColor) }
        }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        applyParagraph { $0.alignment = alignment }
    }

    func setLineSpacing(_ spacing: CGFloat) {
        applyParagraph { $0.lineSpacing = spacing }
    }

    /// Paragraph-level edits cover the whole paragraphs the selection touches.
    private func applyParagraph(_ mutate: (NSMutableParagraphStyle) -> Void) {
        guard let tv = textView else { return }
        let nsString = tv.textStorage.string as NSString
        let paragraphRange = nsString.paragraphRange(for: tv.selectedRange)
        let storage = tv.textStorage

        if paragraphRange.length == 0 {
            var typing = tv.typingAttributes
            let para = ((typing[.paragraphStyle] as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            mutate(para)
            typing[.paragraphStyle] = para
            tv.typingAttributes = typing
            refreshState()
            return
        }

        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: paragraphRange, options: []) { value, subRange, _ in
            let para = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            mutate(para)
            storage.addAttribute(.paragraphStyle, value: para, range: subRange)
        }
        storage.endEditing()
        onChange?()
        refreshState()
    }

    /// Toggles a simple bullet prefix on the paragraphs the selection touches.
    func toggleBulletList() {
        guard let tv = textView else { return }
        let nsString = tv.textStorage.string as NSString
        let range = nsString.paragraphRange(for: tv.selectedRange)
        let bullet = "•\t"
        let paragraph = nsString.substring(with: range)
        let lines = paragraph.components(separatedBy: "\n")
        let allBulleted = lines.allSatisfy { $0.isEmpty || $0.hasPrefix(bullet) }
        let rebuilt = lines.map { line -> String in
            if line.isEmpty { return line }
            if allBulleted { return String(line.dropFirst(bullet.count)) }
            return line.hasPrefix(bullet) ? line : bullet + line
        }.joined(separator: "\n")

        let attrs = currentAttributes(in: tv)
        tv.textStorage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: rebuilt, attributes: attrs)
        )
        onChange?()
        refreshState()
    }
}
