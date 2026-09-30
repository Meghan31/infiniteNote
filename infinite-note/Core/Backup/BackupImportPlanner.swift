import Foundation

// MARK: - Library Backup: import planning (pure logic, no I/O)
//
// Decides, per folder / notebook / pen in a backup, what an import does on
// THIS iPad under the duplicate rule the user picked. Matching is by id: a
// backup made on one iPad and imported on the same (or a restored) iPad
// carries the same ids, so "already here" is exact — renamed items still match.

enum DuplicateStrategy: Equatable {
    /// Leave anything already on this iPad untouched; add the rest.
    case skipExisting
    /// Keep whichever copy was edited more recently.
    case newerWins
    /// Add the backup's version as an extra copy (fresh id) next to this iPad's.
    case keepBoth
}

/// What's already on this iPad, reduced to what the planner needs.
struct LocalLibraryIndex {
    var notebookUpdatedAt: [String: Date] = [:]
    var folderUpdatedAt: [String: Date] = [:]
    var penUpdatedAt: [String: Date] = [:]
}

struct ImportPlan {
    enum Action: Equatable { case insert, replace, skip }

    struct FolderItem {
        let source: BackupFolder
        let finalId: String
        let action: Action
        /// Parent after import (nil = Home). Only meaningful when written.
        let finalParentId: String?
    }

    struct NotebookItem {
        let source: BackupNotebook
        let finalId: String
        let action: Action
    }

    struct PenItem {
        let source: BackupPen
        let action: Action
    }

    var folders: [FolderItem] = []
    var notebooks: [NotebookItem] = []
    var pens: [PenItem] = []
    /// Folder links to add (final ids; INSERT OR IGNORE).
    var memberships: [BackupMembership] = []
}

enum BackupImportPlanner {

    static func plan(
        _ manifest: BackupManifest,
        local: LocalLibraryIndex,
        strategy: DuplicateStrategy,
        makeId: @escaping () -> String = { UUID().uuidString }
    ) -> ImportPlan {
        func decide(existing: Date?, incoming: Date) -> ImportPlan.Action {
            guard let existing else { return .insert }
            switch strategy {
            case .skipExisting: return .skip
            case .newerWins:    return incoming > existing ? .replace : .skip
            case .keepBoth:     return .insert
            }
        }
        func finalId(for id: String, existsHere: Bool) -> String {
            strategy == .keepBoth && existsHere ? makeId() : id
        }

        var plan = ImportPlan()

        // Folders — ids first, so parents can be resolved in any order.
        var folderIds: [String: String] = [:]
        var folderActions: [String: ImportPlan.Action] = [:]
        for folder in manifest.folders {
            let existing = local.folderUpdatedAt[folder.id]
            folderIds[folder.id] = finalId(for: folder.id, existsHere: existing != nil)
            folderActions[folder.id] = decide(existing: existing, incoming: folder.updatedAt)
        }
        for folder in manifest.folders {
            guard let id = folderIds[folder.id], let action = folderActions[folder.id] else { continue }
            var parent: String? = nil
            if let backupParent = folder.parentId {
                if let mapped = folderIds[backupParent] {
                    parent = mapped                       // parent travels with the backup
                } else if strategy != .keepBoth, local.folderUpdatedAt[backupParent] != nil {
                    parent = backupParent                 // parent only exists on this iPad
                }                                         // else: unknown parent → Home
            }
            if parent == id { parent = nil }
            plan.folders.append(.init(source: folder, finalId: id, action: action, finalParentId: parent))
        }

        // Notebooks (pages / objects travel with their notebook).
        var notebookIds: [String: String] = [:]
        var notebookActions: [String: ImportPlan.Action] = [:]
        for notebook in manifest.notebooks {
            let existing = local.notebookUpdatedAt[notebook.id]
            let id = finalId(for: notebook.id, existsHere: existing != nil)
            let action = decide(existing: existing, incoming: notebook.updatedAt)
            notebookIds[notebook.id] = id
            notebookActions[notebook.id] = action
            plan.notebooks.append(.init(source: notebook, finalId: id, action: action))
        }

        // Folder links: add a link when at least one side was written by this
        // import. (Two skipped items are this iPad's business — untouched.)
        var seen = Set<BackupMembership>()
        for link in manifest.memberships {
            guard let folderId = folderIds[link.folderId],
                  let notebookId = notebookIds[link.notebookId],
                  let folderAction = folderActions[link.folderId],
                  let notebookAction = notebookActions[link.notebookId] else { continue }
            guard folderAction != .skip || notebookAction != .skip else { continue }
            let mapped = BackupMembership(folderId: folderId, notebookId: notebookId)
            if seen.insert(mapped).inserted { plan.memberships.append(mapped) }
        }

        // Pens are presets, never duplicated: "keep both" adds only missing ones.
        for pen in manifest.customPens {
            let existing = local.penUpdatedAt[pen.id]
            let action: ImportPlan.Action
            switch strategy {
            case .newerWins: action = decide(existing: existing, incoming: pen.updatedAt)
            case .skipExisting, .keepBoth: action = existing == nil ? .insert : .skip
            }
            plan.pens.append(.init(source: pen, action: action))
        }
        return plan
    }

    // MARK: Folder loops

    /// Nested folders must stay a tree. A "newer wins" import can move folder A
    /// under B while this iPad has B under A — a loop that would hang every
    /// "descendants" walk. Returns the folders to lift to Home (parent = nil),
    /// preferring folders this import wrote, until no loop remains.
    static func foldersToLift(parents: [String: String], preferring preferred: Set<String>) -> [String] {
        var parents = parents
        var lifted: [String] = []
        while let loop = firstLoop(in: parents) {
            let pick = loop.first(where: { preferred.contains($0) }) ?? loop[0]
            parents[pick] = nil
            lifted.append(pick)
        }
        return lifted
    }

    private static func firstLoop(in parents: [String: String]) -> [String]? {
        var finished = Set<String>()
        for start in parents.keys.sorted() where !finished.contains(start) {
            var path: [String] = []
            var onPath = Set<String>()
            var node: String? = start
            while let current = node, !finished.contains(current) {
                if onPath.contains(current) {
                    guard let index = path.firstIndex(of: current) else { break }
                    return Array(path[index...])
                }
                onPath.insert(current)
                path.append(current)
                node = parents[current]
            }
            finished.formUnion(path)
        }
        return nil
    }
}
