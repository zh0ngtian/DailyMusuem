import Foundation
import WidgetKit

struct ShortcutInstallPrompt: Identifiable {
    let id = UUID()
    let shortcutName: String
    let installURL: URL
    let errorMessage: String?

    var title: String {
        "需要安装快捷指令"
    }

    var message: String {
        let baseMessage = "请先安装“\(shortcutName)”快捷指令后再试。"
        guard let errorMessage, !errorMessage.isEmpty else {
            return baseMessage
        }
        return "\(baseMessage)\n\n系统返回：\(errorMessage)"
    }
}

@MainActor
final class ShortcutInstallPromptController: ObservableObject {
    static let shared = ShortcutInstallPromptController()

    @Published var prompt: ShortcutInstallPrompt?

    private init() {}

    func show(shortcutName: String, installURL: URL, errorMessage: String? = nil) {
        prompt = ShortcutInstallPrompt(
            shortcutName: shortcutName,
            installURL: installURL,
            errorMessage: errorMessage
        )
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [Route] = []

    func handle(url: URL) {
        #if DEBUG
        if handleDebugWidgetRefresh(url: url) {
            return
        }
        #endif
        if let promptReference = AppDeepLink.parseShortcutInstallPrompt(url: url) {
            ShortcutInstallPromptController.shared.show(
                shortcutName: promptReference.shortcutName,
                installURL: promptReference.installURL,
                errorMessage: promptReference.errorMessage
            )
            return
        }
        guard let reference = AppDeepLink.parse(url: url) else { return }
        path = [.artwork(reference)]
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
