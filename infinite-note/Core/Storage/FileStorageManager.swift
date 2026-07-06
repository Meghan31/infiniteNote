import Foundation
import PencilKit
import UIKit

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
    // point of use instead of being silently swallowed at init. Loads check
    // `fileExists` first, so a missing root is fine before the first save.
    private init() {}

    // MARK: - Drawing

    func saveDrawing(_ drawing: PKDrawing, notebookId: String, pageId: String) throws {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        try ensureNotebookDirectory(notebookId: notebookId)
        // `.atomic` is CRITICAL here: it writes to a temp file and renames.
        // A plain write truncates the destination first, so an app kill
        // mid-save (force-quit from recents — which the cold-launch render
        // bug trained the user to do a lot) left a TRUNCATED file. That file
        // then failed to parse on the next open, the page looked empty, and
        // the ink was unrecoverable. With `.atomic` the old bytes stay intact
        // until the new bytes are fully on disk.
        try drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    func loadDrawing(notebookId: String, pageId: String) throws -> PKDrawing {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return PKDrawing() }
        do {
            let data = try Data(contentsOf: url)
            let drawing = try PKDrawing(data: data)
            // Repair order-flipped stroke timestamps BEFORE the drawing
            // reaches any renderer — loading them raw is what wedged
            // PencilKit app-wide ("Suspect normalizing of a drawing where
            // stroke order is flipped. Reverting."): blank pages, hung
            // thumbnails, and dead pens in every open notebook.
            let result = DrawingSanitizer.sanitize(drawing)
            guard result.repaired else { return drawing }
            NSLog("DrawingSanitizer: repaired %d stroke timestamp(s) in page %@ — original preserved as .orig",
                  result.repairedStrokeCount, pageId)
            persistRepairedDrawing(result.drawing, originalData: data, to: url)
            return result.drawing
        } catch {
            // The file exists but can't be read/parsed. Preserve the bytes
            // under a side name so a bug or crash can never silently destroy
            // them (the save path refuses to overwrite unreadable files, but
            // an on-disk copy makes the ink recoverable no matter what).
            let backup = url.appendingPathExtension("corrupt")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            throw error
        }
    }

    /// Writes a repaired drawing back ONLY after the original bytes are safely
    /// backed up next to it (`<pageId>.drawing.orig`, written once and never
    /// overwritten). Best-effort: any failure leaves the original file exactly
    /// as it was — the in-memory repaired copy still renders this session and
    /// the repair simply re-runs on the next load.
    private func persistRepairedDrawing(_ drawing: PKDrawing, originalData: Data, to url: URL) {
        let backup = url.appendingPathExtension("orig")
        if !FileManager.default.fileExists(atPath: backup.path) {
            guard (try? originalData.write(to: backup, options: .atomic)) != nil else { return }
        }
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    /// Whether the saved drawing for this page must be protected from being
    /// overwritten by an EMPTY drawing. True when a file exists and either
    /// contains strokes or cannot be read/parsed right now (transient I/O or
    /// corruption — assume it's ink and protect it). Used as a last-line
    /// guard so no lifecycle save can blank a page that has real ink on disk.
    func savedDrawingHasProtectableInk(notebookId: String, pageId: String) -> Bool {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { return true }   // unreadable → protect
        guard !data.isEmpty else { return false }
        guard let drawing = try? PKDrawing(data: data) else { return true } // unparseable → protect
        return !drawing.strokes.isEmpty
    }

    // MARK: - Cover Image

    func saveCoverImage(_ data: Data, notebookId: String) throws {
        try ensureNotebookDirectory(notebookId: notebookId)
        let url = coverImageURL(notebookId: notebookId)
        try data.write(to: url)
    }

    func loadCoverImage(notebookId: String) -> UIImage? {
        let url = coverImageURL(notebookId: notebookId)
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
        try data.write(to: url)
    }

    func loadPageBackground(notebookId: String, pageId: String) -> UIImage? {
        let url = pageBackgroundURL(notebookId: notebookId, pageId: pageId)
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
        try data.write(to: url)
    }

    func loadPageObjectImage(notebookId: String, fileName: String) -> UIImage? {
        let url = pageObjectImageURL(notebookId: notebookId, fileName: fileName)
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
        try data.write(to: folderImageURL(folderId: folderId))
    }

    func loadFolderImage(folderId: String) -> UIImage? {
        let url = folderImageURL(folderId: folderId)
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

    private func ensureNotebookDirectory(notebookId: String) throws {
        let dir = notebookDirectory(notebookId: notebookId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
