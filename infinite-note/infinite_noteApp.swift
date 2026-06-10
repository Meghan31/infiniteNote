//
//  infinite_noteApp.swift
//  InfiniteNote
//

import SwiftUI

@main
struct infinite_noteApp: App {
    /// Global theme engine — injected at the root so every view
    /// (home, editor, sheets, popovers) reactively updates, instantly.
    @StateObject private var themeManager = ThemeManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                // Flips system chrome (nav bars, forms, materials) together
                // with our custom surfaces — no restart needed.
                .preferredColorScheme(themeManager.colorScheme)
                .tint(Color.burgundy)
        }
    }
}
