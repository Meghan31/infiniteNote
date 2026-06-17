import Foundation
import PencilKit
import UIKit
import Observation

@Observable
final class NotebookEditorViewModel {
    var notebook: Notebook
    var pages: [Page] = []
    var currentPageIndex: Int = 0
    var drawing: PKDrawing = PKDrawing()
    var isSaving = false
    var errorMessage: String?
    var isRulerActive = false
    var pageBackgroundImage: UIImage? = nil

    /// Bumped ONLY when `drawing` is replaced externally (page switch, erase,
    /// load). `DrawingCanvasView` pushes the binding onto the live canvas only
    /// when this changes — so incidental SwiftUI re-renders can never overwrite
    /// (and wipe) strokes still inside the autosave debounce window.
    var drawingLoadToken = 0

    /// Thumbnail images keyed by page ID, rendered lazily per page.
    var pageThumbnails: [String: UIImage] = [:]
    /// Increment to force a specific page's thumbnail to re-render.
    var thumbnailRefreshTriggers: [String: Int] = [:]

    let canvasController = CanvasController()

    /// Placed-object + lasso editing for the CURRENT page. Reconfigured on
    /// every page switch; bridges to the live canvas drawing via closures so
    /// the lasso can lift/merge ink without owning the canvas.
    let editController = PageEditController()

    /// Mirrors the app theme so the controller seeds new text in a visible
    /// colour and renders ink snapshots under the right trait. Set by the view.
    var isDarkTheme = false {
        didSet { editController.isDark = isDarkTheme }
    }

    /// Called after a notebook-level change (cover / default style) so the
    /// home screen can reload and reflect it.
    var onNotebookChanged: () -> Void = {}

    private let drawingService = DrawingService.shared
    private let notebookService = NotebookService.shared
    private let storage = FileStorageManager.shared
    private let pageObjectService = PageObjectService.shared
    private var saveTask: Task<Void, Never>?
    /// True after a stroke-save failure has been surfaced; reset by the next
    /// successful save. Keeps the ~500 ms autosave from spamming one alert
    /// per stroke while the disk stays full.
    private var hasWarnedSaveFailure = false

    var currentPage: Page? {
        guard currentPageIndex < pages.count else { return nil }
        return pages[currentPageIndex]
    }

    var currentPageStyle: PageStyle {
        currentPage?.pageStyle ?? .grid
    }

    init(notebook: Notebook) {
        self.notebook = notebook
        // Bridge the edit controller to the live canvas drawing.
        editController.getDrawing = { [weak self] in
            self?.canvasController.canvasView?.drawing ?? self?.drawing ?? PKDrawing()
        }
        editController.setDrawing = { [weak self] newDrawing in
            guard let self else { return }
            self.drawing = newDrawing
            // Apply synchronously so a lasso lift/merge shows immediately;
            // safe here because drawing is disabled in lasso mode (no
            // in-flight stroke to cancel).
            self.canvasController.canvasView?.drawing = newDrawing
            self.saveCurrentDrawingDebounced()
        }
        editController.onError = { [weak self] message in
            self?.errorMessage = message
        }
        // Object + lasso edits register on the canvas's UndoManager — the same
        // one PencilKit uses — so the existing undo/redo buttons cover them.
        editController.undoManagerProvider = { [weak self] in
            self?.canvasController.canvasView?.undoManager
        }
    }

    /// Reconfigures the edit controller for whatever page is now current.
    private func configureEditController() {
        guard let page = currentPage else { return }
        editController.configure(notebookId: notebook.id, pageId: page.id, isDark: isDarkTheme)
    }

    /// Commits any in-flight lasso/text selection so nothing is lost on a page
    /// switch, close, export or sync.
    func commitPendingEdits() {
        editController.clearSelection()
    }

    // MARK: - Load

