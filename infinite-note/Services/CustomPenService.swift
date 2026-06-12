import Foundation
import GRDB

/// CRUD for the user's saved pen presets.
///
/// The Default Pen is NOT stored here — it's the immutable
/// `CustomPen.defaultPen` constant, so it can never be deleted, renamed,
/// or modified, and always exists as the fallback (service-level guards
/// below back up the UI rules).
final class CustomPenService: @unchecked Sendable {
    static let shared = CustomPenService()
    private let db = DatabaseManager.shared

    private init() {}

    /// Saved pens, oldest first (stable toolkit order).
    func allPens() throws -> [CustomPen] {
        try db.dbQueue.read { db in
            try CustomPen
                .order(Column("created_at").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func create(_ pen: CustomPen) throws -> CustomPen {
        var pen = pen
        pen.name = pen.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pen.name.isEmpty else { throw PenError.blankName }
        guard !pen.isDefault else { throw PenError.defaultPenIsImmutable }
        pen.createdAt = .now
        pen.updatedAt = .now
        try db.dbQueue.write { db in try pen.insert(db) }
        return pen
    }

    @discardableResult
    func update(_ pen: CustomPen) throws -> CustomPen {
        var pen = pen
        pen.name = pen.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pen.name.isEmpty else { throw PenError.blankName }
        guard !pen.isDefault else { throw PenError.defaultPenIsImmutable }
        pen.updatedAt = .now
        try db.dbQueue.write { db in try pen.update(db) }
        return pen
    }

    /// New pen with the same settings, named "<name> Copy".
    @discardableResult
    func duplicate(_ pen: CustomPen) throws -> CustomPen {
        var copy = pen
        copy.id = UUID().uuidString
        copy.name = pen.name + " Copy"
        return try create(copy)
    }

    func delete(_ pen: CustomPen) throws {
        guard !pen.isDefault else { throw PenError.defaultPenIsImmutable }
        _ = try db.dbQueue.write { db in try pen.delete(db) }
    }

    enum PenError: LocalizedError {
        case blankName
        case defaultPenIsImmutable

        var errorDescription: String? {
            switch self {
            case .blankName:
                return "Give the pen a name before saving."
            case .defaultPenIsImmutable:
                return "The Default Pen can't be changed or deleted."
            }
        }
    }
}
