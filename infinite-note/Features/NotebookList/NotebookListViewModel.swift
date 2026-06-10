import Foundation
import Observation

@Observable
final class NotebookListViewModel {
    var notebooks: [Notebook] = []
    var errorMessage: String?
    var isLoading = false

    private let service = NotebookService.shared

    // MARK: - Load

    func loadNotebooks() {
        isLoading = true
        do { notebooks = try service.allNotebooks() }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    // MARK: - Create

    func createNotebook(
        title: String,
        coverColorIndex: Int = Int.random(in: 0...7),
        coverImageData: Data? = nil,
        defaultPageStyle: PageStyle = .grid,
        description: String? = nil,
        author: String? = nil
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let notebook = try service.createNotebook(
                title: trimmed,
                coverColorIndex: coverColorIndex,
                coverImageData: coverImageData,
                defaultPageStyle: defaultPageStyle,
                description: description,
                author: author
            )
            notebooks.insert(notebook, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Details (PDF cover)

    func updateDetails(description: String?, author: String?, for notebook: Notebook) {
        do {
            try service.updateDetails(description: description, author: author, for: notebook)
            if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[idx].noteDescription = description
                notebooks[idx].author = author
                notebooks[idx].updatedAt = .now
            }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Rename

    func renameNotebook(_ notebook: Notebook, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try service.renameNotebook(notebook, to: trimmed)
            if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[idx].title = trimmed
                notebooks[idx].updatedAt = .now
            }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Delete

    func deleteNotebook(_ notebook: Notebook) {
        do {
            try service.deleteNotebook(notebook)
            notebooks.removeAll { $0.id == notebook.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteNotebooks(at offsets: IndexSet) {
        for index in offsets { deleteNotebook(notebooks[index]) }
    }

    // MARK: - Cover

    func updateCoverColor(_ colorIndex: Int, for notebook: Notebook) {
        do {
            try service.updateCoverColor(colorIndex, for: notebook)
            if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[idx].coverColorIndex = colorIndex
                notebooks[idx].coverImagePath = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func updateCoverImage(_ data: Data, for notebook: Notebook) {
        do {
            try service.updateCoverImage(data, for: notebook)
            if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[idx].coverImagePath = "cover.jpg"
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
