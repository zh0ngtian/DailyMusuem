import Foundation

struct ArtworkReference: Hashable, Codable {
    let museumID: MuseumID
    let objectID: String
    let imageAspectRatio: Double?

    static func == (lhs: ArtworkReference, rhs: ArtworkReference) -> Bool {
        lhs.museumID == rhs.museumID && lhs.objectID == rhs.objectID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(museumID)
        hasher.combine(objectID)
    }
}

struct ShortcutInstallPromptReference: Hashable {
    let shortcutName: String
    let installURL: URL
    let errorMessage: String?
}

enum AppDeepLink {
    private static let scheme = "dailymuseum"
    private static let artworkHost = "artwork"
    private static let shortcutHost = "shortcut"
    private static let shortcutInstallPromptPath = "/install-prompt"

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

    static func shortcutInstallPromptURL(shortcutName: String, installURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = shortcutHost
        components.path = shortcutInstallPromptPath
        components.queryItems = [
            URLQueryItem(name: "shortcutName", value: shortcutName),
            URLQueryItem(name: "installURL", value: installURL.absoluteString)
        ]
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

    static func parseShortcutInstallPrompt(url: URL) -> ShortcutInstallPromptReference? {
        guard url.scheme == scheme,
              url.host == shortcutHost,
              url.path == shortcutInstallPromptPath else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let shortcutName = queryItems.first(where: { $0.name == "shortcutName" })?.value,
              !shortcutName.isEmpty,
              let installURLString = queryItems.first(where: { $0.name == "installURL" })?.value,
              let installURL = URL(string: installURLString) else {
            return nil
        }

        return ShortcutInstallPromptReference(
            shortcutName: shortcutName,
            installURL: installURL,
            errorMessage: queryItems.first(where: { $0.name == "errorMessage" })?.value
        )
    }
}
