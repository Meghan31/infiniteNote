import SwiftUI
import PhotosUI

struct NotebookListView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var viewModel = NotebookListViewModel()
    @State private var selectedNotebook: Notebook?
    @State private var openNotebooks: [Notebook] = []

    @State private var showCreateSheet = false
    @State private var notebookToRename: Notebook?
    @State private var renameText = ""
    @State private var notebookToDelete: Notebook?
    @State private var notebookToEditCover: Notebook?
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 22)]

    private var filteredNotebooks: [Notebook] {
        guard !searchText.isEmpty else { return viewModel.notebooks }
        return viewModel.notebooks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 480)
        } detail: {
            if let notebook = selectedNotebook {
                NotebookEditorView(
                    notebook: notebook,
                    openNotebooks: openNotebooks,
                    onSelectNotebook: { nb in
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedNotebook = nb
                            if !openNotebooks.contains(where: { $0.id == nb.id }) { openNotebooks.append(nb) }
                        }
                    },
                    onCloseNotebook: { nb in
                        withAnimation(.easeOut(duration: 0.2)) {
                            openNotebooks.removeAll { $0.id == nb.id }
                            if selectedNotebook?.id == nb.id { selectedNotebook = openNotebooks.first }
                        }
                    },
                    onGoHome: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            openNotebooks.removeAll()
                            selectedNotebook = nil
                        }
                    }
                )
                .id(notebook.id)
            } else {
                detailPlaceholder
            }
        }
        .onAppear { viewModel.loadNotebooks() }
        // Create sheet — uses proper View struct so @State works
        .sheet(isPresented: $showCreateSheet) {
            NotebookCreationSheet { title, colorIndex, photoData, style in
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.createNotebook(
                        title: title,
                        coverColorIndex: colorIndex,
                        coverImageData: photoData,
                        defaultPageStyle: style
                    )
                }
                showCreateSheet = false
            } onCancel: {
                showCreateSheet = false
            }
        }
        // Edit cover sheet
        .sheet(item: $notebookToEditCover) { nb in
            EditCoverSheet(
                notebook: nb,
                onSaveColor: { colorIndex in viewModel.updateCoverColor(colorIndex, for: nb); notebookToEditCover = nil },
                onSavePhoto: { data in viewModel.updateCoverImage(data, for: nb); notebookToEditCover = nil },
                onCancel: { notebookToEditCover = nil }
            )
        }
        // Rename sheet
        .sheet(item: $notebookToRename) { renameSheet($0) }
        // Delete alert
        .alert("Delete Notebook", isPresented: Binding(
            get: { notebookToDelete != nil },
            set: { if !$0 { notebookToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { notebookToDelete = nil }
            Button("Delete", role: .destructive) {
                if let nb = notebookToDelete {
                    withAnimation(.easeOut(duration: 0.2)) {
                        openNotebooks.removeAll { $0.id == nb.id }
                        if selectedNotebook?.id == nb.id { selectedNotebook = nil }
                        viewModel.deleteNotebook(nb)
                    }
                    notebookToDelete = nil
                }
            }
        } message: { Text("\"\(notebookToDelete?.title ?? "")\" will be permanently deleted.") }
        // Error alert
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        ZStack {
            themeManager.background.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    if viewModel.isLoading {
                        ForEach(0..<6, id: \.self) { _ in NotebookCardShimmer() }
                    } else if filteredNotebooks.isEmpty && !searchText.isEmpty {
                        emptySearch.gridCellColumns(columns.count)
                    } else if filteredNotebooks.isEmpty {
                        emptyLibrary.gridCellColumns(columns.count)
                    } else {
                        ForEach(filteredNotebooks) { notebook in
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedNotebook = notebook
                                    if !openNotebooks.contains(where: { $0.id == notebook.id }) {
                                        openNotebooks.append(notebook)
                                    }
                                }
                            } label: {
                                NotebookCardView(
                                    notebook: notebook,
                                    isSelected: selectedNotebook?.id == notebook.id,
                                    onRename: { renameText = notebook.title; notebookToRename = notebook },
                                    onDelete: { notebookToDelete = notebook },
                                    onEditCover: { notebookToEditCover = notebook }
                                )
                            }
                            .buttonStyle(NotebookButtonStyle())
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
            }
        }
        .navigationTitle("InfiniteNote")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search notebooks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.burgundy))
                        .overlay(Circle().strokeBorder(themeManager.outline, lineWidth: 2))
                        .background(Circle().fill(themeManager.hardShadow).offset(x: 2.5, y: 2.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Detail Placeholder

    private var detailPlaceholder: some View {
        ZStack {
            themeManager.background.ignoresSafeArea()
            gridOverlay
            VStack(spacing: 22) {
                Text("∞")
                    .font(.system(size: 96, weight: .black, design: .rounded))
                    .foregroundStyle(Color.burgundy)
                    .rotationEffect(.degrees(-4))
                    .shadow(color: themeManager.hardShadow, radius: 0, x: 5, y: 5)
                VStack(spacing: 6) {
                    Text("InfiniteNote").font(.cartoon(26, weight: .heavy)).foregroundStyle(themeManager.textPrimary)
                    Text("Ideas deserve permanence.").font(.cartoon(15, weight: .medium)).foregroundStyle(themeManager.textSecondary)
                }
                Button { showCreateSheet = true } label: {
                    Text("Create Notebook")
                }
                .buttonStyle(CartoonButtonStyle(fill: .burgundy))
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Empty States

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            CartoonNotebookMark().frame(width: 84, height: 96).padding(.top, 48)
            VStack(spacing: 6) {
                Text("Start your first notebook.").font(.cartoon(18, weight: .heavy)).foregroundStyle(themeManager.textPrimary)
                Text("Create notes, sketches,\nideas and plans.")
                    .font(.cartoon(14, weight: .medium)).foregroundStyle(themeManager.textSecondary).multilineTextAlignment(.center)
            }
            Button { showCreateSheet = true } label: {
                Text("Create Notebook")
            }
            .buttonStyle(CartoonButtonStyle(fill: .burgundy))
            .padding(.top, 4)
        }
        .padding(.bottom, 40)
    }

    private var emptySearch: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(Color.palmLeaf)
                .padding(20)
                .background(Circle().fill(themeManager.card))
                .overlay(Circle().strokeBorder(themeManager.outline, lineWidth: 2.5))
                .background(Circle().fill(themeManager.hardShadow).offset(x: 4, y: 4))
                .padding(.top, 40)
            Text("No notebooks match \"\(searchText)\"").font(.cartoon(15, weight: .semibold)).foregroundStyle(themeManager.textSecondary)
        }
        .padding(.bottom, 40)
    }

    // A pure-shape notebook glyph (no emoji) for the empty library state.
    private struct CartoonNotebookMark: View {
        @EnvironmentObject private var themeManager: ThemeManager
        var body: some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(themeManager.hardShadow).offset(x: 6, y: 6)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.lightBronze)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(themeManager.outline, lineWidth: 3)
                // Spine
                Rectangle().fill(Color.burgundy)
                    .frame(width: 16)
                    .overlay(alignment: .trailing) { Rectangle().fill(themeManager.outline).frame(width: 2.5) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // Page lines
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(themeManager.outline.opacity(0.55)).frame(width: 38, height: 4)
                    }
                }
                .padding(.leading, 30)
                .padding(.top, 26)
            }
        }
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let spacing: CGFloat = 28; let c = themeManager.grid.opacity(0.6)
                var x: CGFloat = 0
                while x <= size.width { ctx.stroke(Path { p in p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)) }, with: .color(c), lineWidth: 0.5); x += spacing }
                var y: CGFloat = 0
                while y <= size.height { ctx.stroke(Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)) }, with: .color(c), lineWidth: 0.5); y += spacing }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: - Rename Sheet

    private func renameSheet(_ notebook: Notebook) -> some View {
        NavigationStack {
            Form {
                Section { TextField("Notebook title", text: $renameText).font(.system(size: 17)) }
                    header: { Text("New Name").foregroundStyle(Color.palmLeaf) }
                    .listRowBackground(themeManager.card)
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.background)
            .navigationTitle("Rename").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { notebookToRename = nil }.foregroundStyle(themeManager.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { viewModel.renameNotebook(notebook, to: renameText); notebookToRename = nil }
                        .fontWeight(.semibold).foregroundStyle(Color.burgundy)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .themeToggleOverlay()
        .presentationDetents([.height(220)])
    }
}
