import SwiftUI

@main
struct DailyMuseumApp: App {
    @UIApplicationDelegateAdaptor(DailyMuseumAppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView(router: router)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
    }
}
