import Foundation

final class GuimetMuseumAPI {
    struct SearchPoolSnapshot {
        let artworkReferences: [String]
        let hasMoreRemoteItems: Bool
    }

    private enum Constants {
        static let baseURL = URL(string: "https://www.guimet.fr")!
        static let collectionsLandingPath = "/zh-hans/cangpin"
        static let artworkPathPrefix = "/zh-hans/nos-collections/"
        static let objectIDPathSeparator = "~"
        static let requestTimeout: TimeInterval = 20
        static let repositoryName = "吉美国立亚洲艺术博物馆"
    }

    private let session: URLSession
    private let responseCache = GuimetMuseumResponseCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchArtworkReferences(
        collectionPaths: [String]? = nil,
        minimumCount: Int = 10,
        cachePolicy: MuseumRequestCachePolicy = .useCaches,
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> SearchPoolSnapshot {
        let paths = normalizedCollectionPaths(collectionPaths)
        let cacheKey = searchCacheKey(for: paths)

        if cachePolicy.usesCaches,
           let cached = await responseCache.searchState(forKey: cacheKey),
           !cached.references.isEmpty {
            await onLog?("已命中吉美官网藏品页缓存，复用 \(cached.references.count) 条网页路径。")
            return SearchPoolSnapshot(
                artworkReferences: cached.references,
                hasMoreRemoteItems: false
            )
        } else if !cachePolicy.usesCaches {
            await onLog?("network-only 模式，跳过吉美官网藏品页缓存读取。")
        }

        var references: [String] = []
        var knownReferences = Set<String>()
        for path in paths {
            try Task.checkCancellation()
            let url = Constants.baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            let html = try await fetchHTML(url: url, source: "吉美国立亚洲艺术博物馆分类页")
            let summaries = Self.parseCollectionPage(html, baseURL: Constants.baseURL)
            for summary in summaries where knownReferences.insert(summary.objectID).inserted {
                references.append(summary.objectID)
            }
            let label = Self.collectionDisplayName(forPath: path) ?? "分类页"
            await onLog?("\(label)：官网分类页已解析 \(summaries.count) 条藏品候选。")
        }

        if cachePolicy.usesCaches {
            await responseCache.setSearchState(references: references, forKey: cacheKey)
        }

        return SearchPoolSnapshot(
            artworkReferences: references,
            hasMoreRemoteItems: false
        )
    }

    func resetSearchCache(collectionPaths: [String]? = nil) async {
        await responseCache.removeSearchState(forKey: searchCacheKey(for: normalizedCollectionPaths(collectionPaths)))
    }

    func fetchArtwork(
        reference: String,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> Artwork {
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if cachePolicy.usesCaches,
           let cached = await responseCache.artwork(forObjectID: normalizedReference) {
            await RequestLogger.shared.logEvent(source: "吉美官网详情", summary: "命中缓存，path=\(normalizedReference)")
            return cached
        }

        let url = try Self.artworkURL(forObjectID: normalizedReference, baseURL: Constants.baseURL)
        let html = try await fetchHTML(url: url, source: "吉美官网详情")
        let artwork = try Self.parseDetailPage(
            html,
            detailURL: url,
            objectID: normalizedReference,
            repositoryName: Constants.repositoryName
        )
        if cachePolicy.usesCaches {
            await responseCache.setArtwork(artwork)
        }
        return artwork
    }

    static func parseCollectionPage(_ html: String, baseURL: URL) -> [GuimetMuseumArtworkSummary] {
        let articleRanges = ranges(
            in: html,
            pattern: #"<div\b[^>]*role=["']article["'][^>]*node--type-art-work[^>]*>"#
        )
        guard !articleRanges.isEmpty else {
            return []
        }

        return articleRanges.enumerated().compactMap { index, range in
            let end = index + 1 < articleRanges.count ? articleRanges[index + 1].lowerBound : html.endIndex
            let fragment = String(html[range.lowerBound..<end])
            let link = firstCapture(
                in: fragment,
                pattern: #"<a\b[^>]*class=["'][^"']*\bread-more-link\b[^"']*["'][^>]*href=["']([^"']+)["']"#
            ) ?? firstCapture(
                in: fragment,
                pattern: #"<a\b[^>]*href=["']([^"']+)["'][^>]*class=["'][^"']*\bread-more-link\b[^"']*["']"#
            )
            guard let detailURL = publicURL(from: link, baseURL: baseURL),
                  let objectID = objectID(fromArtworkURL: detailURL) else {
                return nil
            }

            let title = firstCapture(in: fragment, pattern: #"<h2[^>]*>([\s\S]*?)</h2>"#)
                .flatMap(sanitizedInlineText) ?? objectID
            let imageURL = imageURL(in: fragment, baseURL: baseURL)
            let category = firstCapture(
                in: fragment,
                pattern: #"<span\b[^>]*field--name-field-ref-taxo-work-category[^>]*>([\s\S]*?)</span>"#
            )
            .flatMap(sanitizedInlineText)

            return GuimetMuseumArtworkSummary(
                objectID: objectID,
                title: title,
                category: category,
                imageURL: imageURL,
                detailURL: detailURL
            )
        }
    }

    static func parseDetailPage(
        _ html: String,
        detailURL: URL,
        objectID: String? = nil,
        repositoryName: String = Constants.repositoryName
    ) throws -> Artwork {
        guard let resolvedObjectID = objectID ?? Self.objectID(fromArtworkURL: detailURL) else {
            throw URLError(.cannotParseResponse)
        }

        let details = parseInfoTable(html)
        let title = firstCapture(
            in: html,
            pattern: #"<h1\b[^>]*class=["'][^"']*\bartwork-title\b[^"']*["'][^>]*>([\s\S]*?)</h1>"#
        )
        .flatMap(sanitizedInlineText)
        ?? metaContent(named: "og:title", in: html)
        ?? resolvedObjectID

        let imageURL = imageURL(
            in: firstCapture(
                in: html,
                pattern: #"<div\b[^>]*class=["'][^"']*\bmain-artwork\b[^"']*["'][^>]*>([\s\S]*?)</figure>"#
            ) ?? html,
            baseURL: Constants.baseURL
        ) ?? metaContent(named: "og:image", in: html).flatMap { publicURL(from: $0, baseURL: Constants.baseURL) }

        let description = parseDescription(html)
        let objectDate = firstCapture(
            in: html,
            pattern: #"<div\b[^>]*field--name-field-text-period[^>]*>([\s\S]*?)</div>"#
        )
        .flatMap(sanitizedInlineText)

        return Artwork(
            id: "guimet-\(resolvedObjectID)",
            museumID: .guimet,
            objectID: resolvedObjectID,
            title: title,
            artworkDescription: description,
            artistDisplayName: details["作者"] ?? details["艺术家"],
            objectDate: objectDate,
            medium: details["材质"],
            dimensions: details["尺寸"],
            department: details["分类"],
            culture: details["地区或地点"],
            country: nil,
            repository: repositoryName,
            primaryImageURL: imageURL,
            primaryImageSmallURL: imageURL,
            objectURL: detailURL
        )
    }

    fileprivate static func objectID(fromArtworkURL url: URL) -> String? {
        guard let decodedPath = url.path.removingPercentEncoding,
              decodedPath.hasPrefix(Constants.artworkPathPrefix) else {
            return nil
        }

        let path = String(decodedPath.dropFirst(Constants.artworkPathPrefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        return path.replacingOccurrences(of: "/", with: Constants.objectIDPathSeparator)
    }

    private static func artworkURL(forObjectID objectID: String, baseURL: URL) throws -> URL {
        let normalized = objectID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: Constants.objectIDPathSeparator)
        let components = normalized
            .split(separator: Character(Constants.objectIDPathSeparator))
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw URLError(.badURL)
        }

        var url = baseURL
        for component in ["zh-hans", "nos-collections"] + components {
            url.append(path: component)
        }
        return url
    }

    private func fetchHTML(url: URL, source: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw URLError(.cannotDecodeContentData)
        }
        await RequestLogger.shared.logEvent(source: source, summary: "已拉取 \(url.absoluteString)")
        return html
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func normalizedCollectionPaths(_ paths: [String]?) -> [String] {
        let rawPaths = paths?.compactMap(Self.cleanPath) ?? Self.defaultCollectionPaths
        return Self.uniqueStrings(rawPaths).sorted()
    }

    private func searchCacheKey(for paths: [String]) -> String {
        paths.joined(separator: "|")
    }

    private static let defaultCollectionPaths: [String] = [
        "/zh-hans/collections/afghanistan-et-gandhara",
        "/zh-hans/collections/asie-du-sud-est",
        "/zh-hans/collections/monde-indien",
        "/zh-hans/collections/monde-himalayen",
        "/zh-hans/collections/chine",
        "/zh-hans/collections/chine-bouddhique-asie-centrale",
        "/zh-hans/collections/coree",
        "/zh-hans/collections/japon",
        "/zh-hans/collections/textiles",
        "/zh-hans/collections/tresors-de-la-bibliotheque",
        "/zh-hans/collections/photographies"
    ]

    private static let collectionNamesByPath: [String: String] = [
        "/zh-hans/collections/afghanistan-et-gandhara": "阿富汗 - 巴基斯坦",
        "/zh-hans/collections/asie-du-sud-est": "东南亚",
        "/zh-hans/collections/monde-indien": "印度世界",
        "/zh-hans/collections/monde-himalayen": "喜马拉雅世界",
        "/zh-hans/collections/chine": "中国",
        "/zh-hans/collections/chine-bouddhique-asie-centrale": "中国佛教 - 中亚",
        "/zh-hans/collections/coree": "韩国收藏",
        "/zh-hans/collections/japon": "日本",
        "/zh-hans/collections/textiles": "织物",
        "/zh-hans/collections/tresors-de-la-bibliotheque": "历史图书馆珍藏",
        "/zh-hans/collections/photographies": "摄影作品"
    ]

    private static func collectionDisplayName(forPath path: String) -> String? {
        collectionNamesByPath[cleanPath(path) ?? path]
    }

    private static func parseInfoTable(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        let cells = matches(
            in: html,
            pattern: #"<div\b[^>]*class=["'][^"']*\bcell\b[^"']*["'][^>]*>[\s\S]*?</div>"#
        )
        for cell in cells {
            guard let label = firstCapture(
                in: cell,
                pattern: #"<span\b[^>]*class=["'][^"']*\bfield__label\b[^"']*["'][^>]*>([\s\S]*?)</span>"#
            )
            .flatMap(sanitizedInlineText),
                  let value = firstCapture(
                    in: cell,
                    pattern: #"<span\b[^>]*class=["'][^"']*\bvalue\b[^"']*["'][^>]*>([\s\S]*?)</span>"#
                  )
                  .flatMap(sanitizedInlineText) else {
                continue
            }
            result[label] = value
        }
        return result
    }

    private static func parseDescription(_ html: String) -> String? {
        var fragments: [String] = []
        if let teaser = firstCapture(
            in: html,
            pattern: #"<div\b[^>]*field--name-field-teaser[^>]*>([\s\S]*?)</div>"#
        ) {
            fragments.append(teaser)
        }

        if let widgetsRange = html.range(of: "field--name-field_ref_widgets")
            ?? html.range(of: "field--name-field-ref-widgets"),
           let accordionRange = html.range(of: "paragraph--type--accordion", range: widgetsRange.upperBound..<html.endIndex) {
            let widgetsHTML = String(html[widgetsRange.lowerBound..<accordionRange.lowerBound])
            fragments.append(contentsOf: captures(in: widgetsHTML, pattern: #"<p\b[^>]*>([\s\S]*?)</p>"#))
        }

        let lines = fragments
            .compactMap(sanitizedBlockText)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return uniqueStrings(lines).joined(separator: "\n\n")
    }

    private static func imageURL(in html: String, baseURL: URL) -> URL? {
        let src = firstCapture(in: html, pattern: #"<img\b[^>]*\bsrc=["']([^"']+)["']"#)
            ?? firstCapture(in: html, pattern: #"<source\b[^>]*\bsrcset=["']([^"'\s]+)"#)
        return publicURL(from: src, baseURL: baseURL)
    }

    private static func metaContent(named name: String, in html: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        return firstCapture(
            in: html,
            pattern: #"<meta\b[^>]*(?:property|name)=["']\#(escapedName)["'][^>]*content=["']([^"']+)["'][^>]*>"#
        )
        .flatMap(sanitizedInlineText)
    }

    private static func publicURL(from rawValue: String?, baseURL: URL) -> URL? {
        guard let rawValue = cleanText(rawValue)?.decodingCommonHTMLEntities(punctuationStyle: .chinese) else {
            return nil
        }
        if let url = URL(string: rawValue), url.scheme != nil {
            return url
        }
        return URL(string: rawValue, relativeTo: baseURL)?.absoluteURL
    }

    private static func sanitizedInlineText(_ html: String?) -> String? {
        sanitizedBlockText(html)?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmedNonEmpty
    }

    private static func sanitizedBlockText(_ html: String?) -> String? {
        guard let html else { return nil }
        let cleaned = html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingCommonHTMLEntities(punctuationStyle: .chinese)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmedNonEmpty
        return cleaned
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        ranges(in: text, pattern: pattern).map { String(text[$0]) }
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captures(in: text, pattern: pattern).first
    }

    private static func ranges(in text: String, pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text) }
    }

    private static func cleanPath(_ value: String?) -> String? {
        guard let value = cleanText(value) else { return nil }
        if let url = URL(string: value), let host = url.host, host.contains("guimet.fr") {
            return url.path
        }
        return value.hasPrefix("/") ? value : "/\(value)"
    }

    fileprivate static func cleanText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    fileprivate static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}

struct GuimetMuseumArtworkSummary: Equatable {
    let objectID: String
    let title: String
    let category: String?
    let imageURL: URL?
    let detailURL: URL
}

private actor GuimetMuseumResponseCache {
    struct SearchState {
        let references: [String]
    }

    static let shared = GuimetMuseumResponseCache()

    private var searchStates: [String: SearchState] = [:]
    private var artworks: [String: Artwork] = [:]

    func searchState(forKey key: String) -> SearchState? {
        searchStates[key]
    }

    func setSearchState(references: [String], forKey key: String) {
        searchStates[key] = SearchState(references: references)
    }

    func removeSearchState(forKey key: String) {
        searchStates.removeValue(forKey: key)
    }

    func artwork(forObjectID objectID: String) -> Artwork? {
        artworks[objectID]
    }

    func setArtwork(_ artwork: Artwork) {
        artworks[artwork.objectID] = artwork
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
