import SwiftUI

// MARK: - Cover Color Picker
//
// The notebook cover swatches used by "New Notebook" and "Edit Cover":
//   • the 6 signature covers + a ⌄ button,
//   • ⌄ opens the extra palette (Color.notebookCoverExtras), which ends with
//     the system color wheel so any custom color can be picked.
// Selection is written as a cover color code (see CoverColorCode).

struct CoverColorPicker: View {
    @Binding var colorIndex: Int
    /// false hides the selection ring (e.g. a photo cover is chosen instead).
    var showsSelection: Bool = true
    /// Runs after the user picks any color (e.g. to drop a picked photo).
    var onPick: () -> Void = {}

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isExpanded: Bool
    @State private var customColor: Color

    private let swatchSize: CGFloat = 38
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    init(colorIndex: Binding<Int>, showsSelection: Bool = true, onPick: @escaping () -> Void = {}) {
        self._colorIndex = colorIndex
        self.showsSelection = showsSelection
        self.onPick = onPick
        let current = colorIndex.wrappedValue
        // Open straight onto the full palette when the cover already uses
        // one of its colors, so the selected swatch is visible.
        let isSignature = Color.notebookCovers.indices.contains(current)
        self._isExpanded = State(initialValue: !isSignature && CoverColorCode.isKnown(current))
        self._customColor = State(initialValue: CoverColorCode.isCustom(current)
                                  ? Color.notebookCover(at: current) : Color.burgundy)
    }

    var body: some View {
        VStack(spacing: 14) {
            // Signature covers + expand / collapse.
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Color.notebookCovers.indices, id: \.self) { index in
                    swatch(code: index, color: Color.notebookCovers[index])
                }
                expandButton
            }

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Color.notebookCoverExtras.indices, id: \.self) { offset in
                        swatch(code: CoverColorCode.extendedBase + offset,
                               color: Color.notebookCoverExtras[offset])
                    }
                    customColorCell
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: Cells

    private func swatch(code: Int, color: Color) -> some View {
        let isSelected = showsSelection && colorIndex == code
        return Button {
            colorIndex = code
            onPick()
        } label: {
            ZStack {
                Circle().fill(themeManager.hardShadow)
                    .frame(width: swatchSize, height: swatchSize).offset(x: 3, y: 3)
                Circle().fill(color).frame(width: swatchSize, height: swatchSize)
                Circle().strokeBorder(themeManager.outline, lineWidth: isSelected ? 3.5 : 2)
                    .frame(width: swatchSize, height: swatchSize)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        // Stays readable on the pale swatches (lemon, mint…).
                        .shadow(color: .black.opacity(0.5), radius: 0, x: 1, y: 1)
                }
            }
            .scaleEffect(isSelected ? 1.12 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
        } label: {
            ZStack {
                Circle().fill(themeManager.hardShadow)
                    .frame(width: swatchSize, height: swatchSize).offset(x: 3, y: 3)
                Circle().fill(themeManager.card).frame(width: swatchSize, height: swatchSize)
                Circle().strokeBorder(themeManager.outline, lineWidth: 2)
                    .frame(width: swatchSize, height: swatchSize)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(themeManager.iconTint)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show fewer colors" : "Show more colors")
    }

    /// The color wheel — pick absolutely any cover color.
    private var customColorCell: some View {
        let isSelected = showsSelection && CoverColorCode.isCustom(colorIndex)
        return ZStack {
            Circle().fill(themeManager.hardShadow)
                .frame(width: swatchSize, height: swatchSize).offset(x: 3, y: 3)
            Circle().fill(themeManager.card).frame(width: swatchSize, height: swatchSize)
            ColorPicker("Custom cover color", selection: customColorBinding, supportsOpacity: false)
                .labelsHidden()
            Circle().strokeBorder(themeManager.outline, lineWidth: isSelected ? 3.5 : 2)
                .frame(width: swatchSize, height: swatchSize)
                .allowsHitTesting(false)
        }
        .scaleEffect(isSelected ? 1.12 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isSelected)
        .accessibilityLabel("Choose your own color")
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { customColor },
            set: { newColor in
                customColor = newColor
                colorIndex = CoverColorCode.custom(newColor)
                onPick()
            }
        )
    }
}
