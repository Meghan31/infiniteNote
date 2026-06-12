<div align="center">

<img src="https://img.shields.io/badge/iOS-18.5-8B1A1A?style=for-the-badge&logo=apple&logoColor=white"/>
<img src="https://img.shields.io/badge/SwiftUI-Framework-C9861A?style=for-the-badge&logo=swift&logoColor=white"/>
<img src="https://img.shields.io/badge/PencilKit-Drawing-2D6A4F?style=for-the-badge&logo=apple&logoColor=white"/>
<img src="https://img.shields.io/badge/Supabase-Sync-1B7A70?style=for-the-badge&logo=supabase&logoColor=white"/>

<br/><br/>

```
██╗███╗   ██╗███████╗██╗███╗   ██╗██╗████████╗███████╗
██║████╗  ██║██╔════╝██║████╗  ██║██║╚══██╔══╝██╔════╝
██║██╔██╗ ██║█████╗  ██║██╔██╗ ██║██║   ██║   █████╗
██║██║╚██╗██║██╔══╝  ██║██║╚██╗██║██║   ██║   ██╔══╝
██║██║ ╚████║██║     ██║██║ ╚████║██║   ██║   ███████╗
╚═╝╚═╝  ╚═══╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝   ╚═╝   ╚══════╝
███╗   ██╗ ██████╗ ████████╗███████╗
████╗  ██║██╔═══██╗╚══██╔══╝██╔════╝
██╔██╗ ██║██║   ██║   ██║   █████╗
██║╚██╗██║██║   ██║   ██║   ██╔══╝
██║ ╚████║╚██████╔╝   ██║   ███████╗
╚═╝  ╚═══╝ ╚═════╝    ╚═╝   ╚══════╝
```

**A cartoon-powered drawing desk for iPhone and iPad.**
Chunky cards · Ink outlines · Hard shadows · Custom pens · Private cloud sync.

</div>

---

## The Idea

InfiniteNote is not a plain notes app with a pen slapped on top. It is built like a bright little drawing desk — tabbed notebooks, page thumbnails, custom covers, and a fixed paper model that keeps what you write on screen perfectly aligned with what lands in the exported PDF.

```
        HOME SHELF                 PAPER DESK                 CLOUD SNAPSHOT
 .--------------------.     .----------------------.     .--------------------.
 | folders + books    | --> | PencilKit A4 canvas  | --> | private PDF backup |
 | search + pins      |     | tools + page styles  |     | RLS-protected row  |
 | photo covers       | <-- | tabs + PDF export    | <-- | sync badge in app  |
 '--------------------'     '----------------------'     '--------------------'
```

---

## Panel 01 — The Shelf

The library is a cartoon bookshelf built for real project work.

| Piece              | What it does                                                   |
| ------------------ | -------------------------------------------------------------- |
| **Notebook cards** | Illustrated cards with cover colors or photo covers            |
| **Folders**        | Root folders, nested folders, authors, item counts, own covers |
| **Search**         | Finds notebooks and folders from the sidebar                   |
| **Pins**           | Pinned items sort to the front                                 |
| **Open tabs**      | Multiple notebooks stay open in the editor tab strip           |
| **Sync badge**     | Cloud sticker on synced notebooks with last-upload time        |

---

## Panel 02 — The Paper Desk

Every page sits on the same fixed A4 portrait coordinate space:

```swift
PaperSpec.size == CGSize(width: 1190, height: 1684)
```

That single paper size is shared by the live canvas, thumbnails, sync snapshots, and exported PDFs — strokes never drift between "what I wrote" and "what I downloaded."

**Page styles:** Plain · Ruled · Dotted · Grid · Photo background

**Editor features:**

- Page thumbnails with drag-to-reorder and delete
- Top tool capsule — pen, custom pen, fountain pen, eraser, extra tools
- Read-only mode for page turning
- Write-only mode — hides all chrome, leaves paper, color switch, tool switch, and exit
- Undo · Redo · Ruler · Color palette · Strength slider · PDF download · PDF share · Sync

