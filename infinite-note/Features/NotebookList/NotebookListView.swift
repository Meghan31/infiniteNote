import SwiftUI
import PhotosUI

struct NotebookListView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = NotebookListViewModel()
    @State private var selectedNotebook: Notebook?
    @State private var openNotebooks: [Notebook] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @State private var showCreateSheet = false
    @State private var notebookToRename: Notebook?
    @State private var renameText = ""
    @State private var notebookToDelete: Notebook?
    @State private var notebookToEditCover: Notebook?
    @State private var searchText = ""
    @State private var createNotebookTargetFolder: Folder?

    // Folders (homepage)
    @State private var selectedFolder: Folder?
    @State private var showCreateFolderSheet = false
    @State private var createFolderParent: Folder?
    @State private var folderToEdit: Folder?
    @State private var folderToDelete: Folder?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 22)]

    private var filteredNotebooks: [Notebook] {
        guard !searchText.isEmpty else { return viewModel.notebooks }
        return viewModel.notebooks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Folders matching the sidebar search (by name or author).
    private var filteredFolders: [Folder] {
        guard !searchText.isEmpty else { return [] }
        return viewModel.folders.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// Live copy of the selected folder (reflects renames/edits instantly).
    private var liveSelectedFolder: Folder? {
        guard let folder = selectedFolder else { return nil }
        return viewModel.folders.first { $0.id == folder.id } ?? folder
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                // Must be applied to the SIDEBAR column content — this is what
                // actually removes the system sidebar toggle (the blue icon).
                // Our custom book-sidebar button replaces it.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 480)
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
                    },
                    onToggleBooksSidebar: { toggleBooksSidebar() },
                    onSynced: { date in viewModel.applySyncDate(date, to: notebook) },
                    onNotebookChanged: { viewModel.loadNotebooks() }
                )
                .id(notebook.id)
            } else {
                detailPlaceholder
            }
        }
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            viewModel.loadNotebooks()
            // Warm up PencilKit's ink renderer (handwritingd) while the user is
            // still on the home screen, so saved pages render on first open
            // instead of coming up blank on a cold launch.
            InkRenderReadiness.shared.ensureWarmupStarted()
        }
        // The database recovered from its temporary in-memory fallback —
        // reload so the library reappears without a force-quit.
        .onReceive(NotificationCenter.default.publisher(for: DatabaseManager.didReopenNotification)) { _ in
            viewModel.loadNotebooks()
        }
        // Every time the app returns to the foreground, make sure we're on the
        // real on-disk database and re-read the library. Idempotent and cheap.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            DatabaseManager.shared.reopenIfNeeded()
            viewModel.loadNotebooks()
        }
        // Create sheet — uses proper View struct so @State works
        .sheet(isPresented: $showCreateSheet) {
            NotebookCreationSheet { title, colorIndex, photoData, style, pageBackground, description, author in
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.createNotebook(
                        title: title,
                        coverColorIndex: colorIndex,
                        coverImageData: photoData,
                        defaultPageStyle: style,
                        pageBackgroundData: pageBackground,
                        description: description,
                        author: author,
                        in: createNotebookTargetFolder
                    )
                }
                createNotebookTargetFolder = nil
                showCreateSheet = false
            } onCancel: {
                createNotebookTargetFolder = nil
                showCreateSheet = false
            }
        }
        // Create folder sheet
        .sheet(isPresented: $showCreateFolderSheet) {
            FolderCreationSheet { name, colorIndex, imageData, author in
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.createFolder(
                        name: name,
                        colorIndex: colorIndex,
                        imageData: imageData,
                        author: author,
                        parent: createFolderParent
                    )
                }
                createFolderParent = nil
                showCreateFolderSheet = false
            } onCancel: {
                createFolderParent = nil
                showCreateFolderSheet = false
            }
        }
        // Edit folder sheet
        .sheet(item: $folderToEdit) { folder in
            FolderCreationSheet(folder: folder) { name, colorIndex, imageData, author in
                viewModel.updateFolder(folder, name: name, colorIndex: colorIndex, imageData: imageData, author: author)
                folderToEdit = nil
            } onCancel: {
                folderToEdit = nil
            }
        }
        // Delete folder alert
        .alert("Delete Folder", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { folderToDelete = nil }
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let selected = selectedFolder, viewModel.isFolder(selected, inside: folder) {
                            selectedFolder = viewModel.parentFolder(of: folder)
                        }
                        viewModel.deleteFolder(folder)
                    }
                    folderToDelete = nil
                }
            }
        } message: {
            Text("\"\(folderToDelete?.name ?? "")\" and its subfolders will be deleted. The notebooks inside stay in your library.")
        }
        // Edit cover sheet
        .sheet(item: $notebookToEditCover) { nb in
            EditCoverSheet(
                notebook: nb,
                // Every save path also refreshes the open-tab / selection
                // copies (like rename does) — otherwise a notebook open in
                // the editor keeps exporting PDFs with the OLD cover color,
                // description and author until it's reopened.
                onSaveColor: { colorIndex in
                    viewModel.updateCoverColor(colorIndex, for: nb)
                    syncOpenCopies(of: nb.id)
                    notebookToEditCover = nil
                },
                onSavePhoto: { data in
                    viewModel.updateCoverImage(data, for: nb)
                    syncOpenCopies(of: nb.id)
                    notebookToEditCover = nil
                },
                onSaveDetails: { description, author in
                    viewModel.updateDetails(description: description, author: author, for: nb)
                    syncOpenCopies(of: nb.id)
                },
                onCancel: { notebookToEditCover = nil }
            )
        }
        // Rename sheet
        .sheet(item: $notebookToRename) { renameSheet($0) }
        // Delete flow — options depend on whether the notebook is synced.
        .confirmationDialog(
            "Delete \"\(notebookToDelete?.title ?? "")\"?",
            isPresented: Binding(
                get: { notebookToDelete != nil },
                set: { if !$0 { notebookToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let nb = notebookToDelete {
                if nb.lastSyncedAt != nil {
                    // Synced → choose whether the cloud copy survives.
                    Button("Delete Locally (Keep Cloud Copy)", role: .destructive) {
                        closeIfOpen(nb)
                        viewModel.deleteNotebook(nb)
                        notebookToDelete = nil
                    }
                    Button("Delete Locally & Unsync", role: .destructive) {
                        closeIfOpen(nb)
                        Task { await viewModel.deleteAndUnsync(nb) }
                        notebookToDelete = nil
                    }
                } else {
                    // Unsynced → offer a cloud backup before deleting.
                    Button("Sync to Cloud, Then Delete Locally") {
                        closeIfOpen(nb)
                        Task { await viewModel.syncThenDeleteLocally(nb) }
                        notebookToDelete = nil
                    }
                    Button("Delete Permanently", role: .destructive) {
                        closeIfOpen(nb)
                        viewModel.deleteNotebook(nb)
                        notebookToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { notebookToDelete = nil }
            }
        } message: {
            if notebookToDelete?.lastSyncedAt != nil {
                Text("This notebook is synced. You can keep its cloud copy or remove it everywhere.")
            } else {
                Text("This notebook is not synced. You can back it up to the cloud first, or delete it permanently.")
            }
        }
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
                VStack(alignment: .leading, spacing: 0) {
                    // Folder matches appear above notebooks when searching.
                    if !filteredFolders.isEmpty {
                        folderSearchResults
                    }
                    LazyVGrid(columns: columns, spacing: 22) {
                        if viewModel.isLoading {
                            ForEach(0..<6, id: \.self) { _ in NotebookCardShimmer() }
                        } else if filteredNotebooks.isEmpty && !searchText.isEmpty {
                            if filteredFolders.isEmpty {
                                emptySearch.gridCellColumns(columns.count)
                            }
                        } else if filteredNotebooks.isEmpty {
                            emptyLibrary.gridCellColumns(columns.count)
                        } else {
                            ForEach(filteredNotebooks) { notebook in
                                Button {
                                    openNotebook(notebook)
                                } label: {
                                    NotebookCardView(
                                        notebook: notebook,
                                        isSelected: selectedNotebook?.id == notebook.id,
                                        onRename: { renameText = notebook.title; notebookToRename = notebook },
                                        onDelete: { notebookToDelete = notebook },
                                        onEditCover: { notebookToEditCover = notebook },
                                        folders: viewModel.folders,
                                        isInFolder: { viewModel.isNotebook(notebook, in: $0) },
                                        onToggleFolder: { viewModel.toggleNotebook(notebook, in: $0) },
                                        onTogglePin: { withAnimation(.easeOut(duration: 0.2)) { viewModel.togglePin(notebook) } }
                                    )
                                }
                                .buttonStyle(NotebookButtonStyle())
                                .overlay(alignment: .topTrailing) {
                                    HStack(spacing: 5) {
                                        if let synced = notebook.lastSyncedAt {
                                            NotebookSyncBadge(date: synced)
                                        }
                                        NotebookCardMenuButton(
                                            folders: viewModel.folders,
                                            isSynced: notebook.lastSyncedAt != nil,
                                            isPinned: notebook.isPinned,
                                            isInFolder: { viewModel.isNotebook(notebook, in: $0) },
                                            onToggleFolder: { viewModel.toggleNotebook(notebook, in: $0) },
                                            onUnsync: { Task { await viewModel.unsync(notebook) } },
                                            onDelete: { notebookToDelete = notebook },
                                            onTogglePin: { withAnimation(.easeOut(duration: 0.2)) { viewModel.togglePin(notebook) } }
                                        )
                                    }
                                    .offset(x: 7, y: -9)
                                }
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("InfiniteNote")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search notebooks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { startCreateNotebook() } label: {
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
            if let folder = liveSelectedFolder {
                folderDetail(folder)
            } else {
                homeContent
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                JigglingIconButton(duration: 0.2, action: { toggleBooksSidebar() }) {
                    AssetIcon(
                        asset: "book-sidebar",
                        systemName: "sidebar.left",
                        size: 34,
                        fallbackTint: themeManager.iconTint
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle books sidebar")

                // ☀/🌙 — next to the book-sidebar icon (was a floating
                // overlay that covered the folder edit button).
                ThemeToggleButton(size: 38)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .background(SidebarToggleHider().frame(width: 0, height: 0))
    }

    private func toggleBooksSidebar() {
        withAnimation(.easeOut(duration: 0.22)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// Closes a notebook's editor tab before it gets deleted.
    private func closeIfOpen(_ notebook: Notebook) {
        withAnimation(.easeOut(duration: 0.2)) {
            openNotebooks.removeAll { $0.id == notebook.id }
            if selectedNotebook?.id == notebook.id { selectedNotebook = nil }
        }
    }

    /// Refreshes the value copies that drive the editor (open tabs + current
    /// selection) from the view model, so edits like a rename show up in the
    /// tab bar and navigation title without reopening the notebook.
    private func syncOpenCopies(of notebookId: String) {
        guard let fresh = viewModel.notebooks.first(where: { $0.id == notebookId }) else { return }
        if let idx = openNotebooks.firstIndex(where: { $0.id == notebookId }) {
            openNotebooks[idx] = fresh
        }
        if selectedNotebook?.id == notebookId { selectedNotebook = fresh }
    }

    /// Opens a notebook in the editor (from the sidebar, a folder, or search).
    private func openNotebook(_ notebook: Notebook) {
        withAnimation(.easeOut(duration: 0.2)) {
            selectedNotebook = notebook
            if !openNotebooks.contains(where: { $0.id == notebook.id }) {
                openNotebooks.append(notebook)
            }
        }
    }

    private func startCreateNotebook(in folder: Folder? = nil) {
        createNotebookTargetFolder = folder
        showCreateSheet = true
    }

    private func startCreateFolder(in parent: Folder? = nil) {
        createFolderParent = parent
        showCreateFolderSheet = true
    }

    // MARK: - Homepage (hero + folders)

    private var homeContent: some View {
        ScrollView {
            VStack(spacing: 34) {
                // Brand hero
                VStack(spacing: 18) {
                    Text("∞")
                        .font(.system(size: 84, weight: .black, design: .rounded))
                        .foregroundStyle(Color.burgundy)
                        .rotationEffect(.degrees(-4))
                        .shadow(color: themeManager.hardShadow, radius: 0, x: 5, y: 5)
                    VStack(spacing: 6) {
                        Text("InfiniteNote").font(.cartoon(26, weight: .heavy)).foregroundStyle(themeManager.textPrimary)
                        Text("Ideas deserve permanence.").font(.cartoon(15, weight: .medium)).foregroundStyle(themeManager.textSecondary)
                    }
                    Button { startCreateNotebook() } label: {
                        Text("Create Notebook")
                    }
                    .buttonStyle(CartoonButtonStyle(fill: .burgundy))
                }
                .padding(.top, 46)

                foldersSection
            }
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
    }

    private var foldersSection: some View {
        let rootFolders = viewModel.rootFolders()
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Folders")
                    .font(.cartoon(22, weight: .heavy))
                    .foregroundStyle(themeManager.textPrimary)
                Spacer()
                Button { startCreateFolder() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 14, weight: .black))
                        Text("New Folder").font(.cartoon(14, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15).padding(.vertical, 9)
                    .background(Capsule().fill(Color.palmLeafDark))
                    .overlay(Capsule().strokeBorder(themeManager.outline, lineWidth: 2))
                    .background(Capsule().fill(themeManager.hardShadow).offset(x: 2.5, y: 2.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New folder")
            }
            .padding(.horizontal, 30)

            if rootFolders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                    Text("No folders yet")
                        .font(.cartoon(15, weight: .bold)).foregroundStyle(themeManager.textSecondary)
                    Text("Create folders, then add notebooks\nor nested folders inside them.")
                        .font(.cartoon(12.5, weight: .medium))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 185), spacing: 18)], spacing: 26) {
                    ForEach(rootFolders) { folder in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { selectedFolder = folder }
                        } label: {
                            FolderIconView(folder: folder, count: viewModel.itemCount(in: folder))
                        }
                        .buttonStyle(NotebookButtonStyle())
                        .contextMenu {
                            Button { withAnimation(.easeOut(duration: 0.2)) { viewModel.togglePin(folder) } } label: {
                                Label(folder.isPinned ? "Unpin" : "Pin Folder",
                                      systemImage: folder.isPinned ? "pin.slash" : "pin")
                            }
                            Button { folderToEdit = folder } label: { Label("Edit Folder", systemImage: "pencil") }
                            Divider()
                            Button(role: .destructive) { folderToDelete = folder } label: { Label("Delete Folder", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: 760)
    }

    // MARK: - Folder Detail (inline on the homepage)

    private func folderDetail(_ folder: Folder) -> some View {
        let childFolders = viewModel.childFolders(in: folder)
        let notebooks = viewModel.notebooks(in: folder)
        let folderCount = childFolders.count
        let notebookCount = viewModel.notebookCount(in: folder)
        let parent = viewModel.parentFolder(of: folder)
        return VStack(spacing: 0) {
            // Header: back, folder identity, edit shortcut
            HStack(spacing: 14) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selectedFolder = parent }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .black))
                        Text(parent?.name ?? "Home").font(.cartoon(15, weight: .bold))
                    }
                    .foregroundStyle(themeManager.iconTint)
                    .padding(.vertical, 6).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.notebookCover(at: folder.colorIndex))
                    .shadow(color: themeManager.hardShadow, radius: 0, x: 2.5, y: 2.5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.cartoon(22, weight: .heavy))
                        .foregroundStyle(themeManager.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let author = folder.author, !author.isEmpty {
                            Text("by \(author)")
                                .font(.cartoon(12.5, weight: .semibold))
                                .foregroundStyle(themeManager.textSecondary)
                        }
                        Text(folderSummary(folderCount: folderCount, notebookCount: notebookCount))
                            .font(.cartoon(12.5, weight: .semibold))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                }
                Spacer()
                Menu {
                    Button {
                        startCreateNotebook(in: folder)
                    } label: {
                        Label("Create Notebook", systemImage: "book.closed.fill")
                    }
                    Button {
                        startCreateFolder(in: folder)
                    } label: {
                        Label("Create Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.burgundy))
                        .overlay(Circle().strokeBorder(themeManager.outline, lineWidth: 2))
                        .background(Circle().fill(themeManager.hardShadow).offset(x: 2, y: 2))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Create in folder")

                Button { folderToEdit = folder } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(themeManager.iconTint)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(themeManager.card))
                        .overlay(Circle().strokeBorder(themeManager.outline, lineWidth: 2))
                        .background(Circle().fill(themeManager.hardShadow).offset(x: 2, y: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit folder")
            }
            .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 14)

            if childFolders.isEmpty && notebooks.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(Color.notebookCover(at: folder.colorIndex).opacity(0.7))
                    Text("This folder is empty")
                        .font(.cartoon(17, weight: .heavy)).foregroundStyle(themeManager.textPrimary)
                    Text("Use the + button to create a notebook\nor another folder here.")
                        .font(.cartoon(13.5, weight: .medium))
                        .foregroundStyle(themeManager.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !childFolders.isEmpty {
                            folderDetailSectionTitle("Folders")
                                .padding(.horizontal, 26)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 185), spacing: 18)], spacing: 26) {
                                ForEach(childFolders) { child in
                                    Button {
                                        withAnimation(.easeOut(duration: 0.2)) { selectedFolder = child }
                                    } label: {
                                        FolderIconView(folder: child, count: viewModel.itemCount(in: child))
                                    }
                                    .buttonStyle(NotebookButtonStyle())
                                    .contextMenu {
                                        Button {
                                            withAnimation(.easeOut(duration: 0.2)) { viewModel.togglePin(child) }
                                        } label: {
                                            Label(child.isPinned ? "Unpin" : "Pin Folder",
                                                  systemImage: child.isPinned ? "pin.slash" : "pin")
                                        }
                                        Button { folderToEdit = child } label: {
                                            Label("Edit Folder", systemImage: "pencil")
                                        }
                                        Divider()
                                        Button(role: .destructive) { folderToDelete = child } label: {
                                            Label("Delete Folder", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 26)
                        }

                        if !notebooks.isEmpty {
                            folderDetailSectionTitle("Notebooks")
                                .padding(.horizontal, 26)

                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(notebooks) { notebook in
                                    Button {
                                        openNotebook(notebook)
                                    } label: {
                                        NotebookCardView(
                                            notebook: notebook,
                                            isSelected: false,
                                            onRename: { renameText = notebook.title; notebookToRename = notebook },
                                            onDelete: { notebookToDelete = notebook },
                                            onEditCover: { notebookToEditCover = notebook },
                                            onRemoveFromFolder: {
                                                withAnimation(.easeOut(duration: 0.2)) {
                                                    viewModel.removeNotebook(notebook, from: folder)
                                                }
                                            },
                                            onTogglePin: { withAnimation(.easeOut(duration: 0.2)) { viewModel.togglePin(notebook) } }
                                        )
                                    }
                                    .buttonStyle(NotebookButtonStyle())
                                    .overlay(alignment: .topTrailing) {
                                        if let synced = notebook.lastSyncedAt {
                                            NotebookSyncBadge(date: synced).offset(x: 7, y: -9)
                                        }
                                    }
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, 26)
                        }
                    }
                    .padding(.top, 10).padding(.bottom, 32)
                }
            }
        }
    }

    private func folderSummary(folderCount: Int, notebookCount: Int) -> String {
        let folders = "\(folderCount) \(folderCount == 1 ? "folder" : "folders")"
        let notebooks = "\(notebookCount) \(notebookCount == 1 ? "notebook" : "notebooks")"
        return "\(folders) · \(notebooks)"
    }

    private func folderDetailSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.cartoon(15, weight: .heavy))
            .foregroundStyle(themeManager.textSecondary)
    }

    // MARK: - Folder Search Results (sidebar)

    private var folderSearchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FOLDERS")
                .font(.cartoon(12, weight: .heavy))
                .foregroundStyle(themeManager.textSecondary)
                .padding(.horizontal, 24)
            ForEach(filteredFolders) { folder in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedFolder = folder
                        selectedNotebook = nil
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.notebookCover(at: folder.colorIndex))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(folder.name)
                                .font(.cartoon(15, weight: .bold))
                                .foregroundStyle(themeManager.textPrimary)
                                .lineLimit(1)
                            if let author = folder.author, !author.isEmpty {
                                Text("by \(author)")
                                    .font(.cartoon(11, weight: .medium))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("\(viewModel.itemCount(in: folder))")
                            .font(.cartoon(12, weight: .heavy))
                            .foregroundStyle(themeManager.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(themeManager.card))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(themeManager.border, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !filteredNotebooks.isEmpty {
                Text("NOTEBOOKS")
                    .font(.cartoon(12, weight: .heavy))
                    .foregroundStyle(themeManager.textSecondary)
                    .padding(.horizontal, 24).padding(.top, 8)
            }
        }
        .padding(.top, 12)
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
            Button { startCreateNotebook() } label: {
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
                    Button("Save") {
                        viewModel.renameNotebook(notebook, to: renameText)
                        // Keep the open tab + nav title in sync — these are
                        // value copies that a rename doesn't reach on its own.
                        syncOpenCopies(of: notebook.id)
                        notebookToRename = nil
                    }
                    .fontWeight(.semibold).foregroundStyle(Color.burgundy)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .themeToggleOverlay()
        .presentationDetents([.height(220)])
    }
}
