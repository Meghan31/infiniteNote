import SwiftUI
import UIKit

// MARK: - Rich Text Format Bar
//
// Floating toolbar shown while a text box is being edited. Drives the shared
// `RichTextEditingController`, which applies every change to the live
// selection (or the typing attributes when nothing is selected).

struct TextFormatBar: View {
    @ObservedObject var controller: RichTextEditingController
    var onDone: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    @State private var showFontMenu = false
    @State private var showTextColor = false
    @State private var showHighlight = false
    @State private var showSpacing = false

    private let fonts = [
        "Helvetica", "Georgia", "Avenir Next", "Courier New",
        "Times New Roman", "Marker Felt", "Snell Roundhand", "Menlo"
    ]
    private let palette: [Color] = [
        .black, .white,
        Color(red: 0.93, green: 0.19, blue: 0.27),
        Color(red: 1.00, green: 0.58, blue: 0.00),
        Color(red: 0.09, green: 0.72, blue: 0.40),
        Color(red: 0.20, green: 0.45, blue: 0.90),
        Color(red: 0.43, green: 0.22, blue: 0.84),
        Color(red: 0.96, green: 0.33, blue: 0.61)
    ]
    private let highlights: [Color] = [
        Color(red: 1.00, green: 0.95, blue: 0.45),
        Color(red: 0.70, green: 0.95, blue: 0.70),
        Color(red: 0.70, green: 0.88, blue: 1.00),
        Color(red: 1.00, green: 0.78, blue: 0.85)
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toggle("bold", isOn: controller.isBold) { controller.toggleBold() }
                toggle("italic", isOn: controller.isItalic) { controller.toggleItalic() }
                toggle("underline", isOn: controller.isUnderline) { controller.toggleUnderline() }

                divider

                fontMenuButton
                sizeStepper

                divider

                textColorButton
                highlightButton

                divider

                toggle("text.alignleft", isOn: controller.alignment == .left) { controller.setAlignment(.left) }
                toggle("text.aligncenter", isOn: controller.alignment == .center) { controller.setAlignment(.center) }
                toggle("text.alignright", isOn: controller.alignment == .right) { controller.setAlignment(.right) }
                toggle("list.bullet", isOn: false) { controller.toggleBulletList() }
                spacingButton

                divider

                Button(action: onDone) {
                    Text("Done")
                        .font(.cartoon(14, weight: .heavy))
                        .foregroundStyle(themeManager.outline)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(themeManager.selectionColor))
                        .overlay(Capsule().strokeBorder(themeManager.outline.opacity(0.5), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(
            Capsule(style: .continuous)
                .fill(themeManager.card)
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(themeManager.outline.opacity(0.4), lineWidth: 1.5))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(themeManager.border.opacity(0.7)).frame(width: 0.5, height: 24)
            .padding(.horizontal, 2)
    }

    private func toggle(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? themeManager.outline : themeManager.iconTint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isOn ? themeManager.selectionColor : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var fontMenuButton: some View {
        Button { showFontMenu = true } label: {
            HStack(spacing: 4) {
                Text(shortFontName(controller.fontFamily))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(themeManager.iconTint)
            .frame(maxWidth: 96)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(themeManager.background.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFontMenu) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fonts, id: \.self) { family in
                    Button {
                        controller.setFontFamily(family)
                        showFontMenu = false
                    } label: {
                        HStack {
                            Text(family)
                                .font(.custom(family, size: 15))
                                .foregroundStyle(themeManager.textPrimary)
                            Spacer()
                            if controller.fontFamily == family {
                                Image(systemName: "checkmark").foregroundStyle(Color.pineTeal)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .frame(width: 230)
            .modifier(ForcePopoverAdaptation())
        }
    }

    private var sizeStepper: some View {
        HStack(spacing: 2) {
            Button { controller.setFontSize(max(8, controller.fontSize - 2)) } label: {
                Image(systemName: "minus").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(themeManager.iconTint).frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
            Text("\(Int(controller.fontSize))")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(themeManager.textPrimary)
                .frame(minWidth: 24)
            Button { controller.setFontSize(min(200, controller.fontSize + 2)) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(themeManager.iconTint).frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(themeManager.background.opacity(0.5)))
    }

    private var textColorButton: some View {
        Button { showTextColor = true } label: {
            Image(systemName: "character")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(themeManager.iconTint)
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.burgundy).frame(height: 3).padding(.horizontal, 6)
                }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTextColor) {
            colorGrid(palette) { controller.setTextColor(UIColor($0)); showTextColor = false }
        }
    }

    private var highlightButton: some View {
        Button { showHighlight = true } label: {
            Image(systemName: "highlighter")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(themeManager.iconTint)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showHighlight) {
            VStack(spacing: 10) {
                colorGrid(highlights) { controller.setHighlight(UIColor($0)); showHighlight = false }
                Button("No Highlight") { controller.setHighlight(nil); showHighlight = false }
                    .font(.cartoon(13, weight: .bold))
                    .foregroundStyle(themeManager.textPrimary)
            }
            .padding(14)
            .modifier(ForcePopoverAdaptation())
        }
    }

    private var spacingButton: some View {
        Button { showSpacing = true } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeManager.iconTint)
                .frame(width: 32, height: 34)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Line Spacing").font(.cartoon(13, weight: .heavy)).foregroundStyle(themeManager.iconTint)
                HStack(spacing: 8) {
                    ForEach([0, 2, 6, 12, 20], id: \.self) { value in
                        Button {
                            controller.setLineSpacing(CGFloat(value))
                            showSpacing = false
                        } label: {
                            Text("\(value)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(themeManager.textPrimary)
                                .frame(width: 34, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(themeManager.selectionColor.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .modifier(ForcePopoverAdaptation())
        }
    }

    private func colorGrid(_ colors: [Color], pick: @escaping (Color) -> Void) -> some View {
        let cols = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 4)
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(colors.indices, id: \.self) { i in
                Button { pick(colors[i]) } label: {
                    Circle().fill(colors[i]).frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(themeManager.outline, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .modifier(ForcePopoverAdaptation())
    }

    private func shortFontName(_ family: String) -> String {
        family.replacingOccurrences(of: " New", with: "")
              .replacingOccurrences(of: " Roman", with: "")
    }
}