    func load() {
        do {
            pages = try drawingService.pages(for: notebook.id)
            if pages.isEmpty {
                let page = try drawingService.addPage(to: notebook.id, style: notebook.defaultPageStyle)
                pages = [page]
            }
            try loadCurrentDrawing()
            loadPageBackground()
            configureEditController()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    func goToPage(at index: Int) {
        guard index >= 0, index < pages.count else { return }
        commitPendingEdits()
        saveCurrentDrawing()
        currentPageIndex = index
        do { try loadCurrentDrawing() }
        catch { errorMessage = error.localizedDescription }
        loadPageBackground()
        configureEditController()
    }

    func goToNextPage() { goToPage(at: currentPageIndex + 1) }
    func goToPreviousPage() { goToPage(at: currentPageIndex - 1) }

    // MARK: - Page Management

    func addPage() {
        commitPendingEdits()
        saveCurrentDrawing()
        do {
            let page = try drawingService.addPage(to: notebook.id, style: notebook.defaultPageStyle)
            pages.append(page)
            currentPageIndex = pages.count - 1
            drawing = PKDrawing()
            drawingLoadToken += 1
            pageBackgroundImage = nil
            configureEditController()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePage(at index: Int) {
        // Bounds-check `index` too: context-menu deletes capture it at render
        // time, so a stale index must never crash on `pages[index]`.
        guard pages.count > 1, pages.indices.contains(index) else { return }
        // Persist any in-flight strokes on the CURRENT page before mutating
        // the page list — `loadCurrentDrawing()` below re-reads it from disk,
        // which would otherwise clobber strokes still in the debounce window
        // when a *different* page is deleted from the sidebar.
        commitPendingEdits()
        saveCurrentDrawing()
        let page = pages[index]
        // The page-objects rows cascade-delete with the page, but their photo
        // files on disk don't — remove them so a deleted page leaves nothing.
        if let objects = try? pageObjectService.objects(for: page.id) {
            for object in objects where object.imageFile != nil {
                storage.deletePageObjectImage(notebookId: notebook.id, fileName: object.imageFile!)
            }
        }
        do {
            try drawingService.deletePage(page)
            pages.remove(at: index)
            // Deleting a page ABOVE the current one shifts every later index
            // down by one — follow the shift so the user stays on the page
            // they were viewing instead of jumping to the next one.
            if index < currentPageIndex { currentPageIndex -= 1 }
            if currentPageIndex >= pages.count { currentPageIndex = pages.count - 1 }
            try loadCurrentDrawing()
            loadPageBackground()
            configureEditController()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drag-to-reorder: moves pages and persists new page numbers.
    func movePage(from source: IndexSet, to destination: Int) {
        let currentPageId = currentPage?.id
        saveCurrentDrawing()
        do {
            try drawingService.movePages(&pages, from: source, to: destination)
            // Keep cursor on the same page after reorder
            if let id = currentPageId, let newIndex = pages.firstIndex(where: { $0.id == id }) {
                currentPageIndex = newIndex
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Drawing Actions

    func onDrawingChanged(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        saveCurrentDrawingDebounced()
    }

    func saveCurrentDrawing() {
        guard let page = currentPage else { return }
        // Pull the LIVE drawing straight from the canvas first. The bound
        // `drawing` copy can lag the canvas by up to ~400 ms (the
        // coordinator's debounce), which used to silently drop strokes drawn
        // right before a page switch, close, sync, or PDF export.
        // (Safe at every call site: this runs before `currentPageIndex`
        // changes, so the canvas still shows `currentPage`. If the canvas is
        // already gone — e.g. onDisappear — we fall back to the bound copy.)
        if let liveDrawing = canvasController.canvasView?.drawing {
            drawing = liveDrawing
        }
        do {
            try drawingService.saveDrawing(drawing, for: page)
            hasWarnedSaveFailure = false
        } catch {
            // Surface the failure (disk full, sandbox trouble) instead of
            // silently dropping ink — once per failure streak, not per stroke.
            if !hasWarnedSaveFailure {
                hasWarnedSaveFailure = true
                errorMessage = "Couldn't save your latest strokes — check free "
                    + "storage. Keep this page open; saving retries on your "
                    + "next stroke. (\(error.localizedDescription))"
            }
            return
        }
        try? notebookService.touchNotebook(notebook)
        // Trigger thumbnail refresh for the saved page
        thumbnailRefreshTriggers[page.id, default: 0] += 1
    }

    func eraseCurrentPage() {
        drawing = PKDrawing()
        drawingLoadToken += 1
        canvasController.clearPage()
        saveCurrentDrawing()
    }

    func undo() { canvasController.undo() }
    func redo() { canvasController.redo() }

    // MARK: - Page Style

    func setPageStyle(_ style: PageStyle, backgroundImageData: Data? = nil) {
        guard let idx = pages.indices.first(where: { pages[$0].id == currentPage?.id }),
              let page = currentPage else { return }

        // Photo style: persist the image FIRST and surface a failure — a
        // swallowed `try?` here left the page styled "photo" with no image
        // on disk (blank after relaunch, blank in exports).
        if style == .photo, let data = backgroundImageData {
            do {
                try storage.savePageBackground(data, notebookId: notebook.id, pageId: page.id)
            } catch {
                errorMessage = "Couldn't save the photo background — check "
                    + "free storage. The page style was not changed. "
                    + "(\(error.localizedDescription))"
                return
            }
        }

        // Persist the style; roll back the in-memory value on failure so the
        // UI never shows a style the database doesn't have.
        let previousStyle = pages[idx].pageStyle
        pages[idx].pageStyle = style
        do { try drawingService.updatePageStyle(style, for: pages[idx]) }
        catch {
            pages[idx].pageStyle = previousStyle
            errorMessage = error.localizedDescription
            return
        }

        if style == .photo {
            if let data = backgroundImageData {
                pageBackgroundImage = UIImage(data: data)
            }
        } else {
            storage.deletePageBackground(notebookId: notebook.id, pageId: page.id)
            pageBackgroundImage = nil
        }
    }

    // MARK: - Notebook-Level Settings

    /// Changes the default style for FUTURE pages. Existing pages are untouched.
    func setDefaultPageStyle(_ style: PageStyle) {
        do {
            try notebookService.updateDefaultPageStyle(style, for: notebook)
            notebook.defaultPageStyle = style
            onNotebookChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replaces the notebook's cover photo.
    func updateCoverImage(_ data: Data) {
        do {
            try notebookService.updateCoverImage(data, for: notebook)
            notebook.coverImagePath = "cover.jpg"
            notebook.updatedAt = .now
            onNotebookChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Thumbnail Access

    /// Returns the cached thumbnail for `page`, or nil if not yet rendered.
    func thumbnail(for page: Page) -> UIImage? { pageThumbnails[page.id] }

    /// Refresh token for a page — when it changes `PageThumbnailView` re-renders.
    func refreshToken(for page: Page) -> Int { thumbnailRefreshTriggers[page.id] ?? 0 }

    /// Called by `PageThumbnailView` to store a freshly rendered thumbnail.
    func storeThumbnail(_ image: UIImage, for pageId: String) {
        pageThumbnails[pageId] = image
    }

    // MARK: - Private

    private func saveCurrentDrawingDebounced() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveCurrentDrawing()
        }
    }

    private func loadCurrentDrawing() throws {
        defer { drawingLoadToken += 1 }   // external replacement → push to canvas
        guard let page = currentPage else { drawing = PKDrawing(); return }
        drawing = try drawingService.loadDrawing(for: page)
    }

    private func loadPageBackground() {
        guard let page = currentPage else { pageBackgroundImage = nil; return }
        pageBackgroundImage = page.pageStyle == .photo
            ? storage.loadPageBackground(notebookId: notebook.id, pageId: page.id)
            : nil
    }
}
