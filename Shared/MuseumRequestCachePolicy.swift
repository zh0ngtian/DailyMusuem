import Foundation

enum MuseumRequestCachePolicy: Sendable {
    case useCaches
    case networkOnly

    var usesCaches: Bool {
        self == .useCaches
    }
}
