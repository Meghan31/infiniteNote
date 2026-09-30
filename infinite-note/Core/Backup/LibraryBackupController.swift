import SwiftUI
import UIKit

// MARK: - Library Backup: flow controller
//
// One shared controller drives the whole save / import flow so the shelf
// button works identically on the home screen and inside a notebook. The
// presentation (file picker, "backup ready" sheet, duplicate choice, progress,
// results) is attached once at the app root with `.libraryBackupUI(...)`.

@MainActor
final class LibraryBackupController: ObservableObject {
    static let shared = LibraryBackupController()

    /// Posted right before the library is read or changed, so an open editor
    /// writes its latest strokes to disk first.
    static let willAccessLibraryNotification = Notification.Name("LibraryBackup.willAccessLibrary")
    /// Posted right before an import writes. Open notebooks are closed so an
    /// editor can never save an old page over an imported one.
    static let willImportNotification = Notification.Name("LibraryBackup.willImport")
    /// Posted after an import finished (or failed) — the library reloads.
    static let didImportNotification = Notification.Name("LibraryBackup.didImport")

    enum Phase: Equatable {
        case idle, exporting, opening, importing

        var message: String {
            switch self {
            case .idle:      return ""
            case .exporting: return "Creating backup\u{2026}"
            case .opening:   return "Reading backup\u{2026}"
            case .importing: return "Importing your notes\u{2026}"
            }
        }
    }

    struct ReadyBackup: Identifiable {
        let id = UUID()
        let export: BackupExport
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var phase: Phase = .idle
    @Published var isPickingFile = false
    @Published var readyBackup: ReadyBackup?
    @Published var pendingImport: PendingImport?
    @Published var notice: Notice?

    var isBusy: Bool { phase != .idle }

    private init() {}

    // MARK: Save

    func saveBackup() {
        guard !isBusy else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            notice = Notice(title: "Couldn't Create Backup",
                            message: BackupError.filesLocked.localizedDescription)
            return
        }
        // Flush the open page first so the backup has the very latest strokes.
        NotificationCenter.default.post(name: Self.willAccessLibraryNotification, object: nil)
        phase = .exporting

        let deviceName = UIDevice.current.name
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        Task {
            // Give the open editor a beat to finish writing its page.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.exportLibrary(deviceName: deviceName, appVersion: appVersion)
                }.value
                phase = .idle
                readyBackup = ReadyBackup(export: export)
            } catch {
                phase = .idle
                notice = Notice(title: "Couldn't Create Backup", message: error.localizedDescription)
            }
        }
    }

    // MARK: Import

    func chooseBackupFile() {
        guard !isBusy else { return }
        isPickingFile = true
    }

    /// Picked a file (a local copy made by the picker): read + validate it,
    /// then ask what to do with duplicates.
    func didPickFile(_ url: URL) {
        guard !isBusy else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            notice = Notice(title: "Couldn't Import Backup",
                            message: BackupError.filesLocked.localizedDescription)
            return
        }
        phase = .opening
        Task {
            do {
                let pending = try await Task.detached(priority: .userInitiated) { () throws -> PendingImport in
                    defer { try? FileManager.default.removeItem(at: url) }   // the picker's copy
                    return try LibraryBackupService.openBackup(at: url)
                }.value
                phase = .idle
                pendingImport = pending
            } catch {
                phase = .idle
                notice = Notice(title: "Couldn't Import Backup", message: error.localizedDescription)
            }
        }
    }

    func runImport(_ pending: PendingImport, strategy: DuplicateStrategy) {
        pendingImport = nil
        guard !isBusy else { return }
        // Save, then close open notebooks BEFORE writing — an editor left open
        // could otherwise save its (older) page over the imported one.
        NotificationCenter.default.post(name: Self.willAccessLibraryNotification, object: nil)
        NotificationCenter.default.post(name: Self.willImportNotification, object: nil)
        phase = .importing

        Task {
            // Let the closed editor finish tearing down (its autosave windows
            // are under a second) before the library changes underneath it.
            try? await Task.sleep(for: .seconds(1))
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.importBackup(pending, strategy: strategy)
                }.value
                phase = .idle
                NotificationCenter.default.post(name: Self.didImportNotification, object: nil)
                notice = Notice(title: "Import Complete", message: summary.message)
            } catch {
                Task.detached { LibraryBackupService.discard(pending) }
                phase = .idle
                NotificationCenter.default.post(name: Self.didImportNotification, object: nil)
                notice = Notice(title: "Import Failed",
                                message: "Nothing in your library was changed. \(error.localizedDescription)")
            }
        }
    }

    func cancelImport(_ pending: PendingImport) {
        pendingImport = nil
        Task.detached { LibraryBackupService.discard(pending) }
    }
}
