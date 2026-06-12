import SwiftUI
import PhotosUI

// MARK: - Folder Icon (homepage grid item)
//
// A big cartoon folder: colored folder glyph with the hard "sticker" shadow,
// the folder's custom image overlaid on the body, an item-count badge,
// and the name + optional author underneath.

struct FolderIconView: View {
    let folder: Folder
    let count: Int

    @State private var overlayImage: UIImage?
    @EnvironmentObject private var themeManager: ThemeManager

    private var tint: Color { Color.notebookCover(at: folder.colorIndex) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Big folder glyph + cartoon hard shadow.
                Image(systemName: "folder.fill")
                    .font(.system(size: 84, weight: .regular))
                    .foregroundStyle(tint)
                    .shadow(color: themeManager.hardShadow, radius: 0, x: 4, y: 4)

                // Custom image overlaid on the folder body.
                if let img = overlayImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(themeManager.outline, lineWidth: 2)
                        )
                        .rotationEffect(.degrees(-3))
                        .offset(y: 8)
                        .shadow(color: themeManager.hardShadow.opacity(0.5), radius: 0, x: 2, y: 2)
                }

                // Pinned indicator — the cartoon pin from assets.
                if folder.isPinned {
                    AssetIcon(asset: "pin", systemName: "pin.fill", size: 26, fallbackTint: .burgundy)
                        .rotationEffect(.degrees(-22))
                        .offset(x: -40, y: -32)
                        .allowsHitTesting(false)
                }

                // Item-count badge.
                Text("\(count)")
                    .font(.cartoon(12, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.burgundy))
                    .overlay(Capsule().strokeBorder(themeManager.outline, lineWidth: 1.5))
                    .offset(x: 38, y: -34)
            }
            .frame(width: 110, height: 92)

            VStack(spacing: 2) {
                Text(folder.name)
                    .font(.cartoon(14, weight: .heavy))
                    .foregroundStyle(themeManager.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let author = folder.author, !author.isEmpty {
                    Text("by \(author)")
                        .font(.cartoon(11, weight: .medium))
                        .foregroundStyle(themeManager.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 130)
        }
        .task(id: "\(folder.id)-\(folder.imagePath ?? "none")-\(folder.updatedAt)") {
            guard folder.imagePath != nil else { overlayImage = nil; return }
            overlayImage = await Task.detached(priority: .userInitiated) {
                FileStorageManager.shared.loadFolderImage(folderId: folder.id)
            }.value
        }
    }
}

// MARK: - Create / Edit Folder Sheet
//
// `folder == nil` → create; otherwise edits that folder (prefilled). When
// editing, leaving the image untouched keeps the existing one.

struct FolderCreationSheet: View {
    var folder: Folder?
    var onSave: (String, Int, Data?, String?) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var name: String
    @State private var author: String
    @State private var colorIndex: Int
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showFileImporter = false
    @State private var existingImage: UIImage?

    private let covers = Color.notebookCovers

    init(
        folder: Folder? = nil,
        onSave: @escaping (String, Int, Data?, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.folder = folder
        self.onSave = onSave
        self.onCancel = onCancel
        self._name = State(initialValue: folder?.name ?? "")
        self._author = State(initialValue: folder?.author ?? "")
        self._colorIndex = State(initialValue: folder?.colorIndex ?? (Color.notebookCovers.indices.randomElement() ?? 0))
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Name + author ─────────────────────────────────────
                Section {
                    TextField("e.g. University", text: $name)
                        .font(.system(size: 17))
                        .listRowBackground(themeManager.card)
                    TextField("Author (optional)", text: $author)
                        .font(.system(size: 15))
                        .textContentType(.name)
                        .listRowBackground(themeManager.card)
                } header: { Text("Folder Name").foregroundStyle(Color.palmLeaf) }

                // ── Color ─────────────────────────────────────────────
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: covers.count), spacing: 12) {
                        ForEach(covers.indices, id: \.self) { i in
                            let isSel = colorIndex == i
                            Button { colorIndex = i } label: {
                                ZStack {
                                    Circle().fill(themeManager.hardShadow).frame(width: 38, height: 38).offset(x: 3, y: 3)
                                    Circle().fill(covers[i]).frame(width: 38, height: 38)
                                    Circle().strokeBorder(themeManager.outline, lineWidth: isSel ? 3.5 : 2).frame(width: 38, height: 38)
                                    if isSel {
                                        Image(systemName: "checkmark").font(.system(size: 13, weight: .black)).foregroundStyle(.white)
                                    }
                                }
                                .scaleEffect(isSel ? 1.12 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isSel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(themeManager.card)
                } header: { Text("Folder Color").foregroundStyle(Color.palmLeaf) }

                // ── Image (overlaid on the folder icon) ───────────────
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        if let data = photoData, let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else if let img = existingImage {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .opacity(0.85)
                        }
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                                Label("Photos", systemImage: "photo.on.rectangle")
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.burgundy)
                            }
                            .onChange(of: photoItem) { _, item in
                                guard let item else { return }
                                Task {
                                    if let data = try? await item.loadTransferable(type: Data.self) { photoData = data }
                                }
                            }
                            Button { showFileImporter = true } label: {
                                Label("Files", systemImage: "folder")
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.burgundy)
                            }
                            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image, .jpeg, .png, .heic], allowsMultipleSelection: false) { result in
                                if case .success(let urls) = result, let url = urls.first {
                                    let ok = url.startAccessingSecurityScopedResource()
                                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                                    photoData = try? Data(contentsOf: url)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(themeManager.card)
                } header: { Text("Image (Optional)").foregroundStyle(Color.palmLeaf) }
                  footer: { Text("Shown on top of the big folder icon.") }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.background)
            .navigationTitle(folder == nil ? "New Folder" : "Edit Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).foregroundStyle(themeManager.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(folder == nil ? "Create" : "Save") {
                        onSave(name, colorIndex, photoData, author.nilIfBlank)
                    }
                    .fontWeight(.semibold).foregroundStyle(Color.burgundy)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .task {
            if let folder, folder.imagePath != nil {
                existingImage = await Task.detached(priority: .userInitiated) {
                    FileStorageManager.shared.loadFolderImage(folderId: folder.id)
                }.value
            }
        }
    }
}
