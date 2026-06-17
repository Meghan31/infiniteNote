import SwiftUI
import PencilKit
import UIKit

// MARK: - Content Layer (below the ink canvas)
//
// Pure presentation of placed objects, sized to the fixed paper space. It is
// never hit-testable, so the Pencil draws straight through onto it — that is
// how writing lands "on" a photo. The object currently being edited is hidden
// here because the editable copy lives in the interaction overlay above.

struct PageObjectsContentView: View {
    var controller: PageEditController

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(controller.objects) { obj in
                if obj.id != controller.editingObjectId {
                    objectView(obj)
                        .frame(width: obj.width, height: obj.height)
                        .rotationEffect(.radians(obj.rotation))
                        .position(x: obj.center.x, y: obj.center.y)
                }
            }
        }
        .frame(width: PaperSpec.size.width, height: PaperSpec.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func objectView(_ obj: PageObject) -> some View {
        switch obj.kind {
        case .photo:
            if let img = controller.images[obj.id] {
                // Fit (don't fill) so the WHOLE photo is always visible inside
                // its box — filling cropped imported screenshots to a band.
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: obj.width, height: obj.height)
            } else {
                Rectangle().fill(Color.gray.opacity(0.15))
            }
        case .text:
            RichTextLabel(
                attributed: controller.attributed[obj.id] ?? NSAttributedString(string: ""),
                width: obj.width
            )
        }
    }
}

// MARK: - Interaction Overlay (above the ink canvas)
//
// Active ONLY in Lasso/Select mode (the parent adds it to the tree then). It
// hosts object selection/move/resize, text editing, and the lasso ink
// selection with its move/resize handles. All geometry is in paper space
// through the "paper" coordinate space; `displayScale` (the page's fit factor)
// keeps handles a constant size on screen.

struct PageSelectionOverlay: View {
    var controller: PageEditController
    let displayScale: CGFloat
    let isDark: Bool

    @EnvironmentObject private var themeManager: ThemeManager

    @State private var dragStartFrame: CGRect?
    @State private var inkStartTranslation: CGSize = .zero
    /// Captured at the start of an ink resize so the opposite corner stays put:
    /// (displayed opposite-corner position, base opposite-corner position).
    @State private var inkResizeStart: (displayed: CGPoint, base: CGPoint)?

