import SwiftUI

// MARK: - Press Button Style (cartoon springy press)

struct NotebookButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .rotationEffect(.degrees(configuration.isPressed ? -1.5 : 0))
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Notebook Card

struct NotebookCardView: View {
    let notebook: Notebook
    var isSelected: Bool = false
    var onRename: () -> Void
    var onDelete: () -> Void
    var onEditCover: () -> Void = {}

    @State private var coverImage: UIImage?
    @EnvironmentObject private var themeManager: ThemeManager

    private var accentColor: Color { Color.notebookCover(at: notebook.coverColorIndex) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background: photo cover or solid card
            if let img = coverImage {
                // Full-bleed cover photo
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 140)
                    .clipped()
                // Gradient overlay so text remains readable
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                // Solid card with a fat colored header band (the "cover").
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        accentColor
                        // Playful spine dots, like a sticker tab.
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle().fill(.white.opacity(0.85))
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.top, 10)
                    }
                    .frame(height: 56)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(themeManager.outline).frame(height: 2.5)
                    }
                    cardBackground
                }
            }

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(notebook.title)
                    .font(.cartoon(16, weight: .heavy))
                    .foregroundStyle(coverImage != nil ? .white : themeManager.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(coverImage != nil ? .white.opacity(0.85) : accentColor)
                    Text(notebook.updatedAt.relativeLabel)
                        .font(.cartoon(11, weight: .semibold))
                        .foregroundStyle(coverImage != nil ? .white.opacity(0.85) : themeManager.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cartoonSurface(
            fill: themeManager.card,
            cornerRadius: 20,
            lineWidth: isSelected ? 3.5 : 2.5,
            shadowOffset: isSelected ? 7 : 5,
            outlineColor: isSelected ? .burgundy : themeManager.outline
        )
        .contextMenu {
            Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            Button { onEditCover() } label: { Label("Edit Cover", systemImage: "photo") }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        }
        .task(id: notebook.id) {
            // Load cover image off-main
            coverImage = await Task.detached(priority: .userInitiated) {
                FileStorageManager.shared.loadCoverImage(notebookId: notebook.id)
            }.value
        }
        .onChange(of: notebook.coverImagePath) { _, _ in
            Task {
                coverImage = await Task.detached(priority: .userInitiated) {
                    FileStorageManager.shared.loadCoverImage(notebookId: notebook.id)
                }.value
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        themeManager.card
    }
}

// MARK: - Shimmer

struct NotebookCardShimmer: View {
    @State private var phase: CGFloat = 0
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.lightBronze.opacity(0.55).frame(height: 56)
                .overlay(alignment: .bottom) { Rectangle().fill(themeManager.outline).frame(height: 2.5) }
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(themeManager.border).frame(width: 130, height: 14)
                Spacer()
                Capsule().fill(themeManager.border.opacity(0.6)).frame(width: 80, height: 10)
            }
            .padding(14)
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cartoonSurface(fill: themeManager.card, cornerRadius: 20)
        .opacity(phase)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { phase = 0.4 }
        }
    }
}

// MARK: - Date Helper

private extension Date {
    var relativeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return self.formatted(date: .abbreviated, time: .omitted)
    }
}
