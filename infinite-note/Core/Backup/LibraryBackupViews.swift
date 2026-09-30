import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Shelf button

/// The "local save" button on the shelf (next to ☀/🌙). Opens a menu with
/// "Save Backup File" and "Import Backup File…".
struct BackupMenuButton: View {
    var size: CGFloat = 38

    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var backup = LibraryBackupController.shared

    var body: some View {
        Menu {
            Button { backup.saveBackup() } label: {
                Label("Save Backup File", systemImage: "arrow.down.doc.fill")
            }
            Button { backup.chooseBackupFile() } label: {
                Label("Import Backup File\u{2026}", systemImage: "tray.and.arrow.down.fill")
            }
        } label: {
            ZStack {
                Circle().fill(themeManager.card)
                Circle().strokeBorder(themeManager.outline, lineWidth: 2.5)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(themeManager.isDark ? Color.lightBronze : Color.burgundy)
            }
            .frame(width: size, height: size)
            .background(
                Circle().fill(themeManager.hardShadow)
                    .offset(x: size * 0.087, y: size * 0.087)
            )
            .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .disabled(backup.isBusy)
        .accessibilityLabel("Local backup")
    }
}

// MARK: - Root presenter

extension View {
    /// Attaches the backup flow's UI (file picker, "backup ready" sheet,
    /// duplicate choice, progress, results). Apply once, at the app root.
    func libraryBackupUI(
        onWillImport: @escaping () -> Void,
        onDidImport: @escaping () -> Void
    ) -> some View {
        modifier(LibraryBackupPresenter(onWillImport: onWillImport, onDidImport: onDidImport))
    }
}

private struct LibraryBackupPresenter: ViewModifier {
    var onWillImport: () -> Void
    var onDidImport: () -> Void

    @ObservedObject private var backup = LibraryBackupController.shared

    private static var importTypes: [UTType] {
        var types: [UTType] = []
        if let backupType = UTType(filenameExtension: BackupContainer.fileExtension) {
            types.append(backupType)
        }
        types.append(.data)
        return types
    }

