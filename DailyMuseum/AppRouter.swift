import Foundation
import WidgetKit

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [Route] = []

    func handle(url: URL) {
        #if DEBUG
        if handleDebugWidgetRefresh(url: url) {
            return
        }
        #endif
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
