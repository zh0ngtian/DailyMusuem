import Foundation

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [Route] = []

    func handle(url: URL) {
        guard let reference = AppDeepLink.parse(url: url) else { return }
        path = [.artwork(reference)]
    }
}