    func body(content: Content) -> some View {
        content
            // UIKit picker in a sheet (not `.fileImporter`, which can clash with
            // the editor's own `.fileExporter`). It hands back a full local
            // COPY, so an iCloud Drive file is downloaded before we read it.
            .sheet(isPresented: $backup.isPickingFile) {
                ImportFilePicker(contentTypes: Self.importTypes) { url in
                    backup.isPickingFile = false
                    if let url { backup.didPickFile(url) }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $backup.readyBackup) { ready in
                BackupReadyView(export: ready.export)
            }
            .alert(importTitle, isPresented: pendingBinding, presenting: backup.pendingImport) { pending in
                importActions(for: pending)
            } message: { pending in
                Text(importMessage(for: pending))
            }
            .alert(backup.notice?.title ?? "", isPresented: noticeBinding, presenting: backup.notice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            .overlay {
                ZStack {
                    if backup.isBusy {
                        BackupProgressOverlay(message: backup.phase.message)
                    }
                }
                // Animate only the progress card — never the library behind it.
                .animation(.easeOut(duration: 0.2), value: backup.isBusy)
            }
            .onReceive(NotificationCenter.default.publisher(for: LibraryBackupController.willImportNotification)) { _ in
                onWillImport()
            }
            .onReceive(NotificationCenter.default.publisher(for: LibraryBackupController.didImportNotification)) { _ in
                onDidImport()
            }
    }

    // MARK: Duplicate choice

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { backup.pendingImport != nil },
            set: { if !$0 { backup.pendingImport = nil } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { backup.notice != nil },
            set: { if !$0 { backup.notice = nil } }
        )
    }

    private var importTitle: String {
        guard let pending = backup.pendingImport, pending.duplicateCount > 0 else { return "Import Backup?" }
        return "Some of This Is Already Here"
    }

    @ViewBuilder
    private func importActions(for pending: PendingImport) -> some View {
        if pending.duplicateCount > 0 {
            Button("Skip Ones Already Here") { backup.runImport(pending, strategy: .skipExisting) }
            Button("Keep the Newer Version") { backup.runImport(pending, strategy: .newerWins) }
            Button("Add as Copies") { backup.runImport(pending, strategy: .keepBoth) }
        } else {
            Button("Import") { backup.runImport(pending, strategy: .skipExisting) }
        }
        Button("Cancel", role: .cancel) { backup.cancelImport(pending) }
    }

    private func importMessage(for pending: PendingImport) -> String {
        let manifest = pending.manifest
        let made = manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        var text = "Backup from \(manifest.deviceName), \(made)\n"
            + "\(plural(manifest.notebooks.count, "notebook")) · "
            + "\(plural(manifest.folders.count, "folder")) · "
            + "\(plural(manifest.pageCount, "page"))"

        guard pending.duplicateCount > 0 else {
            return text + "\n\nEverything will be added to your library."
        }
        var already: [String] = []
        if pending.duplicateNotebooks > 0 { already.append(plural(pending.duplicateNotebooks, "notebook")) }
        if pending.duplicateFolders > 0 { already.append(plural(pending.duplicateFolders, "folder")) }
        let one = pending.duplicateCount == 1
        text += "\n\n\(already.joined(separator: " and ")) \(one ? "is" : "are") already on this iPad. "
            + "What should happen to \(one ? "it" : "them")?\n\n"
            + "Skip \u{2014} keep this iPad's version.\n"
            + "Newer \u{2014} keep whichever was edited last.\n"
            + "Copies \u{2014} add the backup's version too.\n\n"
            + "Everything else in the backup is added either way."
        return text
    }

    private func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

// MARK: - Progress overlay

private struct BackupProgressOverlay: View {
    let message: String

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        ZStack {
            // Blocks touches while the library is being read or changed.
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(themeManager.textPrimary)
                Text(message)
                    .font(.cartoon(17, weight: .heavy))
                    .foregroundStyle(themeManager.textPrimary)
                Text("Keep InfiniteNote open until this finishes.")
                    .font(.cartoon(12.5, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .cartoonSurface(fill: themeManager.card, cornerRadius: 22, lineWidth: 2.5, shadowOffset: 6)
        }
        .transition(.opacity)
    }
}

// MARK: - "Backup ready" sheet

private struct BackupReadyView: View {
    let export: BackupExport

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var showShareSheet = false
    @State private var showFilesExport = false
    @State private var savedToFiles = false

    var body: some View {
        ZStack {
            themeManager.background.ignoresSafeArea()

            VStack(spacing: 22) {
                header
                summaryCard
                actionButtons
                if savedToFiles {
                    Label("Saved to Files", systemImage: "checkmark.circle.fill")
                        .font(.cartoon(13, weight: .bold))
                        .foregroundStyle(Color.pineTeal)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                Text("To restore or share: tap the backup button \u{2192} Import Backup File on any iPad.")
                    .font(.cartoon(12, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        // System share sheet — AirDrop to a friend, Messages, Mail, Drive…
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [export.url])
        }
        // Save a copy straight into Files / iCloud Drive.
        .sheet(isPresented: $showFilesExport) {
            ExportToFilesPicker(url: export.url) { didSave in
                showFilesExport = false
                if didSave {
                    withAnimation(.spring(response: 0.35)) { savedToFiles = true }
                }
            }
            .ignoresSafeArea()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Text("Backup Ready")
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

    private var summaryCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.burgundy))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(themeManager.outline, lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(export.url.lastPathComponent)
                    .font(.cartoon(15, weight: .heavy))
                    .foregroundStyle(themeManager.textPrimary)
                    .lineLimit(2)
                Text(detailText)
                    .font(.cartoon(12.5, weight: .bold))
                    .foregroundStyle(themeManager.iconTint)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cartoonSurface(fill: themeManager.card, cornerRadius: 18, lineWidth: 2, shadowOffset: 5)
    }

    private var detailText: String {
        func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        return [
            plural(export.notebookCount, "notebook"),
            plural(export.folderCount, "folder"),
            plural(export.pageCount, "page"),
            export.byteCount.formatted(.byteCount(style: .file))
        ].joined(separator: " · ")
    }

    private var actionButtons: some View {
        VStack(spacing: 14) {
            Button { showFilesExport = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .heavy))
                    Text("Save to Files")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CartoonButtonStyle(fill: .burgundy))
            .accessibilityLabel("Save backup file to Files")

            Button { showShareSheet = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .heavy))
                    Text("Share or AirDrop")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CartoonButtonStyle(fill: themeManager.card, foreground: themeManager.iconTint))
            .accessibilityLabel("Share backup file")
        }
        .padding(.top, 2)
    }
}

// MARK: - Pick a backup file

/// Opens the system Files picker and returns a local COPY of the chosen file
/// (nil if cancelled).
private struct ImportFilePicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onFinish: (URL?) -> Void

        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(nil)
        }
    }
}

// MARK: - Save a copy to Files

/// Exports a COPY of a file with the system Files picker — streams from disk,
/// so even a very large backup never has to be loaded into memory.
private struct ExportToFilesPicker: UIViewControllerRepresentable {
    let url: URL
    var onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
