import Foundation
import Observation

@Observable
final class NotebookListViewModel {
    var notebooks: [Notebook] = []
    var errorMessage: String?
    var isLoading = false

    // Folders (homepage)
    var folders: [Folder] = []
    /// folderId → notebook ids inside it (membership + count cache).
    var folderMemberships: [String: Set<String>] = [:]

    private let service = NotebookService.shared
    private let folderService = FolderService.shared

    // MARK: - Load

    func loadNotebooks() {
        isLoading = true
        // The database fell back to a temporary in-memory store (disk full,
        // corruption, …) — warn once so the user knows nothing will persist.
        if let dbError = DatabaseManager.shared.initializationError {
            errorMessage = """
            Your notebook library couldn't be opened, so changes made now \
            won't be saved after the app closes. Freeing up storage and \
            relaunching usually fixes this. (\(dbError.localizedDescription))
            """
        }
        do { notebooks = try service.allNotebooks() }
        catch { errorMessage = error.localizedDescription }
        loadFolders()
        isLoading = false
    }

    func loadFolders() {
        do {
            folders = try folderService.allFolders()
            folderMemberships = try folderService.allMemberships()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Create

    func createNotebook(
        title: String,
        coverColorIndex: Int = Int.random(in: 0..<Color_notebookCoversCount),
        coverImageData: Data? = nil,
        defaultPageStyle: PageStyle = .grid,
        pageBackgroundData: Data? = nil,
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
                pageBackgroundData: pageBackgroundData,
                description: description,
                author: author
            )
            notebooks.insert(notebook, at: 0)
            // Match the DB sort (pinned first, then recency) — a plain
            // insert(at: 0) put the new notebook ABOVE pinned ones until
            // the next reload.
            sortNotebooks()
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
            // The DB cascade already removed its folder links — mirror that
            // in the in-memory cache so folder count badges update instantly.
            for key in folderMemberships.keys {
                folderMemberships[key]?.remove(notebook.id)
            }
        } catch { errorMessage = error.localizedDescription }
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

    // MARK: - Pins

    /// Mirrors the DB sort: pinned first, then most recently updated.
    private func sortNotebooks() {
        notebooks.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func sortFolders() {
        folders.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func togglePin(_ notebook: Notebook) {
        do {
            try service.setPinned(!notebook.isPinned, for: notebook)
            if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[idx].isPinned.toggle()
            }
            sortNotebooks()
        } catch { errorMessage = error.localizedDescription }
    }

    func togglePin(_ folder: Folder) {
        do {
            try folderService.setPinned(!folder.isPinned, for: folder)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx].isPinned.toggle()
            }
            sortFolders()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Sync

    /// Reflects a completed cloud sync in the UI immediately.
    /// (SyncService already stamped the local DB.)
    func applySyncDate(_ date: Date, to notebook: Notebook) {
        if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
            notebooks[idx].lastSyncedAt = date
        }
    }

    /// Removes the notebook's cloud copy; the notebook stays local.
    @MainActor
    func unsync(_ notebook: Notebook) async {
        do {
            try await SyncService.shared.unsyncNotebook(notebook)
            if let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[idx].lastSyncedAt = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Delete flow (synced notebook): also remove the cloud copy.
    /// If the cloud step fails (e.g. offline), NOTHING is deleted — and the
    /// error says so, so users know their notebook is still here.
    @MainActor
    func deleteAndUnsync(_ notebook: Notebook) async {
        do {
            try await SyncService.shared.unsyncNotebook(notebook)
            deleteNotebook(notebook)
        } catch {
            errorMessage = "Couldn't remove the cloud copy, so the notebook "
                + "was NOT deleted — your local copy is untouched. Check your "
                + "connection and try again. (\(error.localizedDescription))"
        }
    }

    /// Delete flow (unsynced notebook): upload a cloud copy first, then
    /// delete locally. Nothing is deleted if the sync fails.
    @MainActor
    func syncThenDeleteLocally(_ notebook: Notebook) async {
        do {
            _ = try await SyncService.shared.syncNotebook(notebook)
            deleteNotebook(notebook)
        } catch {
            errorMessage = "Cloud backup failed, so the notebook was NOT "
                + "deleted — your local copy is untouched. Check your "
                + "connection and try again. (\(error.localizedDescription))"
        }
    }

    // MARK: - Folders

    func createFolder(name: String, colorIndex: Int, imageData: Data?, author: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let folder = try folderService.createFolder(
                name: trimmed, colorIndex: colorIndex, imageData: imageData, author: author
            )
            folders.insert(folder, at: 0)
            folderMemberships[folder.id] = []
            // Match the DB sort (pinned first, then recency) — a plain
            // insert(at: 0) put the new folder ABOVE pinned ones until the
            // next reload (same bug class as createNotebook, fixed above).
            sortFolders()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateFolder(_ folder: Folder, name: String, colorIndex: Int, imageData: Data?, author: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try folderService.updateFolder(
                folder, name: trimmed, colorIndex: colorIndex, imageData: imageData, author: author
            )
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx] = updated
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteFolder(_ folder: Folder) {
        do {
            try folderService.deleteFolder(folder)
            folders.removeAll { $0.id == folder.id }
            folderMemberships[folder.id] = nil
        } catch { errorMessage = error.localizedDescription }
    }

    /// Notebooks inside `folder` — live from the notebooks array so cards
    /// stay in sync (renames, covers, deletions).
    func notebooks(in folder: Folder) -> [Notebook] {
        let ids = folderMemberships[folder.id] ?? []
        return notebooks.filter { ids.contains($0.id) }
    }

    func notebookCount(in folder: Folder) -> Int {
        folderMemberships[folder.id]?.count ?? 0
    }

    func isNotebook(_ notebook: Notebook, in folder: Folder) -> Bool {
        folderMemberships[folder.id]?.contains(notebook.id) ?? false
    }

    /// Adds or removes the notebook from the folder (one membership max —
    /// enforced both here and by the join table's primary key).
    func toggleNotebook(_ notebook: Notebook, in folder: Folder) {
        do {
            if isNotebook(notebook, in: folder) {
                try folderService.removeNotebook(notebook.id, from: folder)
                folderMemberships[folder.id]?.remove(notebook.id)
            } else {
                try folderService.addNotebook(notebook.id, to: folder)
                folderMemberships[folder.id, default: []].insert(notebook.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func removeNotebook(_ notebook: Notebook, from folder: Folder) {
        do {
            try folderService.removeNotebook(notebook.id, from: folder)
            folderMemberships[folder.id]?.remove(notebook.id)
        } catch { errorMessage = error.localizedDescription }
    }
}
