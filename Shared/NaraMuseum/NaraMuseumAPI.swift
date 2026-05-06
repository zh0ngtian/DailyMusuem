import Foundation

enum NaraMuseumDataSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case official
    case colbase

    static let defaultValue: NaraMuseumDataSource = .official

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .official:
            return "馆方数据源"
        case .colbase:
            return "ColBase"
        }
    }

    static func storedValue(in defaults: UserDefaults) -> NaraMuseumDataSource {
        guard
            let rawValue = defaults.string(forKey: SettingsKeys.naraMuseumDataSource),
            let value = NaraMuseumDataSource(rawValue: rawValue)
        else {
            return defaultValue
        }
        return value
    }
}

enum NaraMuseumOfficialDepartment: String, CaseIterable, Identifiable, Sendable {
    case sculpture = "雕刻"
    case painting = "绘画"
    case calligraphy = "书迹"
    case craft = "工艺"
    case archaeology = "考古"
    case ancientChineseBronze = "中国古代青铜器"
    case other = "其他"

    var id: String {
        switch self {
        case .sculpture:
            return "official-sculpture"
        case .painting:
            return "official-painting"
        case .calligraphy:
            return "official-calligraphy"
        case .craft:
            return "official-craft"
        case .archaeology:
            return "official-archaeology"
        case .ancientChineseBronze:
            return "official-ancient-chinese-bronze"
        case .other:
            return "official-other"
        }
    }

    var displayName: String {
        rawValue
    }
}

final class NaraMuseumAPI {
    struct SearchPoolSnapshot {
        let objectIDs: [String]
        let hasMoreRemoteItems: Bool
    }

    private enum Constants {
        static let requestTimeout: TimeInterval = 20
        static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        static let accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        static let acceptLanguage = "zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7"
        static let repositoryName = "奈良国立博物馆"
    }

    static let objectIDPrefix = "narahaku-"

    private let baseURL = URL(string: "https://www.narahaku.go.jp/chinese/collection/")!
    private let session: URLSession
    private let responseCache = NaraMuseumResponseCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func isOfficialObjectID(_ objectID: String) -> Bool {
        objectID.hasPrefix(objectIDPrefix)
    }

    static func rawObjectID(from objectID: String) -> String {
        if objectID.hasPrefix(objectIDPrefix) {
            return String(objectID.dropFirst(objectIDPrefix.count))
        }
        return objectID
    }

    static func officialObjectID(from rawID: String) -> String {
        rawID.hasPrefix(objectIDPrefix) ? rawID : "\(objectIDPrefix)\(rawID)"
    }

