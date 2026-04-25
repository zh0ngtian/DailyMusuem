import Foundation
import SwiftUI

@main
struct DailyMuseumApp: App {
    @UIApplicationDelegateAdaptor(DailyMuseumAppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter()

    init() {
        StartupNetworkPermissionRequester.request()
    }

    var body: some Scene {
        WindowGroup {
            RootView(router: router)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
    }
}

private enum StartupNetworkPermissionRequester {
    static func request() {
        // iOS has no generic internet permission API; the first outbound request triggers the system prompt where required.
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 4

        Task(priority: .userInitiated) {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
