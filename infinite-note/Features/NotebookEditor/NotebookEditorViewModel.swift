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

    /// Daemon-independent fallback render of the current page's ink (drawn with
    /// Core Graphics, not PencilKit) shown UNDER the live canvas so saved
    /// strokes are visible on a cold launch even while `handwritingd` can't
    /// rasterize. Display-only — never persisted, never edited.
    var inkFallbackImage: UIImage? = nil
    /// Whether the fallback image should currently be shown. Set when a page
    /// loads with ink; cleared once the live canvas confirms it has rendered.
    var showInkFallback = false
    /// Flips true the first time the live canvas confirms a render this session.
    /// After that the renderer is warm, so page turns skip the fallback (the
    /// live canvas draws straight away) and never flash the approximation.
    private var liveRenderConfirmed = false

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
    /// True while the CURRENT page's drawing could not be read from disk
    /// (I/O error or corrupt file). While set, every save for this page is
    /// BLOCKED: saving would overwrite the real ink on disk with whatever the
    /// canvas happens to show (empty, or worse, the previous page's strokes).
    /// Cleared by the next successful load of the page.
    private var currentPageLoadFailed = false

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
            // `load()` can run again mid-session (database recovered from the
            // in-memory fallback) — keep the cursor in bounds if the page
            // list changed shape.
            if currentPageIndex >= pages.count {
                currentPageIndex = max(0, pages.count - 1)
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
            refreshInkFallback()
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

    /// Persists the current page's drawing.
    ///
    /// - Parameter allowEmptyOverwrite: pass `true` ONLY when an empty canvas
    ///   is a deliberate user state (explicit page erase, ink erased or cut by
    ///   hand, lasso edits). Lifecycle saves (page switch, close, background,
    ///   sync, PDF export) leave it `false`, which arms a shield: an EMPTY
    ///   drawing never overwrites a page whose file still holds real ink.
    ///   Rationale: every data-loss incident here had the same shape — some
    ///   failure (render daemon down, unread file, load error) left the canvas
    ///   blank while the disk still had the user's strokes, and one incidental
    ///   save then destroyed them permanently.
    func saveCurrentDrawing(allowEmptyOverwrite: Bool = false) {
        guard let page = currentPage else { return }
        // The page's ink never made it INTO memory — saving now would write
        // over the user's real strokes with a blank (or stale) canvas. Skip;
        // the flag clears on the next successful load of this page.
        guard !currentPageLoadFailed else { return }
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
        // Blank-overwrite shield (see `allowEmptyOverwrite`).
        if drawing.strokes.isEmpty, !allowEmptyOverwrite,
           storage.savedDrawingHasProtectableInk(notebookId: notebook.id, pageId: page.id) {
            return
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
        refreshInkFallback()
        canvasController.clearPage()
        // Explicit user erase — the ONE lifecycle path where persisting an
        // empty drawing over saved ink is exactly what was asked for.
        saveCurrentDrawing(allowEmptyOverwrite: true)
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
            // This path only fires from real canvas edits (strokes, hand
            // erasing, lasso cut/merge) — an empty canvas here is the user's
            // deliberate doing, so it may persist.
            saveCurrentDrawing(allowEmptyOverwrite: true)
        }
    }

    private func loadCurrentDrawing() throws {
        defer { drawingLoadToken += 1; refreshInkFallback() }   // push to canvas + refresh fallback
        guard let page = currentPage else { drawing = PKDrawing(); return }
        do {
            drawing = try drawingService.loadDrawing(for: page)
            currentPageLoadFailed = false
        } catch {
            // NEVER leave the previous page's ink in `drawing` on a failed
            // load — it would render onto (and eventually be saved into) this
            // page. Show it blank, and block saves until a load succeeds so
            // the on-disk file stays untouched.
            drawing = PKDrawing()
            currentPageLoadFailed = true
            throw error
        }
    }

    /// Called when the app returns to the foreground with this editor open.
    /// iOS can tear the ink render daemon (`handwritingd`) down while the app
    /// is suspended — so ink that rendered fine this morning can silently come
    /// back BLANK now, with the fallback machinery already disarmed by the
    /// earlier successful render. Re-verify with a real pixel probe and, if
    /// the renderer is gone, re-show the CG fallback and re-arm the canvas's
    /// forced-render hand-off. Cheap no-op while everything is healthy.
    func reassertInkVisibilityIfNeeded() {
        guard !drawing.strokes.isEmpty else { return }
        // Probe ASYNCHRONOUSLY — never render on the main thread (with the
        // daemon wedged that call can stall or kill the app). If the renderer
        // is genuinely gone, bring the CG fallback back and re-arm the canvas.
        InkRenderReadiness.shared.verifyReadiness { [weak self] ok in
            guard let self, !ok, !self.drawing.strokes.isEmpty else { return }
            self.liveRenderConfirmed = false
            self.refreshInkFallback()
            (self.canvasController.canvasView as? ManagedCanvasView)?.rearmInkRender()
        }
    }

    /// Set while the CG fallback has been shown this session — the sidebar
    /// thumbnails rendered in that window are approximations (or blank), so
    /// one refresh pass is owed when the live renderer comes back.
    private var thumbnailsNeedRecoveryRefresh = false

    /// The ink renderer just came (back) up: re-render every thumbnail once so
    /// approximated/blank sidebar pages upgrade to the real PencilKit render.
    /// Safe to call repeatedly — only acts if a refresh is actually owed.
    func rendererDidRecover() {
        guard thumbnailsNeedRecoveryRefresh else { return }
        thumbnailsNeedRecoveryRefresh = false
        for page in pages {
            thumbnailRefreshTriggers[page.id, default: 0] += 1
        }
    }

    /// Re-renders the daemon-independent ink fallback for the current page. It's
    /// shown only until the live canvas confirms a render this session (after
    /// which the renderer is warm and page turns draw live straight away).
    private func refreshInkFallback() {
        guard !liveRenderConfirmed, !drawing.strokes.isEmpty else {
            inkFallbackImage = nil
            showInkFallback = false
            return
        }
        inkFallbackImage = StrokeImageRenderer.image(
            for: drawing, size: PaperSpec.size, darkTheme: isDarkTheme)
        showInkFallback = (inkFallbackImage != nil)
        if showInkFallback { thumbnailsNeedRecoveryRefresh = true }
    }

    /// Called by the canvas once the LIVE PencilKit canvas has actually rendered
    /// its ink — hands off from the fallback image to the real canvas.
    func liveInkDidRender() {
        liveRenderConfirmed = true
        showInkFallback = false
    }

    private func loadPageBackground() {
        guard let page = currentPage else { pageBackgroundImage = nil; return }
        pageBackgroundImage = page.pageStyle == .photo
            ? storage.loadPageBackground(notebookId: notebook.id, pageId: page.id)
            : nil
    }
}
