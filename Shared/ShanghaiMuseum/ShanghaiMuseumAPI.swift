import Foundation

final class ShanghaiMuseumAPI {
    struct SearchPoolSnapshot {
        let artworkCodes: [String]
        let hasMoreRemoteItems: Bool
    }

    private enum Constants {
        static let baseURL = URL(string: "https://www.shanghaimuseum.net/mu/")!
        static let pageSize = 10
        static let requestTimeout: TimeInterval = 20
        static let minimumRequestInterval: TimeInterval = 1
        static let repositoryName = "上海博物馆"
        static let countryName = "中国"
    }

    private let session: URLSession
    private let responseCache = ShanghaiMuseumResponseCache.shared
    private let persistentCache = ShanghaiMuseumPersistentCache.shared
    private static let requestThrottle = ShanghaiMuseumRequestThrottle(
        minimumInterval: Constants.minimumRequestInterval
    )

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchArtworkCodes(
        subtypes: [String]? = nil,
        minimumCount: Int = Constants.pageSize,
        cachePolicy: MuseumRequestCachePolicy = .useCaches,
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> SearchPoolSnapshot {
        let logger = RequestLogger.shared
        let cacheKey = searchCacheKey(for: subtypes)

        var artworkCodes: [String] = []
        var summaryArtworks: [Artwork] = []
        var nextPage = 1
        var hasMore = true

        if cachePolicy.usesCaches {
            await onLog?("检查上海博物馆展品编码内存缓存...")
            if let cached = await responseCache.searchState(forKey: cacheKey), !cached.artworkCodes.isEmpty {
                artworkCodes = cached.artworkCodes
                nextPage = cached.nextPage
                hasMore = cached.hasMore
                await logger.logEvent(source: "上海博物馆搜索", summary: "命中内存缓存，复用 \(cached.artworkCodes.count) 条展品编码")
                await onLog?("已命中内存缓存，直接复用 \(cached.artworkCodes.count) 条展品编码。")
                if cached.artworkCodes.count >= minimumCount || !cached.hasMore {
                    return SearchPoolSnapshot(artworkCodes: cached.artworkCodes, hasMoreRemoteItems: cached.hasMore)
                }
                await onLog?("现有上海博物馆缓存不足 \(minimumCount) 条，继续拉取下一页...")
            }

            if artworkCodes.isEmpty {
                await onLog?("未命中内存缓存，检查上海博物馆本地缓存...")
                if let persisted = await persistentCache.searchSnapshot(forKey: cacheKey), !persisted.artworkCodes.isEmpty {
                    artworkCodes = persisted.artworkCodes
                    summaryArtworks = persisted.summaryArtworks
                    nextPage = persisted.nextPage
                    hasMore = persisted.hasMore
                    await responseCache.setSearchState(
                        artworkCodes: persisted.artworkCodes,
                        nextPage: persisted.nextPage,
                        hasMore: persisted.hasMore,
                        forKey: cacheKey
                    )
                    if !persisted.summaryArtworks.isEmpty {
                        await responseCache.setArtworks(persisted.summaryArtworks)
                        await onLog?("已从本地缓存恢复 \(persisted.summaryArtworks.count) 条上海博物馆摘要数据。")
                    }
                    await logger.logEvent(source: "上海博物馆搜索", summary: "命中本地缓存，复用 \(persisted.artworkCodes.count) 条展品编码")
                    await onLog?("已命中本地缓存，读取到 \(persisted.artworkCodes.count) 条展品编码。")
                    if persisted.artworkCodes.count >= minimumCount || !persisted.hasMore {
                        return SearchPoolSnapshot(artworkCodes: persisted.artworkCodes, hasMoreRemoteItems: persisted.hasMore)
                    }
                    await onLog?("本地缓存条目不足 \(minimumCount) 条，继续拉取下一页...")
                }
            }
        } else {
            await onLog?("网络直连模式，跳过上海博物馆搜索缓存读取。")
        }

        if artworkCodes.isEmpty {
            await onLog?("未命中本地缓存，开始从上海博物馆拉取分页展品编码...")
        }

        var knownCodes = Set(artworkCodes)
        while artworkCodes.count < minimumCount, hasMore {
            let response = try await fetchSearchPage(
                subtypes: subtypes,
                page: nextPage,
                limit: Constants.pageSize
            )

            guard !response.data.isEmpty else {
                hasMore = false
                break
            }

            let uniqueItems = response.data.filter { item in
                let code = item.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { return false }
                return knownCodes.insert(code).inserted
            }
            let pageArtworks = uniqueItems.map { $0.toArtwork(baseURL: Constants.baseURL) }
            artworkCodes.append(contentsOf: pageArtworks.map(\.objectID))
            summaryArtworks.append(contentsOf: pageArtworks)

            if cachePolicy.usesCaches {
                await responseCache.setArtworks(pageArtworks)
                await persistentCache.setArtworks(pageArtworks)
            }

            let currentPage = nextPage
            nextPage += 1
            hasMore = currentPage * Constants.pageSize < response.count

            await onLog?("上海博物馆已缓存 \(artworkCodes.count) 条展品编码，后续按需继续拉取。")

            if cachePolicy.usesCaches {
                await responseCache.setSearchState(
                    artworkCodes: artworkCodes,
                    nextPage: nextPage,
                    hasMore: hasMore,
                    forKey: cacheKey
                )
                await persistentCache.setSearchSnapshot(
                    artworkCodes: artworkCodes,
                    summaryArtworks: summaryArtworks,
                    nextPage: nextPage,
                    hasMore: hasMore,
                    forKey: cacheKey
                )
            }
        }

        guard !artworkCodes.isEmpty else {
            await logger.logEvent(source: "上海博物馆搜索", summary: "搜索结果为空，忽略空缓存并返回空数组")
            await onLog?("上海博物馆未返回任何展品编码，本次不写入空缓存。")
            return SearchPoolSnapshot(artworkCodes: [], hasMoreRemoteItems: false)
        }

        if cachePolicy.usesCaches {
            await responseCache.setSearchState(
                artworkCodes: artworkCodes,
                nextPage: nextPage,
                hasMore: hasMore,
                forKey: cacheKey
            )
            await persistentCache.setSearchSnapshot(
                artworkCodes: artworkCodes,
                summaryArtworks: summaryArtworks,
                nextPage: nextPage,
                hasMore: hasMore,
                forKey: cacheKey
            )
            await onLog?("上海博物馆展品编码已就绪，当前缓存 \(artworkCodes.count) 条。")
        } else {
            await onLog?("上海博物馆展品编码已就绪，共 \(artworkCodes.count) 条，网络直连模式不写入缓存。")
        }
        return SearchPoolSnapshot(artworkCodes: artworkCodes, hasMoreRemoteItems: hasMore)
    }

    func allArtworkCodes(
        subtypes: [String]? = nil,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> [String] {
        var minimumCount = Constants.pageSize
        var snapshot = try await searchArtworkCodes(
            subtypes: subtypes,
            minimumCount: minimumCount,
            cachePolicy: cachePolicy
        )

        while snapshot.hasMoreRemoteItems {
            minimumCount = snapshot.artworkCodes.count + Constants.pageSize
            snapshot = try await searchArtworkCodes(
                subtypes: subtypes,
                minimumCount: minimumCount,
                cachePolicy: cachePolicy
            )
        }

        return snapshot.artworkCodes
    }

    func resetSearchCache(subtypes: [String]? = nil) async {
        let key = searchCacheKey(for: subtypes)
        await responseCache.removeSearchState(forKey: key)
        await persistentCache.removeSearchSnapshot(forKey: key)
    }

    func fetchArtwork(
        objectCode: String,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> Artwork {
        let logger = RequestLogger.shared

        if cachePolicy.usesCaches {
            if let cached = await responseCache.artwork(forCode: objectCode) {
                await logger.logEvent(source: "上海博物馆详情", summary: "命中内存缓存，code=\(objectCode)")
                return cached
            }

            if let persisted = await persistentCache.artwork(forCode: objectCode) {
                await responseCache.setArtwork(persisted, forCode: objectCode)
                await logger.logEvent(source: "上海博物馆详情", summary: "命中本地缓存，code=\(objectCode)")
                return persisted
            }
        }

        let page = try await fetchArticlePage(objectCode: objectCode)

        var primaryImageURL: URL?
        var primaryImageSmallURL: URL?
        do {
            let imageURLs = try await fetchImageURLs(objectCode: objectCode)
            primaryImageURL = imageURLs.primaryImageURL
            primaryImageSmallURL = imageURLs.primaryImageSmallURL
        } catch {
            await logger.logEvent(
                source: "上海博物馆详情",
                summary: "图片页解析失败，继续返回文字详情，code=\(objectCode)"
            )
        }

        let artwork = page.toArtwork(
            primaryImageURL: primaryImageURL,
            primaryImageSmallURL: primaryImageSmallURL,
            repositoryName: Constants.repositoryName,
            countryName: Constants.countryName
        )
        if cachePolicy.usesCaches {
            await responseCache.setArtwork(artwork, forCode: objectCode)
            await persistentCache.setArtwork(artwork, forCode: objectCode)
        }
        return artwork
    }

    func cachedSearchArtwork(objectCode: String) async -> Artwork? {
        await responseCache.artwork(forCode: objectCode)
    }

    private func fetchSearchPage(
        subtypes: [String]?,
        page: Int,
        limit: Int
    ) async throws -> ShanghaiMuseumSearchResponse {
        let url = makeSearchURL()
        let request = try makeSearchRequest(
            url: url,
            subtypes: subtypes,
            page: page,
            limit: limit
        )
        let logger = RequestLogger.shared
        let throttleDelay = try await Self.requestThrottle.waitForTurn()
        if throttleDelay > 0 {
            let delayText = String(format: "%.2f", throttleDelay)
            await logger.logEvent(
                source: "上海博物馆搜索",
                summary: "触发限流保护，等待 \(delayText)s 后再请求，page=\(page)"
            )
        }

        let start = Date()
        await logger.logRequestStart(source: "上海博物馆搜索", url: url)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let decoded = try JSONDecoder().decode(ShanghaiMuseumSearchResponse.self, from: data)
            guard decoded.code == 0 else {
                throw ShanghaiMuseumAPIError.api(decoded.msg)
            }
            await logger.logRequestSuccess(
                source: "上海博物馆搜索",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return decoded
        } catch {
            await logger.logRequestFailure(
                source: "上海博物馆搜索",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func fetchArticlePage(objectCode: String) async throws -> ShanghaiMuseumArticlePage {
        let url = articleURL(objectCode: objectCode)
        let request = makeGETRequest(
            url: url,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            referer: collectionURL()
        )
        let logger = RequestLogger.shared
        let throttleDelay = try await Self.requestThrottle.waitForTurn()
        if throttleDelay > 0 {
            let delayText = String(format: "%.2f", throttleDelay)
            await logger.logEvent(
                source: "上海博物馆详情",
                summary: "触发限流保护，等待 \(delayText)s 后再请求，code=\(objectCode)"
            )
        }

        let start = Date()
        await logger.logRequestStart(source: "上海博物馆详情", url: url)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let html = String(decoding: data, as: UTF8.self)
            let page = try ShanghaiMuseumArticlePageParser.parse(
                html: html,
                objectCode: objectCode,
                objectURL: url,
                baseURL: Constants.baseURL
            )
            await logger.logRequestSuccess(
                source: "上海博物馆详情",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return page
        } catch {
            await logger.logRequestFailure(
                source: "上海博物馆详情",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func fetchImageURLs(objectCode: String) async throws -> ShanghaiMuseumImageURLs {
        let url = imageFrameURL(objectCode: objectCode)
        let request = makeGETRequest(
            url: url,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            referer: articleURL(objectCode: objectCode)
        )
        let logger = RequestLogger.shared
        let throttleDelay = try await Self.requestThrottle.waitForTurn()
        if throttleDelay > 0 {
            let delayText = String(format: "%.2f", throttleDelay)
            await logger.logEvent(
                source: "上海博物馆图片",
                summary: "触发限流保护，等待 \(delayText)s 后再请求，code=\(objectCode)"
            )
        }

        let start = Date()
        await logger.logRequestStart(source: "上海博物馆图片", url: url)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let html = String(decoding: data, as: UTF8.self)
            let imageURLs = try ShanghaiMuseumImagePageParser.parse(html: html, baseURL: Constants.baseURL)
            await logger.logRequestSuccess(
                source: "上海博物馆图片",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return imageURLs
        } catch {
            await logger.logRequestFailure(
                source: "上海博物馆图片",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func searchCacheKey(for subtypes: [String]?) -> String {
        subtypeParameter(for: subtypes) ?? "all"
    }

    private func subtypeParameter(for subtypes: [String]?) -> String? {
        let normalized = normalizedSubtypes(subtypes)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return normalized.joined(separator: ",")
    }

    private func normalizedSubtypes(_ subtypes: [String]?) -> [String]? {
        guard let subtypes else { return nil }

        var seen: Set<String> = []
        let normalized: [String] = subtypes.compactMap { subtype -> String? in
            let trimmed = subtype.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }

        return normalized.isEmpty ? nil : normalized
    }

    private func makeSearchURL() -> URL {
        Constants.baseURL.appending(path: "frontend/pg/collection/search-antique")
    }

    private func collectionURL() -> URL {
        Constants.baseURL.appending(path: "frontend/pg/collection/antique")
    }

    private func articleURL(objectCode: String) -> URL {
        Constants.baseURL
            .appending(path: "frontend/pg/article/id")
            .appending(path: objectCode)
    }

    private func imageFrameURL(objectCode: String) -> URL {
        Constants.baseURL
            .appending(path: "frontend/pg/article/aid")
            .appending(path: objectCode)
    }

    private func makeSearchRequest(
        url: URL,
        subtypes: [String]?,
        page: Int,
        limit: Int
    ) throws -> URLRequest {
        let subtypeValue: Any = subtypeParameter(for: subtypes) ?? NSNull()
        let payload: [String: Any] = [
            "params": [
                "langCode": "CHINESE",
                "antiqueSourceCode": "ANTIQUE_SOURCE_1",
                "esFlag": true,
                "ai0": "1",
                "ai1": "1",
                "keywords": NSNull(),
                "types": NSNull(),
                "ages": NSNull(),
                "year": NSNull(),
                "place": NSNull(),
                "author": NSNull(),
                "matter": NSNull(),
                "shape": NSNull(),
                "style": NSNull(),
                "subject": NSNull(),
                "subtype": subtypeValue,
                "tech": NSNull(),
                "objectFlag": NSNull(),
                "videoFlag": NSNull(),
                "stampFlag": NSNull(),
                "prefaceFlag": NSNull(),
                "donateFlag": NSNull(),
                "unearthFlag": NSNull()
            ],
            "page": page,
            "limit": limit
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(collectionURL().absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func makeGETRequest(url: URL, accept: String, referer: URL?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

private enum ShanghaiMuseumAPIError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case .api(let message):
            return message.isEmpty ? "上海博物馆接口返回异常。" : message
        }
    }
}

private struct ShanghaiMuseumSearchResponse: Decodable {
    let code: Int
    let count: Int
    let data: [ShanghaiMuseumSearchItem]
    let msg: String
}

private struct ShanghaiMuseumSearchItem: Decodable {
    struct EntryItem: Decodable {
        let entryItemCode: String?
        let entryItemName: String?
    }

    let age: EntryItem?
    let antiqueType1: EntryItem?
    let antiqueType2: EntryItem?
    let catalog: String?
    let code: String
    let description: String?
    let locationName: String?
    let locationURLString: String?
    let name: String
    let picPath: String?
    let picPath2: String?
    let thumbnailPath: String?

    enum CodingKeys: String, CodingKey {
        case age
        case antiqueType1
        case antiqueType2
        case catalog
        case code
        case description
        case locationName
        case locationURLString = "locationUrl"
        case name
        case picPath
        case picPath2
        case thumbnailPath
    }

    func toArtwork(baseURL: URL) -> Artwork {
        let catalogValues = ShanghaiMuseumCatalogParser.parse(catalogHTML: catalog)

        return Artwork(
            id: "shm-\(code)",
            museumID: .shm,
            objectID: code,
            title: name,
            artworkDescription: description?.trimmedNonEmpty,
            artistDisplayName: catalogValues["作者"],
            objectDate: ShanghaiMuseumDateFormatter.makeDate(
                era: age?.entryItemName,
                detailedDate: catalogValues["纪年"]
            ),
            medium: catalogValues["材质"],
            dimensions: catalogValues["尺寸"],
            department: ShanghaiMuseumSearchItem.departmentName(
                primary: antiqueType1?.entryItemName,
                secondary: antiqueType2?.entryItemName
            ),
            culture: catalogValues["产地"],
            country: "中国",
            repository: "上海博物馆",
            primaryImageURL: ShanghaiMuseumURLBuilder.absoluteURL(from: picPath, baseURL: baseURL)
                ?? ShanghaiMuseumURLBuilder.absoluteURL(from: picPath2, baseURL: baseURL)
                ?? ShanghaiMuseumURLBuilder.absoluteURL(from: thumbnailPath, baseURL: baseURL),
            primaryImageSmallURL: ShanghaiMuseumURLBuilder.absoluteURL(from: thumbnailPath, baseURL: baseURL)
                ?? ShanghaiMuseumURLBuilder.absoluteURL(from: picPath2, baseURL: baseURL)
                ?? ShanghaiMuseumURLBuilder.absoluteURL(from: picPath, baseURL: baseURL),
            objectURL: baseURL
                .appending(path: "frontend/pg/article/id")
                .appending(path: code)
        )
    }

    private static func departmentName(primary: String?, secondary: String?) -> String? {
        let names = [primary, secondary]
            .compactMap { $0?.trimmedNonEmpty }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " / ")
    }
}

private struct ShanghaiMuseumArticlePage {
    let objectCode: String
    let title: String
    let era: String?
    let detailedDate: String?
    let category: String?
    let dimensions: String?
    let medium: String?
    let artist: String?
    let place: String?
    let descriptionHTML: String?
    let objectURL: URL

    func toArtwork(
        primaryImageURL: URL?,
        primaryImageSmallURL: URL?,
        repositoryName: String,
        countryName: String
    ) -> Artwork {
        Artwork(
            id: "shm-\(objectCode)",
            museumID: .shm,
            objectID: objectCode,
            title: title,
            artworkDescription: descriptionHTML,
            artistDisplayName: artist,
            objectDate: ShanghaiMuseumDateFormatter.makeDate(
                era: era,
                detailedDate: detailedDate
            ),
            medium: medium,
            dimensions: dimensions,
            department: category,
            culture: place,
            country: countryName,
            repository: repositoryName,
            primaryImageURL: primaryImageURL,
            primaryImageSmallURL: primaryImageSmallURL,
            objectURL: objectURL
        )
    }
}

private struct ShanghaiMuseumImageURLs {
    let primaryImageURL: URL?
    let primaryImageSmallURL: URL?
}

private enum ShanghaiMuseumArticlePageParser {
    static func parse(
        html: String,
        objectCode: String,
        objectURL: URL,
        baseURL: URL
    ) throws -> ShanghaiMuseumArticlePage {
        let title = firstCapture(
            in: html,
            pattern: #"<div\s+class="title">\s*([^<]+?)\s*(?:<|$)"#
        )?.htmlDecodedText.trimmedNonEmpty

        guard let title else {
            throw URLError(.cannotParseResponse)
        }

        let rows = parseRows(html: html, baseURL: baseURL)
        let descriptionHTML = firstCapture(
            in: html,
            pattern: #"<div\s+class="subtitle">简介</div>\s*((?:<p.*?</p>\s*)+)"#
        )?.trimmedNonEmpty

        return ShanghaiMuseumArticlePage(
            objectCode: objectCode,
            title: title,
            era: rows["时代"]?.firstText,
            detailedDate: rows["详细年代"]?.firstText,
            category: rows["类别"]?.joinedText(separator: " / "),
            dimensions: rows["尺寸"]?.joinedText(separator: "；"),
            medium: rows["材质"]?.firstText,
            artist: rows["作者"]?.firstText,
            place: rows["产地"]?.firstText,
            descriptionHTML: descriptionHTML,
            objectURL: objectURL
        )
    }

    private static func parseRows(html: String, baseURL: URL) -> [String: ShanghaiMuseumArticleRow] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<li>\s*<div\s+class="left">(.*?)：</div>\s*<ul\s+class="site-list right">\s*(.*?)\s*</ul>\s*</li>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return [:]
        }

        let range = NSRange(html.startIndex..., in: html)
        var rows: [String: ShanghaiMuseumArticleRow] = [:]

        for match in regex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges > 2,
                  let labelRange = Range(match.range(at: 1), in: html),
                  let contentRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let label = String(html[labelRange]).htmlDecodedText.trimmedNonEmpty
            let contentHTML = String(html[contentRange])
            guard let label else { continue }

            rows[label] = ShanghaiMuseumArticleRow(
                itemHTMLValues: captures(in: contentHTML, pattern: #"<li>(.*?)</li>"#),
                linkURL: firstCapture(in: contentHTML, pattern: #"<a\s+href="(.*?)""#)
                    .flatMap { ShanghaiMuseumURLBuilder.absoluteURL(from: $0, baseURL: baseURL) }
            )
        }

        return rows
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captures(in: text, pattern: pattern).first
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }
}

private struct ShanghaiMuseumArticleRow {
    let itemHTMLValues: [String]
    let linkURL: URL?

    var firstText: String? {
        joinedText(separator: " / ")
    }

    func joinedText(separator: String) -> String? {
        let values = itemHTMLValues
            .map(\.htmlDecodedText)
            .compactMap(\.trimmedNonEmpty)
        guard !values.isEmpty else { return nil }
        return values.joined(separator: separator)
    }
}

private enum ShanghaiMuseumImagePageParser {
    static func parse(html: String, baseURL: URL) throws -> ShanghaiMuseumImageURLs {
        let primaryImageURL = firstCapture(
            in: html,
            pattern: #"<figure[^>]*data-src="(.*?)""#
        ).flatMap { ShanghaiMuseumURLBuilder.absoluteURL(from: $0, baseURL: baseURL) }
        let primaryImageSmallURL = firstCapture(
            in: html,
            pattern: #"<img\s+src="(.*?)""#
        ).flatMap { ShanghaiMuseumURLBuilder.absoluteURL(from: $0, baseURL: baseURL) }

        guard primaryImageURL != nil || primaryImageSmallURL != nil else {
            throw URLError(.cannotParseResponse)
        }

        return ShanghaiMuseumImageURLs(
            primaryImageURL: primaryImageURL ?? primaryImageSmallURL,
            primaryImageSmallURL: primaryImageSmallURL ?? primaryImageURL
        )
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}

private enum ShanghaiMuseumCatalogParser {
    static func parse(catalogHTML: String?) -> [String: String] {
        guard let catalogHTML, !catalogHTML.isEmpty else {
            return [:]
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"<tr[^>]*>\s*<td[^>]*>(.*?)</td>\s*<td[^>]*>(.*?)</td>\s*</tr>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return [:]
        }

        let range = NSRange(catalogHTML.startIndex..., in: catalogHTML)
        var values: [String: String] = [:]

        for match in regex.matches(in: catalogHTML, options: [], range: range) {
            guard match.numberOfRanges > 2,
                  let keyRange = Range(match.range(at: 1), in: catalogHTML),
                  let valueRange = Range(match.range(at: 2), in: catalogHTML) else {
                continue
            }

            let key = String(catalogHTML[keyRange]).htmlDecodedText.trimmedNonEmpty
            let value = String(catalogHTML[valueRange]).htmlDecodedText.trimmedNonEmpty
            guard let key, let value else { continue }
            values[key] = value
        }

        return values
    }
}

private enum ShanghaiMuseumDateFormatter {
    static func makeDate(era: String?, detailedDate: String?) -> String? {
        let cleanedEra = era?.trimmedNonEmpty
        let cleanedDetailedDate = detailedDate?.trimmedNonEmpty

        switch (cleanedEra, cleanedDetailedDate) {
        case let (era?, detailedDate?) where era != detailedDate:
            return "\(era) · \(detailedDate)"
        case let (_, detailedDate?):
            return detailedDate
        case let (era?, _):
            return era
        default:
            return nil
        }
    }
}

private enum ShanghaiMuseumURLBuilder {
    static func absoluteURL(from path: String?, baseURL: URL) -> URL? {
        guard let path = path?.trimmedNonEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return URL(string: path, relativeTo: baseURL)?.absoluteURL
        }

        if !components.path.hasSuffix("/") {
            components.path += "/"
        }

        let directoryBaseURL = components.url ?? baseURL
        return URL(string: path, relativeTo: directoryBaseURL)?.absoluteURL
    }
}

actor ShanghaiMuseumResponseCache {
    static let shared = ShanghaiMuseumResponseCache()

    struct SearchState {
        let artworkCodes: [String]
        let nextPage: Int
        let hasMore: Bool
    }

    private var searchStateStorage: [String: SearchState] = [:]
    private var artworkStorage: [String: Artwork] = [:]

    func searchState(forKey key: String) -> SearchState? {
        searchStateStorage[key]
    }

    func setSearchState(
        artworkCodes: [String],
        nextPage: Int,
        hasMore: Bool,
        forKey key: String
    ) {
        searchStateStorage[key] = SearchState(
            artworkCodes: artworkCodes,
            nextPage: nextPage,
            hasMore: hasMore
        )
    }

    func removeSearchState(forKey key: String) {
        searchStateStorage.removeValue(forKey: key)
    }

    func artwork(forCode code: String) -> Artwork? {
        artworkStorage[code]
    }

    func setArtwork(_ artwork: Artwork, forCode code: String) {
        artworkStorage[code] = artwork
    }

    func setArtworks(_ artworks: [Artwork]) {
        for artwork in artworks {
            artworkStorage[artwork.objectID] = artwork
        }
    }
}

private actor ShanghaiMuseumPersistentCache {
    static let shared = ShanghaiMuseumPersistentCache()

    struct SearchSnapshot {
        let artworkCodes: [String]
        let summaryArtworks: [Artwork]
        let nextPage: Int
        let hasMore: Bool
    }

    private struct CachedSearchSnapshot: Codable {
        let artworkCodes: [String]
        let summaryArtworks: [Artwork]
        let nextPage: Int
        let hasMore: Bool
        let createdAt: Date
    }

    private struct CachedArtwork: Codable {
        let artwork: Artwork
        let createdAt: Date
    }

    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL
            .appendingPathComponent("DailyMuseum", isDirectory: true)
            .appendingPathComponent("ShanghaiMuseumV2", isDirectory: true)
    }

    func searchSnapshot(forKey key: String) -> SearchSnapshot? {
        let fileURL = searchSnapshotFileURL(forKey: key)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(CachedSearchSnapshot.self, from: data) else {
            return nil
        }

        return SearchSnapshot(
            artworkCodes: cached.artworkCodes,
            summaryArtworks: cached.summaryArtworks,
            nextPage: cached.nextPage,
            hasMore: cached.hasMore
        )
    }

    func setSearchSnapshot(
        artworkCodes: [String],
        summaryArtworks: [Artwork],
        nextPage: Int,
        hasMore: Bool,
        forKey key: String
    ) {
        let cached = CachedSearchSnapshot(
            artworkCodes: artworkCodes,
            summaryArtworks: summaryArtworks,
            nextPage: nextPage,
            hasMore: hasMore,
            createdAt: Date()
        )
        let fileURL = searchSnapshotFileURL(forKey: key)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore cache write failures and keep network path as fallback.
        }
    }

    func removeSearchSnapshot(forKey key: String) {
        try? FileManager.default.removeItem(at: searchSnapshotFileURL(forKey: key))
    }

    func artwork(forCode code: String) -> Artwork? {
        let fileURL = artworkFileURL(forCode: code)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(CachedArtwork.self, from: data) else {
            return nil
        }
        return cached.artwork
    }

    func setArtwork(_ artwork: Artwork, forCode code: String) {
        let cached = CachedArtwork(artwork: artwork, createdAt: Date())
        let fileURL = artworkFileURL(forCode: code)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore cache write failures and keep network path as fallback.
        }
    }

    func setArtworks(_ artworks: [Artwork]) {
        for artwork in artworks {
            setArtwork(artwork, forCode: artwork.objectID)
        }
    }

    private func searchSnapshotFileURL(forKey key: String) -> URL {
        directoryURL.appendingPathComponent("search-\(sanitize(key)).json")
    }

    private func artworkFileURL(forCode code: String) -> URL {
        directoryURL.appendingPathComponent("artwork-\(sanitize(code)).json")
    }

    private func sanitize(_ value: String) -> String {
        let sanitized = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized)
    }
}

private actor ShanghaiMuseumRequestThrottle {
    private let minimumInterval: TimeInterval
    private var nextAllowedRequestTime: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func waitForTurn(now: Date = Date()) async throws -> TimeInterval {
        let scheduledTime = max(now, nextAllowedRequestTime)
        let delay = max(0, scheduledTime.timeIntervalSince(now))
        nextAllowedRequestTime = scheduledTime.addingTimeInterval(minimumInterval)

        guard delay > 0 else {
            return 0
        }

        let nanoseconds = UInt64(delay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        return delay
    }
}

private extension String {
    var htmlDecodedText: String {
        self
            .decodingCommonHTMLEntities()
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
