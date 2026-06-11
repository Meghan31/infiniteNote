import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue

    /// Non-nil when the on-disk database could not be opened or migrated and
    /// the app fell back to a TEMPORARY in-memory database. The UI surfaces
    /// this so the user knows changes won't persist this session.
    /// (Previously this was a `fatalError`, which turned any disk-full or
    /// corruption error into a permanent crash loop at launch.)
    private(set) var initializationError: Error?

    private init() {
        let dbURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("infinite_note.db")

        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try Self.runMigrations(on: queue)
            dbQueue = queue
        } catch {
            initializationError = error
            // Keep the app usable without touching the (possibly corrupt)
            // file on disk — a future launch or update may still recover it.
            do {
                let memoryQueue = try DatabaseQueue()
                try Self.runMigrations(on: memoryQueue)
                dbQueue = memoryQueue
            } catch {
                // Migrations are deterministic; if even an in-memory database
                // fails, something is catastrophically wrong with the runtime.
                fatalError("In-memory database initialization failed: \(error)")
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

        try migrator.migrate(dbQueue)
    }
}
