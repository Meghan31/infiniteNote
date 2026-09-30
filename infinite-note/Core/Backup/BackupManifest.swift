import Foundation

// MARK: - Library Backup: manifest
//
// A `.infinitenote` backup is ONE self-contained file holding the whole
// library: every folder (with nesting), notebook, page, placed text box /
// photo, custom pen, and the files behind them (ink, covers, photo page
// backgrounds, placed photos). This file describes the "table of contents"
// part — plain Codable data, deliberately decoupled from the GRDB models so
// the database schema can evolve without breaking old backups.
//
// Files are referenced by CONTAINER PATHS (e.g. "notebooks/<id>/<pageId>.drawing")
// that point at blobs stored after the manifest (see BackupContainer.swift).

struct BackupManifest: Codable {
    static let formatName = "InfiniteNote Library Backup"
    static let currentVersion = 1

    var format: String
    var version: Int
    var createdAt: Date
    var deviceName: String
    var appVersion: String
    var folders: [BackupFolder]
    var notebooks: [BackupNotebook]
    var memberships: [BackupMembership]
    var customPens: [BackupPen]

    var pageCount: Int { notebooks.reduce(0) { $0 + $1.pages.count } }
}

struct BackupFolder: Codable {
    var id: String
    var parentId: String?
    var name: String
    var colorIndex: Int
    var author: String?
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Container path of the folder's cover photo, if it has one.
    var coverFile: String?
}

struct BackupNotebook: Codable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var coverColorIndex: Int
    var defaultPageStyle: String
    var noteDescription: String?
    var author: String?
    var isPinned: Bool
    /// Container path of the cover photo, if it has one.
    var coverFile: String?
    var pages: [BackupPage]
}

struct BackupPage: Codable {
    var id: String
    var pageNumber: Int
    var pageStyle: String
    /// Container path of the page's PencilKit ink (raw `.drawing` bytes).
    var drawingFile: String?
    /// Container path of a photo page background.
    var backgroundFile: String?
    var objects: [BackupPageObject]
}

struct BackupPageObject: Codable {
    var id: String
    var kind: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double
    var zIndex: Int
    var textRTF: Data?
    /// The photo's on-disk file name inside the notebook folder (kept on import).
    var imageFileName: String?
    /// Container path of the photo bytes.
    var imageFile: String?
    var createdAt: Date
    var updatedAt: Date
}

struct BackupMembership: Codable, Hashable {
    var folderId: String
    var notebookId: String
}

struct BackupPen: Codable {
    var id: String
    var name: String
    var colorHex: String
    var opacity: Double
    var width: Double
    var stabilization: Double
    var bezierSmoothing: Double
    var pressureSensitivity: Double
    var startTaper: Double
    var endTaper: Double
    var inkFlow: Double
    var softness: Double
    var velocitySensitivity: Double
    var minWidth: Double
    var maxWidth: Double
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case notABackup
    case newerVersion
    case damaged(String)
    case incomplete
    case libraryUnavailable
    case filesLocked
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notABackup:
            return "This file isn't an InfiniteNote backup."
        case .newerVersion:
            return "This backup was made by a newer version of InfiniteNote. Update the app, then import it again."
        case .damaged(let detail):
            return "This backup file is damaged and can't be imported (\(detail))."
        case .incomplete:
            return "This backup file is incomplete — it may not have finished copying. Copy it again and retry."
        case .libraryUnavailable:
            return "Your notebook library is temporarily unavailable. Relaunch InfiniteNote and try again."
        case .filesLocked:
            return "Notebook files are locked by iPadOS. Unlock the iPad and try again."
        case .writeFailed:
            return "Couldn't write the backup file — check free storage and try again."
        }
    }
}

// MARK: - Coding + validation

extension BackupManifest {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy =
            .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.nonConformingFloatDecodingStrategy =
            .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    static func decode(_ json: Data) throws -> BackupManifest {
        let manifest: BackupManifest
        do { manifest = try decoder().decode(BackupManifest.self, from: json) }
        catch { throw BackupError.notABackup }
        guard manifest.format == formatName else { throw BackupError.notABackup }
        guard manifest.version <= currentVersion else { throw BackupError.newerVersion }
        return manifest
    }

    /// IDs become folder names on disk, so a backup may only use plain
    /// ASCII letters, digits, "-" and "_" (UUIDs) — never "/" or "..".
    static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...80).contains(bytes.count) else { return false }
        return bytes.allSatisfy(isIdentifierByte)
    }

    /// A single file name: identifier bytes plus ".", never starting with ".".
    static func isSafeFileName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), bytes[0] != 46 else { return false }
        return bytes.allSatisfy { isIdentifierByte($0) || $0 == 46 }
    }

    /// "notebooks/<id>/<file>", "notebooks/<id>/objects/<file>" or "folders/<id>/<file>".
    static func isSafeContainerPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (3...4).contains(parts.count),
              parts[0] == "notebooks" || parts[0] == "folders" else { return false }
        return parts.dropFirst().allSatisfy(isSafeFileName)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 95
    }

    /// Checks every identifier and file reference, and returns the container
    /// paths the importer must find in the file. Throws on anything unsafe.
    func validatedFilePaths() throws -> Set<String> {
        var paths = Set<String>()
        func add(_ path: String?) throws {
            guard let path else { return }
            guard Self.isSafeContainerPath(path) else { throw BackupError.damaged("bad file path") }
            paths.insert(path)
        }
        func requireID(_ id: String, _ what: String) throws {
            guard Self.isSafeIdentifier(id) else { throw BackupError.damaged("bad \(what) id") }
        }

        var folderIds = Set<String>()
        for folder in folders {
            try requireID(folder.id, "folder")
            guard folderIds.insert(folder.id).inserted else { throw BackupError.damaged("duplicate folder") }
            if let parent = folder.parentId { try requireID(parent, "folder") }
            try add(folder.coverFile)
        }
        var notebookIds = Set<String>()
        for notebook in notebooks {
            try requireID(notebook.id, "notebook")
            guard notebookIds.insert(notebook.id).inserted else { throw BackupError.damaged("duplicate notebook") }
            try add(notebook.coverFile)
            for page in notebook.pages {
                try requireID(page.id, "page")
                try add(page.drawingFile)
                try add(page.backgroundFile)
                for object in page.objects {
                    try requireID(object.id, "page object")
                    if let name = object.imageFileName, !Self.isSafeFileName(name) {
                        throw BackupError.damaged("bad photo name")
                    }
                    try add(object.imageFile)
                }
            }
        }
        for membership in memberships {
            try requireID(membership.folderId, "folder")
            try requireID(membership.notebookId, "notebook")
        }
        var penIds = Set<String>()
        for pen in customPens {
            try requireID(pen.id, "pen")
            guard penIds.insert(pen.id).inserted else { throw BackupError.damaged("duplicate pen") }
        }
        return paths
    }
}
