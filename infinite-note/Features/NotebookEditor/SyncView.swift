import SwiftUI

/// Cloud sync sheet — opened from the cloud button in the editor's top-right
/// capsule. Starts syncing immediately (one tap = one sync) and reports the
/// result, including when the notebook was last synced.
struct SyncView: View {
    let notebook: Notebook
    var canvasSize: CGSize? = nil
    var onSynced: (Date) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var syncState: SyncState = .syncing

    enum SyncState { case syncing, success(Date), failure(String) }

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
                            .frame(width: 96, height: 96)
                        statusIcon
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

                        if let last = lastSyncedLabel {
                            Label(last, systemImage: "clock.arrow.2.circlepath")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.pineTeal)
                                .padding(.top, 6)
                        }
                    }

                    Spacer()

                    // Action
                    if case .failure = syncState {
                        Button {
                            syncState = .syncing
                            Task { await sync() }
                        } label: {
                            Text("Try Again")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 28).padding(.vertical, 11)
                                .background(Capsule().fill(Color.burgundy))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                    }

                    // Footer note
                    Text("Uploads a PDF snapshot to Supabase")
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
        .task { await sync() }
    }

    private func sync() async {
        do {
            let date = try await SyncService.shared.syncNotebook(notebook, canvasSize: canvasSize)
            onSynced(date)
            withAnimation(.spring(response: 0.4)) { syncState = .success(date) }
        } catch {
            withAnimation { syncState = .failure(error.localizedDescription) }
        }
    }

    /// Previous sync shown while uploading / after failure.
    private var lastSyncedLabel: String? {
        switch syncState {
        case .success(let date):
            return "Synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .syncing, .failure:
            guard let last = notebook.lastSyncedAt else { return nil }
            return "Last synced \(last.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch syncState {
        case .syncing:
            AssetIcon(asset: "cloud-sync", systemName: "icloud.and.arrow.up", size: 60, fallbackTint: iconForeground)
        case .success:
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(iconForeground)
        case .failure:
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(iconForeground)
        }
    }

    private var iconBackground: Color {
        switch syncState {
        case .syncing, .success: return Color.pineTeal.opacity(0.1)
        case .failure:           return Color.burgundy.opacity(0.1)
        }
    }

    private var iconForeground: Color {
        switch syncState {
        case .syncing, .success: return Color.pineTeal
        case .failure:           return Color.burgundy
        }
    }

    private var titleText: String {
        switch syncState {
        case .syncing: return "Syncing\u{2026}"
        case .success: return "Synced"
        case .failure: return "Sync Failed"
        }
    }

    private var subtitleText: String {
        switch syncState {
        case .syncing:
            return "Uploading \"\(notebook.title)\"\nto Supabase\u{2026}"
        case .success:
            return "\"\(notebook.title)\" is safely in the cloud."
        case .failure(let msg):
            return msg
        }
    }
}

extension SyncView.SyncState: Equatable {
    static func == (lhs: SyncView.SyncState, rhs: SyncView.SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.syncing, .syncing), (.success, .success), (.failure, .failure): return true
        default: return false
        }
    }
}
