import Foundation

struct ArtworkReference: Hashable, Codable {
    let museumID: MuseumID
    let objectID: String
    let imageAspectRatio: Double?
}

enum AppDeepLink {
    private static let scheme = "dailymuseum"
    private static let artworkHost = "artwork"

    static func artworkURL(reference: ArtworkReference) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = artworkHost
        components.path = "/\(reference.museumID.rawValue)/\(reference.objectID)"
        if let imageAspectRatio = reference.imageAspectRatio {
            components.queryItems = [
                URLQueryItem(name: "imageAspectRatio", value: String(imageAspectRatio))
            ]
        }
        return components.url
    }

    static func parse(url: URL) -> ArtworkReference? {
        guard url.scheme == scheme, url.host == artworkHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2,
              let museumID = MuseumID(rawValue: parts[0]) else {
            return nil
        }
        let imageAspectRatio = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "imageAspectRatio" })?
            .value
            .flatMap(Double.init)
        return ArtworkReference(
            museumID: museumID,
            objectID: parts[1],
            imageAspectRatio: imageAspectRatio
        )
    }
}
