import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - PDF Export Support
//
// Small helpers used by the notebook editor to download and share the
// generated PDF. `PDFExportDocument` backs SwiftUI's `.fileExporter` (the
// "Download / Save to Files" flow); `ShareSheet` wraps a UIActivityViewController
// for the "Share to other apps" flow.

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

/// A thin SwiftUI wrapper over UIActivityViewController (the system share sheet).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
