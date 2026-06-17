import SwiftUI
import PencilKit
import UIKit
import Observation

// MARK: - Geometry helpers

extension Array where Element == CGPoint {
    /// Even-odd ray-cast point-in-polygon test.
    func containsPoint(_ p: CGPoint) -> Bool {
        guard count >= 3 else { return false }
        var inside = false
        var j = count - 1
        for i in 0..<count {
            let a = self[i], b = self[j]
            if (a.y > p.y) != (b.y > p.y) {
                let slope = (p.y - a.y) / (b.y - a.y)
                let x = a.x + slope * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    var boundingRect: CGRect {
        guard let first = self.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in self.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Ink Selection

/// A set of strokes lifted off the canvas by the lasso. The originals are
/// removed from the live drawing while selected (so movement shows); the
/// snapshot image is what the overlay draws, transformed live. On commit the
/// net transform is baked into the real strokes and they're merged back.
struct InkSelection {
    var strokes: [PKStroke]      // lifted originals (their own transforms intact)
    var image: UIImage           // snapshot rendered in paper space
    var bounds: CGRect           // paper-space bounds of the snapshot
    var translation: CGSize = .zero
    var scale: CGFloat = 1

    /// Net paper-space transform from the live move/scale, about the bounds
    /// centre. Baked into each stroke on commit.
    var liveTransform: CGAffineTransform {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: c.x + translation.width, y: c.y + translation.height)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -c.x, y: -c.y)
        return t
    }

    /// Selection rect as currently shown (scaled about centre + translated).
    var displayedRect: CGRect {
        let w = bounds.width * scale
        let h = bounds.height * scale
        let cx = bounds.midX + translation.width
        let cy = bounds.midY + translation.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: - Page Edit Controller
//
// Owns ALL placed-object + lasso editing state and operations for the current
// page. The SwiftUI layers render from it and call its methods; persistence
// goes through PageObjectService. The live ink drawing is reached through the
// injected get/set closures so the controller never owns the canvas.

@Observable
final class PageEditController {

    // Injected per page.
    var notebookId: String = ""
    var pageId: String = ""
    var isDark: Bool = false

    // Closures bridging to the canvas's PKDrawing (owned by the ViewModel).
    var getDrawing: () -> PKDrawing = { PKDrawing() }
    var setDrawing: (PKDrawing) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    // Placed objects + decoded caches.
    var objects: [PageObject] = []
    var images: [String: UIImage] = [:]
    var attributed: [String: NSAttributedString] = [:]

    // Selection / editing.
    var selectedObjectId: String?
    var editingObjectId: String?
    /// Live attributed text bound to the editor while editing.
    var editingText = NSAttributedString(string: "")

    // Lasso ink selection.
    var inkSelection: InkSelection?
    var lassoPoints: [CGPoint] = []

    // Clipboards (in-memory, survive across pages within a session).
    private var objectClipboard: PageObject?
    private var inkClipboard: [PKStroke] = []

    // Undo/redo — registered on the SAME UndoManager PencilKit uses (the
    // canvas's), so the existing undo/redo buttons revert ink, objects and
    // lasso edits in one interleaved timeline.
    var undoManagerProvider: () -> UndoManager? = { nil }
    private var undoSnapshot: [PageObject]?
    private var inkUndoBaseline: PKDrawing?

    private let service = PageObjectService.shared

    /// Drives the rich-text format bar and the live editor's selection.
    let textController = RichTextEditingController()

    var hasClipboard: Bool { objectClipboard != nil || !inkClipboard.isEmpty }

    init() {
        textController.onChange = { [weak self] in self?.captureEditorText() }
    }

    /// Pulls the latest attributed text out of the live editor (after a
    /// format-bar change that mutated the text storage directly).
    private func captureEditorText() {
        guard let tv = textController.textView else { return }
        editingText = tv.attributedText
        liveTextChanged()
    }

    /// Height a text object needs to show ALL its text at a given width.
    /// Prefers the live editor's own layout (most accurate) and falls back to
    /// measuring the stored attributed string.
    func fittedTextHeight(_ id: String, width: CGFloat) -> CGFloat {
        let inset = RichText.textInset
        // Live editor measurement — exact, matches what the user is typing.
        if editingObjectId == id, let tv = textController.textView {
            let h = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            return max(60, ceil(h))
        }
        let attr = attributed[id] ?? NSAttributedString(string: "")
        let constraint = CGSize(width: width - inset.left - inset.right,
                                height: .greatestFiniteMagnitude)
        let measured = attr.boundingRect(
            with: constraint, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return max(60, ceil(measured.height) + inset.top + inset.bottom)
    }

    /// Recomputes a text object's height to fit its content at its current
    /// width (used live while typing and after a width resize).
    func refitTextHeight(_ id: String) {
        guard let i = index(of: id), objects[i].kind == .text else { return }
        objects[i].height = Double(fittedTextHeight(id, width: CGFloat(objects[i].width)))
    }

    // MARK: - Loading

    func configure(notebookId: String, pageId: String, isDark: Bool) {
        self.notebookId = notebookId
        self.pageId = pageId
        self.isDark = isDark
        clearSelection()
        load()
    }

    func load() {
        do {
            objects = try service.objects(for: pageId)
        } catch {
            onError(error.localizedDescription)
            objects = []
        }
        images.removeAll()
        attributed.removeAll()
        for obj in objects {
            switch obj.kind {
            case .photo:
                if let img = service.loadPhoto(obj, notebookId: notebookId) {
                    images[obj.id] = img
                }
            case .text:
                if let data = obj.textRTF, let str = RichText.attributedString(fromRTF: data) {
                    attributed[obj.id] = str
                } else {
                    attributed[obj.id] = RichText.placeholder(color: defaultTextColor)
                }
            }
        }
    }

    private var defaultTextColor: UIColor { isDark ? .white : .black }

    // MARK: - Selection helpers

    func clearSelection() {
        // Commit any in-flight ink move before dropping the selection.
        commitInkSelection()
        selectedObjectId = nil
        endEditing(commit: true)
        lassoPoints = []
    }

    func selectObject(_ id: String) {
        commitInkSelection()
        selectedObjectId = id
        bringToFront(id)
    }

    func object(_ id: String?) -> PageObject? {
        guard let id else { return nil }
        return objects.first { $0.id == id }
    }

    private func index(of id: String) -> Int? {
        objects.firstIndex { $0.id == id }
    }

    // MARK: - Insert

    /// Inserts a new empty text box centred on the page and enters edit mode.
    @discardableResult
    func insertTextBox() -> PageObject? {
        let size = CGSize(width: 520, height: 150)
        let origin = CGPoint(x: (PaperSpec.size.width - size.width) / 2,
                             y: (PaperSpec.size.height - size.height) / 2)
        let empty = RichText.placeholder(color: defaultTextColor)
        let rtf = RichText.rtf(from: empty)
        var obj = PageObject(
            pageId: pageId, kind: .text,
            x: Double(origin.x), y: Double(origin.y),
            width: Double(size.width), height: Double(size.height),
            zIndex: nextZ(), textRTF: rtf
        )
        let before = objects
        do {
            obj = try service.insert(obj)
            objects.append(obj)
            attributed[obj.id] = empty
            selectedObjectId = obj.id
            beginEditing(obj.id)
            registerObjectsUndo(before: before, after: objects, actionName: "Insert Text")
            return obj
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    /// Inserts a photo object sized to fit the page while preserving aspect.
    @discardableResult
    func insertPhoto(_ image: UIImage) -> PageObject? {
        do {
            let file = try service.savePhoto(image, notebookId: notebookId)
            let fitted = fittedSize(for: image.size)
            let origin = CGPoint(x: (PaperSpec.size.width - fitted.width) / 2,
                                 y: (PaperSpec.size.height - fitted.height) / 2)
            var obj = PageObject(
                pageId: pageId, kind: .photo,
                x: Double(origin.x), y: Double(origin.y),
                width: Double(fitted.width), height: Double(fitted.height),
                zIndex: nextZ(), imageFile: file
            )
            let before = objects
            obj = try service.insert(obj)
            objects.append(obj)
            images[obj.id] = image
            selectedObjectId = obj.id
            registerObjectsUndo(before: before, after: objects, actionName: "Insert Photo")
            return obj
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    private func fittedSize(for size: CGSize) -> CGSize {
        let maxW = PaperSpec.size.width * 0.7
        let maxH = PaperSpec.size.height * 0.7
        guard size.width > 0, size.height > 0 else { return CGSize(width: 400, height: 400) }
        let scale = min(maxW / size.width, maxH / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func nextZ() -> Int { (objects.map(\.zIndex).max() ?? 0) + 1 }

    // MARK: - Move / resize / rotate (live + commit)

    /// Live frame update during a drag — in-memory only (no DB write per frame).
    func setFrame(_ frame: CGRect, for id: String) {
        guard let i = index(of: id) else { return }
        objects[i].frame = frame
    }

    func setRotation(_ radians: Double, for id: String) {
        guard let i = index(of: id) else { return }
        objects[i].rotation = radians
    }

    /// Persists an object after a manipulation gesture ends.
    func commitObject(_ id: String) {
        guard let obj = object(id) else { return }
        do { try service.update(obj) }
        catch { onError(error.localizedDescription) }
    }

    func bringToFront(_ id: String) {
        guard let i = index(of: id), objects[i].zIndex != nextZ() - 1 || objects.count == 1 else { return }
        objects[i].zIndex = nextZ()
        objects.sort { $0.zIndex < $1.zIndex }
        commitObject(id)
    }

    // MARK: - Text editing

    func beginEditing(_ id: String) {
        guard let obj = object(id), obj.kind == .text else { return }
        editingObjectId = id
        editingText = attributed[id] ?? RichText.placeholder(color: defaultTextColor)
    }

    /// Ends editing. When `commit`, writes the live text back to the object
    /// (auto-sizing height to fit) and persists.
    func endEditing(commit: Bool) {
        guard let id = editingObjectId else { return }
        // Measure WHILE still editing so the live editor's exact layout is used.
        if commit, let i = index(of: id) {
            attributed[id] = editingText
            objects[i].textRTF = RichText.rtf(from: editingText)
            objects[i].height = Double(fittedTextHeight(id, width: CGFloat(objects[i].width)))
            commitObject(id)
        }
        editingObjectId = nil
    }

    func liveTextChanged() {
        guard let id = editingObjectId, let i = index(of: id) else { return }
        attributed[id] = editingText
        objects[i].textRTF = RichText.rtf(from: editingText)
        // Grow (or shrink) the box vertically so all text always fits.
        objects[i].height = Double(fittedTextHeight(id, width: CGFloat(objects[i].width)))
    }

    // MARK: - Delete / duplicate / clipboard (objects)

    func deleteSelectedObject() {
        guard let id = selectedObjectId, let obj = object(id) else { return }
        let before = objects
        do {
            // Delete only the row (keep the photo file) so undo can restore it.
            try service.deleteRow(obj)
            objects.removeAll { $0.id == id }
            selectedObjectId = nil
            registerObjectsUndo(before: before, after: objects, actionName: "Delete")
        } catch {
            onError(error.localizedDescription)
        }
    }

    func duplicateSelectedObject() {
        guard let id = selectedObjectId, let src = object(id) else { return }
        let before = objects
        var copy = src
        copy.id = UUID().uuidString
        copy.x += 30
        copy.y += 30
        copy.zIndex = nextZ()
        copy.createdAt = Date()
        // Photos: duplicate the bytes on disk so deleting one keeps the other.
        if src.kind == .photo, let img = images[src.id] {
            if let file = try? service.savePhoto(img, notebookId: notebookId) {
                copy.imageFile = file
            }
        }
        do {
            copy = try service.insert(copy)
            objects.append(copy)
            if src.kind == .photo { images[copy.id] = images[src.id] }
            if src.kind == .text { attributed[copy.id] = attributed[src.id] }
            selectedObjectId = copy.id
            registerObjectsUndo(before: before, after: objects, actionName: "Duplicate")
        } catch {
            onError(error.localizedDescription)
        }
    }

    func copySelectedObject() {
        guard let id = selectedObjectId, let obj = object(id) else { return }
        objectClipboard = obj
    }

    func cutSelectedObject() {
        copySelectedObject()
        deleteSelectedObject()
    }

    // MARK: - Paste (objects or ink or system clipboard)

    func paste() {
        // 1) An object we copied in-app.
        if let src = objectClipboard {
            var copy = src
            copy.id = UUID().uuidString
            copy.pageId = pageId
            copy.x += 30; copy.y += 30
            copy.zIndex = nextZ()
            copy.createdAt = Date()
            if src.kind == .photo, let file = src.imageFile,
               let img = FileStorageManager.shared.loadPageObjectImage(notebookId: notebookId, fileName: file),
               let newFile = try? service.savePhoto(img, notebookId: notebookId) {
                copy.imageFile = newFile
            }
            let before = objects
            do {
                copy = try service.insert(copy)
                objects.append(copy)
                rebuildCaches()
                selectedObjectId = copy.id
                registerObjectsUndo(before: before, after: objects, actionName: "Paste")
            } catch { onError(error.localizedDescription) }
            return
        }
        // 2) Ink strokes we cut/copied.
        if !inkClipboard.isEmpty {
            pasteInk()
            return
        }
        // 3) System pasteboard — image or text becomes a new object.
        let pb = UIPasteboard.general
        if let image = pb.image {
            insertPhoto(image)
        } else if let text = pb.string, !text.isEmpty {
            insertTextObject(from: RichText.attributedString(fromPlain: text, color: defaultTextColor))
        }
    }

    /// Inserts a non-empty text object (used by paste) without entering edit.
    @discardableResult
    private func insertTextObject(from attr: NSAttributedString) -> PageObject? {
        let width: CGFloat = 600
        let inset = RichText.textInset
        let measured = attr.boundingRect(
            with: CGSize(width: width - inset.left - inset.right, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = max(80, ceil(measured.height) + inset.top + inset.bottom)
        let origin = CGPoint(x: (PaperSpec.size.width - width) / 2,
                             y: (PaperSpec.size.height - height) / 2)
        var obj = PageObject(
            pageId: pageId, kind: .text,
            x: Double(origin.x), y: Double(origin.y),
            width: Double(width), height: Double(height),
            zIndex: nextZ(), textRTF: RichText.rtf(from: attr))
        let before = objects
        do {
            obj = try service.insert(obj)
            objects.append(obj)
            attributed[obj.id] = attr
            selectedObjectId = obj.id
            registerObjectsUndo(before: before, after: objects, actionName: "Paste Text")
            return obj
        } catch { onError(error.localizedDescription); return nil }
    }

    // MARK: - Lasso (ink)

    func updateLasso(_ points: [CGPoint]) { lassoPoints = points }

    /// Finishes a lasso gesture: selects strokes mostly inside the polygon,
    /// lifts them off the canvas and prepares a movable/resizable snapshot.
    func endLasso() {
        defer { lassoPoints = [] }
        let polygon = lassoPoints
        guard polygon.count >= 3 else { return }

        let drawing = getDrawing()
        var selected: [PKStroke] = []
        var remaining: [PKStroke] = []
        for stroke in drawing.strokes {
            if strokeMostlyInside(stroke, polygon: polygon) { selected.append(stroke) }
            else { remaining.append(stroke) }
        }
        guard !selected.isEmpty else { return }

        // Baseline for undo = the whole drawing before we lift anything.
        inkUndoBaseline = drawing
        // Remove from the canvas so the move is visible.
        setDrawing(PKDrawing(strokes: remaining))
        makeInkSelection(from: selected)
    }

    private func strokeMostlyInside(_ stroke: PKStroke, polygon: [CGPoint]) -> Bool {
        let points = stroke.path.map { $0.location.applying(stroke.transform) }
        guard !points.isEmpty else { return false }
        let inside = points.reduce(into: 0) { $0 += polygon.containsPoint($1) ? 1 : 0 }
        return Double(inside) / Double(points.count) >= 0.5
    }

    private func makeInkSelection(from strokes: [PKStroke]) {
        let lifted = PKDrawing(strokes: strokes)
        var bounds = lifted.bounds.insetBy(dx: -8, dy: -8)
        if !bounds.isFinite || bounds.isEmpty {
            bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        }
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: isDark ? .dark : .light).performAsCurrent {
            image = lifted.image(from: bounds, scale: 2.0)
        }
        inkSelection = InkSelection(strokes: strokes, image: image, bounds: bounds)
        selectedObjectId = nil
    }

    func moveInk(translation: CGSize) {
        inkSelection?.translation = translation
    }

    func scaleInk(_ scale: CGFloat) {
        inkSelection?.scale = max(0.1, scale)
    }

    /// Bakes the live transform into the lifted strokes, merges them back and
    /// registers the whole lasso edit as one undo step.
    func commitInkSelection() {
        guard let sel = inkSelection else { return }
        inkSelection = nil
        mergeBack(sel)
        finalizeInkUndo("Move Selection")
    }

    func deleteInkSelection() {
        guard inkSelection != nil else { return }
        // Lifted strokes were already removed from the drawing; just drop them.
        inkSelection = nil
        finalizeInkUndo("Delete Selection")
    }

    func copyInkSelection() {
        guard let sel = inkSelection else { return }
        inkClipboard = bakedStrokes(of: sel)
        // Copy leaves the ink in place: merge it back unchanged (no net change,
        // so finalize registers nothing).
        inkSelection = nil
        mergeBack(sel)
        finalizeInkUndo("Copy Selection")
    }

    func cutInkSelection() {
        guard let sel = inkSelection else { return }
        inkClipboard = bakedStrokes(of: sel)
        inkSelection = nil   // not merged back → removed
        finalizeInkUndo("Cut Selection")
    }

    func duplicateInkSelection() {
        guard let sel = inkSelection else { return }
        let copies = bakedStrokes(of: sel)
        // Drop the originals back in place WITHOUT finalizing — the baseline
        // carries through so the copy's eventual commit is one undo step.
        mergeBack(sel)
        inkSelection = nil
        offsetAndSelect(copies, by: CGSize(width: 40, height: 40))
    }

    private func pasteInk() {
        guard !inkClipboard.isEmpty else { return }
        // Baseline = the drawing as it is now; the pasted strokes' eventual
        // commit becomes one undo step.
        inkUndoBaseline = getDrawing()
        offsetAndSelect(inkClipboard, by: CGSize(width: 40, height: 40))
    }

    /// Returns the selection's strokes with the live transform baked in.
    private func bakedStrokes(of sel: InkSelection) -> [PKStroke] {
        let t = sel.liveTransform
        return sel.strokes.map { stroke in
            var s = stroke
            s.transform = s.transform.concatenating(t)
            return s
        }
    }

    /// Adds strokes (already in paper space) offset by `offset`, leaving them
    /// as a fresh ink selection ready to move.
    private func offsetAndSelect(_ strokes: [PKStroke], by offset: CGSize) {
        let t = CGAffineTransform(translationX: offset.width, y: offset.height)
        let moved = strokes.map { stroke -> PKStroke in
            var s = stroke
            s.transform = s.transform.concatenating(t)
            return s
        }
        makeInkSelection(from: moved)
    }

    // MARK: - Undo / Redo

    /// Snapshots the object list at the start of a multi-frame gesture
    /// (move / resize) so it can be reverted as one undo step.
    func beginUndoGroup() { undoSnapshot = objects }

    func endUndoGroup(_ actionName: String) {
        guard let before = undoSnapshot else { return }
        undoSnapshot = nil
        registerObjectsUndo(before: before, after: objects, actionName: actionName)
    }

    private func registerObjectsUndo(before: [PageObject], after: [PageObject], actionName: String) {
        guard before != after, let um = undoManagerProvider() else { return }
        um.registerUndo(withTarget: self) { ctrl in
            ctrl.restoreObjects(before)
            // The block above is the undo; this registers its redo.
            ctrl.registerObjectsUndo(before: after, after: before, actionName: actionName)
        }
        um.setActionName(actionName)
    }

    private func restoreObjects(_ snapshot: [PageObject]) {
        do { try service.replaceAll(forPage: pageId, with: snapshot) }
        catch { onError(error.localizedDescription) }
        objects = snapshot
        selectedObjectId = nil
        editingObjectId = nil
        rebuildCaches()
    }

    /// Reloads photo/text caches for whatever objects are now present.
    private func rebuildCaches() {
        for obj in objects {
            switch obj.kind {
            case .photo:
                if images[obj.id] == nil,
                   let img = service.loadPhoto(obj, notebookId: notebookId) {
                    images[obj.id] = img
                }
            case .text:
                if let data = obj.textRTF,
                   let str = RichText.attributedString(fromRTF: data) {
                    attributed[obj.id] = str
                }
            }
        }
    }

    /// Registers an ink (drawing) change as one undo step, restoring the
    /// pre-operation drawing on undo and re-applying it on redo.
    private func registerInkUndo(before: PKDrawing, after: PKDrawing, actionName: String) {
        guard before != after, let um = undoManagerProvider() else { return }
        um.registerUndo(withTarget: self) { ctrl in
            ctrl.setDrawing(before)
            ctrl.registerInkUndo(before: after, after: before, actionName: actionName)
        }
        um.setActionName(actionName)
    }

    /// Closes out an ink operation: registers the baseline→final change.
    private func finalizeInkUndo(_ actionName: String) {
        guard let before = inkUndoBaseline else { return }
        inkUndoBaseline = nil
        let after = getDrawing()
        registerInkUndo(before: before, after: after, actionName: actionName)
    }

    /// Merges the selection's (transformed) strokes back into the drawing
    /// WITHOUT finalizing an undo step.
    private func mergeBack(_ sel: InkSelection) {
        let baked = bakedStrokes(of: sel)
        var strokes = getDrawing().strokes
        strokes.append(contentsOf: baked)
        setDrawing(PKDrawing(strokes: strokes))
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