---

## Panel 03 — The Pen Box

InfiniteNote treats pens as a first-class part of the app, not a hidden setting.

| Tool                                          | Notes                                                                      |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| **Pen**                                       | Stock PencilKit handwriting                                                |
| **Custom Pen**                                | Saved presets with live stroke previews                                    |
| **Pencil / Marker / Highlighter**             | Familiar PencilKit tools with tuned defaults                               |
| **Fountain / Monoline / Crayon / Watercolor** | iOS 17+ tools with graceful fallbacks                                      |
| **Shape**                                     | Turns rough lines, rectangles, ellipses, and triangles into cleaner shapes |
| **Eraser**                                    | Stroke or pixel erasing                                                    |

Custom pens store width, opacity, smoothing, pressure response, tapers, ink flow, softness, velocity sensitivity, and min/max width in the local database. The Pen Designer includes a live scribble pad so the preview matches the canvas.

---

## Panel 04 — Finger Choreography

Fingers navigate. Apple Pencil writes. Simulator builds allow mouse input for testing.

| Gesture              | Mode      | Result                                    |
| -------------------- | --------- | ----------------------------------------- |
| 2-finger double tap  | Edit      | Undo                                      |
| 3-finger double tap  | Edit      | Redo                                      |
| 3-finger long press  | Edit      | Confirm erase page                        |
| 3-finger swipe up    | Edit      | Next page — swipe again to add at the end |
| 3-finger swipe down  | Edit      | Previous page                             |
| 3-finger swipe left  | Read-only | Next page                                 |
| 3-finger swipe right | Read-only | Previous page                             |

Gesture recognizers are custom where PencilKit gets fussy, keeping multi-finger gestures reliable on a canvas and avoiding system text menus.

---

## Panel 05 — PDF With a Cover

Every exported notebook becomes a designed PDF.

- A full cover page comes first — user photo or bundled artwork cycling through `background 1` → `background 10`
- Title, description, author, page count, dates, and links drawn onto cartoon sticker plates
- Each page renders with its saved paper style and strokes
- PDF generation runs off the main thread for download and share flows
- Temporary export folders are isolated per generation; stale ones are cleaned up automatically

**Source files:**

```
infinite-note/Core/PDF/PDFGenerator.swift
infinite-note/Features/NotebookEditor/PDFExportSupport.swift
```

---

## Panel 06 — Storage

InfiniteNote is local-first.

```
SQLite (GRDB):
  infinite_note.db

File-backed notebook assets:
  Documents/notebooks/<notebook-id>/<page-id>.drawing
  Documents/notebooks/<notebook-id>/cover.jpg
  Documents/notebooks/<notebook-id>/<page-id>_bg.jpg

File-backed folder assets:
  Documents/folders/<folder-id>/cover.jpg

Cloud:
  notes/<user-id>/<notebook-id>.pdf  →  Supabase private bucket
  public.synced_notebooks             →  metadata row per notebook
```

GRDB owns structured data: notebooks, pages, folders, folder membership, sync timestamps, pins, nested folder parent links, and custom pen presets. `FileStorageManager` owns PencilKit drawings and images. If the on-disk database cannot open, the app falls back to a temporary in-memory database and warns the user instead of crash-looping.

---

## Panel 07 — Cloud Snapshot

Sync is intentionally narrow: one PDF snapshot per notebook, uploaded to a private Supabase bucket with a matching metadata row in `synced_notebooks`.

Access is controlled by Supabase Auth, disabled public sign-ups, a private storage bucket, and RLS policies from `supabase-sync-setup.sql`. The publishable key is allowed to live in the app; the private email and password live only in a git-ignored file.

**First-time sync setup:**

```sh
cp SyncSecrets.example.swift infinite-note/Core/Sync/SyncSecrets.swift
# Fill in the private Supabase email and password
# Run supabase-sync-setup.sql in the Supabase SQL editor
```

---

## The Color Palette

