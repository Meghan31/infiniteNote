import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

struct NotebookEditorView: View {
    let notebook: Notebook
    let openNotebooks: [Notebook]
    let onSelectNotebook: (Notebook) -> Void
    let onCloseNotebook: (Notebook) -> Void
    let onGoHome: () -> Void
    let onToggleBooksSidebar: () -> Void
    var onSynced: (Date) -> Void = { _ in }

    @State private var viewModel: NotebookEditorViewModel
    @State private var showSyncSheet = false
    @State private var showPageSidebar = true
    /// Read-only mode: drawing/editing disabled; pages turn with 3-finger
    /// horizontal swipes; the toolbar collapses to just the read-mode icon.
    @State private var isReadOnly = false

    // Drawing tool state
    @State private var selectedTool: DrawingToolType = .pen
    /// Default ink is black. PencilKit renders it black on a white (light)
    /// page and automatically inverts it to white on a black (dark) page,
    /// because the canvas's interface style is pinned to our theme.
    @State private var selectedColor: Color = .black
    @State private var toolSizes: [DrawingToolType: CGFloat] = [
        .pen: 3, .marker: 15, .highlighter: 25, .eraser: 20
    ]
    @State private var showColorPicker = false
    @State private var showErasePageConfirm = false
    @State private var showMoreTools = false

    // Page style
    @State private var showStylePicker = false
    @State private var pageStylePhotoItem: PhotosPickerItem?

    // Home alert
    @State private var showHomeAlert = false

    // Page-swipe hint + new-page double-swipe window
    @State private var pageHintText: String?
    @State private var hintToken = 0
    @State private var lastEndSwipeUpTime: Date?

    // PDF export / share
    @State private var showShareSheet = false
    @State private var sharePDFURL: URL?
    @State private var showPDFExporter = false
    @State private var exportDocument: PDFExportDocument?

    @EnvironmentObject private var themeManager: ThemeManager

    /// Swatches shown in the color popover. Black leads (it auto-inverts to
    /// white on a dark page); the rest are vivid hues that read on both
    /// white and black pages.
    private let presetColors: [Color] = [
        .black,
        Color(red: 0.93, green: 0.19, blue: 0.27),
        Color(red: 1.00, green: 0.58, blue: 0.00),
        Color(red: 0.97, green: 0.84, blue: 0.00),
        Color(red: 0.09, green: 0.72, blue: 0.40),
        Color(red: 0.00, green: 0.68, blue: 0.78),
        Color(red: 0.20, green: 0.45, blue: 0.90),
        Color(red: 0.43, green: 0.22, blue: 0.84),
        Color(red: 0.96, green: 0.33, blue: 0.61),
        Color(red: 0.60, green: 0.34, blue: 0.12),
    ]

    private let primaryTools: [DrawingToolType] = [.pen, .fountainPen, .eraser]
    private var remainingTools: [DrawingToolType] {
        DrawingToolType.allCases.filter { !primaryTools.contains($0) }
    }

    init(
        notebook: Notebook,
        openNotebooks: [Notebook] = [],
        onSelectNotebook: @escaping (Notebook) -> Void = { _ in },
        onCloseNotebook: @escaping (Notebook) -> Void = { _ in },
        onGoHome: @escaping () -> Void = {},
        onToggleBooksSidebar: @escaping () -> Void = {},
        onSynced: @escaping (Date) -> Void = { _ in }
    ) {
        self.notebook = notebook
        self.openNotebooks = openNotebooks
        self.onSelectNotebook = onSelectNotebook
        self.onCloseNotebook = onCloseNotebook
        self.onGoHome = onGoHome
        self.onToggleBooksSidebar = onToggleBooksSidebar
        self.onSynced = onSynced
        self._viewModel = State(initialValue: NotebookEditorViewModel(notebook: notebook))
    }

    private var currentSize: CGFloat { toolSizes[selectedTool] ?? selectedTool.defaultSize }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            fileTabBar

            // Pen + undo toolbar now lives at the TOP of the notes area.
            drawingToolbar

