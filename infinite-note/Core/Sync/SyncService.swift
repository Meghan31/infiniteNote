import Foundation

// NOTE: Add Supabase Swift SDK via Swift Package Manager:
// https://github.com/supabase/supabase-swift
// Package: supabase-swift, version: 2.x
// Then replace the placeholder below with actual Supabase client usage.

final class SyncService {
    static let shared = SyncService()

    // MARK: - Configuration
    // Set these from your Supabase project settings → API
    private let supabaseURL = URL(string: "https://YOUR_PROJECT_REF.supabase.co")!
    private let supabaseKey = "YOUR_ANON_KEY"
    private let bucketName = "notes"

    private init() {}

    // MARK: - Upload

    func uploadNotebook(_ notebook: Notebook) async throws {
        // 1. Generate PDF
        let pdfURL = try PDFGenerator.shared.generatePDF(for: notebook)
        let pdfData = try Data(contentsOf: pdfURL)

        // 2. Build upload path
        let filename = "\(notebook.title.sanitizedFilename).pdf"
        let path = filename

        // 3. Upload to Supabase Storage via REST API
        var request = URLRequest(url: supabaseURL.appendingPathComponent("storage/v1/object/\(bucketName)/\(path)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert") // overwrite existing
        request.httpBody = pdfData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SyncError.uploadFailed
        }

        // 4. Clean up temp PDF
        try? FileManager.default.removeItem(at: pdfURL)
    }

    enum SyncError: LocalizedError {
        case uploadFailed
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .uploadFailed:
                return "Upload to Supabase failed. Check your connection and credentials."
            case .notConfigured:
                return "Supabase is not configured. Set your project URL and anon key in SyncService.swift."
            }
        }
    }
}
