import Foundation

struct ArtworkFeedItem: Identifiable, Hashable {
    let id: String
    let artwork: Artwork
    var imageAspectRatio: Double?
}

