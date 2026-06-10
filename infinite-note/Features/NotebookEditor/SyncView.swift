import SwiftUI

struct SyncView: View {
    let notebook: Notebook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var syncState: SyncState = .idle

    enum SyncState { case idle, syncing, success, failure(String) }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // Status icon
                    ZStack {
                        Circle()
                            .fill(iconBackground)
                            .frame(width: 88, height: 88)
                        Image(systemName: iconName)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(iconForeground)
                    }
                    .padding(.bottom, 28)

                    // Text
                    VStack(spacing: 8) {
                        Text(titleText)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(themeManager.textPrimary)

                        Text(subtitleText)
                            .font(.system(size: 14))
                            .foregroundStyle(themeManager.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    Spacer()

                    // Action
                    VStack(spacing: 12) {
                        if case .idle = syncState {
                            syncButton
                        }
                        if case .failure = syncState {
                            Button("Try Again") { syncState = .idle }
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.burgundy)
                        }
                    }
                    .padding(.bottom, 8)

                    // Footer note
                    Text("Exports a PDF snapshot to Supabase Storage")
                        .font(.system(size: 12))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.7))
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Sync Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(themeManager.textSecondary)
                }
            }
        }
        .themeToggleOverlay()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var syncButton: some View {
        Button {
            Task { await sync() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up.fill")
                Text("Sync Notebook")
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            // Sync button → pineTeal (palette usage rule)
            .background(Color.pineTeal)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
    }

    private func sync() async {
        syncState = .syncing
        do {
            try await SyncService.shared.uploadNotebook(notebook)
            withAnimation(.spring(response: 0.4)) { syncState = .success }
        } catch {
            withAnimation { syncState = .failure(error.localizedDescription) }
        }
    }

    private var iconName: String {
        switch syncState {
        case .idle:    return "icloud.and.arrow.up"
        case .syncing: return "arrow.trianglehead.2.counterclockwise.rotate.90"
        case .success: return "checkmark.circle"
        case .failure: return "exclamationmark.triangle"
        }
    }

    private var iconBackground: Color {
        // pineTeal → sync + success states; burgundy → failure
        switch syncState {
        case .idle:    return Color.pineTeal.opacity(0.08)
        case .syncing: return Color.pineTeal.opacity(0.08)
        case .success: return Color.pineTeal.opacity(0.1)
        case .failure: return Color.burgundy.opacity(0.1)
        }
    }

    private var iconForeground: Color {
        switch syncState {
        case .idle, .syncing: return Color.pineTeal
        case .success: return Color.pineTeal
        case .failure: return Color.burgundy
        }
    }

    private var titleText: String {
        switch syncState {
        case .idle:    return "Ready to Sync"
        case .syncing: return "Uploading\u{2026}"
        case .success: return "Synced"
        case .failure: return "Sync Failed"
        }
    }

    private var subtitleText: String {
        switch syncState {
        case .idle:
            return "Upload \"\(notebook.title)\" as a PDF\nto Supabase Storage."
        case .syncing:
            return "Generating PDF and uploading\u{2026}"
        case .success:
            return "\"\(notebook.title)\" was uploaded successfully."
        case .failure(let msg):
            return msg
        }
    }
}

extension SyncView.SyncState: Equatable {
    static func == (lhs: SyncView.SyncState, rhs: SyncView.SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.syncing, .syncing), (.success, .success): return true
        case (.failure, .failure): return true
        default: return false
        }
    }
}
