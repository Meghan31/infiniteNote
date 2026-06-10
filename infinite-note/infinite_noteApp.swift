//
//  infinite_noteApp.swift
//  InfiniteNote
//

import SwiftUI
import UIKit

// MARK: - App Delegate
//
// Locks the app to portrait. `supportedInterfaceOrientationsFor` is the
// authoritative runtime source of allowed orientations, overriding Info.plist.

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}

@main
struct infinite_noteApp: App {
    /// Global theme engine — injected at the root so every view
    /// (home, editor, sheets, popovers) reactively updates, instantly.
    @StateObject private var themeManager = ThemeManager.shared

    /// Portrait lock (see AppDelegate).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
