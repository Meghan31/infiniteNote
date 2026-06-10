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

    /// Thumbnail images keyed by page ID, rendered lazily per page.
    var pageThumbnails: [String: UIImage] = [:]
    /// Increment to force a specific page's thumbnail to re-render.
    var thumbnailRefreshTriggers: [String: Int] = [:]

    let canvasController = CanvasController()

    private let drawingService = DrawingService.shared
    private let notebookService = NotebookService.shared
    private let storage = FileStorageManager.shared
    private var saveTask: Task<Void, Never>?

    var currentPage: Page? {
        guard currentPageIndex < pages.count else { return nil }
        return pages[currentPageIndex]
    }

    var currentPageStyle: PageStyle {
        currentPage?.pageStyle ?? .grid
    }

    init(notebook: Notebook) {
        self.notebook = notebook
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    func goToPage(at index: Int) {
        guard index >= 0, index < pages.count else { return }
        saveCurrentDrawing()
        currentPageIndex = index
        do { try loadCurrentDrawing() }
        catch { errorMessage = error.localizedDescription }
        loadPageBackground()
    }

    func goToNextPage() { goToPage(at: currentPageIndex + 1) }
    func goToPreviousPage() { goToPage(at: currentPageIndex - 1) }

    // MARK: - Page Management

    func addPage() {
        saveCurrentDrawing()
        do {
            let page = try drawingService.addPage(to: notebook.id, style: notebook.defaultPageStyle)
            pages.append(page)
            currentPageIndex = pages.count - 1
            drawing = PKDrawing()
            pageBackgroundImage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePage(at index: Int) {
        guard pages.count > 1 else { return }
        let page = pages[index]
        do {
            try drawingService.deletePage(page)
            pages.remove(at: index)
            if currentPageIndex >= pages.count { currentPageIndex = pages.count - 1 }
            try loadCurrentDrawing()
            loadPageBackground()
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
        try? drawingService.saveDrawing(drawing, for: page)
        try? notebookService.touchNotebook(notebook)
        // Trigger thumbnail refresh for the saved page
        thumbnailRefreshTriggers[page.id, default: 0] += 1
    }

    func eraseCurrentPage() {
        drawing = PKDrawing()
        canvasController.clearPage()
        saveCurrentDrawing()
    }

    func undo() { canvasController.undo() }
    func redo() { canvasController.redo() }

    // MARK: - Page Style

    func setPageStyle(_ style: PageStyle, backgroundImageData: Data? = nil) {
        guard let idx = pages.indices.first(where: { pages[$0].id == currentPage?.id }),
              let page = currentPage else { return }
        pages[idx].pageStyle = style
        do { try drawingService.updatePageStyle(style, for: pages[idx]) }
        catch { errorMessage = error.localizedDescription; return }

        if style == .photo {
            if let data = backgroundImageData {
                try? storage.savePageBackground(data, notebookId: notebook.id, pageId: page.id)
                pageBackgroundImage = UIImage(data: data)
            }
        } else {
            storage.deletePageBackground(notebookId: notebook.id, pageId: page.id)
            pageBackgroundImage = nil
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