    func searchArtworkIDs(
        departments: [String]? = nil,
        minimumCount: Int = 10,
        cachePolicy: MuseumRequestCachePolicy = .useCaches,
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> SearchPoolSnapshot {
        let selectedDepartments = normalizedDepartments(departments)
        let cacheKey = selectedDepartments.joined(separator: "|")
        let logger = RequestLogger.shared

        if cachePolicy.usesCaches,
           let cached = await responseCache.searchState(forKey: cacheKey),
           !cached.objectIDs.isEmpty {
            await logger.logEvent(source: "奈良国立博物馆馆方搜索", summary: "命中内存缓存，复用 \(cached.objectIDs.count) 条 objectIDs")
            await onLog?("已命中奈良馆方搜索缓存，直接复用 \(cached.objectIDs.count) 条 objectIDs。")
            return SearchPoolSnapshot(objectIDs: cached.objectIDs, hasMoreRemoteItems: false)
        }

        await onLog?("开始从奈良国立博物馆馆方藏品数据库拉取候选，门类：\(selectedDepartments.joined(separator: "、"))。")
        var summaries: [NaraMuseumSearchSummary] = []
        for department in selectedDepartments {
            try Task.checkCancellation()
            let page = try await fetchSearchPage(department: department)
            let parsed = Self.parseSearchPage(page.html, baseURL: baseURL)
            summaries.append(contentsOf: parsed)
            await onLog?("\(department)：馆方搜索页已解析 \(parsed.count) 条候选。")
        }

        let uniqueSummaries = Self.stableUniqueSummaries(summaries)
        let objectIDs = uniqueSummaries.map(\.objectID)
        if cachePolicy.usesCaches {
            await responseCache.setSearchState(objectIDs: objectIDs, forKey: cacheKey)
            await responseCache.setSearchArtworks(uniqueSummaries.map(\.artwork))
        }

        await logger.logEvent(source: "奈良国立博物馆馆方搜索", summary: "搜索完成，门类=\(selectedDepartments.joined(separator: "、"))，共 \(objectIDs.count) 条")
        await onLog?("奈良馆方 objectIDs 已就绪，当前可用 \(objectIDs.count) 条。")
        return SearchPoolSnapshot(
            objectIDs: objectIDs.count >= minimumCount ? objectIDs : objectIDs,
            hasMoreRemoteItems: false
        )
    }

    func fetchArtwork(
        objectID: String,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> Artwork {
        let rawID = Self.rawObjectID(from: objectID)
        if cachePolicy.usesCaches,
           let cached = await responseCache.artwork(forID: rawID) {
            await RequestLogger.shared.logEvent(source: "奈良国立博物馆馆方详情", summary: "命中内存缓存，objectID=\(rawID)")
            return cached
        }

        let url = baseURL.appending(path: "\(rawID).html")
        let html = try await fetchHTML(url: url, source: "奈良国立博物馆馆方详情")
        let artwork = try Self.parseDetailPage(html, rawID: rawID, detailURL: url)
        if cachePolicy.usesCaches {
            await responseCache.setArtwork(artwork, forID: rawID)
        }
        return artwork
    }

    func cachedSearchArtwork(objectID: String) async -> Artwork? {
        let rawID = Self.rawObjectID(from: objectID)
        return await responseCache.searchArtwork(forID: rawID)
    }

    static func parseSearchPage(_ html: String, baseURL: URL) -> [NaraMuseumSearchSummary] {
        matches(in: html, pattern: #"<p\b[^>]*data-href=["'][^"']+["'][\s\S]*?</p>"#)
            .compactMap { block -> NaraMuseumSearchSummary? in
                guard
                    let href = firstCapture(in: block, pattern: #"data-href=["']([^"']+\.html)["']"#),
                    let rawID = href.split(separator: ".").first.map(String.init)
                else {
                    return nil
                }

                let imageTag = firstCapture(in: block, pattern: #"(<img\b[^>]*>)"#)
                let imageURLString = imageTag
                    .flatMap { attribute("data-original", in: $0) ?? attribute("src", in: $0) }
                let title = imageTag
                    .flatMap { attribute("alt", in: $0) }
                    .flatMap(cleanText)
                    ?? firstCapture(in: block, pattern: #"<span>([\s\S]*?)</span>"#).flatMap(cleanText)
                    ?? rawID
                let summary = firstCapture(in: block, pattern: #"<span>([\s\S]*?)</span>"#)
                    .flatMap {
                        cleanText(
                            $0.replacingOccurrences(
                                of: "(?i)\\s*<br\\s*/?>\\s*",
                                with: " / ",
                                options: .regularExpression
                            )
                        )
                    }
                let url = imageURLString.flatMap { absoluteURL(from: $0, baseURL: baseURL) }

                return NaraMuseumSearchSummary(
                    rawID: rawID,
                    title: title,
                    summary: summary,
                    thumbnailURL: url,
                    detailURL: baseURL.appending(path: href)
                )
            }
    }

    static func parseDetailPage(_ html: String, rawID: String, detailURL: URL) throws -> Artwork {
        guard let title = firstCapture(in: html, pattern: #"<h2>\s*([\s\S]*?)</h2>"#).flatMap(cleanText),
              !title.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        let descriptionBlock = firstCapture(in: html, pattern: #"<div class=["']description["'][^>]*>([\s\S]*?)<div class=["']btnOperation["']"#) ?? ""
        let descriptionLines = firstCapture(in: descriptionBlock, pattern: #"<p>([\s\S]*?)</p>"#)
            .map(linesFromBreakSeparatedHTML) ?? []
        let descriptionFields = parseDescriptionFields(from: descriptionLines)
        let placeAndDate = descriptionFields.placeAndDate
        let placeAndDateParts = placeAndDate?
            .components(separatedBy: CharacterSet(charactersIn: "　"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let country = placeAndDateParts.first
        let objectDate = placeAndDateParts.dropFirst().isEmpty ? placeAndDate : placeAndDateParts.dropFirst().joined(separator: " ")
        let department = parseTableValue(label: "门类", html: html)
        let description = firstCapture(in: html, pattern: #"<div class=["']text["']\s+id=["']kaisetsu["'][^>]*>([\s\S]*?)</div>"#)
            .flatMap(cleanDescriptionText)
        let mainImageTag = matches(in: html, pattern: #"<img\b[^>]*class=["']mainPicture["'][^>]*>"#).first
            ?? matches(in: html, pattern: #"<img\b[^>]*data-id=["']\#(NSRegularExpression.escapedPattern(for: rawID))["'][^>]*>"#).first
        let primaryURL = mainImageTag
            .flatMap { attribute("palm", in: $0) ?? attribute("data-original", in: $0) ?? attribute("src", in: $0) }
            .flatMap { absoluteURL(from: $0, baseURL: detailURL) }
        let smallURL = mainImageTag
            .flatMap { attribute("data-original", in: $0) ?? attribute("src", in: $0) ?? attribute("palm", in: $0) }
            .flatMap { absoluteURL(from: $0, baseURL: detailURL) }

        return Artwork(
            id: "nnm-\(Self.officialObjectID(from: rawID))",
            museumID: .nnm,
            objectID: Self.officialObjectID(from: rawID),
            title: title,
            artworkDescription: description,
            artistDisplayName: nil,
            objectDate: objectDate,
            medium: descriptionFields.medium,
            dimensions: descriptionFields.dimensions,
            department: department,
            culture: nil,
            country: country,
            repository: Constants.repositoryName,
            primaryImageURL: primaryURL,
            primaryImageSmallURL: smallURL,
            objectURL: detailURL
        )
    }

    private func normalizedDepartments(_ departments: [String]?) -> [String] {
        let allDepartments = NaraMuseumOfficialDepartment.allCases.map(\.displayName)
        guard let departments, !departments.isEmpty else {
            return allDepartments
        }
        let allowed = Set(allDepartments)
        let normalized = departments.filter { allowed.contains($0) }
        return normalized.isEmpty ? allDepartments : normalized
    }

    private func fetchSearchPage(department: String) async throws -> NaraMuseumSearchPage {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bumon", value: department),
            URLQueryItem(name: "img", value: "1"),
            URLQueryItem(name: "action", value: "image_search")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return NaraMuseumSearchPage(html: try await fetchHTML(url: url, source: "奈良国立博物馆馆方搜索"))
    }

    private func fetchHTML(url: URL, source: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Constants.accept, forHTTPHeaderField: "Accept")
        request.setValue(Constants.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let start = Date()
        await RequestLogger.shared.logRequestStart(source: source, url: url)
        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            await RequestLogger.shared.logRequestSuccess(
                source: source,
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return html
        } catch {
            await RequestLogger.shared.logRequestFailure(
                source: source,
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private static func stableUniqueSummaries(_ summaries: [NaraMuseumSearchSummary]) -> [NaraMuseumSearchSummary] {
        var seen: Set<String> = []
        var result: [NaraMuseumSearchSummary] = []
        result.reserveCapacity(summaries.count)

        for summary in summaries where seen.insert(summary.rawID).inserted {
            result.append(summary)
        }
        return result
    }

    private static func parseTableValue(label: String, html: String) -> String? {
        firstCapture(
            in: html,
            pattern: #"<th>\s*\#(NSRegularExpression.escapedPattern(for: label))\s*</th>\s*<td>([\s\S]*?)</td>"#
        ).flatMap(cleanText)
    }

    private static func linesFromBreakSeparatedHTML(_ html: String) -> [String] {
        html.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .compactMap(cleanText)
            .filter { !$0.isEmpty }
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstCapture(
            in: tag,
            pattern: #"\b\#(NSRegularExpression.escapedPattern(for: name))=["']([^"']*)["']"#
        )
    }

    private static func cleanText(_ html: String) -> String? {
        let cleaned = html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingCommonHTMLEntities(punctuationStyle: .chinese)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanDescriptionText(_ html: String) -> String? {
        let paragraphHTMLs = matches(in: html, pattern: #"(?i)<p\b[^>]*>[\s\S]*?</p>"#)
        let sourceHTMLs = paragraphHTMLs.isEmpty ? [html] : paragraphHTMLs

        let cleaned = sourceHTMLs
            .flatMap(descriptionTextSegments)
            .filter { !$0.contains("翻译") }
            .map(removingTextAfterFinalChinesePeriod)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func descriptionTextSegments(from html: String) -> [String] {
        html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingCommonHTMLEntities(punctuationStyle: .chinese)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func removingTextAfterFinalChinesePeriod(_ text: String) -> String {
        guard let finalPeriodIndex = text.lastIndex(of: "。") else {
            return text
        }

        return String(text[...finalPeriodIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absoluteURL(from rawValue: String, baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved: URL?
        if trimmed.hasPrefix("//") {
            resolved = URL(string: "https:\(trimmed)")
        } else if let absolute = URL(string: trimmed), absolute.scheme != nil {
            resolved = absolute
        } else {
            resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }

        guard let url = resolved,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return resolved
        }
        if components.scheme == "http" {
            components.scheme = "https"
        }
        return components.url ?? url
    }

    private static func parseDescriptionFields(from lines: [String]) -> (
        medium: String?,
        dimensions: String?,
        placeAndDate: String?
    ) {
        let indexedLines = Array(lines.enumerated())
        let dimensionIndex = indexedLines.first { isDimensionLine($0.element) }?.offset
        let placeAndDateIndex = dimensionIndex.flatMap { dimensionIndex in
            indexedLines.first { index, line in
                index > dimensionIndex && !isDimensionLine(line)
            }?.offset
        } ?? indexedLines.first { index, line in
            index != dimensionIndex && isPlaceAndDateLine(line)
        }?.offset
        let mediumIndex = indexedLines.first { index, _ in
            index != dimensionIndex && index != placeAndDateIndex
        }?.offset

        return (
            medium: mediumIndex.flatMap { lines[safe: $0] },
            dimensions: dimensionIndex.flatMap { lines[safe: $0] },
            placeAndDate: placeAndDateIndex.flatMap { lines[safe: $0] }
        )
    }

    private static func isDimensionLine(_ line: String) -> Bool {
        let hasNumber = line.range(of: #"[0-9０-９]"#, options: .regularExpression) != nil
        guard hasNumber else { return false }
        return line.range(
            of: #"(?i)(cm|mm|㎝|厘米|公分|高|縦|纵|長|长|横|幅|径|厚|奥行|全長|口径|底径)"#,
            options: .regularExpression
        ) != nil
    }

    private static func isPlaceAndDateLine(_ line: String) -> Bool {
        line.range(
            of: #"(世纪|世紀|公元|时代|時代|王朝|西周|东周|東周|春秋|战国|戰國|秦|汉|漢|魏|晋|隋|唐|宋|元|明|清|飞鸟|飛鳥|奈良|平安|鎌倉|镰仓|室町|桃山|江户|江戸|明治|大正|昭和|平成|令和)"#,
            options: .regularExpression
        ) != nil
    }
}

struct NaraMuseumSearchSummary: Equatable {
    let rawID: String
    let title: String
    let summary: String?
    let thumbnailURL: URL?
    let detailURL: URL

    var objectID: String {
        NaraMuseumAPI.officialObjectID(from: rawID)
    }

    var artwork: Artwork {
        Artwork(
            id: "nnm-\(objectID)",
            museumID: .nnm,
            objectID: objectID,
            title: title,
            artworkDescription: summary,
            artistDisplayName: nil,
            objectDate: nil,
            medium: nil,
            dimensions: nil,
            department: nil,
            culture: nil,
            country: nil,
            repository: "奈良国立博物馆",
            primaryImageURL: thumbnailURL,
            primaryImageSmallURL: thumbnailURL,
            objectURL: detailURL
        )
    }
}

private struct NaraMuseumSearchPage {
    let html: String
}

private actor NaraMuseumResponseCache {
    static let shared = NaraMuseumResponseCache()

    struct SearchState {
        let objectIDs: [String]
    }

    private var searchStateStorage: [String: SearchState] = [:]
    private var artworkStorage: [String: Artwork] = [:]
    private var searchArtworkStorage: [String: Artwork] = [:]

    func searchState(forKey key: String) -> SearchState? {
        searchStateStorage[key]
    }

    func setSearchState(objectIDs: [String], forKey key: String) {
        searchStateStorage[key] = SearchState(objectIDs: objectIDs)
    }

    func artwork(forID id: String) -> Artwork? {
        artworkStorage[id]
    }

    func setArtwork(_ artwork: Artwork, forID id: String) {
        artworkStorage[id] = artwork
    }

    func searchArtwork(forID id: String) -> Artwork? {
        searchArtworkStorage[NaraMuseumAPI.rawObjectID(from: id)]
    }

    func setSearchArtworks(_ artworks: [Artwork]) {
        for artwork in artworks {
            searchArtworkStorage[NaraMuseumAPI.rawObjectID(from: artwork.objectID)] = artwork
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
