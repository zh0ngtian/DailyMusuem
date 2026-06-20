import SwiftUI
import UIKit

struct RootView: View {
    @ObservedObject var router: AppRouter
    @ObservedObject private var installPromptController = InstallPromptController.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var isShowingRequestLogs = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            NavigationStack(path: $router.path) {
                MuseumListView()
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
            }

            if settings.isRequestLogAccessUnlocked && !isShowingRequestLogs {
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
        .alert(item: $installPromptController.prompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text("去安装")) {
                    UIApplication.shared.open(prompt.installURL)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onChange(of: settings.isRequestLogAccessUnlocked) { _, isUnlocked in
            if !isUnlocked {
                isShowingRequestLogs = false
            }
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
