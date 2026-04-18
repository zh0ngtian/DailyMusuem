import SwiftUI

struct RootView: View {
    @ObservedObject var router: AppRouter
    @State private var isShowingRequestLogs = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            NavigationStack(path: $router.path) {
                MuseumListView()
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
            }

            if !isShowingRequestLogs {
                logButton
            }
        }
        .sheet(isPresented: $isShowingRequestLogs) {
            NavigationStack {
                RequestLogsView {
                    isShowingRequestLogs = false
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .museum(let museum):
            ArtworkFeedView(museum: museum)
        case .artwork(let reference):
            ArtworkDetailLoaderView(reference: reference)
        case .favorites:
            FavoritesView()
        case .settings:
            SettingsView()
        }
    }

    private var logButton: some View {
        Button {
            isShowingRequestLogs = true
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.black, in: Circle())
        }
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
        .padding(.leading, 16)
        .padding(.bottom, 16)
    }
}

enum Route: Hashable {
    case museum(Museum)
    case artwork(ArtworkReference)
    case favorites
    case settings
}
