import SwiftUI
import UIKit

// MARK: - Rich Text Display (non-interactive)
//
// Renders a text object's attributed string for the CONTENT layer that sits
// below the ink canvas. Never editable, never first responder — it's pure
// presentation, so the Pencil writes straight through onto it.

struct RichTextLabel: UIViewRepresentable {
    let attributed: NSAttributedString
    /// Box width in paper points — the text MUST wrap to this.
    var width: CGFloat

    func makeUIView(context: Context) -> InsetLabel {
        let label = InsetLabel()
        label.insets = RichText.textInset
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.isUserInteractionEnabled = false
        label.attributedText = attributed
        label.preferredMaxLayoutWidth = max(1, width - RichText.textInset.left - RichText.textInset.right)
        return label
    }

    func updateUIView(_ label: InsetLabel, context: Context) {
        if label.attributedText != attributed { label.attributedText = attributed }
        label.insets = RichText.textInset
        label.preferredMaxLayoutWidth = max(1, width - RichText.textInset.left - RichText.textInset.right)
    }
}

/// UILabel that insets its text — wraps reliably to its frame width inside
/// SwiftUI (unlike a non-scrolling UITextView, which expands to one long line).
final class InsetLabel: UILabel {
    var insets: UIEdgeInsets = .zero

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inset = bounds.inset(by: insets)
        let rect = super.textRect(forBounds: inset, limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left,
                                           bottom: -insets.bottom, right: -insets.right))
    }
}

// MARK: - Rich Text Editor (edit mode)
//
// Editable UITextView used only while a text box is in edit mode. Binds its
// attributed string back to the model and registers with the shared
// `RichTextEditingController` so the format bar can act on the live selection.

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributed: NSAttributedString
    let controller: RichTextEditingController
    /// Theme-aware caret/handle tint so it reads on either page colour.
    var tintColor: UIColor
    /// Box width in paper points — the text MUST wrap to this.
    var width: CGFloat
    var onEnded: () -> Void = {}

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = RichText.textInset
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.tintColor = tintColor
        RichText.pinWrapWidth(tv, boxWidth: width)
        tv.attributedText = attributed
        // Seed typing attributes from the existing text so an empty box keeps
        // its chosen style.
        if attributed.length > 0 {
            tv.typingAttributes = attributed.attributes(at: 0, effectiveRange: nil)
        }
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
            controller.bind(tv)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.tintColor = tintColor
        RichText.pinWrapWidth(tv, boxWidth: width)
        // Only push external changes (e.g. a programmatic style applied while
        // the binding lives outside) — never clobber what the user is typing.
        if !context.coordinator.isEditing, tv.attributedText != attributed {
            tv.attributedText = attributed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        var isEditing = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            parent.controller.bind(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.attributed = textView.attributedText
            parent.controller.refreshState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.refreshState()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            parent.attributed = textView.attributedText
            parent.controller.unbind(textView)
            parent.onEnded()
        }
    }
}
