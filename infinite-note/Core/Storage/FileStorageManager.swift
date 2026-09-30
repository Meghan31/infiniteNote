import Foundation
import PencilKit
import UIKit

enum FileStorageError: LocalizedError {
    case protectedDataUnavailable

    var errorDescription: String? {
        switch self {
        case .protectedDataUnavailable:
            return "Notebook files are locked by iPadOS. Unlock the device and try again."
        }
    }
}

final class FileStorageManager {
    static let shared = FileStorageManager()

    private let rootURL: URL = {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notebooks")
    }()

    // No eager directory creation here: every save path builds its full
    // directory chain on demand (`withIntermediateDirectories: true`) and
    // THROWS to its caller on failure — so storage problems surface at the
    // point of use instead of being silently swallowed at init. Drawing loads
    // first verify that protected files are available, so a locked iPad can
    // never be mistaken for a blank page and then saved back to disk.
    private init() {}

    // MARK: - Drawing

    func saveDrawing(_ drawing: PKDrawing, notebookId: String, pageId: String) throws {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        try ensureNotebookDirectory(notebookId: notebookId)
        try backupExistingDrawingIfNeeded(at: url, notebookId: notebookId, pageId: pageId)
        try drawing.dataRepresentation().write(to: url, options: .atomic)
        makeAccessible(url)
    }

