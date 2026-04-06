import SwiftUI

struct RootView: View {
    @ObservedObject var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.path) {
            MuseumListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .museum(let museum):
                        ArtworkFeedView(museum: museum)
                    case .artwork(let reference):
                        ArtworkDetailLoaderView(reference: reference)
                    case .settings:
                        SettingsView()
                    }
                }
        }
    }
}

enum Route: Hashable {
    case museum(Museum)
    case artwork(ArtworkReference)
    case settings
}
