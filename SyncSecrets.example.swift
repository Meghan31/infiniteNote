// TEMPLATE — the real file lives at infinite-note/Core/Sync/SyncSecrets.swift
// (that path is git-ignored; this repo-root copy is NOT compiled).
//
// Copy this file there and fill in the credentials of the single Supabase
// user created in Dashboard → Authentication → Users → "Add user".
// Sign-ups are disabled server-side, so that account is the only key to the
// database; without this file the app builds fail with "cannot find
// SyncSecrets" — that's intentional.

import Foundation

enum SyncSecrets {
    static let email = "YOUR-EMAIL-HERE"
    static let password = "YOUR-PASSWORD-HERE"
}
