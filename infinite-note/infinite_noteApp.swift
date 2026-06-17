//
//  infinite_noteApp.swift
//  InfiniteNote
//

import SwiftUI
import UIKit

// MARK: - App Delegate
//
// Locks the app to portrait — no landscape, even when an iPad is rotated.
// This works together with the project settings: `UIRequiresFullScreen = YES`
// (an iPad that supports multitasking is FORCED to allow all orientations,
// so we opt out) and portrait-only `UISupportedInterfaceOrientations`.
// iPad additionally allows upside-down portrait (still portrait; required
// by Apple for portrait-only iPad apps).

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .portraitUpsideDown]
            : .portrait
    }
}

@main
struct infinite_noteApp: App {
    /// Global theme engine — injected at the root so every view
    /// (home, editor, sheets, popovers) reactively updates, instantly.
    @StateObject private var themeManager = ThemeManager.shared

    /// Portrait lock (see AppDelegate).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                // Flips system chrome (nav bars, forms, materials) together
                // with our custom surfaces — no restart needed.
                .preferredColorScheme(themeManager.colorScheme)
                .tint(Color.burgundy)
        }
        .onChange(of: scenePhase) { _, phase in
            // If the database fell back to the in-memory store on launch,
            // re-attempt the real one whenever the app becomes active — the
            // user's content returns without a force-quit. (No-op otherwise.)
            if phase == .active { DatabaseManager.shared.reopenIfNeeded() }
        }
    }
}
