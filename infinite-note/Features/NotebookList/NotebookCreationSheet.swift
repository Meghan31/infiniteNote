import SwiftUI
import PhotosUI

// MARK: - Create Notebook Sheet

struct NotebookCreationSheet: View {
    var onCreate: (String, Int, Data?, PageStyle) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var title = ""
    @State private var coverTab: CoverTab = .color
    @State private var colorIndex: Int = Color.notebookCovers.indices.randomElement() ?? 0
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var selectedStyle: PageStyle = .grid
    @State private var showFileImporter = false

    enum CoverTab { case color, photo }

    private let covers = Color.notebookCovers

    var body: some View {
        NavigationStack {
            Form {
                // ── Title ─────────────────────────────────────────────
                Section {
                    TextField("e.g. Distributed Systems", text: $title)
                        .font(.system(size: 17))
                        .listRowBackground(themeManager.card)
                } header: { Text("Notebook Title").foregroundStyle(Color.palmLeaf) }

                // ── Cover ─────────────────────────────────────────────
                Section {
                    Picker("", selection: $coverTab) {
                        Text("Color").tag(CoverTab.color)
                        Text("Photo").tag(CoverTab.photo)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init())

                    if coverTab == .color {
                        colorGrid.listRowBackground(themeManager.card)
                    } else {
                        photoPickerSection.listRowBackground(themeManager.card)
                    }
                } header: { Text("Cover").foregroundStyle(Color.palmLeaf) }

                // ── Page Style ────────────────────────────────────────
                Section {
                    pageStyleGrid.listRowBackground(themeManager.card)
                } header: { Text("Page Style").foregroundStyle(Color.palmLeaf) }
                  footer: { Text("This style applies to all pages in the notebook.") }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.background)
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).foregroundStyle(themeManager.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title, colorIndex, photoData, selectedStyle)
                    }
                    .fontWeight(.semibold).foregroundStyle(Color.burgundy)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Color Grid

    private var colorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: covers.count), spacing: 12) {
            ForEach(covers.indices, id: \.self) { i in
                let isSel = colorIndex == i && photoData == nil
                Button { colorIndex = i; photoData = nil } label: {
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
    }

    // MARK: - Photo Picker Section

    private var photoPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data = photoData, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Button {
                    showFileImporter = true
                } label: {
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
    }

    // MARK: - Page Style Grid

    private var pageStyleGrid: some View {
        let styles: [PageStyle] = [.plain, .ruled, .dots, .grid]
        return VStack(spacing: 12) {
            // 4 style cards in a row
            HStack(spacing: 10) {
                ForEach(styles, id: \.self) { style in
                    styleCard(style)
                }
            }

            // Photo background option
            PhotosPicker(selection: Binding(
                get: { nil as PhotosPickerItem? },
                set: { item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            // Store photo bg data somewhere — for now just mark style as .photo
                            // The actual bg will be set after creation via setPageStyle
                            // For simplicity, just select .photo style
                            selectedStyle = .photo
                        }
                    }
                }
            ), matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(Color.palmLeaf)
                    Text("Photo Background")
                        .font(.system(size: 13, weight: selectedStyle == .photo ? .semibold : .regular))
                        .foregroundStyle(selectedStyle == .photo ? Color.burgundy : themeManager.textSecondary)
                    Spacer()
                    if selectedStyle == .photo {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.burgundy)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selectedStyle == .photo ? Color.palmLeafDark.opacity(0.15) : themeManager.card)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selectedStyle == .photo ? Color.burgundy.opacity(0.4) : themeManager.border, lineWidth: selectedStyle == .photo ? 1.5 : 0.5)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func styleCard(_ style: PageStyle) -> some View {
        let isSelected = selectedStyle == style
        return Button { selectedStyle = style } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(themeManager.page).frame(height: 52)
                    stylePreview(style).frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.burgundy : themeManager.border, lineWidth: isSelected ? 2 : 0.5))
                Text(style.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.burgundy : themeManager.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func stylePreview(_ style: PageStyle) -> some View {
        let gridColor = themeManager.grid
        return Canvas { ctx, size in
            switch style {
            case .plain: break
            case .ruled:
                var y: CGFloat = 9
                while y < size.height {
                    ctx.stroke(Path { p in p.move(to: .init(x: 4, y: y)); p.addLine(to: .init(x: size.width - 3, y: y)) }, with: .color(gridColor.opacity(0.8)), lineWidth: 0.6)
                    y += 9
                }
            case .dots:
                var y: CGFloat = 9
                while y < size.height {
                    var x: CGFloat = 9
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x-0.8, y: y-0.8, width: 1.6, height: 1.6)), with: .color(gridColor.opacity(0.8)))
                        x += 9
                    }
                    y += 9
                }
            case .grid:
                var x: CGFloat = 9
                while x < size.width {
                    ctx.stroke(Path { p in p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)) }, with: .color(gridColor.opacity(0.7)), lineWidth: 0.4)
                    x += 9
                }
                var y: CGFloat = 9
                while y < size.height {
                    ctx.stroke(Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)) }, with: .color(gridColor.opacity(0.7)), lineWidth: 0.4)
                    y += 9
                }
            case .photo: break
            }
        }
    }
}

// MARK: - Edit Cover Sheet

struct EditCoverSheet: View {
    let notebook: Notebook
    var onSaveColor: (Int) -> Void
    var onSavePhoto: (Data) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var coverTab: CoverTab = .color
    @State private var colorIndex: Int
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showFileImporter = false

    enum CoverTab { case color, photo }

    private let covers = Color.notebookCovers

    init(notebook: Notebook, onSaveColor: @escaping (Int) -> Void, onSavePhoto: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.notebook = notebook
        self.onSaveColor = onSaveColor
        self.onSavePhoto = onSavePhoto
        self.onCancel = onCancel
        self._colorIndex = State(initialValue: notebook.coverColorIndex)
        self._coverTab = State(initialValue: notebook.coverImagePath != nil ? .photo : .color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $coverTab) {
                        Text("Color").tag(CoverTab.color)
                        Text("Photo").tag(CoverTab.photo)
                    }
                    .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(.init())

                    if coverTab == .color {
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
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            if let data = photoData, let img = UIImage(data: data) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            HStack(spacing: 16) {
                                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                                    Label("Photos", systemImage: "photo.on.rectangle")
                                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.burgundy)
                                }
                                .onChange(of: photoItem) { _, item in
                                    guard let item else { return }
                                    Task { if let data = try? await item.loadTransferable(type: Data.self) { photoData = data } }
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
                    }
                } header: { Text("Cover").foregroundStyle(Color.palmLeaf) }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.background)
            .navigationTitle("Edit Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).foregroundStyle(themeManager.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if coverTab == .photo, let data = photoData { onSavePhoto(data) }
                        else { onSaveColor(colorIndex) }
                    }
                    .fontWeight(.semibold).foregroundStyle(Color.burgundy)
                }
            }
        }
        .themeToggleOverlay()
        .presentationDetents([.medium, .large])
    }
}
