import Foundation
import WidgetKit

struct InstallPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let installURL: URL
}

@MainActor
final class InstallPromptController: ObservableObject {
    static let shared = InstallPromptController()

    @Published var prompt: InstallPrompt?

    private init() {}

    func showShortcutInstallPrompt(
        shortcutName: String,
        installURL: URL,
        errorMessage: String? = nil
    ) {
        prompt = InstallPrompt(
            title: "需要安装快捷指令",
            message: installPromptMessage(
                baseMessage: "请先安装“\(shortcutName)”快捷指令后再试。",
                errorMessage: errorMessage
            ),
            installURL: installURL
        )
    }

    func showAppInstallPrompt(
        appName: String,
        installURL: URL,
        errorMessage: String? = nil
    ) {
        prompt = InstallPrompt(
            title: "需要安装 App",
            message: installPromptMessage(
                baseMessage: "请先安装“\(appName)”App后再试。",
                errorMessage: errorMessage
            ),
            installURL: installURL
        )
    }

    private func installPromptMessage(baseMessage: String, errorMessage: String?) -> String {
        guard let errorMessage, !errorMessage.isEmpty else {
            return baseMessage
        }
        return "\(baseMessage)\n\n系统返回：\(errorMessage)"
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [Route] = []

    func handle(url: URL) {
        if SettingsKeys.widgetCompatibilityMode, let group = WidgetCompatibilityGroup.from(refreshURL: url) {
            path = []
            Task {
                await WidgetManualRefreshRunner(logSource: "Widget 兼容刷新")
                    .perform(compatibilityGroup: group)
            }
            return
        }
        #if DEBUG
        if handleDebugWidgetRefresh(url: url) {
            return
        }
        #endif
        if let promptReference = AppDeepLink.parseShortcutInstallPrompt(url: url) {
            showInstallPrompt(for: promptReference)
            return
        }
        guard let reference = AppDeepLink.parse(url: url) else { return }
        path = [.artwork(reference)]
    }

    private func showInstallPrompt(for promptReference: ShortcutInstallPromptReference) {
        let promptKind = AIAssistantInstallPromptKind.resolve(errorMessage: promptReference.errorMessage)
        if promptKind == .app,
           let appName = promptReference.appName,
           let appInstallURL = promptReference.appInstallURL {
            InstallPromptController.shared.showAppInstallPrompt(
                appName: appName,
                installURL: appInstallURL,
                errorMessage: promptReference.errorMessage
            )
            return
        }

        InstallPromptController.shared.showShortcutInstallPrompt(
            shortcutName: promptReference.shortcutName,
            installURL: promptReference.shortcutInstallURL,
            errorMessage: promptReference.errorMessage
        )
    }

    #if DEBUG
    private func handleDebugWidgetRefresh(url: URL) -> Bool {
        guard url.scheme == "dailymuseum",
              url.host == "debug",
              url.path == "/widget-refresh" else {
            return false
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let familyKey = queryItems.first(where: { $0.name == "familyKey" })?.value ?? ""
        let instanceToken = queryItems.first(where: { $0.name == "instanceToken" })?.value
        let scopeRawValue = queryItems.first(where: { $0.name == "scopeRawValue" })?.value
        Task {
            await WidgetManualRefreshRunner(logSource: "Widget 调试")
                .perform(
                    familyKey: familyKey,
                    instanceToken: instanceToken,
                    scopeRawValue: scopeRawValue
                )
        }
        return true
    }
    #endif
}
