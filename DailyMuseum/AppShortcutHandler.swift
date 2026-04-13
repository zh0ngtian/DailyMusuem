import UIKit

private enum AppShortcutAction: String {
    case forceRefreshAllWidgets = "tech.zh0ngtian.DailyMuseum.shortcuts.forceRefreshAllWidgets"
}

final class DailyMuseumAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = DailyMuseumSceneDelegate.self
        return configuration
    }
}

final class DailyMuseumSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else {
            return
        }
        handle(shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handle(shortcutItem))
    }

    @discardableResult
    private func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = AppShortcutAction(rawValue: shortcutItem.type) else {
            return false
        }

        switch action {
        case .forceRefreshAllWidgets:
            Task { @MainActor in
                SettingsStore.shared.forceRefreshAllWidgets()
            }
            return true
        }
    }
}
