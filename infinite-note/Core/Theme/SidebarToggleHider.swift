import SwiftUI
import UIKit

struct SidebarToggleHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.scheduleRemoval()
    }

    final class Controller: UIViewController {
        private var removalScheduled = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleRemoval()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleRemoval()
        }

        func scheduleRemoval() {
            guard !removalScheduled else { return }
            removalScheduled = true

            DispatchQueue.main.async { [weak self] in
                self?.removalScheduled = false
                self?.removeSidebarToggle()
            }
        }

        private func removeSidebarToggle() {
            guard let displayModeButton = splitViewController?.displayModeButtonItem else { return }

            candidateNavigationItems.forEach {
                remove(displayModeButton, from: $0)
            }
        }

        private var candidateNavigationItems: [UINavigationItem] {
            var items: [UINavigationItem] = [navigationItem]

            var currentParent = parent
            while let viewController = currentParent {
                items.append(viewController.navigationItem)
                currentParent = viewController.parent
            }

            if let navigationController {
                items.append(navigationController.navigationItem)
                items.append(contentsOf: navigationController.viewControllers.map(\.navigationItem))
                if let topViewController = navigationController.topViewController {
                    items.append(topViewController.navigationItem)
                }
                if let visibleViewController = navigationController.visibleViewController {
                    items.append(visibleViewController.navigationItem)
                }
            }

            return items
        }

        private func remove(_ displayModeButton: UIBarButtonItem, from navigationItem: UINavigationItem) {
            if let leadingItem = navigationItem.leftBarButtonItem,
               matches(leadingItem, displayModeButton) {
                navigationItem.leftBarButtonItem = nil
            }

            guard let leadingItems = navigationItem.leftBarButtonItems else { return }
            let filteredItems = leadingItems.filter { !matches($0, displayModeButton) }
            if filteredItems.count != leadingItems.count {
                navigationItem.leftBarButtonItems = filteredItems.isEmpty ? nil : filteredItems
            }

            navigationItem.leftItemsSupplementBackButton = false
        }

        private func matches(_ item: UIBarButtonItem, _ displayModeButton: UIBarButtonItem) -> Bool {
            if item === displayModeButton { return true }

            if item.action == displayModeButton.action {
                let itemTarget = item.target as AnyObject?
                let displayModeTarget = displayModeButton.target as AnyObject?
                if itemTarget === displayModeTarget { return true }
            }

            return false
        }
    }
}
