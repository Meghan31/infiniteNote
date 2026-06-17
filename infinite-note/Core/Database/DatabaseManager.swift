import Foundation
import GRDB
import UIKit

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue

    /// Non-nil when the on-disk database could not be opened or migrated and
    /// the app fell back to a TEMPORARY in-memory database. The UI surfaces
    /// this so the user knows changes won't persist this session.
    /// (Previously this was a `fatalError`, which turned any disk-full or
    /// corruption error into a permanent crash loop at launch.)
    private(set) var initializationError: Error?

    /// Posted when the on-disk database is recovered after having fallen back
    /// to the temporary in-memory store — the UI reloads its content on this.
    static let didReopenNotification = Notification.Name("DatabaseManager.didReopen")

    private let dbURL: URL

    private init() {
        dbURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("infinite_note.db")

        // CRITICAL on real devices: make the database folder use a consistent
        // "available after first unlock" protection BEFORE opening. Otherwise
        // SQLite's journal/sidecar files can inherit a stricter class than the
        // main file, and a normal relaunch then can't read the database — which
        // looks exactly like "all my data vanished" even though it's safe on
        // disk. Done before the open so new sidecar files inherit it too.
        Self.makeAccessible(dbURL)

        // Opening can also fail transiently right after a rebuild / OS-kill,
        // before a stale lock clears — so retry a few times. The on-disk file
        // is NEVER deleted or replaced here; the user's data is always safe.
        var openError: Error?
        if let queue = Self.openDiskQueue(at: dbURL, attempts: 5, lastError: &openError) {
            dbQueue = queue
            initializationError = nil
        } else {
            // Last resort: a temporary in-memory store so the app still runs.
            do {
                let memoryQueue = try DatabaseQueue()
                try Self.runMigrations(on: memoryQueue)
                dbQueue = memoryQueue
                // Keep the REAL underlying error so the UI can show what went
                // wrong (locked / corrupt / I/O), which pinpoints the cause.
                initializationError = openError ?? NSError(
                    domain: "DatabaseManager", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The notebook library is temporarily unavailable."])
            } catch {
                fatalError("In-memory database initialization failed: \(error)")
            }
            scheduleRecovery()
        }

        // If the open failed because protected data wasn't ready yet, retry the
        // instant it becomes available (right after the device is unlocked).
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reopenIfNeeded()
        }
    }

    // MARK: - Disk open (with retries)

    /// Attempts to open and migrate the on-disk database, retrying briefly so a
    /// stale lock from a just-killed process can release. Returns nil on
    /// persistent failure. Does NOT delete or replace the file.
    private static func openDiskQueue(at url: URL, attempts: Int,
                                      lastError: inout Error?) -> DatabaseQueue? {
        // Reset protection first so a file left with a stricter class by an
        // earlier build can be read on this (unlocked) launch.
        makeAccessible(url)
        for attempt in 0..<max(1, attempts) {
            do {
                let queue = try DatabaseQueue(path: url.path)
                try runMigrations(on: queue)
                makeAccessible(url)   // keep newly-created sidecar files readable
                return queue
            } catch {
                lastError = error
                if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.3) }
            }
        }
        if let lastError { NSLog("DatabaseManager open failed: \(lastError)") }
        return nil
    }

    /// Sets "available after first unlock" protection on the database folder and
    /// every database file, so all of them share one accessible class. (The
    /// folder attribute makes future journal/wal/shm files inherit it.)
    private static func makeAccessible(_ url: URL) {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] =
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.setAttributes(attrs, ofItemAtPath: url.deletingLastPathComponent().path)
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"]
        where fm.fileExists(atPath: path) {
            try? fm.setAttributes(attrs, ofItemAtPath: path)
        }
    }

    // MARK: - Recovery

    /// Re-attempts the on-disk database when currently on the in-memory
    /// fallback. Safe to call repeatedly / on every foreground. Returns true if
    /// recovered. No-op once the real database is open.
    @discardableResult
    func reopenIfNeeded() -> Bool {
        guard initializationError != nil else { return false }
        var error: Error?
        guard let queue = Self.openDiskQueue(at: dbURL, attempts: 2, lastError: &error) else { return false }
        dbQueue = queue
        initializationError = nil
        NotificationCenter.default.post(name: Self.didReopenNotification, object: nil)
        return true
    }

    /// Retries recovery a few times on the main queue (each call opens ONCE —
    /// no overlapping connections that could self-lock).
    private func scheduleRecovery() {
        for delay in [0.5, 1.5, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reopenIfNeeded()
            }
        }
    }

    private static func runMigrations(on dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        // v1 — initial schema
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "notebooks", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("cover_color_index", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "pages", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("notebook_id", .text).notNull()
                    .references("notebooks", onDelete: .cascade)
                t.column("page_number", .integer).notNull()
            }
        }

        // v2 — cover images + page styles
        migrator.registerMigration("v2_cover_and_style") { db in
            try db.alter(table: "notebooks") { t in
                t.add(column: "cover_image_path", .text)
            }
            try db.alter(table: "pages") { t in
                t.add(column: "page_style", .text).defaults(to: "grid")
            }
        }

        // v3 — default page style per notebook
        migrator.registerMigration("v3_default_page_style") { db in
            try db.alter(table: "notebooks") { t in
                t.add(column: "default_page_style", .text).defaults(to: "grid")
            }
        }

        // v4 — optional details for the PDF cover page
        migrator.registerMigration("v4_cover_details") { db in
            try db.alter(table: "notebooks") { t in
                t.add(column: "note_description", .text)
                t.add(column: "author", .text)
            }
        }

        // v5 — home-screen folders. The join table's composite primary key
        // guarantees a notebook can be added to a folder only once.
        migrator.registerMigration("v5_folders") { db in
            try db.create(table: "folders", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("color_index", .integer).notNull().defaults(to: 0)
                t.column("image_path", .text)
                t.column("author", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "folder_notebooks", ifNotExists: true) { t in
                t.column("folder_id", .text).notNull()
                    .references("folders", onDelete: .cascade)
                t.column("notebook_id", .text).notNull()
                    .references("notebooks", onDelete: .cascade)
                t.primaryKey(["folder_id", "notebook_id"])
            }
        }

        // v6 — cloud sync timestamp (nil = never synced)
        migrator.registerMigration("v6_sync") { db in
            try db.alter(table: "notebooks") { t in
                t.add(column: "last_synced_at", .datetime)
            }
        }

        // v7 — pinned notebooks + folders (pinned sort first)
        migrator.registerMigration("v7_pins") { db in
            try db.alter(table: "notebooks") { t in
                t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "folders") { t in
                t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            }
        }

        // v8 — nested folders. Existing folders keep `parent_id == nil`,
        // which makes them root folders on the Home grid.
        migrator.registerMigration("v8_nested_folders") { db in
            try db.alter(table: "folders") { t in
                t.add(column: "parent_id", .text)
                    .references("folders", onDelete: .cascade)
            }
        }

        // v9 — custom pen presets (the Default Pen is a code constant, not a row)
        migrator.registerMigration("v9_custom_pens") { db in
            try db.create(table: "custom_pens", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("color_hex", .text).notNull().defaults(to: "000000")
                t.column("opacity", .double).notNull().defaults(to: 1)
                t.column("width", .double).notNull().defaults(to: 3)
                t.column("stabilization", .double).notNull().defaults(to: 0.5)
                t.column("bezier_smoothing", .double).notNull().defaults(to: 0.5)
                t.column("pressure_sensitivity", .double).notNull().defaults(to: 0.08)
                t.column("start_taper", .double).notNull().defaults(to: 0.4)
                t.column("end_taper", .double).notNull().defaults(to: 0.5)
                t.column("ink_flow", .double).notNull().defaults(to: 1)
                t.column("softness", .double).notNull().defaults(to: 0)
                t.column("velocity_sensitivity", .double).notNull().defaults(to: 0.15)
                t.column("min_width", .double).notNull().defaults(to: 1.5)
                t.column("max_width", .double).notNull().defaults(to: 6)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }

        // v10 — placed page objects (rich-text boxes + photos). These live ON
        // the page in the fixed paper coordinate space, NOT as a background.
        // Photo bytes live on disk (image_file); text is stored inline as RTF.
        migrator.registerMigration("v10_page_objects") { db in
            try db.create(table: "page_objects", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("page_id", .text).notNull()
                    .references("pages", onDelete: .cascade)
                t.column("kind", .text).notNull().defaults(to: "text")
                t.column("x", .double).notNull().defaults(to: 0)
                t.column("y", .double).notNull().defaults(to: 0)
                t.column("width", .double).notNull().defaults(to: 200)
                t.column("height", .double).notNull().defaults(to: 120)
                t.column("rotation", .double).notNull().defaults(to: 0)
                t.column("z_index", .integer).notNull().defaults(to: 0)
                t.column("text_rtf", .blob)
                t.column("image_file", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_page_objects_page",
                on: "page_objects",
                columns: ["page_id"],
                ifNotExists: true
            )
        }

        try migrator.migrate(dbQueue)
    }
}
