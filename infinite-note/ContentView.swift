//
//  ContentView.swift
//  infinite-note
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        NotebookListView()
            .background(themeManager.background.ignoresSafeArea())
            // Floating ☀/🌙 toggle — ZStack overlay above home & editor.
            // Sheets apply the same overlay to stay covered in modals.
            .themeToggleOverlay()
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager.shared)
}
