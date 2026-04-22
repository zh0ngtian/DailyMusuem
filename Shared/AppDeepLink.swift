import Foundation

enum WeChatShareDiagnostics {
    static func isSchemeDeclared(in plist: [String: Any]?) -> Bool {
        guard let rawSchemes = plist?["LSApplicationQueriesSchemes"] as? [Any] else {
            return false
        }

        return rawSchemes
            .compactMap { $0 as? String }
            .contains { $0.caseInsensitiveCompare("weixin") == .orderedSame }
    }

    static func canOpenFailureSummary(isSchemeDeclared: Bool) -> String {
        if isSchemeDeclared {
            return "分享失败：canOpenURL(weixin://) 返回 false，可能未安装微信，或系统当前无法拉起微信。"
        }

        return "分享失败：canOpenURL(weixin://) 返回 false，且 Info.plist 未声明 LSApplicationQueriesSchemes=weixin，当前无法准确判断是否已安装微信。"
    }

    static func openFailureSummary(isSchemeDeclared: Bool) -> String {
        if isSchemeDeclared {
            return "分享失败：UIApplication.open(weixin://) 回调返回 false。Info.plist 已声明 LSApplicationQueriesSchemes=weixin。"
        }

        return "分享失败：UIApplication.open(weixin://) 回调返回 false。Info.plist 未声明 LSApplicationQueriesSchemes=weixin。"
    }
}

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
    let shortcutInstallURL: URL
    let appName: String?
    let appInstallURL: URL?
    let errorMessage: String?
}

enum AIAssistantInstallPromptKind: Equatable {
    case shortcut
    case app

    static func resolve(errorMessage: String?) -> Self {
        guard let normalizedErrorMessage = errorMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedErrorMessage.isEmpty else {
            return .shortcut
        }

        let appFailureMarkers = [
            "the app could not be opened",
            "该app无法打开",
            "app无法打开"
        ]
        if appFailureMarkers.contains(where: normalizedErrorMessage.contains) {
            return .app
        }

        return .shortcut
    }
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

    static func shortcutInstallPromptURL(
        shortcutName: String,
        installURL: URL,
        appName: String? = nil,
        appInstallURL: URL? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = shortcutHost
        components.path = shortcutInstallPromptPath
        var queryItems = [
            URLQueryItem(name: "shortcutName", value: shortcutName),
            URLQueryItem(name: "shortcutInstallURL", value: installURL.absoluteString)
        ]
        if let appName, !appName.isEmpty {
            queryItems.append(URLQueryItem(name: "appName", value: appName))
        }
        if let appInstallURL {
            queryItems.append(URLQueryItem(name: "appInstallURL", value: appInstallURL.absoluteString))
        }
        components.queryItems = queryItems
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
              let installURLString = queryItems.first(where: { $0.name == "shortcutInstallURL" })?.value,
              let shortcutInstallURL = URL(string: installURLString) else {
            return nil
        }

        return ShortcutInstallPromptReference(
            shortcutName: shortcutName,
            shortcutInstallURL: shortcutInstallURL,
            appName: queryItems.first(where: { $0.name == "appName" })?.value,
            appInstallURL: queryItems
                .first(where: { $0.name == "appInstallURL" })?
                .value
                .flatMap(URL.init(string:)),
            errorMessage: queryItems.first(where: { $0.name == "errorMessage" })?.value
        )
    }
}
