import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue

    private init() {
        let dbURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("infinite_note.db")

        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try runMigrations()
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    private func runMigrations() throws {
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

        try migrator.migrate(dbQueue)
    }
}