    func loadDrawing(notebookId: String, pageId: String) throws -> PKDrawing {
        try ensureProtectedDataAvailable()
        makeAccessible(rootURL)
        makeAccessible(notebookDirectory(notebookId: notebookId))
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return PKDrawing() }
        makeAccessible(url)
        let data = try Data(contentsOf: url)
        return try PKDrawing(data: data)
    }

    // MARK: - Cover Image

    func saveCoverImage(_ data: Data, notebookId: String) throws {
        try ensureNotebookDirectory(notebookId: notebookId)
        let url = coverImageURL(notebookId: notebookId)
        try data.write(to: url, options: .atomic)
        makeAccessible(url)
    }

    func loadCoverImage(notebookId: String) -> UIImage? {
        makeAccessible(rootURL)
        makeAccessible(notebookDirectory(notebookId: notebookId))
        let url = coverImageURL(notebookId: notebookId)
        makeAccessible(url)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func deleteCoverImage(notebookId: String) {
        let url = coverImageURL(notebookId: notebookId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Page Background Image (for .photo style)

    func savePageBackground(_ data: Data, notebookId: String, pageId: String) throws {
        try ensureNotebookDirectory(notebookId: notebookId)
        let url = pageBackgroundURL(notebookId: notebookId, pageId: pageId)
        try data.write(to: url, options: .atomic)
        makeAccessible(url)
    }

    func loadPageBackground(notebookId: String, pageId: String) -> UIImage? {
        makeAccessible(rootURL)
        makeAccessible(notebookDirectory(notebookId: notebookId))
        let url = pageBackgroundURL(notebookId: notebookId, pageId: pageId)
        makeAccessible(url)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func deletePageBackground(notebookId: String, pageId: String) {
        let url = pageBackgroundURL(notebookId: notebookId, pageId: pageId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Page Object Images (placed photos)

    /// Persists a placed-photo's bytes under the notebook folder, keyed by the
    /// object's stored `image_file` name. Throws so a disk-full failure
    /// surfaces instead of silently losing the photo.
    func savePageObjectImage(_ data: Data, notebookId: String, fileName: String) throws {
        try ensureNotebookDirectory(notebookId: notebookId)
        let url = pageObjectImageURL(notebookId: notebookId, fileName: fileName)
        try data.write(to: url, options: .atomic)
        makeAccessible(url)
    }

    func loadPageObjectImage(notebookId: String, fileName: String) -> UIImage? {
        makeAccessible(rootURL)
        makeAccessible(notebookDirectory(notebookId: notebookId))
        let url = pageObjectImageURL(notebookId: notebookId, fileName: fileName)
        makeAccessible(url)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func pageObjectImageURL(notebookId: String, fileName: String) -> URL {
        notebookDirectory(notebookId: notebookId).appendingPathComponent(fileName)
    }

    func deletePageObjectImage(notebookId: String, fileName: String) {
        let url = pageObjectImageURL(notebookId: notebookId, fileName: fileName)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Folder Image

    private var foldersRootURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folders")
    }

    func saveFolderImage(_ data: Data, folderId: String) throws {
        let dir = folderDirectory(folderId: folderId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        makeAccessible(foldersRootURL)
        makeAccessible(dir)
        let url = folderImageURL(folderId: folderId)
        try data.write(to: url, options: .atomic)
        makeAccessible(url)
    }

    func loadFolderImage(folderId: String) -> UIImage? {
        makeAccessible(foldersRootURL)
        makeAccessible(folderDirectory(folderId: folderId))
        let url = folderImageURL(folderId: folderId)
        makeAccessible(url)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func deleteFolderFiles(folderId: String) {
        try? FileManager.default.removeItem(at: folderDirectory(folderId: folderId))
    }

    private func folderDirectory(folderId: String) -> URL {
        foldersRootURL.appendingPathComponent(folderId)
    }

    private func folderImageURL(folderId: String) -> URL {
        folderDirectory(folderId: folderId).appendingPathComponent("cover.jpg")
    }

    // MARK: - Deletion

    func deleteNotebookFiles(notebookId: String) throws {
        let dir = notebookDirectory(notebookId: notebookId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    func deleteDrawing(notebookId: String, pageId: String) throws {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private Helpers

    private func notebookDirectory(notebookId: String) -> URL {
        rootURL.appendingPathComponent(notebookId)
    }

    private func drawingURL(notebookId: String, pageId: String) -> URL {
        notebookDirectory(notebookId: notebookId).appendingPathComponent("\(pageId).drawing")
    }

    private func coverImageURL(notebookId: String) -> URL {
        notebookDirectory(notebookId: notebookId).appendingPathComponent("cover.jpg")
    }

    private func pageBackgroundURL(notebookId: String, pageId: String) -> URL {
        notebookDirectory(notebookId: notebookId).appendingPathComponent("\(pageId)_bg.jpg")
    }

    private func drawingBackupDirectory(notebookId: String, pageId: String) -> URL {
        notebookDirectory(notebookId: notebookId)
            .appendingPathComponent("drawing-backups", isDirectory: true)
            .appendingPathComponent(pageId, isDirectory: true)
    }

    private func ensureNotebookDirectory(notebookId: String) throws {
        let dir = notebookDirectory(notebookId: notebookId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        makeAccessible(rootURL)
        makeAccessible(dir)
    }

    private func backupExistingDrawingIfNeeded(
        at url: URL,
        notebookId: String,
        pageId: String
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard data.count > 1024,
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else { return }

        let backupDir = drawingBackupDirectory(notebookId: notebookId, pageId: pageId)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        makeAccessible(backupDir.deletingLastPathComponent())
        makeAccessible(backupDir)

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let backupURL = backupDir.appendingPathComponent("\(stamp).drawing")
        try data.write(to: backupURL, options: .atomic)
        makeAccessible(backupURL)
        pruneDrawingBackups(in: backupDir, keeping: 8)
    }

    private func pruneDrawingBackups(in directory: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > limit else { return }

        let sorted = files.sorted {
            let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for oldBackup in sorted.dropFirst(limit) {
            try? fm.removeItem(at: oldBackup)
        }
    }

    private func ensureProtectedDataAvailable() throws {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw FileStorageError.protectedDataUnavailable
        }
    }

    private func makeAccessible(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let attrs: [FileAttributeKey: Any] =
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.setAttributes(attrs, ofItemAtPath: url.path)
    }
}
