import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - PDF Export Support
//
// Helpers used by the notebook editor to download and share the generated
// PDF. `PDFExportDocument` backs SwiftUI's `.fileExporter` (the "Download /
// Save to Files" flow); `SharePDFView` is the themed share popup, which wraps
// the system share sheet (`ShareSheet`) and a Files export in one place.

/// A FileDocument wrapper around raw PDF data, for `.fileExporter`.
struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Identifiable payload for `.sheet(item:)`.
///
/// The share popup used to be driven by a Bool + optional URL, which raced on
/// first presentation: SwiftUI evaluated the sheet body before the URL state
/// landed, leaving an empty (white) sheet until something — like a theme
/// toggle — forced a re-render. With `.sheet(item:)` the content is built
/// from the item itself, so the URL always exists by construction.
struct SharePDFItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A thin SwiftUI wrapper over UIActivityViewController (the system share sheet).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Share Popup
//
// The cartoon-styled share sheet: a notebook summary card (cover, title,
// pages, file size) above two chunky actions — "Share to Apps" (system share
// sheet) and "Save to Files" (.fileExporter). Fully theme-aware, so it reads
// correctly in light and dark mode from the first presentation.

struct SharePDFView: View {
    let notebook: Notebook
    let pdfURL: URL

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var pdfData: Data?
    @State private var pageCount = 0
    @State private var showSystemShare = false
    @State private var showFileExporter = false
    @State private var saveFeedback: SaveFeedback?

    private enum SaveFeedback { case saved, failed(String) }

    private var accent: Color { Color.notebookCover(at: notebook.coverColorIndex) }

    var body: some View {
        ZStack {
            themeManager.background.ignoresSafeArea()

            VStack(spacing: 22) {
                header
                notebookCard
                actionButtons
                feedbackLabel
                Spacer(minLength: 0)
                Text("Exports a PDF snapshot of this notebook")
                    .font(.cartoon(12, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        // System share sheet, fed the always-present URL.
        .sheet(isPresented: $showSystemShare) { ShareSheet(items: [pdfURL]) }
        // "Save to Files" export.
        .fileExporter(
            isPresented: $showFileExporter,
            document: pdfData.map(PDFExportDocument.init(data:)),
            contentType: .pdf,
            defaultFilename: notebook.title.sanitizedFilename
        ) { result in
            withAnimation(.spring(response: 0.35)) {
                switch result {
                case .success: saveFeedback = .saved
                case .failure(let error): saveFeedback = .failed(error.localizedDescription)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            pdfData = try? Data(contentsOf: pdfURL)
            pageCount = (try? DrawingService.shared.pages(for: notebook.id).count) ?? 0
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Share Notebook")
                .font(.cartoon(22, weight: .heavy))
                .foregroundStyle(themeManager.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(themeManager.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(themeManager.card))
                    .overlay(Circle().strokeBorder(themeManager.outline.opacity(0.35), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Notebook summary card

    private var notebookCard: some View {
        HStack(spacing: 16) {
            // Mini cover: accent color + ruled lines, like the library cards.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(.white.opacity(0.55)).frame(height: 3)
                    }
                }
                .padding(.horizontal, 10)
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .frame(width: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: 52, height: 68)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(themeManager.outline, lineWidth: 2)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(notebook.title)
                    .font(.cartoon(17, weight: .heavy))
                    .foregroundStyle(themeManager.textPrimary)
                    .lineLimit(2)
                if let author = notebook.author, !author.isEmpty {
                    Text("by \(author)")
                        .font(.cartoon(13, weight: .semibold))
                        .foregroundStyle(themeManager.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 11, weight: .bold))
                    Text(metaText)
                        .font(.cartoon(12.5, weight: .bold))
                }
                .foregroundStyle(themeManager.iconTint)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cartoonSurface(fill: themeManager.card, cornerRadius: 18, lineWidth: 2, shadowOffset: 5)
    }

    private var metaText: String {
        var parts = ["\(pageCount) page\(pageCount == 1 ? "" : "s")"]
        if let bytes = pdfData?.count, bytes > 0 {
            parts.append(Int64(bytes).formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actionButtons: some View {
        VStack(spacing: 14) {
            Button { showSystemShare = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .heavy))
                    Text("Share to Apps")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CartoonButtonStyle(fill: .burgundy))
            .accessibilityLabel("Share PDF to other apps")

            Button { showFileExporter = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .heavy))
                    Text("Save to Files")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CartoonButtonStyle(fill: themeManager.card, foreground: themeManager.iconTint))
            .disabled(pdfData == nil)
            .accessibilityLabel("Save PDF to Files")
        }
        .padding(.top, 2)
    }

    // MARK: Save feedback

    @ViewBuilder
    private var feedbackLabel: some View {
        switch saveFeedback {
        case .saved:
            Label("Saved to Files", systemImage: "checkmark.circle.fill")
                .font(.cartoon(13, weight: .bold))
                .foregroundStyle(Color.pineTeal)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.cartoon(12.5, weight: .bold))
                .foregroundStyle(Color.burgundy)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        case nil:
            EmptyView()
        }
    }
}
