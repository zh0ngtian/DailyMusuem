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
        let familyKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "familyKey" })?
            .value ?? ""
        Task {
            await WidgetManualRefreshRunner(logSource: "Widget 调试")
                .perform(familyKey: familyKey)
        }
        return true
    }
    #endif
}
