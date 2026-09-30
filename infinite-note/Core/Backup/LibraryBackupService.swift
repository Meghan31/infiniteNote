import Foundation
import GRDB

// MARK: - Library Backup: export + import
//
// EXPORT reads one consistent database snapshot, gathers the files behind it,
// and writes a single `.infinitenote` file (BackupContainer).
//
// IMPORT is two steps so the user can decide what happens to duplicates:
//   1. `openBackup` unpacks + validates the file into a private staging folder
//      and counts what's already on this iPad (nothing in the library changes).
//   2. `importBackup` applies the chosen DuplicateStrategy:
//        • files are moved into place first, REVERSIBLY (anything replaced is
//          set aside, not deleted);
//        • then every row is written in ONE database transaction;
//        • if the transaction fails, the files are rolled back — the library is
//          left exactly as it was.
// Page and page-object ids are always freshly generated (they're internal),
// so an import can never collide with pages already on this iPad. Notebook and
// folder ids are kept (except "keep both" copies) so re-importing the same
// backup recognises what's already here. Imported notebooks start unsynced.

/// A backup that has been read, validated and unpacked, waiting for the user
/// to choose what happens to duplicates.
struct PendingImport: Identifiable {
    let id = UUID()
    let manifest: BackupManifest
    /// Private unpacked copy of the file (removed after import or cancel).
    let stagingRoot: URL
    let duplicateNotebooks: Int
    let duplicateFolders: Int

    var duplicateCount: Int { duplicateNotebooks + duplicateFolders }
}

struct BackupExport {
    let url: URL
    let notebookCount: Int
    let folderCount: Int
    let pageCount: Int
    let byteCount: Int64
}

struct ImportSummary {
    var notebooksAdded = 0
    var notebooksCopied = 0
    var notebooksReplaced = 0
    var notebooksSkipped = 0
    var foldersAdded = 0
    var foldersCopied = 0
    var foldersReplaced = 0
    var foldersSkipped = 0
    var pensAdded = 0
    var pensReplaced = 0

    var message: String {
        var lines: [String] = []
        let notebooks = notebooksAdded + notebooksCopied
        let folders = foldersAdded + foldersCopied
        if notebooks + folders > 0 {
            lines.append("Added \(Self.count(notebooks, "notebook")) and \(Self.count(folders, "folder")).")
        }
        if notebooksCopied + foldersCopied > 0 {
            lines.append("\(Self.count(notebooksCopied + foldersCopied, "copy", plural: "copies")) "
                + "added next to the originals already here.")
        }
        if notebooksReplaced + foldersReplaced > 0 {
            lines.append("Updated \(Self.count(notebooksReplaced, "notebook")) and "
                + "\(Self.count(foldersReplaced, "folder")) to the newer backup version.")
        }
        if notebooksSkipped + foldersSkipped > 0 {
            lines.append("Left \(Self.count(notebooksSkipped + foldersSkipped, "item")) "
                + "that were already here untouched.")
        }
        if pensAdded + pensReplaced > 0 {
            lines.append("Imported \(Self.count(pensAdded + pensReplaced, "custom pen")).")
        }
        return lines.isEmpty
            ? "Everything in this backup is already on this iPad."
            : lines.joined(separator: "\n")
    }

    private static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }
}

enum LibraryBackupService {

    private static var storage: FileStorageManager { FileStorageManager.shared }
    private static var dbQueue: DatabaseQueue { DatabaseManager.shared.dbQueue }
    private static var fm: FileManager { FileManager.default }

