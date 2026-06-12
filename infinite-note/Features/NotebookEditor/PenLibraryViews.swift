import SwiftUI
import PencilKit

// MARK: - Pen Library (popover under the Pen tool)
//
// Tap the Pen tool → this menu:
//   Default Pen          (built-in, immutable, always the fallback)
//   + Create Pen         (opens the Pen Designer)
//   ── MY PENS ──
//   Study Notes Pen  ✕   (tap = select · long-press = Edit / Duplicate / Delete)
//
// Every row shows a live sample stroke rendered through the SAME
// StrokeRefiner the canvas uses, so the preview is exactly what the pen
// writes like.

/// Sheet driver for the Pen Designer. `editing == nil` → create flow.
struct PenDesignerRequest: Identifiable {
    let id = UUID()
    var editing: CustomPen?
}

struct PenLibraryMenu: View {
    let pens: [CustomPen]
    let activePenId: String?          // nil = Default Pen active
    var onSelectDefault: () -> Void
    var onSelect: (CustomPen) -> Void
    var onCreate: () -> Void
    var onEdit: (CustomPen) -> Void
    var onDuplicate: (CustomPen) -> Void
    var onDeleteRequest: (CustomPen) -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pens")
                .font(.cartoon(14, weight: .heavy))
                .foregroundStyle(themeManager.iconTint)

            // Default Pen — no ✕, no context menu (cannot be deleted,
            // renamed, or modified).
            penRow(
                CustomPen.defaultPen,
                isActive: activePenId == nil,
                subtitle: "Built-in · handwriting tuned",
                action: onSelectDefault
            )

            // Create Pen
            Button(action: onCreate) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.burgundy)
                    Text("Create Pen")
                        .font(.cartoon(14, weight: .heavy))
                        .foregroundStyle(themeManager.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(themeManager.card))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(themeManager.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create a new custom pen")

            if !pens.isEmpty {
                Divider()
                Text("MY PENS")
                    .font(.cartoon(11, weight: .heavy))
                    .foregroundStyle(themeManager.textSecondary)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(pens) { pen in
                            penRow(
                                pen,
                                isActive: activePenId == pen.id,
                                subtitle: nil,
                                action: { onSelect(pen) }
                            )
                            .contextMenu {
                                Button { onEdit(pen) } label: {
                                    Label("Edit", systemImage: "slider.horizontal.3")
                                }
                                Button { onDuplicate(pen) } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                Divider()
                                Button(role: .destructive) { onDeleteRequest(pen) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 290)
            }
        }
        .padding(14)
        .frame(width: 316)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func penRow(
        _ pen: CustomPen,
        isActive: Bool,
        subtitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 10) {
                    PenStrokePreview(pen: pen)
                        .frame(width: 76, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pen.name)
                            .font(.cartoon(13.5, weight: .bold))
                            .foregroundStyle(themeManager.textPrimary)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.cartoon(10.5, weight: .medium))
                                .foregroundStyle(themeManager.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.pineTeal)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Delete (✕) — saved pens only; confirmation handled by caller.
            if !pen.isDefault {
                Button { onDeleteRequest(pen) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(themeManager.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(themeManager.border.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .accessibilityLabel("Delete \(pen.name)")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isActive ? themeManager.selectionColor.opacity(0.35) : themeManager.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isActive ? themeManager.selectionColor : themeManager.border,
                              lineWidth: isActive ? 2 : 1)
        )
    }
}

// MARK: - Sample-stroke preview (async render)

struct PenStrokePreview: View {
    let pen: CustomPen

    @State private var image: UIImage?
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: "\(pen.hashValue)-\(themeManager.isDark)") {
            let pen = pen
            let dark = themeManager.isDark
            image = await Task.detached(priority: .userInitiated) {
                pen.previewImage(dark: dark)
            }.value
        }
    }
}

// MARK: - Pen Designer
//
// Create or edit a pen. Every slider feeds the SAME parameters the canvas
// uses, and the scribble pad runs strokes through StrokeRefiner live — what
// you test here is exactly what you get on the page.

struct PenDesignerView: View {
    var editing: CustomPen?           // nil → create
    var seedColor: Color              // toolbar color when creating
    var seedWidth: CGFloat            // toolbar width when creating
    var onSave: (CustomPen) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var draft: CustomPen
    @State private var draftColor: Color
    @State private var clearToken = 0

