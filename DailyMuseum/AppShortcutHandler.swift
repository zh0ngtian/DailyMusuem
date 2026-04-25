import UIKit

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
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PreviewOrientationCoordinator.shared.currentMask
    }
}
