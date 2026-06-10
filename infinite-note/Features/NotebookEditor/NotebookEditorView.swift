import SwiftUI
import PencilKit
import PhotosUI

struct NotebookEditorView: View {
    let notebook: Notebook
    let openNotebooks: [Notebook]
    let onSelectNotebook: (Notebook) -> Void
    let onCloseNotebook: (Notebook) -> Void
    let onGoHome: () -> Void

    @State private var viewModel: NotebookEditorViewModel
    @State private var showSyncSheet = false
    @State private var showPageSidebar = true

    // Drawing tool state
    @State private var selectedTool: DrawingToolType = .pen
    @State private var selectedColor: Color = .black
    @State private var toolSizes: [DrawingToolType: CGFloat] = [
        .pen: 3, .marker: 15, .highlighter: 25, .eraser: 20
    ]
    @State private var showColorPicker = false
    @State private var showErasePageConfirm = false

    // Page style
    @State private var showStylePicker = false
    @State private var pageStylePhotoItem: PhotosPickerItem?

    // Home alert
    @State private var showHomeAlert = false

    @EnvironmentObject private var themeManager: ThemeManager

    private let presetColors: [Color] = [
        .black, Color(white: 0.25), Color(white: 0.55),
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

    init(
        notebook: Notebook,
        openNotebooks: [Notebook] = [],
        onSelectNotebook: @escaping (Notebook) -> Void = { _ in },
        onCloseNotebook: @escaping (Notebook) -> Void = { _ in },
        onGoHome: @escaping () -> Void = {}
    ) {
        self.notebook = notebook
        self.openNotebooks = openNotebooks
        self.onSelectNotebook = onSelectNotebook
        self.onCloseNotebook = onCloseNotebook
        self.onGoHome = onGoHome
        self._viewModel = State(initialValue: NotebookEditorViewModel(notebook: notebook))
    }

    private var currentSize: CGFloat { toolSizes[selectedTool] ?? selectedTool.defaultSize }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            fileTabBar

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
                        canvasController: viewModel.canvasController,
                        onErasePage: { showErasePageConfirm = true },
                        onNextPage: { withAnimation(.easeOut(duration: 0.25)) { viewModel.goToNextPage() } },
                        onPrevPage: { withAnimation(.easeOut(duration: 0.25)) { viewModel.goToPreviousPage() } },
                        onNewPage: { withAnimation(.easeOut(duration: 0.25)) { viewModel.addPage() } }
                    )
                    pageFooter
                    if !showPageSidebar {
                        floatingSidebarButton
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
            }
        }
        .background(themeManager.background)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { drawingToolbar }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.saveCurrentDrawing() }
        .sheet(isPresented: $showSyncSheet) { SyncView(notebook: notebook) }
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
                        Image(systemName: "house.fill").font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.burgundy)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(Capsule().fill(Color.burgundy.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    if !openNotebooks.isEmpty {
                        RoundedRectangle(cornerRadius: 1).fill(themeManager.border).frame(width: 1, height: 16)
                    }
                    ForEach(openNotebooks) { nb in fileTab(for: nb) }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(height: 44)
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

    // MARK: - Floating Sidebar Button

    private var floatingSidebarButton: some View {
        VStack {
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.22)) { showPageSidebar = true } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.palmLeaf)
                    .frame(width: 26, height: 52)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(themeManager.border.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(width: 26)
    }

    // MARK: - Drawing Toolbar

    private var drawingToolbar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(themeManager.border.opacity(0.6)).frame(height: 0.5)
            HStack(spacing: 0) {
                // Sidebar toggle — active state burgundy, idle icon palmLeaf
                Button { withAnimation(.easeOut(duration: 0.22)) { showPageSidebar.toggle() } } label: {
                    Image(systemName: showPageSidebar ? "sidebar.squares.left" : "sidebar.left")
                        .font(.system(size: 16, weight: showPageSidebar ? .semibold : .regular))
                        .foregroundStyle(showPageSidebar ? Color.burgundy : Color.palmLeaf)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).padding(.leading, 4)

                toolbarDivider

                // Tool selector
                HStack(spacing: 2) { ForEach(DrawingToolType.allCases, id: \.self) { toolButton($0) } }
                    .padding(.horizontal, 6)

                toolbarDivider

                // Color (pen/marker/highlight only)
                if selectedTool != .eraser { colorPickerButton; toolbarDivider }

                // Size
                sizeSliderSection

                Spacer(minLength: 0)

                toolbarDivider

                // Page style
                Button { showStylePicker.toggle() } label: {
                    Image(systemName: viewModel.currentPageStyle.systemImage)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Color.palmLeaf)
                        .frame(width: 42, height: 44)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStylePicker, arrowEdge: .bottom) { pageStylePopover }

                toolbarDivider

                // Undo / Redo
                HStack(spacing: 0) {
                    toolbarActionButton(icon: "arrow.uturn.backward") { viewModel.undo() }
                    toolbarActionButton(icon: "arrow.uturn.forward")  { viewModel.redo() }
                }
                .padding(.trailing, 4)
            }
            .frame(height: 52)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Page Style Popover

    private var pageStylePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Page Style")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.palmLeaf)
            let nonPhotoStyles: [PageStyle] = [.plain, .ruled, .dots, .grid]
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(nonPhotoStyles, id: \.self) { styleCard($0) }
            }
            Divider()
            PhotosPicker(selection: $pageStylePhotoItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(Color.burgundy)
                    Text("Import Photo as Background")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.burgundy)
                    Spacer()
                    if viewModel.currentPageStyle == .photo {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.burgundy)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.palmLeafDark.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(viewModel.currentPageStyle == .photo ? Color.burgundy.opacity(0.5) : Color.clear, lineWidth: 1.5)))
            }
            .buttonStyle(.plain)
            .onChange(of: pageStylePhotoItem) { _, _ in showStylePicker = false }
        }
        .padding(16).frame(width: 280)
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
                    .strokeBorder(isSelected ? Color.burgundy : themeManager.border,
                                  lineWidth: isSelected ? 2 : 0.5))
                Text(style.label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.burgundy : themeManager.textSecondary)
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
                                       with: .color(Color.burgundy.opacity(0.3)), lineWidth: 0.6)
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
                // Current page indicator → burgundy (palette usage rule)
                Text("Page \(viewModel.currentPageIndex + 1) of \(viewModel.pages.count)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.burgundy)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial).clipShape(Capsule())
                    .padding(16)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Page Sidebar

    private var pageSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Section header → palmLeaf (palette usage rule)
                Text("Pages")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.palmLeaf).textCase(.uppercase).tracking(0.5)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.22)) { showPageSidebar = false } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.palmLeaf).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                Button { viewModel.addPage() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.burgundy)
                        .frame(width: 24, height: 24)
                        .background(Color.burgundy.opacity(0.1)).clipShape(Circle())
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

    private func toolButton(_ tool: DrawingToolType) -> some View {
        let isSelected = selectedTool == tool
        // Active tool → burgundy icon on palmLeafDark selected background;
        // idle tool icons → palmLeaf (palette usage rules)
        return Button { withAnimation(.easeOut(duration: 0.15)) { selectedTool = tool } } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.burgundy : Color.palmLeaf)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.palmLeafDark.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var colorPickerButton: some View {
        Button { showColorPicker.toggle() } label: {
            ZStack {
                Circle().fill(selectedColor).frame(width: 24, height: 24).shadow(color: selectedColor.opacity(0.4), radius: 3)
                Circle().strokeBorder(themeManager.border, lineWidth: 1.5).frame(width: 24, height: 24)
            }
            .frame(width: 46, height: 52)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPicker, arrowEdge: .bottom) { colorPopover }
    }

    private var colorPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.palmLeaf)
            let cols = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(presetColors.indices, id: \.self) { i in
                    Button { selectedColor = presetColors[i]; showColorPicker = false } label: {
                        ZStack {
                            Circle().fill(presetColors[i]).frame(width: 30, height: 30)
                            Circle().strokeBorder(themeManager.border.opacity(0.5), lineWidth: 1).frame(width: 30, height: 30)
                        }
                        .overlay {
                            if selectedColor == presetColors[i] {
                                Circle().strokeBorder(Color.burgundy, lineWidth: 2.5).frame(width: 34, height: 34)
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Text("Custom").font(.system(size: 13)).foregroundStyle(themeManager.textSecondary)
                Spacer()
                ColorPicker("", selection: $selectedColor, supportsOpacity: false).labelsHidden().frame(width: 36, height: 36)
            }
        }
        .padding(16).frame(width: 248)
    }

    private var sizeSliderSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(themeManager.textSecondary.opacity(0.5))
            Slider(
                value: Binding(get: { toolSizes[selectedTool] ?? selectedTool.defaultSize }, set: { toolSizes[selectedTool] = $0 }),
                in: selectedTool.sizeRange
            )
            .frame(width: 110).tint(Color.burgundy)
            Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(themeManager.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 10)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(themeManager.border.opacity(0.7)).frame(width: 0.5, height: 26)
    }

    private func toolbarActionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.palmLeaf).frame(width: 42, height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { viewModel.isRulerActive.toggle() } label: {
                Image(systemName: "ruler").symbolVariant(viewModel.isRulerActive ? .fill : .none)
                    .foregroundStyle(viewModel.isRulerActive ? Color.burgundy : Color.palmLeaf)
            }
            // Sync button → pineTeal (palette usage rule)
            Button { showSyncSheet = true } label: {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(Color.pineTeal)
            }
            Button { onCloseNotebook(notebook); onGoHome() } label: {
                Image(systemName: "xmark.circle").font(.system(size: 16)).foregroundStyle(Color.palmLeaf)
            }
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
                                .strokeBorder(isSelected ? Color.burgundy : themeManager.border,
                                              lineWidth: isSelected ? 1.5 : 0.5)
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
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.burgundy : themeManager.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: { Label("Delete Page", systemImage: "trash") }
        }
        // Lazy-load thumbnail; re-render when refreshToken changes (after each save)
        .task(id: refreshToken) {
            let img = await Task.detached(priority: .background) {
                drawingService.renderThumbnail(for: page, size: CGSize(width: 76, height: 96))
            }.value
            thumbnail = img
            onThumbnailReady(img)
        }
    }
}
