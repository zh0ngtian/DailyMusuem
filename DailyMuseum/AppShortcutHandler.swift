import UIKit

private enum AppShortcutAction: String {
    case forceRefreshAllWidgets = "tech.zh0ngtian.DailyMuseum.shortcuts.forceRefreshAllWidgets"
}

@MainActor
final class PreviewOrientationCoordinator {
    static let shared = PreviewOrientationCoordinator()

    let defaultMask: UIInterfaceOrientationMask = [.portrait, .portraitUpsideDown]
    private(set) var currentMask: UIInterfaceOrientationMask

    private init() {
        currentMask = defaultMask
    }

    func activatePreviewMode() {
        updateOrientationMask(.allButUpsideDown)
    }

    func deactivatePreviewMode() {
        updateOrientationMask(defaultMask)
    }

    private func updateOrientationMask(_ mask: UIInterfaceOrientationMask) {
        guard currentMask != mask else {
            return
        }

        currentMask = mask

        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { scene in
                scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
            }

        for scene in activeScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            scene.requestGeometryUpdate(preferences) { _ in }
        }
    }
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

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PreviewOrientationCoordinator.shared.currentMask
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