```
  Burgundy     ████  #8B1A1A   Primary CTA · Active states
  Light Bronze ████  #C9861A   Sunny secondary tone
  Palm Leaf    ████  #2D6A4F   Accents · Toolbar color
  Palm Dark    ████  #1B4332   Selected fills · Menu color
  Pine Teal    ████  #1B7A70   Sync · Success states
  Sky Pop      ████  #2563EB   Extra cover color
  Ink Black    ████  #1A0A00   Outlines · Shadows
  Cream Paper  ████  #FFF8F0   Base background
```

---

## Design DNA

```
  heavy ink outline
+ solid offset shadow
+ rounded system type
+ bright cover palette
+ real image assets
+ springy press states
= comic sticker notebook desk
```

---

## Project Map

```
infinite-note/
  infinite_noteApp.swift                 app entry, portrait lock, theme inject
  ContentView.swift                      root NotebookListView

  Core/
    Database/DatabaseManager.swift       GRDB queue and migrations
    Drawing/DrawingService.swift         pages, drawings, thumbnails
    Drawing/StrokeRefiner.swift          custom-pen stroke cleanup
    PDF/PDFGenerator.swift               cover page and PDF rendering
    Storage/FileStorageManager.swift     drawings, covers, page backgrounds
    Sync/SyncService.swift               Supabase PDF snapshot sync
    Theme/CartoonStyle.swift             ink outlines and hard shadows
    Theme/ThemeManager.swift             light/dark semantic theme
    Theme/AssetIcon.swift                themed asset rendering

  Features/
    NotebookList/                        shelf, cards, folders, creation flows
    NotebookEditor/                      canvas, tools, PDF share, sync, pens

  Models/
    Notebook.swift                       notebook metadata
    Page.swift                           page order and page style
    Folder.swift                         nested folder metadata
    CustomPen.swift                      custom pen presets

  Assets.xcassets/                       icons, covers, tool art, app icon
```

---

## Build Requirements

| Tool           | Version                                     |
| -------------- | ------------------------------------------- |
| Xcode          | 16 era project                              |
| iOS target     | 18.5                                        |
| Devices        | iPhone and iPad                             |
| Orientation    | Portrait (iPad allows portrait upside-down) |
| GRDB           | 7.11.0                                      |
| supabase-swift | 2.46.0                                      |

**Open in Xcode:**

```sh
open infinite-note.xcodeproj
```

**Command-line build:**

```sh
xcodebuild \
  -project infinite-note.xcodeproj \
  -scheme infinite-note \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/infinite-note-derived \
  -quiet build
```

---

## Quick Start

```
Start a notebook:
  Tap Create Notebook → choose title, cover, page style, optional details.

Organize:
  Create folders → nest folders → pin important items → move notebooks.

Write:
  Open a notebook → pick a tool → choose color and strength → write on paper.

Navigate pages:
  Use the sidebar thumbnail strip or 3-finger swipes.

Export:
  Download to Files or share a designed PDF snapshot.

Sync:
  Tap sync → confirm → upload a private PDF snapshot to Supabase.
```

---

## Guardrails

- **Never commit** `infinite-note/Core/Sync/SyncSecrets.swift` — keep `SyncSecrets.example.swift` as the safe template
- Keep `supabase-sync-setup.sql` in the repo so the storage/table/RLS contract stays visible
- Keep PDF, canvas, and thumbnails tied to `PaperSpec.size` or strokes will drift
- When changing gestures, update the visible hint text too
- When changing storage writes, surface failures — never silently drop drawings, covers, or backgrounds

---

## Credits

Built around **Apple Pencil**, **SwiftUI**, **PencilKit**, **GRDB**, **PDFKit**, and **Supabase**.

The personality comes from the app's own cartoon design language: bold outlines, hard shadows, bright covers, and controls that feel like stickers on a desk.

---

<div align="center">

`SwiftUI` · `PencilKit` · `PDFKit` · `GRDB 7.11` · `supabase-swift 2.46` · `iOS 18.5`

</div>
