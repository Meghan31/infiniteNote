import Foundation
import Supabase
import UIKit

/// Cloud sync via Supabase.
///
/// Each sync uploads ONE PDF snapshot per notebook to the PRIVATE `notes`
/// storage bucket at `<user-id>/<notebook-id>.pdf` (stable path, overwritten
/// on every sync), upserts a row into `public.synced_notebooks`, and stamps
/// `last_synced_at` in the local database — which drives the sync badge on
/// notebook cards.
///
/// Security model — single private account, no sign-in UI:
///   • The app silently signs in as ONE manually created Supabase user,
///     using credentials from `SyncSecrets.swift` (git-ignored). The SDK
///     persists the session in the keychain and refreshes tokens itself.
///   • Sign-ups AND anonymous sign-ins are disabled server-side, so no
///     other account can ever be created — even with the publishable key
///     below (public by design), strangers can't touch the project.
///   • Row Level Security additionally scopes every row and storage object
///     to `auth.uid()` (defense in depth).
///   • Setup: run `supabase-sync-setup.sql` once in the SQL editor; in
///     Authentication, disable sign-ups + anonymous sign-ins and create the
///     one user; copy its credentials into SyncSecrets.swift.
final class SyncService: @unchecked Sendable {
    static let shared = SyncService()
    private init() {}

    // MARK: - Configuration (Supabase project → Settings → API)

    private enum Config {
        static let projectURL = URL(string: "https://tdgpyymwjfkqmfjetgot.supabase.co")!
        static let apiKey = "sb_publishable_si6NGjI4y-WRKOfNFjkY3g_KyGtdfPg"
        static let bucket = "notes"
        static let table = "synced_notebooks"
    }

    /// Supabase client — auth, storage and PostgREST in one. Replaces the old
    /// raw-URLSession layer, which authenticated as plain `anon` and couldn't
    /// attach per-user tokens.
    private let client = SupabaseClient(
        supabaseURL: Config.projectURL,
        supabaseKey: Config.apiKey
    )

    // MARK: - Auth

    /// Returns the owner's user id, signing in with the private credentials
    /// the first time. `client.auth.session` refreshes an expired session
    /// from the keychain, so this only hits the sign-in endpoint when no
    /// usable session exists. A leftover ANONYMOUS session from the old sync
    /// flow is discarded and replaced with the real account.
    private func ensureSignedIn() async throws -> UUID {
        if let session = try? await client.auth.session, !session.user.isAnonymous {
            return session.user.id
        }
        try? await client.auth.signOut()
        do {
            let session = try await client.auth.signIn(
                email: SyncSecrets.email,
                password: SyncSecrets.password
            )
            return session.user.id
        } catch {
            throw SyncError.auth(detail: error.localizedDescription)
        }
    }

    /// Storage path for a notebook's PDF, scoped to the owning user — the
    /// RLS policies only allow access inside your own `<user-id>/` folder.
    /// (Lowercased: `auth.uid()::text` is lowercase on the server, while
    /// Swift's `uuidString` is uppercase.)
    private func pdfPath(userId: UUID, notebookId: String) -> String {
        "\(userId.uuidString.lowercased())/\(notebookId).pdf"
    }

    // MARK: - Sync

    /// Generates the notebook PDF, uploads it, records the sync in Supabase,
    /// and stamps the local DB. Returns the sync date for immediate UI use.
    @discardableResult
    func syncNotebook(_ notebook: Notebook, canvasSize: CGSize? = nil) async throws -> Date {
        let userId = try await ensureSignedIn()

        // 1. PDF snapshot (includes the cover page).
        let pdfURL = try PDFGenerator.shared.generatePDF(for: notebook, canvasSize: canvasSize)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdfData = try Data(contentsOf: pdfURL)

        // 2. Upload to Storage — per-user folder, overwritten each sync
        //    (so renaming the notebook never orphans old files).
        let path = pdfPath(userId: userId, notebookId: notebook.id)
        do {
            _ = try await client.storage.from(Config.bucket).upload(
                path,
                data: pdfData,
                options: FileOptions(contentType: "application/pdf", upsert: true)
            )
        } catch {
            throw SyncError.server(context: "Upload", detail: error.localizedDescription)
        }

        // 3. Upsert the sync record (primary key = user_id + notebook id).
        let syncedAt = Date.now
        let pageCount = (try? DrawingService.shared.pages(for: notebook.id).count) ?? 0
        let record = SyncRecord(
            userId: userId.uuidString.lowercased(),
            id: notebook.id,
            title: notebook.title,
            author: notebook.author,
            pageCount: pageCount,
            pdfPath: path,
            syncedAt: ISO8601DateFormatter().string(from: syncedAt)
        )
        do {
            _ = try await client.from(Config.table)
                .upsert(record, onConflict: "user_id,id", returning: .minimal)
                .execute()
        } catch {
            throw SyncError.server(context: "Sync record", detail: error.localizedDescription)
        }

        // 4. Stamp locally → sync badge appears on the card.
        try NotebookService.shared.markSynced(notebook, at: syncedAt)
        return syncedAt
    }

    // MARK: - Unsync

    /// Removes the notebook from the cloud: deletes the PDF from storage and
    /// the row from `synced_notebooks`, then clears the local sync stamp
    /// (badge disappears). Missing cloud objects are tolerated — `remove`
    /// succeeds with an empty result when the object is already gone.
    func unsyncNotebook(_ notebook: Notebook) async throws {
        let userId = try await ensureSignedIn()

        // 1. Delete the stored PDF.
        do {
            _ = try await client.storage.from(Config.bucket)
                .remove(paths: [pdfPath(userId: userId, notebookId: notebook.id)])
        } catch {
            throw SyncError.server(context: "Unsync", detail: error.localizedDescription)
        }

        // 2. Delete the sync record (RLS limits the match to this user's row).
        do {
            _ = try await client.from(Config.table)
                .delete()
                .eq("id", value: notebook.id)
                .execute()
        } catch {
            throw SyncError.server(context: "Unsync record", detail: error.localizedDescription)
        }

        // 3. Clear the local stamp.
        try NotebookService.shared.clearSyncStamp(notebook)
    }

    // MARK: - Errors

    enum SyncError: LocalizedError {
        case auth(detail: String)
        case server(context: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .auth(let detail):
                return "Couldn't sign in to sync. \(detail.prefix(120)) "
                    + "(Check that SyncSecrets.swift matches the user in "
                    + "Supabase → Authentication → Users.)"
            case .server(let context, let detail):
                return "\(context) failed. \(detail.prefix(160))"
            }
        }
    }
}

// MARK: - Row payload

/// Mirrors `public.synced_notebooks` (see supabase-sync-setup.sql).
/// `user_id` is also enforced server-side: the insert policy requires it to
/// equal `auth.uid()`, and the column defaults to it.
private struct SyncRecord: Encodable {
    let userId: String
    let id: String
    let title: String
    let author: String?
    let pageCount: Int
    let pdfPath: String
    let syncedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, author
        case userId = "user_id"
        case pageCount = "page_count"
        case pdfPath = "pdf_path"
        case syncedAt = "synced_at"
    }
}