    private static var exportsRoot: URL {
        fm.temporaryDirectory.appendingPathComponent("LibraryBackups", isDirectory: true)
    }
    private static var importsRoot: URL {
        fm.temporaryDirectory.appendingPathComponent("LibraryImports", isDirectory: true)
    }
    /// Safety net: notebooks / folders that a "newer wins" import replaced are
    /// kept here (last two imports) instead of being deleted outright.
    private static var replacedRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".replaced-by-import", isDirectory: true)
    }

    // MARK: - Export

    private struct Snapshot {
        var notebooks: [Notebook] = []
        var pages: [Page] = []
        var objects: [PageObject] = []
        var folders: [Folder] = []
        var memberships: [BackupMembership] = []
        var pens: [CustomPen] = []
    }

    /// Writes the whole library to a new `.infinitenote` file in a temporary
    /// folder and returns it. Run off the main thread.
    static func exportLibrary(deviceName: String, appVersion: String) throws -> BackupExport {
        guard DatabaseManager.shared.initializationError == nil else { throw BackupError.libraryUnavailable }

        // One read = one consistent snapshot of every table.
        let snapshot: Snapshot = try dbQueue.read { db in
            var result = Snapshot()
            result.notebooks = try Notebook.fetchAll(db)
            result.pages = try Page.fetchAll(db)
            result.objects = try PageObject.fetchAll(db)
            result.folders = try Folder.fetchAll(db)
            result.pens = try CustomPen.fetchAll(db)
            for row in try Row.fetchAll(db, sql: "SELECT folder_id, notebook_id FROM folder_notebooks") {
                let folderId: String = row["folder_id"]
                let notebookId: String = row["notebook_id"]
                result.memberships.append(BackupMembership(folderId: folderId, notebookId: notebookId))
            }
            return result
        }

        var files: [(path: String, source: URL)] = []
        var includedPaths = Set<String>()
        /// Adds a file to the backup if it exists; returns its container path.
        func include(_ source: URL, as path: String) -> String? {
            if includedPaths.contains(path) { return path }
            guard fm.fileExists(atPath: source.path) else { return nil }
            includedPaths.insert(path)
            files.append((path: path, source: source))
            return path
        }

        var folders: [BackupFolder] = []
        for folder in snapshot.folders {
            var cover: String? = nil
            if folder.imagePath != nil {
                cover = include(storage.folderImageFileURL(folderId: folder.id), as: "folders/\(folder.id)/cover.jpg")
            }
            folders.append(BackupFolder(
                id: folder.id, parentId: folder.parentId, name: folder.name,
                colorIndex: folder.colorIndex, author: folder.author, isPinned: folder.isPinned,
                createdAt: folder.createdAt, updatedAt: folder.updatedAt, coverFile: cover))
        }

        let pagesByNotebook = Dictionary(grouping: snapshot.pages, by: { $0.notebookId })
        let objectsByPage = Dictionary(grouping: snapshot.objects, by: { $0.pageId })
        var notebooks: [BackupNotebook] = []
        for notebook in snapshot.notebooks {
            let base = "notebooks/\(notebook.id)"
            var pages: [BackupPage] = []
            let notebookPages = (pagesByNotebook[notebook.id] ?? []).sorted { $0.pageNumber < $1.pageNumber }
            for page in notebookPages {
                var objects: [BackupPageObject] = []
                let pageObjects = (objectsByPage[page.id] ?? []).sorted { $0.zIndex < $1.zIndex }
                for object in pageObjects {
                    var imageFile: String? = nil
                    if let name = object.imageFile, BackupManifest.isSafeFileName(name) {
                        imageFile = include(
                            storage.pageObjectImageURL(notebookId: notebook.id, fileName: name),
                            as: "\(base)/objects/\(name)")
                    }
                    objects.append(BackupPageObject(
                        id: object.id, kind: object.kind.rawValue,
                        x: object.x, y: object.y, width: object.width, height: object.height,
                        rotation: object.rotation, zIndex: object.zIndex, textRTF: object.textRTF,
                        imageFileName: imageFile == nil ? nil : object.imageFile, imageFile: imageFile,
                        createdAt: object.createdAt, updatedAt: object.updatedAt))
                }
                let drawing = include(storage.drawingFileURL(notebookId: notebook.id, pageId: page.id),
                                      as: "\(base)/\(page.id).drawing")
                let background = include(storage.pageBackgroundFileURL(notebookId: notebook.id, pageId: page.id),
                                         as: "\(base)/\(page.id)_bg.jpg")
                pages.append(BackupPage(
                    id: page.id, pageNumber: page.pageNumber, pageStyle: page.pageStyle.rawValue,
                    drawingFile: drawing, backgroundFile: background, objects: objects))
            }
            var cover: String? = nil
            if notebook.coverImagePath != nil {
                cover = include(storage.coverImageFileURL(notebookId: notebook.id), as: "\(base)/cover.jpg")
            }
            notebooks.append(BackupNotebook(
                id: notebook.id, title: notebook.title,
                createdAt: notebook.createdAt, updatedAt: notebook.updatedAt,
                coverColorIndex: notebook.coverColorIndex,
                defaultPageStyle: notebook.defaultPageStyle.rawValue,
                noteDescription: notebook.noteDescription, author: notebook.author,
                isPinned: notebook.isPinned, coverFile: cover, pages: pages))
        }

        let manifest = BackupManifest(
            format: BackupManifest.formatName,
            version: BackupManifest.currentVersion,
            createdAt: Date(),
            deviceName: deviceName,
            appVersion: appVersion,
            folders: folders,
            notebooks: notebooks,
            memberships: snapshot.memberships,
            customPens: snapshot.pens.map(backupPen(from:)))
        // Never hand out a file that the importer would refuse.
        _ = try manifest.validatedFilePaths()
        let json = try BackupManifest.encoder().encode(manifest)

        try? fm.removeItem(at: exportsRoot)   // previous exports
        try fm.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        let url = exportsRoot.appendingPathComponent(
            "\(exportFileName(for: manifest.createdAt)).\(BackupContainer.fileExtension)")
        do {
            try BackupContainer.write(manifestJSON: json, files: files, to: url)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }

        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return BackupExport(
            url: url,
            notebookCount: notebooks.count,
            folderCount: folders.count,
            pageCount: manifest.pageCount,
            byteCount: size)
    }

    // MARK: - Import step 1: open

    /// Reads, validates and unpacks a picked backup file. Changes nothing in
    /// the library. Run off the main thread.
    static func openBackup(at url: URL) throws -> PendingImport {
        guard DatabaseManager.shared.initializationError == nil else { throw BackupError.libraryUnavailable }

        try? fm.removeItem(at: importsRoot)   // leftovers from an abandoned import
        let staging = importsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesRoot = staging.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        do {
            var decoded: BackupManifest?
            try BackupContainer.extract(from: url, into: filesRoot) { json in
                let manifest = try BackupManifest.decode(json)
                decoded = manifest
                return try manifest.validatedFilePaths()
            }
            guard let manifest = decoded else { throw BackupError.notABackup }

            let local = try localIndex()
            return PendingImport(
                manifest: manifest,
                stagingRoot: staging,
                duplicateNotebooks: manifest.notebooks.filter { local.notebookUpdatedAt[$0.id] != nil }.count,
                duplicateFolders: manifest.folders.filter { local.folderUpdatedAt[$0.id] != nil }.count)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Deletes a pending import's unpacked files (cancel / after import).
    static func discard(_ pending: PendingImport) {
        try? fm.removeItem(at: pending.stagingRoot)
    }

    // MARK: - Import step 2: apply

    private struct NotebookWrite {
        let action: ImportPlan.Action
        let notebook: Notebook
        let pages: [Page]
        let objects: [PageObject]
        let readyDirectory: URL
    }

    private struct FolderWrite {
        let action: ImportPlan.Action
        /// Row to write, with `parentId == nil` — parents are set in a second
        /// pass so insert order never matters.
        let folder: Folder
        let parentId: String?
        let readyDirectory: URL?
    }

    /// Applies a pending import with the chosen duplicate rule. All-or-nothing.
    /// Run off the main thread.
    static func importBackup(_ pending: PendingImport, strategy: DuplicateStrategy) throws -> ImportSummary {
        guard DatabaseManager.shared.initializationError == nil else { throw BackupError.libraryUnavailable }

        // Re-read what's here now (the library may have changed since opening).
        let plan = BackupImportPlanner.plan(pending.manifest, local: try localIndex(), strategy: strategy)
        let filesRoot = pending.stagingRoot.appendingPathComponent("files", isDirectory: true)
        let readyRoot = pending.stagingRoot.appendingPathComponent("ready", isDirectory: true)

        // 1. Final rows + ready-to-install folders (still inside staging).
        var notebookWrites: [NotebookWrite] = []
        for item in plan.notebooks where item.action != .skip {
            notebookWrites.append(try prepareNotebook(item, filesRoot: filesRoot, readyRoot: readyRoot))
        }
        var folderWrites: [FolderWrite] = []
        for item in plan.folders where item.action != .skip {
            folderWrites.append(try prepareFolder(item, filesRoot: filesRoot, readyRoot: readyRoot))
        }

        // 2. Files into place (reversible), then 3. one DB transaction.
        let batch = replacedRoot.appendingPathComponent(batchName(), isDirectory: true)
        var journal = FileInstallJournal()
        do {
            try fm.createDirectory(at: storage.notebooksRootDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: storage.foldersRootDirectory, withIntermediateDirectories: true)
            for write in notebookWrites {
                try journal.install(
                    write.readyDirectory,
                    at: storage.notebookDirectoryURL(notebookId: write.notebook.id),
                    setAsideIn: batch.appendingPathComponent("notebooks", isDirectory: true))
            }
            for write in folderWrites {
                guard let ready = write.readyDirectory else { continue }
                try journal.install(
                    ready,
                    at: storage.folderDirectoryURL(folderId: write.folder.id),
                    setAsideIn: batch.appendingPathComponent("folders", isDirectory: true))
            }

            try dbQueue.write { db in
                try writeRows(db, notebooks: notebookWrites, folders: folderWrites, plan: plan)
            }
        } catch {
            journal.rollback()
            throw error
        }

        // 4. Finish up.
        for url in journal.installed {
            storage.applyFileProtection(recursivelyAt: url)
        }
        pruneReplacedBatches(keeping: 2)
        discard(pending)
        return summary(for: plan)
    }

    private static func writeRows(
        _ db: Database,
        notebooks: [NotebookWrite],
        folders: [FolderWrite],
        plan: ImportPlan
    ) throws {
        // Folders: rows first, then parents.
        for write in folders {
            var folder = write.folder
            if write.action == .replace { try folder.update(db) } else { try folder.insert(db) }
        }
        for write in folders {
            try db.execute(
                sql: "UPDATE folders SET parent_id = ? WHERE id = ?",
                arguments: [write.parentId, write.folder.id])
        }
        // Nested folders must stay a tree (see BackupImportPlanner.foldersToLift).
        var parents: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, parent_id FROM folders WHERE parent_id IS NOT NULL") {
            let id: String = row["id"]
            let parent: String = row["parent_id"]
            parents[id] = parent
        }
        let writtenFolders = Set(folders.map { $0.folder.id })
        for id in BackupImportPlanner.foldersToLift(parents: parents, preferring: writtenFolders) {
            try db.execute(sql: "UPDATE folders SET parent_id = NULL WHERE id = ?", arguments: [id])
        }

        // Notebooks + their pages and placed objects.
        for write in notebooks {
            var notebook = write.notebook
            if write.action == .replace {
                // Pages (and, by cascade, their placed objects) are replaced
                // wholesale. This iPad's folder links for the notebook stay.
                try db.execute(sql: "DELETE FROM pages WHERE notebook_id = ?", arguments: [notebook.id])
                try notebook.update(db)
            } else {
                try notebook.insert(db)
            }
            for var page in write.pages { try page.insert(db) }
            for var object in write.objects { try object.insert(db) }
        }

        for link in plan.memberships {
            try db.execute(
                sql: "INSERT OR IGNORE INTO folder_notebooks (folder_id, notebook_id) VALUES (?, ?)",
                arguments: [link.folderId, link.notebookId])
        }

        for item in plan.pens where item.action != .skip {
            var pen = customPen(from: item.source)
            if item.action == .replace { try pen.update(db) } else { try pen.insert(db) }
        }
    }

    private static func prepareNotebook(
        _ item: ImportPlan.NotebookItem,
        filesRoot: URL,
        readyRoot: URL
    ) throws -> NotebookWrite {
        let source = item.source
        let id = item.finalId
        let directory = readyRoot
            .appendingPathComponent("notebooks", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        /// Moves an unpacked file into the notebook folder under `name`.
        func place(_ containerPath: String?, named name: String) throws -> Bool {
            guard let containerPath else { return false }
            let target = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { return true }   // shared photo
            try fm.moveItem(at: filesRoot.appendingPathComponent(containerPath), to: target)
            return true
        }

        let coverName = storage.coverImageFileURL(notebookId: id).lastPathComponent
        let hasCover = try place(source.coverFile, named: coverName)

        var pages: [Page] = []
        var objects: [PageObject] = []
        for backupPage in source.pages {
            let pageId = UUID().uuidString
            _ = try place(backupPage.drawingFile,
                          named: storage.drawingFileURL(notebookId: id, pageId: pageId).lastPathComponent)
            _ = try place(backupPage.backgroundFile,
                          named: storage.pageBackgroundFileURL(notebookId: id, pageId: pageId).lastPathComponent)
            pages.append(Page(
                id: pageId,
                notebookId: id,
                pageNumber: backupPage.pageNumber,
                pageStyle: PageStyle(rawValue: backupPage.pageStyle) ?? .grid))

            for backupObject in backupPage.objects {
                var imageName: String? = nil
                if let name = backupObject.imageFileName, try place(backupObject.imageFile, named: name) {
                    imageName = name
                }
                objects.append(PageObject(
                    id: UUID().uuidString,
                    pageId: pageId,
                    kind: PageObjectKind(rawValue: backupObject.kind) ?? .text,
                    x: backupObject.x,
                    y: backupObject.y,
                    width: backupObject.width,
                    height: backupObject.height,
                    rotation: backupObject.rotation,
                    zIndex: backupObject.zIndex,
                    textRTF: backupObject.textRTF,
                    imageFile: imageName,
                    createdAt: backupObject.createdAt,
                    updatedAt: backupObject.updatedAt))
            }
        }

        var notebook = Notebook(
            id: id,
            title: source.title,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt,
            coverColorIndex: source.coverColorIndex,
            coverImagePath: hasCover ? coverName : nil,
            defaultPageStyle: PageStyle(rawValue: source.defaultPageStyle) ?? .grid,
            noteDescription: source.noteDescription,
            author: source.author)
        notebook.isPinned = source.isPinned
        notebook.lastSyncedAt = nil   // a restored / shared copy is not synced from this iPad

        return NotebookWrite(action: item.action, notebook: notebook, pages: pages,
                             objects: objects, readyDirectory: directory)
    }

    private static func prepareFolder(
        _ item: ImportPlan.FolderItem,
        filesRoot: URL,
        readyRoot: URL
    ) throws -> FolderWrite {
        let source = item.source
        let directory = readyRoot
            .appendingPathComponent("folders", isDirectory: true)
            .appendingPathComponent(item.finalId, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let coverName = storage.folderImageFileURL(folderId: item.finalId).lastPathComponent
        var hasCover = false
        if let path = source.coverFile {
            try fm.moveItem(at: filesRoot.appendingPathComponent(path),
                            to: directory.appendingPathComponent(coverName))
            hasCover = true
        }
        let folder = Folder(
            id: item.finalId,
            parentId: nil,
            name: source.name,
            colorIndex: source.colorIndex,
            imagePath: hasCover ? coverName : nil,
            author: source.author,
            isPinned: source.isPinned,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt)
        // A replaced folder always swaps its directory (an old cover can't
        // linger); a new folder only needs one when it has a cover.
        let ready: URL? = (item.action == .replace || hasCover) ? directory : nil
        return FolderWrite(action: item.action, folder: folder, parentId: item.finalParentId,
                           readyDirectory: ready)
    }

    // MARK: - Helpers

    private static func localIndex() throws -> LocalLibraryIndex {
        try dbQueue.read { db in
            var index = LocalLibraryIndex()
            for notebook in try Notebook.fetchAll(db) { index.notebookUpdatedAt[notebook.id] = notebook.updatedAt }
            for folder in try Folder.fetchAll(db) { index.folderUpdatedAt[folder.id] = folder.updatedAt }
            for pen in try CustomPen.fetchAll(db) { index.penUpdatedAt[pen.id] = pen.updatedAt }
            return index
        }
    }

    private static func summary(for plan: ImportPlan) -> ImportSummary {
        var summary = ImportSummary()
        for item in plan.notebooks {
            switch item.action {
            case .insert:
                if item.finalId == item.source.id { summary.notebooksAdded += 1 } else { summary.notebooksCopied += 1 }
            case .replace: summary.notebooksReplaced += 1
            case .skip:    summary.notebooksSkipped += 1
            }
        }
        for item in plan.folders {
            switch item.action {
            case .insert:
                if item.finalId == item.source.id { summary.foldersAdded += 1 } else { summary.foldersCopied += 1 }
            case .replace: summary.foldersReplaced += 1
            case .skip:    summary.foldersSkipped += 1
            }
        }
        for item in plan.pens {
            switch item.action {
            case .insert:  summary.pensAdded += 1
            case .replace: summary.pensReplaced += 1
            case .skip:    break
            }
        }
        return summary
    }

    private static func pruneReplacedBatches(keeping limit: Int) {
        guard let batches = try? fm.contentsOfDirectory(
            at: replacedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let newestFirst = batches.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in newestFirst.dropFirst(limit) {
            try? fm.removeItem(at: old)
        }
    }

    private static func exportFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "InfiniteNote Backup \(formatter.string(from: date))"
    }

    /// Sortable, unique name for a set-aside batch.
    private static func batchName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

    private static func backupPen(from pen: CustomPen) -> BackupPen {
        BackupPen(
            id: pen.id, name: pen.name, colorHex: pen.colorHex, opacity: pen.opacity,
            width: pen.width, stabilization: pen.stabilization, bezierSmoothing: pen.bezierSmoothing,
            pressureSensitivity: pen.pressureSensitivity, startTaper: pen.startTaper,
            endTaper: pen.endTaper, inkFlow: pen.inkFlow, softness: pen.softness,
            velocitySensitivity: pen.velocitySensitivity, minWidth: pen.minWidth,
            maxWidth: pen.maxWidth, createdAt: pen.createdAt, updatedAt: pen.updatedAt)
    }

    private static func customPen(from pen: BackupPen) -> CustomPen {
        CustomPen(
            id: pen.id, name: pen.name, colorHex: pen.colorHex, opacity: pen.opacity,
            width: pen.width, stabilization: pen.stabilization, bezierSmoothing: pen.bezierSmoothing,
            pressureSensitivity: pen.pressureSensitivity, startTaper: pen.startTaper,
            endTaper: pen.endTaper, inkFlow: pen.inkFlow, softness: pen.softness,
            velocitySensitivity: pen.velocitySensitivity, minWidth: pen.minWidth,
            maxWidth: pen.maxWidth, createdAt: pen.createdAt, updatedAt: pen.updatedAt)
    }
}

// MARK: - Reversible file installation

/// Moves ready folders into the library, setting aside anything already at
/// the destination. `rollback()` restores the previous state exactly.
private struct FileInstallJournal {
    private(set) var installed: [URL] = []
    private var setAside: [(original: URL, aside: URL)] = []

    mutating func install(_ ready: URL, at target: URL, setAsideIn asideDirectory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: asideDirectory, withIntermediateDirectories: true)
            let aside = asideDirectory.appendingPathComponent(target.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
            try fm.moveItem(at: target, to: aside)
            setAside.append((original: target, aside: aside))
        }
        try fm.moveItem(at: ready, to: target)
        installed.append(target)
    }

    func rollback() {
        let fm = FileManager.default
        for url in installed.reversed() {
            try? fm.removeItem(at: url)
        }
        for entry in setAside.reversed() {
            try? fm.moveItem(at: entry.aside, to: entry.original)
        }
    }
}
