# InfiniteNote v1

## Project Overview

InfiniteNote is a native iPad note-taking application built using SwiftUI and PencilKit.

The application is designed to be a lightweight alternative to GoodNotes focused on handwritten note creation and local-first storage.

Version 1 intentionally excludes advanced functionality and focuses only on a stable notebook creation, editing, storage, PDF export, and sync workflow.

---

# Core Principles

1. Local-first architecture.
2. No cloud dependency for editing.
3. Fast notebook loading.
4. Simple architecture over complex abstractions.
5. Native Apple frameworks whenever possible.
6. Production-quality code.
7. MVVM architecture.
8. Small codebase.
9. No premature optimization.
10. Build features incrementally.

---

# Technology Stack

## Language

Swift 6

## UI Framework

SwiftUI

## Drawing Engine

PencilKit

## Database

SQLite

## ORM

GRDB

## PDF Generation

PDFKit

## Cloud Storage

Supabase Storage

## File Storage

FileManager

## Architecture

MVVM

---

# Current Project Status

## Completed

* Xcode project created
* SwiftUI application bootstrapped
* Initial repository created

## Not Yet Implemented

* Database layer
* Notebook management
* PencilKit integration
* Drawing persistence
* PDF export
* Supabase sync

The AI agent should assume that only the default SwiftUI boilerplate exists.

---

# Functional Requirements

## Notebook Management

Users must be able to:

* Create notebook
* Rename notebook
* Delete notebook
* View notebook list

---

## Notebook Editing

Users must be able to:

* Open notebook
* Draw with Apple Pencil
* Draw with finger
* Save drawings automatically
* Reopen notebook and continue editing

---

## Page Management

Users must be able to:

* Create page
* Navigate pages
* Delete page

Each notebook contains multiple pages.

---

## Persistence

All notebook data must be stored locally.

The application must work completely offline.

No network connection should be required for editing.

---

## Sync

User manually presses Sync.

Sync flow:

Notebook
→ Generate PDF
→ Upload PDF
→ Supabase Storage

No real-time sync.

No background sync.

No collaborative editing.

---

# Explicitly Out Of Scope

Do NOT implement any of the following:

* OCR
* AI features
* Search indexing
* Real-time collaboration
* Shared notebooks
* User accounts
* Authentication
* Cloud editing
* Infinite canvas
* Audio recording
* Video recording
* Mac application
* iPhone optimization
* iCloud Sync
* Edge Functions
* Push notifications

These features may be added in future versions.

---

# Data Model

## Notebook

Fields:

* id
* title
* createdAt
* updatedAt

---

## Page

Fields:

* id
* notebookId
* pageNumber

---

# Database Schema

## notebooks

CREATE TABLE notebooks (
id TEXT PRIMARY KEY,
title TEXT NOT NULL,
created_at DATETIME,
updated_at DATETIME
);

## pages

CREATE TABLE pages (
id TEXT PRIMARY KEY,
notebook_id TEXT,
page_number INTEGER
);

No additional tables unless absolutely necessary.

---

# Local Storage Design

Notebook metadata is stored in SQLite.

Actual drawings are stored on disk.

Folder structure:

Documents/

notebooks/

{notebook-id}/

page-1.drawing

page-2.drawing

page-3.drawing

Each file stores:

PKDrawing.dataRepresentation()

Never store drawing blobs inside SQLite.

---

# Application Structure

InfiniteNote/

App/

Core/

Database/

Storage/

Drawing/

PDF/

Sync/

Models/

Features/

NotebookList/

NotebookEditor/

Settings/

Services/

Resources/

Extensions/

---

# Architecture Rules

## MVVM

Views should contain presentation logic only.

ViewModels handle state and user actions.

Services handle business logic.

Database and storage layers must never be accessed directly from Views.

---

## Dependency Flow

View

↓

ViewModel

↓

Service

↓

Database / File System

---

## Separation of Concerns

Drawing logic belongs in Drawing module.

Database logic belongs in Database module.

PDF logic belongs in PDF module.

Sync logic belongs in Sync module.

Do not mix responsibilities.

---

# Coding Standards

## General

* Prefer SwiftUI-first solutions.
* Prefer native Apple APIs.
* Avoid unnecessary third-party dependencies.
* Keep files focused and small.
* Use meaningful naming.
* Avoid massive ViewModels.

---

## Error Handling

Use proper Swift error handling.

Do not silently ignore errors.

Surface recoverable errors to UI.

---

## Async Operations

Use async/await.

Avoid callback-based code when possible.

---

## State Management

Use:

* @State
* @StateObject
* @Observable
* @Environment

Prefer native SwiftUI state management.

Do not introduce Redux-style architectures.

---

# Supabase Requirements

Use Supabase only for Storage Buckets.

No Auth.

No Postgres usage.

No Realtime.

No Edge Functions.

Bucket name:

notes

Example upload:

notes/calculus.pdf

notes/distributed-systems.pdf

---

# Build Order

The AI agent should implement features in the following sequence.

## Phase 1

Database Foundation

Tasks:

* Setup GRDB
* Create DatabaseManager
* Create migrations
* Create Notebook model
* Create Page model

Deliverable:

Notebook CRUD works.

---

## Phase 2

Notebook List Screen

Tasks:

* List notebooks
* Create notebook
* Delete notebook
* Rename notebook

Deliverable:

User can manage notebooks.

---

## Phase 3

PencilKit Integration

Tasks:

* Create drawing canvas
* Save drawing
* Load drawing

Deliverable:

Notebook pages persist drawings locally.

---

## Phase 4

Page System

Tasks:

* Add pages
* Delete pages
* Navigate pages

Deliverable:

Multi-page notebooks.

---

## Phase 5

PDF Export

Tasks:

* Render pages
* Generate PDF
* Save temporary PDF

Deliverable:

Notebook exports correctly.

---

## Phase 6

Supabase Sync

Tasks:

* Configure Supabase SDK
* Upload PDFs
* Sync button

Deliverable:

Manual PDF upload works.

---

# Definition of Done

Version 1 is complete when:

* Notebook CRUD works
* Multi-page notebooks work
* PencilKit drawings persist
* Data survives app restarts
* PDF export works
* PDF uploads to Supabase
* App functions completely offline except Sync

Nothing beyond this scope should be built until v1 is finished.
