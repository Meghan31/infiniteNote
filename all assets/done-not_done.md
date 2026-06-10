## InfiniteNote — Status Handoff

### What's Built (Phases 1–2 complete, 3–6 scaffolded)

---

**Project Setup**
- Xcode project bootstrapped, iOS 18.5, Swift 5, SwiftUI, iPad-targeted
- GRDB and supabase-swift packages are resolved (`Package.resolved` present) and **linked to the target** in `project.pbxproj` via `XCSwiftPackageProductDependency` — no manual Xcode steps needed
- `PBXFileSystemSynchronizedRootGroup` used — all Swift files under `infinite-note/` are auto-included in the build

---

**Phase 1 — Database Foundation ✅ Complete**

Files: `DatabaseManager.swift`, `Notebook.swift`, `Page.swift`, `NotebookService.swift`, `DrawingService.swift`, `FileStorageManager.swift`

- `DatabaseManager` — singleton, GRDB `DatabaseQueue`, versioned migration (`v1_initial`) creating `notebooks` and `pages` tables with cascade delete
- `Notebook` — `MutablePersistableRecord` + `FetchableRecord`, fields: `id`, `title`, `created_at`, `updated_at`, `cover_color_index`
- `Page` — same GRDB conformance, fields: `id`, `notebook_id`, `page_number`
- `NotebookService` — CRUD: `allNotebooks()`, `createNotebook()`, `renameNotebook()`, `deleteNotebook()`, `touchNotebook()`
- `DrawingService` — page CRUD: `pages(for:)`, `addPage(to:)`, `deletePage(_:)` with auto-renumbering, `saveDrawing`, `loadDrawing`
- `FileStorageManager` — saves/loads `PKDrawing.dataRepresentation()` to `Documents/notebooks/{notebookId}/{pageId}.drawing`
- First page auto-created when a notebook is created

---

**Phase 2 — Notebook List UI ✅ Complete**

Files: `NotebookListView.swift`, `NotebookListViewModel.swift`, `NotebookCardView.swift`

- `NavigationSplitView` — sidebar (grid of cards) + detail pane
- `NotebookListViewModel` — `@Observable`, `loadNotebooks()`, `createNotebook()`, `renameNotebook()`, `deleteNotebook()`
- Cards — white background, 4px muted ink-colored spine tab, subtle `opacity: 0.05 radius: 10` shadow, `updated Today/Yesterday/date` label
- Animations — `scale 0.98→1.0, easeOut 0.2s` via `NotebookButtonStyle: ButtonStyle`
- Empty state — `📓` icon, "Start your first notebook." copy, "Create Notebook" indigo button
- Search — `searchable()` filtering notebooks by title
- Create sheet — `.presentationDetents([.medium])`, title field + cover color swatch preview
- Rename sheet — `.presentationDetents([.height(220)])`
- Delete — confirmation alert with notebook title

---

**Design System ✅ Complete — Infinite Paper theme**

File: `Color+Extensions.swift`

Full palette implemented with adaptive light/dark variants:
- Light: `paperWhite #FAF8F4`, `inkBlack #1D1D1F`, `slateGray #6B7280`, `borderGray #E5E7EB`, `gridGray #D8D8D8`
- Dark: `notebookDark #121418`, `surfaceDark #1B1E24`, `cardDark #22262D`, `gridDark #30353D`
- Accent: `deepIndigo #4F46E5` (light) / `indigoLight #7C7BFF` (dark)
- 8 muted academic spine colors: Midnight Indigo, Ocean Blue, Forest Teal, Royal Purple, Amber Brown, Burgundy, Forest Green, Graphite

---

**Phase 3 — PencilKit Canvas ⚠️ Scaffolded, not tested**

Files: `DrawingCanvasView.swift`, `NotebookEditorView.swift`, `NotebookEditorViewModel.swift`

- `DrawingCanvasView` — `UIViewRepresentable` wrapping `PKCanvasView`, `PKToolPicker` wired, `anyInput` policy (finger + Pencil), debounced `400ms` auto-save
- `NotebookEditorView` — `NavigationSplitView`-style layout with collapsible page sidebar (110pt wide), engineering graph paper canvas background (28pt grid, every 4th line major), page number badge, ruler toggle, sync button in toolbar
- `NotebookEditorViewModel` — `@Observable`, loads pages on appear, debounced `500ms` drawing save, `goToPage`, `addPage`, `deletePage`
- **Not yet verified to build and run** — PencilKit `PKToolPicker.shared(for:window:)` call may need adjustment; the `makeUIView` tries to call it before the view has a window

---

**Phase 4 — Page System ⚠️ Scaffolded**

Built into `DrawingService` and `NotebookEditorViewModel`:
- Add page, delete page (guards against deleting last page), auto-renumber, page sidebar with thumbnails (`PageThumbnailView` with grid pattern + spine accent)
- **Not tested end-to-end**

---

**Phase 5 — PDF Export ⚠️ Scaffolded, not tested**

File: `PDFGenerator.swift`

- Renders each `PKDrawing` to a `UIImage`, draws ruled lines + margin line via `UIGraphicsBeginPDFContextToData`, adds page number footer
- Saves to `FileManager.default.temporaryDirectory`
- **Canvas size hardcoded to 2048×2732** — may not match actual `PKCanvasView` content bounds in practice

---

**Phase 6 — Supabase Sync ⚠️ Scaffolded, not configured**

Files: `SyncService.swift`, `SyncView.swift`

- `SyncService` — uses raw `URLSession` REST to POST PDF to Supabase Storage bucket `notes`, with `x-upsert: true`
- **Requires user to fill in**: `supabaseURL` and `supabaseKey` in `SyncService.swift`
- `SyncView` — indigo-styled sheet with idle/syncing/success/failure states

---

### What Needs To Be Done Before v1 Ship

**Must fix before anything works:**

1. **`PKToolPicker` window timing bug** — `makeUIView` calls `PKToolPicker.shared(for: canvas.window ?? UIWindow())` but `canvas.window` is `nil` at `makeUIView` time. Need to move tool picker setup to `didMoveToWindow` via a `UIViewRepresentable` coordinator or use `updateUIView` after the view is in the hierarchy.

2. **PDF canvas size mismatch** — `PDFGenerator` assumes 2048×2732 but `PKCanvasView.contentSize` is set to the same in `DrawingCanvasView`. Needs verification that `drawing.image(from: bounds, scale: 1.0)` covers the full drawing area.

3. **Supabase credentials** — open `SyncService.swift`, replace `YOUR_PROJECT_REF` and `YOUR_ANON_KEY`.

**Phase 3 remaining work:**
- Verify PencilKit toolbar appears correctly on iPad simulator/device
- Test that drawings persist across app restarts
- Handle `PKCanvasView` scroll correctly (currently `alwaysBounceVertical = true`, content size 2048×2732)

**Phase 4 remaining work:**
- Test page add/delete/navigate end-to-end
- Page thumbnail previews currently show only a static grid — no live drawing preview (acceptable for v1, but worth noting)

**Phase 5 remaining work:**
- Test PDF export produces correct output
- Verify all pages are captured, not just current page

**Phase 6 remaining work:**
- Wire in Supabase credentials
- Test upload on a real device (simulator has no network restrictions but real auth matters)
- Handle large notebooks (PDF size limit in Supabase free tier is 50MB)

**Nice-to-have before ship:**
- `Settings` screen (placeholder exists in PRD structure, not yet built)
- App icon (PRD calls for `∞` made from two notebook pages)
- Haptic feedback on page add/delete
- `@AppStorage` to remember last open notebook