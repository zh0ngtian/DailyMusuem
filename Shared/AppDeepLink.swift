import Foundation

struct ArtworkReference: Hashable, Codable {
    let museumID: MuseumID
    let objectID: String
}

enum AppDeepLink {
    private static let scheme = "dailymuseum"
    private static let artworkHost = "artwork"

    static func artworkURL(reference: ArtworkReference) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = artworkHost
        components.path = "/\(reference.museumID.rawValue)/\(reference.objectID)"
        return components.url
    }

    static func parse(url: URL) -> ArtworkReference? {
        guard url.scheme == scheme, url.host == artworkHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2,
              let museumID = MuseumID(rawValue: parts[0]) else {
            return nil
        }
        return ArtworkReference(museumID: museumID, objectID: parts[1])
    }
}
