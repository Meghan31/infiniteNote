import Foundation
import UIKit

/// Cloud sync via Supabase.
///
/// Each sync uploads ONE PDF snapshot per notebook (stable path
/// `<notebook-id>.pdf`, overwritten on every sync) to the `notes` storage
/// bucket, upserts a row into `public.synced_notebooks`, and stamps
/// `last_synced_at` in the local database — which drives the sync badge on
/// notebook cards.
///
/// Uses Supabase's REST APIs directly (Storage + PostgREST). Run
/// `supabase-sync-setup.sql` (repo root) once in the Supabase SQL editor to
/// create the bucket, policies, and table.
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

    // MARK: - Sync

    /// Generates the notebook PDF, uploads it, records the sync in Supabase,
    /// and stamps the local DB. Returns the sync date for immediate UI use.
    @discardableResult
    func syncNotebook(_ notebook: Notebook, canvasSize: CGSize? = nil) async throws -> Date {
        // 1. PDF snapshot (includes the cover page).
        let pdfURL = try PDFGenerator.shared.generatePDF(for: notebook, canvasSize: canvasSize)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdfData = try Data(contentsOf: pdfURL)

        // 2. Upload to Storage — stable path per notebook, overwritten each
        //    sync (so renaming the notebook never orphans old files).
        let path = "\(notebook.id).pdf"
        try await uploadPDF(pdfData, to: path)

        // 3. Upsert the sync record.
        let syncedAt = Date.now
        let pageCount = (try? DrawingService.shared.pages(for: notebook.id).count) ?? 0
        try await upsertRecord(for: notebook, pdfPath: path, pageCount: pageCount, syncedAt: syncedAt)

        // 4. Stamp locally → sync badge appears on the card.
        try NotebookService.shared.markSynced(notebook, at: syncedAt)
        return syncedAt
    }

    // MARK: - Unsync

    /// Removes the notebook from the cloud: deletes the PDF from storage and
    /// the row from `synced_notebooks`, then clears the local sync stamp
    /// (badge disappears). Missing cloud objects are tolerated.
    func unsyncNotebook(_ notebook: Notebook) async throws {
        // 1. Delete the stored PDF.
        let objectURL = Config.projectURL
            .appendingPathComponent("storage/v1/object/\(Config.bucket)/\(notebook.id).pdf")
        var objectRequest = URLRequest(url: objectURL)
        objectRequest.httpMethod = "DELETE"
        objectRequest.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        objectRequest.setValue(Config.apiKey, forHTTPHeaderField: "apikey")
        let (objBody, objResponse) = try await URLSession.shared.data(for: objectRequest)
        try Self.ensureSuccess(objResponse, body: objBody, context: "Unsync", allowNotFound: true)

        // 2. Delete the sync record.
        var components = URLComponents(
            url: Config.projectURL.appendingPathComponent("rest/v1/\(Config.table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(notebook.id)")]
        var rowRequest = URLRequest(url: components.url!)
        rowRequest.httpMethod = "DELETE"
        rowRequest.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        rowRequest.setValue(Config.apiKey, forHTTPHeaderField: "apikey")
        rowRequest.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let (rowBody, rowResponse) = try await URLSession.shared.data(for: rowRequest)
        try Self.ensureSuccess(rowResponse, body: rowBody, context: "Unsync record", allowNotFound: true)

        // 3. Clear the local stamp.
        try NotebookService.shared.clearSyncStamp(notebook)
    }

    // MARK: - Storage upload

    private func uploadPDF(_ data: Data, to path: String) async throws {
        let url = Config.projectURL
            .appendingPathComponent("storage/v1/object/\(Config.bucket)/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert") // overwrite existing
        request.httpBody = data

        let (body, response) = try await URLSession.shared.data(for: request)
        try Self.ensureSuccess(response, body: body, context: "Upload")
    }

    // MARK: - Sync record (PostgREST upsert)

    private func upsertRecord(
        for notebook: Notebook,
        pdfPath: String,
        pageCount: Int,
        syncedAt: Date
    ) async throws {
        let url = Config.projectURL.appendingPathComponent("rest/v1/\(Config.table)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // merge-duplicates → upsert on the primary key (notebook id).
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")

        let record: [String: Any?] = [
            "id": notebook.id,
            "title": notebook.title,
            "author": notebook.author,
            "page_count": pageCount,
            "pdf_path": pdfPath,
            "synced_at": ISO8601DateFormatter().string(from: syncedAt)
        ]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [record.compactMapValues { $0 }]
        )

        let (body, response) = try await URLSession.shared.data(for: request)
        try Self.ensureSuccess(response, body: body, context: "Sync record")
    }

    // MARK: - Helpers

    private static func ensureSuccess(
        _ response: URLResponse,
        body: Data,
        context: String,
        allowNotFound: Bool = false
    ) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncError.network }
        if allowNotFound && http.statusCode == 404 { return }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: body, encoding: .utf8) ?? ""
            throw SyncError.server(context: context, status: http.statusCode, detail: detail)
        }
    }

    enum SyncError: LocalizedError {
        case network
        case server(context: String, status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .network:
                return "Couldn't reach Supabase. Check your connection."
            case .server(let context, let status, let detail):
                let trimmed = detail.prefix(160)
                return "\(context) failed (HTTP \(status)). \(trimmed)"
            }
        }
    }
}
