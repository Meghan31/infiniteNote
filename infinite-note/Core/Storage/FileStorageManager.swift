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

    private init() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: - Drawing

    func saveDrawing(_ drawing: PKDrawing, notebookId: String, pageId: String) throws {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        try ensureNotebookDirectory(notebookId: notebookId)
        try drawing.dataRepresentation().write(to: url)
    }

    func loadDrawing(notebookId: String, pageId: String) throws -> PKDrawing {
        let url = drawingURL(notebookId: notebookId, pageId: pageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return PKDrawing() }
        let data = try Data(contentsOf: url)
        return try PKDrawing(data: data)
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
