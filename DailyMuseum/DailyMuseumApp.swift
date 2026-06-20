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
        Task(priority: .userInitiated) {
            try? await MuseumMetadataStore.shared.refresh(cachePolicy: .networkOnly)
        }
    }
}