            HStack(spacing: 0) {
                if showPageSidebar {
                    pageSidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack(alignment: .leading) {
                    canvasBackground
                    DrawingCanvasView(
                        drawing: Binding(get: { viewModel.drawing }, set: { viewModel.onDrawingChanged($0) }),
                        isRulerActive: viewModel.isRulerActive,
                        toolType: selectedTool,
                        color: UIColor(selectedColor),
                        lineWidth: currentSize,
                        isDarkTheme: themeManager.isDark,
                        isReadOnly: isReadOnly,
                        canvasController: viewModel.canvasController,
                        onErasePage: { showErasePageConfirm = true },
                        onNextPage: { handleSwipeUpNext() },     // 3-finger up / read-only swipe left
                        onPrevPage: { handleSwipeDownPrev() }    // 3-finger down / read-only swipe right
                    )
                    pageFooter
                    if let hint = pageHintText {
                        pageHintBubble(hint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .allowsHitTesting(false)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
        }
        .background(themeManager.background)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { editorToolbar }
        .toolbar(removing: .sidebarToggle)
        .background(SidebarToggleHider().frame(width: 0, height: 0))
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.saveCurrentDrawing() }
        .sheet(isPresented: $showSyncSheet) {
            SyncView(
                notebook: notebook,
                canvasSize: viewModel.canvasController.canvasView?.bounds.size,
                onSynced: onSynced
            )
        }
        // Share the notebook PDF to other apps.
        .sheet(isPresented: $showShareSheet) {
            if let url = sharePDFURL { ShareSheet(items: [url]) }
        }
        // Download / save the notebook PDF to Files.
        .fileExporter(
            isPresented: $showPDFExporter,
            document: exportDocument,
            contentType: .pdf,
            defaultFilename: notebook.title.sanitizedFilename
        ) { result in
            if case .failure(let error) = result { viewModel.errorMessage = error.localizedDescription }
        }
        .onChange(of: pageStylePhotoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    viewModel.setPageStyle(.photo, backgroundImageData: data)
                }
                pageStylePhotoItem = nil
            }
        }
        .confirmationDialog("Erase this page?", isPresented: $showErasePageConfirm, titleVisibility: .visible) {
            Button("Erase Page", role: .destructive) { viewModel.eraseCurrentPage() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("All strokes on this page will be removed.") }
        .alert("Close all files?", isPresented: $showHomeAlert) {
            Button("Close All", role: .destructive) { onGoHome() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Going home will close all open files.") }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    // MARK: - File Tab Bar

    private var fileTabBar: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(themeManager.border.opacity(0.6)).frame(height: 0.5).frame(maxHeight: .infinity, alignment: .bottom)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { showHomeAlert = true } label: {
                        AssetIcon(
                            asset: themeManager.isDark ? "home-white" : "home",
                            systemName: "house.fill",
                            size: 30,
                            fallbackTint: themeManager.iconTint,
                            symbolWeight: .bold
                        )
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Home")
                    if !openNotebooks.isEmpty {
                        RoundedRectangle(cornerRadius: 1).fill(themeManager.border).frame(width: 1, height: 16)
                    }
                    ForEach(openNotebooks) { nb in fileTab(for: nb) }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(height: 50)
    }

    private func fileTab(for nb: Notebook) -> some View {
        let isActive = nb.id == notebook.id
        let accent = Color.notebookCover(at: nb.coverColorIndex)
        return HStack(spacing: 0) {
            Button { onSelectNotebook(nb) } label: {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                        .shadow(color: accent.opacity(0.5), radius: isActive ? 3 : 0)
                    Text(nb.title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(isActive ? themeManager.textPrimary : themeManager.textSecondary)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            Button { onCloseNotebook(nb) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isActive ? themeManager.textPrimary.opacity(0.45) : themeManager.textSecondary.opacity(0.35))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(themeManager.border.opacity(isActive ? 0.55 : 0.35)))
            }
            .buttonStyle(.plain).padding(.trailing, 8)
        }
        .background(
            // Selected tab → palmLeafDark (hover/selected states rule)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color.palmLeafDark.opacity(themeManager.isDark ? 0.28 : 0.16) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isActive ? accent.opacity(0.35) : Color.clear, lineWidth: 1))
        )
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    // MARK: - Drawing Toolbar

    private var drawingToolbar: some View {
        VStack(spacing: 0) {
            if isReadOnly {
                // Read-only: everything in this bar is hidden except the
                // read-mode icon, which exits back to editing.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    readOnlyToggleButton.padding(.trailing, 4)
                }
                .frame(height: 62)
                .background(themeManager.card)
            } else {
                editingToolbarRow
            }

            // Heavy ink rule under the bar — it sits at the top of the page now.
            Rectangle().fill(themeManager.outline).frame(height: 2)
        }
        .animation(.easeOut(duration: 0.2), value: isReadOnly)
    }

    private var editingToolbarRow: some View {
        HStack(spacing: 0) {
                // Sidebar toggle.
                Button { withAnimation(.easeOut(duration: 0.22)) { showPageSidebar.toggle() } } label: {
                    AssetIcon(
                        asset: themeManager.isDark ? "page-sidebar-white" : "page-sidebar",
                        systemName: showPageSidebar ? "sidebar.squares.left" : "sidebar.left",
                        size: 35,
                        fallbackTint: themeManager.iconTint,
                        addsDepth: false
                    )
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.leading, 4)
                .accessibilityLabel("Toggle page sidebar")

                toolbarDivider

                // Tool selector — the full pen set
                toolKitCapsule

                toolbarDivider

                // Color (ink tools only)
                if selectedTool.isInk { colorPickerButton; toolbarDivider }

                // Size
                sizeSliderSection

                Spacer(minLength: 0)

                toolbarDivider

                // Page style
                Button { showStylePicker.toggle() } label: {
                    Image(systemName: viewModel.currentPageStyle.systemImage)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(themeManager.iconTint)
                        .frame(width: 42, height: 44)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStylePicker, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { pageStylePopover }

                toolbarDivider

                // Undo / Redo + read-only toggle
                HStack(spacing: 0) {
                    toolbarActionButton(icon: "arrow.uturn.backward") { viewModel.undo() }
                    toolbarActionButton(icon: "arrow.uturn.forward")  { viewModel.redo() }
                    readOnlyToggleButton
                }
                .padding(.trailing, 4)
        }
        .frame(height: 62)
        .background(themeManager.card)
    }

    /// Enters / exits read-only mode. Active state sits on a sage chip with
    /// the cartoon hard shadow, like a selected tool.
    private var readOnlyToggleButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isReadOnly.toggle() }
        } label: {
            Image(systemName: isReadOnly ? "eye.fill" : "eye")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isReadOnly ? themeManager.outline : themeManager.iconTint)
                .frame(width: 39, height: 39)
                .background(
                    Circle().fill(isReadOnly ? themeManager.selectionColor : Color.clear)
                )
                .background(
                    Circle()
                        .fill(isReadOnly ? themeManager.hardShadow.opacity(0.28) : Color.clear)
                        .offset(x: 2, y: 2.5)
                )
                .contentShape(Circle())
                .frame(width: 42, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReadOnly ? "Exit read-only mode" : "Read-only mode")
    }

    // MARK: - Page Style Popover

    private var pageStylePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Page Style")
                .font(.cartoon(14, weight: .heavy)).foregroundStyle(themeManager.iconTint)
            let nonPhotoStyles: [PageStyle] = [.plain, .ruled, .dots, .grid]
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(nonPhotoStyles, id: \.self) { styleCard($0) }
            }
            Divider()
            PhotosPicker(selection: $pageStylePhotoItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 15, weight: .semibold)).foregroundStyle(themeManager.iconTint)
                    Text("Import Photo as Background")
                        .font(.cartoon(13, weight: .semibold)).foregroundStyle(themeManager.iconTint)
                    Spacer()
                    if viewModel.currentPageStyle == .photo {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(themeManager.iconTint)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(themeManager.selectionColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(viewModel.currentPageStyle == .photo ? themeManager.selectionColor : Color.clear, lineWidth: 2)))
            }
            .buttonStyle(.plain)
            .onChange(of: pageStylePhotoItem) { _, _ in showStylePicker = false }
        }
        .padding(16).frame(width: 280)
        .modifier(ForcePopoverAdaptation())
    }

    private func styleCard(_ style: PageStyle) -> some View {
        let isSelected = viewModel.currentPageStyle == style
        return Button {
            viewModel.setPageStyle(style)
            showStylePicker = false
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(themeManager.page)
                        .frame(height: 56)
                    pageStylePreview(style).frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? themeManager.selectionColor : themeManager.border,
                                  lineWidth: isSelected ? 2.5 : 0.5))
                Text(style.label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? themeManager.selectionColor : themeManager.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pageStylePreview(_ style: PageStyle) -> some View {
        let gridColor = themeManager.grid
        Canvas { ctx, size in
            switch style {
            case .plain: break
            case .ruled:
                var y: CGFloat = 9
                while y < size.height {
                    let p = Path { q in q.move(to: .init(x: 5, y: y)); q.addLine(to: .init(x: size.width - 3, y: y)) }
                    ctx.stroke(p, with: .color(gridColor.opacity(0.8)), lineWidth: 0.6)
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
                    let p = Path { q in q.move(to: .init(x: x, y: 0)); q.addLine(to: .init(x: x, y: size.height)) }
                    ctx.stroke(p, with: .color(gridColor.opacity(0.7)), lineWidth: 0.4)
                    x += 9
                }
                var y: CGFloat = 9
                while y < size.height {
                    let p = Path { q in q.move(to: .init(x: 0, y: y)); q.addLine(to: .init(x: size.width, y: y)) }
                    ctx.stroke(p, with: .color(gridColor.opacity(0.7)), lineWidth: 0.4)
                    y += 9
                }
            case .photo: break
            }
        }
    }

    // MARK: - Canvas Background

    private var canvasBackground: some View {
        GeometryReader { geo in
            ZStack {
                // Notebook page — pure white (light) / pure black (dark)
                themeManager.page
                if viewModel.currentPageStyle == .photo, let img = viewModel.pageBackgroundImage {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped().opacity(0.35)
                } else {
                    Canvas { ctx, size in
                        let style = viewModel.currentPageStyle
                        let spacing: CGFloat = 28
                        let faint = themeManager.grid.opacity(themeManager.isDark ? 0.55 : 0.65)
                        let major = themeManager.grid.opacity(themeManager.isDark ? 0.28 : 0.32)
                        switch style {
                        case .plain:
                            break
                        case .ruled:
                            let margin: CGFloat = 64
                            ctx.stroke(Path { p in p.move(to: .init(x: margin, y: 0)); p.addLine(to: .init(x: margin, y: size.height)) },
                                       with: .color(themeManager.iconTint.opacity(0.35)), lineWidth: 0.6)
                            var y: CGFloat = spacing
                            while y <= size.height {
                                ctx.stroke(Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)) },
                                           with: .color(faint), lineWidth: 0.4)
                                y += spacing
                            }
                        case .dots:
                            var y: CGFloat = spacing
                            while y <= size.height {
                                var x: CGFloat = spacing
                                while x <= size.width {
                                    ctx.fill(Path(ellipseIn: CGRect(x: x-1, y: y-1, width: 2, height: 2)), with: .color(faint))
                                    x += spacing
                                }
                                y += spacing
                            }
                        case .grid, .photo:
                            var x: CGFloat = 0
                            while x <= size.width {
                                let isMajor = Int(x / spacing) % 4 == 0
                                ctx.stroke(Path { p in p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)) },
                                           with: .color(isMajor ? major : faint), lineWidth: isMajor ? 0.75 : 0.4)
                                x += spacing
                            }
                            var y: CGFloat = 0
                            while y <= size.height {
                                let isMajor = Int(y / spacing) % 4 == 0
                                ctx.stroke(Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)) },
                                           with: .color(isMajor ? major : faint), lineWidth: isMajor ? 0.75 : 0.4)
                                y += spacing
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Page Footer

    private var pageFooter: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                // Current page indicator
                Text("Page \(viewModel.currentPageIndex + 1) of \(viewModel.pages.count)")
                    .font(.cartoon(12, weight: .bold)).foregroundStyle(themeManager.outline)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Capsule().fill(themeManager.selectionColor))
                    .overlay(Capsule().strokeBorder(themeManager.outline, lineWidth: 1.5))
                    .padding(16)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Page Sidebar

    private var pageSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.22)) { showPageSidebar = false } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(themeManager.iconTint).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                Button { viewModel.addPage() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .black))
                        .foregroundStyle(themeManager.iconTint)
                        .frame(width: 24, height: 24)
                        .background(themeManager.iconTint.opacity(0.14)).clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)

            Divider().background(themeManager.border)

            // Scrollable page list with drag-to-reorder
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnailView(
                            page: page,
                            pageNumber: index + 1,
                            isSelected: viewModel.currentPageIndex == index,
                            accentColor: Color.notebookCover(at: notebook.coverColorIndex),
                            refreshToken: viewModel.refreshToken(for: page),
                            drawingService: DrawingService.shared,
                            canvasSize: viewModel.canvasController.canvasView?.bounds.size,
                            onThumbnailReady: { img in viewModel.storeThumbnail(img, for: page.id) }
                        ) {
                            withAnimation(.easeOut(duration: 0.2)) { viewModel.goToPage(at: index) }
                        } onDelete: {
                            withAnimation(.easeOut(duration: 0.2)) { viewModel.deletePage(at: index) }
                        }
                        .id(index)
                        .listRowInsets(.init(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.currentPageIndex) { _, idx in
                    withAnimation { proxy.scrollTo(idx, anchor: .center) }
                }
            }

            Divider().background(themeManager.border)
            Text("\(viewModel.pages.count) \(viewModel.pages.count == 1 ? "page" : "pages")")
                .font(.system(size: 11)).foregroundStyle(themeManager.textSecondary).padding(.vertical, 8)
        }
        .frame(width: 114)
        .background(themeManager.card)
        .overlay(alignment: .trailing) { Divider().background(themeManager.border) }
    }

    // MARK: - Toolbar Subviews

    private var toolKitCapsule: some View {
        HStack(spacing: 4) {
            ForEach(primaryTools, id: \.self) { toolButton($0, closesMoreTools: showMoreTools) }
            moreToolsButton
            if showMoreTools {
                ForEach(remainingTools, id: \.self) { toolButton($0, closesMoreTools: true) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(themeManager.card)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(themeManager.isDark ? 0.14 : 0.75),
                                    Color.clear,
                                    Color.black.opacity(themeManager.isDark ? 0.26 : 0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(themeManager.isDark ? 0.24 : 0.85),
                            themeManager.outline.opacity(themeManager.isDark ? 0.58 : 0.26)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.6
                )
        )
        .background(
            Capsule(style: .continuous)
                .fill(themeManager.hardShadow.opacity(themeManager.isDark ? 0.62 : 0.24))
                .offset(x: 3.5, y: 4.5)
        )
        .shadow(color: .black.opacity(themeManager.isDark ? 0.34 : 0.16), radius: 5, x: 1.5, y: 3)
        .padding(.horizontal, 8)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: showMoreTools)
    }

    private var moreToolsButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                showMoreTools.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(themeManager.iconTint)
                .rotationEffect(.degrees(showMoreTools ? 180 : 0))
                .frame(width: 39, height: 39)
                .background(
                    Circle()
                        .fill(showMoreTools ? themeManager.selectionColor : Color.clear)
                )
                .background(
                    Circle()
                        .fill(showMoreTools ? themeManager.hardShadow.opacity(0.28) : Color.clear)
                        .offset(x: 2, y: 2.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More drawing tools")
    }

    private func toolButton(_ tool: DrawingToolType, closesMoreTools: Bool = false) -> some View {
        let isSelected = selectedTool == tool
        // One universal icon tint; the selected tool gets a circular chip.
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                selectedTool = tool
                if closesMoreTools { showMoreTools = false }
            }
        } label: {
            toolGlyph(tool, isSelected: isSelected)
                .frame(width: 39, height: 39)
                .background(
                    Circle()
                        .fill(isSelected ? themeManager.selectionColor : Color.clear)
                )
                .background(
                    Circle()
                        .fill(isSelected ? themeManager.hardShadow.opacity(0.28) : Color.clear)
                        .offset(x: 2, y: 2.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private var exportActionsCapsule: some View {
        HStack(spacing: 2) {
            Button { downloadPDF() } label: {
                capsuleActionIcon(asset: themedActionAsset("download"), systemName: "arrow.down.circle", size: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download PDF")

            Button { sharePDF() } label: {
                capsuleActionIcon(asset: themedActionAsset("share"), systemName: "square.and.arrow.up", size: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share PDF")

            Button {
                // Persist in-flight strokes so the synced PDF is current.
                viewModel.saveCurrentDrawing()
                showSyncSheet = true
            } label: {
                capsuleActionIcon(asset: themedActionAsset("sync"), systemName: "icloud.and.arrow.up", size: 33)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sync notebook")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    themeManager.outline.opacity(themeManager.isDark ? 0.5 : 0.26),
                    lineWidth: 1.25
                )
        )
    }

    private func themedActionAsset(_ name: String) -> String {
        "\(name)-\(themeManager.isDark ? "dark" : "light")"
    }

    private func capsuleActionIcon(asset: String, systemName: String, size: CGFloat) -> some View {
        AssetIcon(
            asset: asset,
            systemName: systemName,
            size: size,
            fallbackTint: themeManager.iconTint,
            addsDepth: false
        )
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }

    /// Uses the downloaded full-color tool artwork when present (always shown in
    /// full color — no silhouette), otherwise an SF Symbol. The selected tool
    /// sits on a sage chip, so the SF fallback uses the dark ink color for
    /// contrast.
    @ViewBuilder
    private func toolGlyph(_ tool: DrawingToolType, isSelected: Bool) -> some View {
        if UIImage(named: tool.assetName) != nil {
            Image(tool.assetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 25, height: 25)
        } else {
            Image(systemName: tool.systemImage)
                .font(.system(size: 17, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? themeManager.outline : themeManager.iconTint)
        }
    }

    private var colorPickerButton: some View {
        Button { showColorPicker.toggle() } label: {
            ZStack {
                Circle().fill(themeManager.hardShadow).frame(width: 26, height: 26).offset(x: 2, y: 2)
                Circle().fill(selectedColor).frame(width: 26, height: 26)
                Circle().strokeBorder(themeManager.outline, lineWidth: 2).frame(width: 26, height: 26)
            }
            .frame(width: 46, height: 52)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { colorPopover }
    }

    private var colorPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color").font(.cartoon(14, weight: .heavy)).foregroundStyle(themeManager.iconTint)
            let cols = Array(repeating: GridItem(.fixed(40), spacing: 10), count: 5)
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(presetColors.indices, id: \.self) { i in
                    Button {
                        selectedColor = presetColors[i]
                        showColorPicker = false
                    } label: {
                        ZStack {
                            Circle().fill(presetColors[i]).frame(width: 34, height: 34)
                            Circle().strokeBorder(themeManager.outline, lineWidth: 2).frame(width: 34, height: 34)
                            if selectedColor == presetColors[i] {
                                Circle().strokeBorder(themeManager.selectionColor, lineWidth: 3).frame(width: 40, height: 40)
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            // Full system color palette (wheel / sliders / grid).
            ColorPicker(selection: $selectedColor, supportsOpacity: false) {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette.fill").foregroundStyle(themeManager.iconTint)
                    Text("More Colors").font(.cartoon(14, weight: .bold)).foregroundStyle(themeManager.textPrimary)
                }
            }
        }
        .padding(16)
        .frame(width: 268)
        .modifier(ForcePopoverAdaptation())
    }

    private var sizeSliderSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(themeManager.textSecondary.opacity(0.5))
            Slider(
                value: Binding(get: { toolSizes[selectedTool] ?? selectedTool.defaultSize }, set: { toolSizes[selectedTool] = $0 }),
                in: selectedTool.sizeRange
            )
            .frame(width: 110).tint(themeManager.iconTint)
            Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(themeManager.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 10)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(themeManager.border.opacity(0.7)).frame(width: 0.5, height: 26)
    }

    private func toolbarActionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold))
                .foregroundStyle(themeManager.iconTint).frame(width: 42, height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        // Books (notebook list) sidebar toggle + theme switch.
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button { onToggleBooksSidebar() } label: {
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

            // ☀/🌙 — next to the book-sidebar icon.
            ThemeToggleButton(size: 38)
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            // Scale / ruler
            Button { viewModel.isRulerActive.toggle() } label: {
                AssetIcon(
                    asset: "scale",
                    systemName: viewModel.isRulerActive ? "ruler.fill" : "ruler",
                    size: 34,
                    fallbackTint: themeManager.iconTint
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle ruler")
            exportActionsCapsule
        }
    }

    // MARK: - Page Swipe Navigation

    /// 3-finger swipe down → previous page (grey hint at the first page).
    private func handleSwipeDownPrev() {
        lastEndSwipeUpTime = nil
        if viewModel.currentPageIndex <= 0 {
            showPageHint("This is the first page")
        } else {
            withAnimation(.easeOut(duration: 0.25)) { viewModel.goToPreviousPage() }
        }
    }

    /// 3-finger swipe up → next page. On the last page, a second up-swipe
    /// within 5 seconds creates a new page (never in read-only mode).
    private func handleSwipeUpNext() {
        if viewModel.currentPageIndex < viewModel.pages.count - 1 {
            lastEndSwipeUpTime = nil
            withAnimation(.easeOut(duration: 0.25)) { viewModel.goToNextPage() }
        } else if isReadOnly {
            showPageHint("This is the last page")
        } else {
            let now = Date()
            if let last = lastEndSwipeUpTime, now.timeIntervalSince(last) <= 5 {
                lastEndSwipeUpTime = nil
                withAnimation(.easeOut(duration: 0.25)) { viewModel.addPage() }
                showPageHint("New page added")
            } else {
                lastEndSwipeUpTime = now
                showPageHint("Swipe up again to add a page")
            }
        }
    }

    /// Shows a small grey hint bubble that auto-dismisses.
    private func showPageHint(_ text: String) {
        hintToken += 1
        let token = hintToken
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pageHintText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            if hintToken == token {
                withAnimation(.easeOut(duration: 0.2)) { pageHintText = nil }
            }
        }
    }

    private func pageHintBubble(_ text: String) -> some View {
        Text(text)
            .font(.cartoon(13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color(white: 0.32)))   // grey background
            .overlay(Capsule().strokeBorder(themeManager.outline.opacity(0.4), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    // MARK: - PDF Export

    /// Saves the current page, then renders the whole notebook to a temp PDF.
    private func makeNotebookPDF() -> URL? {
        viewModel.saveCurrentDrawing()
        // The PKCanvasView bounds are the coordinate space the strokes live in —
        // pass them so the PDF scales the drawing to fill the page correctly.
        let canvasSize = viewModel.canvasController.canvasView?.bounds.size
        do {
            return try PDFGenerator.shared.generatePDF(for: notebook, canvasSize: canvasSize)
        } catch {
            viewModel.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func downloadPDF() {
        guard let url = makeNotebookPDF(), let data = try? Data(contentsOf: url) else { return }
        exportDocument = PDFExportDocument(data: data)
        showPDFExporter = true
    }

    private func sharePDF() {
        guard let url = makeNotebookPDF() else { return }
        sharePDFURL = url
        showShareSheet = true
    }
}

// MARK: - Popover Adaptation
//
// Keeps popovers as floating popovers (instead of expanding to a full sheet on
// compact widths), so the color / page-style pickers always drop down from the
// toolbar and show their full content.

private struct ForcePopoverAdaptation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationCompactAdaptation(.popover)
        } else {
            content
        }
    }
}

// MARK: - Page Thumbnail View (renders actual drawn content)

struct PageThumbnailView: View {
    let page: Page
    let pageNumber: Int
    let isSelected: Bool
    let accentColor: Color
    let refreshToken: Int
    let drawingService: DrawingService
    var canvasSize: CGSize?
    var onThumbnailReady: (UIImage) -> Void
    var onTap: () -> Void
    var onDelete: () -> Void

    @State private var thumbnail: UIImage?
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    // Page card — current page indicator → burgundy
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(themeManager.page)
                        .frame(width: 76, height: 96)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isSelected ? themeManager.selectionColor : themeManager.border,
                                              lineWidth: isSelected ? 2.5 : 0.5)
                        )
                        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                    // ── Actual drawn content ───────────────────────────
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 76, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .opacity(0.9)
                    } else {
                        // Placeholder grid while thumbnail loads
                        let gridColor = themeManager.grid
                        Canvas { ctx, size in
                            let spacing: CGFloat = 8
                            let c = gridColor.opacity(0.5)
                            var y: CGFloat = spacing
                            while y < size.height {
                                ctx.stroke(Path { p in p.move(to: .init(x: 3, y: y)); p.addLine(to: .init(x: size.width - 2, y: y)) }, with: .color(c), lineWidth: 0.4)
                                y += spacing
                            }
                        }
                        .frame(width: 76, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }

                    // Accent spine
                    HStack {
                        Rectangle().fill(accentColor.opacity(isSelected ? 1.0 : 0.4))
                            .frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2))
                        Spacer()
                    }
                    .frame(width: 76, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                Text("\(pageNumber)")
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? themeManager.selectionColor : themeManager.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: { Label("Delete Page", systemImage: "trash") }
        }
        // Lazy-load thumbnail; re-render when the drawing is saved
        // (refreshToken) or the theme flips (isDark).
        .task(id: "\(refreshToken)-\(themeManager.isDark)") {
            let size = canvasSize
            let dark = themeManager.isDark
            let img = await Task.detached(priority: .background) {
                drawingService.renderThumbnail(
                    for: page,
                    size: CGSize(width: 76, height: 96),
                    canvasSize: size,
                    isDark: dark
                )
            }.value
            thumbnail = img
            onThumbnailReady(img)
        }
    }
}
