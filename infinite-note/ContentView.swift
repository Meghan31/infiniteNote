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
        // The ☀/🌙 toggle lives in the navigation bar next to the
        // book-sidebar icon (home + editor). Sheets still use the floating
        // overlay since they cover the navigation bar.
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager.shared)
}