    init(
        editing: CustomPen?,
        seedColor: Color,
        seedWidth: CGFloat,
        onSave: @escaping (CustomPen) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editing = editing
        self.seedColor = seedColor
        self.seedWidth = seedWidth
        self.onSave = onSave
        self.onCancel = onCancel
        if let editing {
            self._draft = State(initialValue: editing)
            self._draftColor = State(initialValue: editing.color)
        } else {
            var pen = CustomPen(name: "")
            pen.colorHex = CustomPen.hexString(from: seedColor)
            pen.width = Double(seedWidth)
            pen.maxWidth = max(pen.maxWidth, pen.width * 1.6)
            self._draft = State(initialValue: pen)
            self._draftColor = State(initialValue: seedColor)
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Live preview ──────────────────────────────────────
                Section {
                    VStack(spacing: 8) {
                        PenStrokePreview(pen: draft)
                            .frame(height: 34)
                            .frame(maxWidth: .infinity)
                        ZStack(alignment: .topTrailing) {
                            PenScribblePad(pen: draft, clearToken: clearToken,
                                           isDark: themeManager.isDark)
                                .frame(height: 130)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(themeManager.page))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(themeManager.border, lineWidth: 1))
                            Button { clearToken += 1 } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(themeManager.iconTint)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(themeManager.card.opacity(0.9)))
                                    .overlay(Circle().strokeBorder(themeManager.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .accessibilityLabel("Clear test area")
                        }
                        Text("Scribble above to test — finger or Pencil.")
                            .font(.cartoon(11, weight: .medium))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    .listRowBackground(themeManager.card)
                } header: { Text("Live Preview").foregroundStyle(Color.palmLeaf) }

                // ── Appearance ────────────────────────────────────────
                Section {
                    TextField("e.g. Study Notes Pen", text: $draft.name)
                        .font(.system(size: 16))
                        .listRowBackground(themeManager.card)
                    ColorPicker(selection: $draftColor, supportsOpacity: false) {
                        Text("Color").font(.cartoon(13.5, weight: .bold))
                            .foregroundStyle(themeManager.textPrimary)
                    }
                    .onChange(of: draftColor) { _, color in
                        draft.colorHex = CustomPen.hexString(from: color)
                    }
                    .listRowBackground(themeManager.card)
                    sliderRow("Width", value: $draft.width, in: 1...24) {
                        String(format: "%.1f pt", $0)
                    }
                    sliderRow("Opacity", value: $draft.opacity, in: 0.2...1) {
                        "\(Int($0 * 100)) %"
                    }
                } header: { Text("Appearance").foregroundStyle(Color.palmLeaf) }

                // ── Stroke Behavior ───────────────────────────────────
                Section {
                    sliderRow("Stroke Stabilization", value: $draft.stabilization, in: 0...1) {
                        "\(Int($0 * 100)) %"
                    }
                    sliderRow("Bézier Smoothing", value: $draft.bezierSmoothing, in: 0...1) {
                        "\(Int($0 * 100)) %"
                    }
                    sliderRow("Pressure Sensitivity", value: $draft.pressureSensitivity, in: 0...0.2) {
                        "\(Int($0 * 100)) %"
                    }
                    sliderRow("Start Taper", value: $draft.startTaper, in: 0...1) {
                        "\(Int($0 * 100)) %"
                    }
                    sliderRow("End Taper", value: $draft.endTaper, in: 0...1) {
                        "\(Int($0 * 100)) %"
                    }
                } header: { Text("Stroke Behavior").foregroundStyle(Color.palmLeaf) }
                  footer: {
                      Text("Stabilization, smoothing, pressure and tapers are applied the moment each stroke is completed.")
                  }

                // ── Advanced ──────────────────────────────────────────
                Section {
                    sliderRow("Ink Flow", value: $draft.inkFlow, in: 0.3...1) {
                        "\(Int($0 * 100)) %"
                    }
                    sliderRow("Stroke Softness", value: $draft.softness, in: 0...1) {
                        $0 >= 0.7 ? "soft (pencil ink)" : "\(Int($0 * 100)) %"
                    }
                    sliderRow("Velocity Sensitivity", value: $draft.velocitySensitivity, in: 0...1) {
                        "\(Int($0 * 100)) %"
                    }
                    sliderRow("Minimum Width", value: $draft.minWidth, in: 0.5...12) {
                        String(format: "%.1f pt", $0)
                    }
                    sliderRow("Maximum Width", value: $draft.maxWidth, in: 2...30) {
                        String(format: "%.1f pt", $0)
                    }
                } header: { Text("Advanced").foregroundStyle(Color.palmLeaf) }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.background)
            .navigationTitle(editing == nil ? "Pen Designer" : "Edit Pen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(themeManager.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var pen = draft
                        pen.name = pen.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        pen.maxWidth = max(pen.maxWidth, pen.minWidth)
                        onSave(pen)
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(canSave ? Color.burgundy : themeManager.textSecondary)
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.cartoon(13.5, weight: .bold))
                    .foregroundStyle(themeManager.textPrimary)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.cartoon(12, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(themeManager.iconTint)
        }
        .listRowBackground(themeManager.card)
    }
}

// MARK: - Scribble test pad
//
// A mini PKCanvasView wired to the draft pen. Finger input is allowed here
// (unlike the page canvas) so the pen can be tested without a Pencil, and
// every finished stroke is refined exactly like on the real page.

private struct PenScribblePad: UIViewRepresentable {
    var pen: CustomPen
    var clearToken: Int
    var isDark: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.overrideUserInterfaceStyle = isDark ? .dark : .light
        canvas.delegate = context.coordinator
        canvas.tool = pen.inkingTool(color: UIColor(pen.color), width: CGFloat(pen.width))
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.pen = pen
        canvas.overrideUserInterfaceStyle = isDark ? .dark : .light
        canvas.tool = pen.inkingTool(color: UIColor(pen.color), width: CGFloat(pen.width))
        if context.coordinator.lastClearToken != clearToken {
            context.coordinator.lastClearToken = clearToken
            canvas.drawing = PKDrawing()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pen: pen) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var pen: CustomPen
        var lastClearToken = 0
        private var knownStrokeCount = 0
        private var isReplacing = false

        init(pen: CustomPen) { self.pen = pen }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            defer { knownStrokeCount = canvasView.drawing.strokes.count }
            guard !isReplacing else { return }
            var strokes = canvasView.drawing.strokes
            guard strokes.count == knownStrokeCount + 1,
                  let last = strokes.last else { return }
            strokes[strokes.count - 1] = StrokeRefiner.refine(last, with: pen)
            isReplacing = true
            canvasView.drawing = PKDrawing(strokes: strokes)
            isReplacing = false
        }
    }
}
