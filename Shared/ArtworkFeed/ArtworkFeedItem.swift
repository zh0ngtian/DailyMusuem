import Foundation

struct ArtworkFeedItem: Identifiable, Hashable {
    private static let minimumDisplayAspectRatio = 1.0 / 3.0
    private static let maximumDisplayAspectRatio = 3.0

    let id: String
    let artwork: Artwork
    var imageAspectRatio: Double?

    var resolvedImageAspectRatio: Double {
        imageAspectRatio ?? 0.78
    }

    var displayImageAspectRatio: Double {
        min(max(resolvedImageAspectRatio, Self.minimumDisplayAspectRatio), Self.maximumDisplayAspectRatio)
    }

    var needsExtremeAspectRatioPadding: Bool {
        resolvedImageAspectRatio < Self.minimumDisplayAspectRatio || resolvedImageAspectRatio > Self.maximumDisplayAspectRatio
    }

    var isExtremelyWideImage: Bool {
        resolvedImageAspectRatio > Self.maximumDisplayAspectRatio
    }
}