    private var handleRadius: CGFloat { 11 / max(displayScale, 0.01) }
    private var lineWidth: CGFloat { 2 / max(displayScale, 0.01) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background layer (BOTTOM): lasso drag + tap-to-deselect. Being
            // the lowest layer, every object target and handle above it wins
            // for its own area, so selecting/moving objects is never stolen.
            Color.clear
                .contentShape(Rectangle())
                .gesture(lassoGesture)
                .onTapGesture { controller.clearSelection() }

            // Lasso path while dragging.
            if controller.lassoPoints.count > 1 {
                lassoPath
            }

            // Transparent per-object hit targets (select / move / edit).
            ForEach(controller.objects) { obj in
                objectTarget(obj)
            }

            // Selected-object chrome (box + resize handles + actions).
            if let id = controller.selectedObjectId, let obj = controller.object(id) {
                objectChrome(obj)
            }

            // Editable text box.
            if let id = controller.editingObjectId, let obj = controller.object(id) {
                textEditor(obj)
            }

            // Lasso ink selection (snapshot + handles + actions).
            if controller.inkSelection != nil {
                inkChrome()
            }
        }
        .frame(width: PaperSpec.size.width, height: PaperSpec.size.height, alignment: .topLeading)
        .coordinateSpace(name: "paper")
    }

    // MARK: Lasso

    private var lassoPath: some View {
        let points = controller.lassoPoints
        return ZStack {
            // Translucent fill of the enclosed region.
            Path { p in
                guard let first = points.first else { return }
                p.move(to: first)
                for pt in points.dropFirst() { p.addLine(to: pt) }
                p.closeSubpath()
            }
            .fill(themeManager.selectionColor.opacity(0.12))

            // Dashed outline.
            Path { p in
                guard let first = points.first else { return }
                p.move(to: first)
                for pt in points.dropFirst() { p.addLine(to: pt) }
                p.addLine(to: first)
            }
            .stroke(themeManager.selectionColor,
                    style: StrokeStyle(lineWidth: lineWidth * 1.2, lineCap: .round,
                                       dash: [10 / displayScale, 7 / displayScale]))
        }
        .allowsHitTesting(false)
    }

    private var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("paper"))
            .onChanged { value in
                guard controller.selectedObjectId == nil,
                      controller.editingObjectId == nil,
                      controller.inkSelection == nil else { return }
                controller.lassoPoints.append(value.location)
            }
            .onEnded { _ in
                guard controller.selectedObjectId == nil,
                      controller.editingObjectId == nil,
                      controller.inkSelection == nil else { return }
                controller.endLasso()
            }
    }

    // MARK: Object hit target

    private func objectTarget(_ obj: PageObject) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: obj.width, height: obj.height)
            .contentShape(Rectangle())
            .rotationEffect(.radians(obj.rotation))
            .position(x: obj.center.x, y: obj.center.y)
            .highPriorityGesture(moveGesture(obj))
            .onTapGesture(count: 2) {
                controller.selectObject(obj.id)
                if obj.kind == .text { controller.beginEditing(obj.id) }
            }
            .onTapGesture(count: 1) { controller.selectObject(obj.id) }
            // While this object is being edited the editor handles touches.
            .allowsHitTesting(controller.editingObjectId == nil)
    }

    private func moveGesture(_ obj: PageObject) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("paper"))
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = obj.frame
                    controller.selectObject(obj.id)
                    controller.beginUndoGroup()
                }
                guard let start = dragStartFrame else { return }
                var f = start
                f.origin.x += value.translation.width
                f.origin.y += value.translation.height
                controller.setFrame(f, for: obj.id)
            }
            .onEnded { _ in
                dragStartFrame = nil
                controller.commitObject(obj.id)
                controller.endUndoGroup("Move")
            }
    }

    // MARK: Selected-object chrome

    private func objectChrome(_ obj: PageObject) -> some View {
        let rect = obj.frame
        return ZStack(alignment: .topLeading) {
            // Bounding box.
            Rectangle()
                .strokeBorder(themeManager.selectionColor, lineWidth: lineWidth)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Corner resize handles.
            ForEach(Corner.allCases, id: \.self) { corner in
                handle()
                    .position(corner.point(in: rect))
                    .gesture(resizeGesture(obj, corner: corner))
            }

            // Action menu just above the box.
            objectActions()
                .position(x: rect.midX, y: rect.minY - 44 / displayScale)
        }
        .rotationEffect(.radians(obj.rotation), anchor: .topLeading)
        // NB: rotation currently always 0 for placed objects.
    }

    private func resizeGesture(_ obj: PageObject, corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("paper"))
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = obj.frame
                    controller.beginUndoGroup()
                }
                guard let start = dragStartFrame else { return }
                let anchor = corner.opposite.point(in: start)

                if obj.kind == .text {
                    // Text resizes by WIDTH only; the top stays put and the
                    // height auto-grows to fit all the text (it can exceed the
                    // box, so the box grows vertically instead of clipping).
                    let newWidth = max(140, abs(value.location.x - anchor.x))
                    var f = start
                    f.origin.x = min(anchor.x, value.location.x)
                    f.size.width = newWidth
                    f.size.height = controller.fittedTextHeight(obj.id, width: newWidth)
                    controller.setFrame(f, for: obj.id)
                    return
                }

                // Photos: free corner resize with the original aspect locked.
                var newRect = CGRect(
                    x: min(anchor.x, value.location.x),
                    y: min(anchor.y, value.location.y),
                    width: max(40, abs(value.location.x - anchor.x)),
                    height: max(40, abs(value.location.y - anchor.y))
                )
                let aspect = start.width / max(start.height, 1)
                if newRect.width / max(newRect.height, 1) > aspect {
                    newRect.size.width = newRect.height * aspect
                } else {
                    newRect.size.height = newRect.width / aspect
                }
                newRect = reanchored(newRect, anchor: anchor, corner: corner)
                controller.setFrame(newRect, for: obj.id)
            }
            .onEnded { _ in
                dragStartFrame = nil
                controller.commitObject(obj.id)
                controller.endUndoGroup("Resize")
            }
    }

    /// Keeps `anchor` corner fixed after an aspect adjustment changed the size.
    private func reanchored(_ rect: CGRect, anchor: CGPoint, corner: Corner) -> CGRect {
        var r = rect
        switch corner {
        case .topLeft:     r.origin = CGPoint(x: anchor.x - r.width, y: anchor.y - r.height)
        case .topRight:    r.origin = CGPoint(x: anchor.x,            y: anchor.y - r.height)
        case .bottomLeft:  r.origin = CGPoint(x: anchor.x - r.width, y: anchor.y)
        case .bottomRight: r.origin = CGPoint(x: anchor.x,            y: anchor.y)
        }
        return r
    }

    private func objectActions() -> some View {
        HStack(spacing: 2) {
            actionButton("doc.on.doc") { controller.copySelectedObject() }
            actionButton("scissors") { controller.cutSelectedObject() }
            actionButton("plus.square.on.square") { controller.duplicateSelectedObject() }
            actionButton("trash") { controller.deleteSelectedObject() }
        }
        .padding(.horizontal, 6 / displayScale)
        .padding(.vertical, 4 / displayScale)
        .background(
            Capsule().fill(themeManager.card)
                .overlay(Capsule().strokeBorder(themeManager.outline.opacity(0.4), lineWidth: lineWidth))
        )
        .scaleEffect(1 / displayScale)
    }

    // MARK: Text editor

    private func textEditor(_ obj: PageObject) -> some View {
        RichTextEditor(
            attributed: Binding(
                get: { controller.editingText },
                set: { controller.editingText = $0; controller.liveTextChanged() }
            ),
            controller: controller.textController,
            tintColor: isDark ? .white : .black,
            width: obj.width,
            onEnded: { }
        )
        .frame(width: obj.width, height: obj.height)
        .background(
            RoundedRectangle(cornerRadius: 4 / displayScale)
                .strokeBorder(themeManager.selectionColor, lineWidth: lineWidth)
        )
        .position(x: obj.center.x, y: obj.center.y)
    }

    // MARK: Ink selection chrome

    @ViewBuilder
    private func inkChrome() -> some View {
        if let sel = controller.inkSelection {
            let rect = sel.displayedRect
            ZStack(alignment: .topLeading) {
                Image(uiImage: sel.image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(inkMoveGesture())

                Rectangle()
                    .strokeBorder(themeManager.selectionColor, lineWidth: lineWidth)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)

                ForEach(Corner.allCases, id: \.self) { corner in
                    handle()
                        .position(corner.point(in: rect))
                        .gesture(inkResizeGesture(corner: corner))
                }

                inkActions()
                    .position(x: rect.midX, y: rect.minY - 44 / displayScale)
            }
        }
    }

    private func inkMoveGesture() -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("paper"))
            .onChanged { value in
                controller.moveInk(translation: CGSize(
                    width: inkStartTranslation.width + value.translation.width,
                    height: inkStartTranslation.height + value.translation.height))
            }
            .onEnded { _ in
                inkStartTranslation = controller.inkSelection?.translation ?? .zero
            }
    }

    private func inkResizeGesture(corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("paper"))
            .onChanged { value in
                guard let sel = controller.inkSelection else { return }
                // Capture the fixed opposite corner once, in both displayed and
                // base spaces, so scaling pins it in place.
                if inkResizeStart == nil {
                    inkResizeStart = (
                        displayed: corner.opposite.point(in: sel.displayedRect),
                        base: corner.opposite.point(in: sel.bounds)
                    )
                }
                guard let start = inkResizeStart else { return }
                let baseDiag = hypot(sel.bounds.width, sel.bounds.height)
                guard baseDiag > 0 else { return }
                // Uniform scale from the dragged-corner distance to the anchor.
                let newScale = max(0.1, hypot(value.location.x - start.displayed.x,
                                              value.location.y - start.displayed.y) / baseDiag)
                // Translation that keeps `start.displayed` fixed under the scale.
                let center = CGPoint(x: sel.bounds.midX, y: sel.bounds.midY)
                let tx = start.displayed.x - center.x - newScale * (start.base.x - center.x)
                let ty = start.displayed.y - center.y - newScale * (start.base.y - center.y)
                controller.scaleInk(newScale)
                controller.moveInk(translation: CGSize(width: tx, height: ty))
            }
            .onEnded { _ in
                inkResizeStart = nil
                inkStartTranslation = controller.inkSelection?.translation ?? .zero
            }
    }

    private func inkActions() -> some View {
        HStack(spacing: 2) {
            actionButton("doc.on.doc") { controller.copyInkSelection() }
            actionButton("scissors") { controller.cutInkSelection() }
            actionButton("plus.square.on.square") { controller.duplicateInkSelection() }
            actionButton("trash") { controller.deleteInkSelection() }
            actionButton("checkmark") { controller.commitInkSelection() }
        }
        .padding(.horizontal, 6 / displayScale)
        .padding(.vertical, 4 / displayScale)
        .background(
            Capsule().fill(themeManager.card)
                .overlay(Capsule().strokeBorder(themeManager.outline.opacity(0.4), lineWidth: lineWidth))
        )
        .scaleEffect(1 / displayScale)
    }

    // MARK: Shared pieces

    private func handle() -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(themeManager.selectionColor, lineWidth: lineWidth))
            .frame(width: handleRadius * 2, height: handleRadius * 2)
            .contentShape(Circle().inset(by: -handleRadius))
    }

    private func actionButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeManager.iconTint)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Corners

enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    var opposite: Corner {
        switch self {
        case .topLeft:     return .bottomRight
        case .topRight:    return .bottomLeft
        case .bottomLeft:  return .topRight
        case .bottomRight: return .topLeft
        }
    }
}
