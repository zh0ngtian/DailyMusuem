import Foundation

final class NationalMuseumChinaAPI {
    private enum Constants {
        static let baseURL = URL(string: "https://appapi.chnmuseum.cn")!
        static let requestTimeout: TimeInterval = 20
        static let repositoryName = "中国国家博物馆"
        static let countryName = "中国"
        static let minimumRequestInterval: TimeInterval = 1
        static let listPageSize = 100
    }

    private let session: URLSession
    private let responseCache = NationalMuseumChinaResponseCache.shared
    private let persistentCache = NationalMuseumChinaPersistentCache.shared
    private static let requestThrottle = NationalMuseumChinaRequestThrottle(
        minimumInterval: Constants.minimumRequestInterval
    )

    init(session: URLSession = .shared) {
        self.session = session
    }

    func exhibitIDPage(
        categoryID: Int? = nil,
        categoryDisplayName: String = "全部",
        page: Int,
        limit: Int
    ) async throws -> NationalMuseumChinaExhibitIDPage {
        let effectiveCategoryID = categoryID ?? 0
        let response = try await fetchExhibitListPage(
            categoryID: effectiveCategoryID,
            page: max(1, page),
            limit: max(1, limit)
        )
        let pageIDs = response.data.list.map(\.exhibitID)
        return NationalMuseumChinaExhibitIDPage(
            categoryID: effectiveCategoryID,
            categoryDisplayName: categoryDisplayName,
            page: response.data.page,
            pageCount: max(1, response.data.pageCount),
            ids: Self.stableUniqueInts(pageIDs)
        )
    }

    func allExhibitIDs(
        categoryID: Int? = nil,
        categoryDisplayName: String = "全部",
        cachePolicy: MuseumRequestCachePolicy = .useCaches,
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> [Int] {
        let effectiveCategoryID = categoryID ?? 0
        let logger = RequestLogger.shared

        if cachePolicy.usesCaches {
            await onLog?("检查中国国家博物馆展品 ID 池（\(categoryDisplayName)）内存缓存...")
            if let cached = await responseCache.exhibitIDs(forCategoryID: effectiveCategoryID) {
                await logger.logEvent(
                    source: "中国国家博物馆展品池",
                    summary: "命中内存缓存，类别=\(categoryDisplayName)，共 \(cached.count) 条"
                )
                await onLog?("已命中内存缓存，类别 \(categoryDisplayName)，共 \(cached.count) 条。")
                return cached
            }

            await onLog?("未命中内存缓存，检查中国国家博物馆展品 ID 池本地缓存...")
            if let persisted = await persistentCache.exhibitIDs(forCategoryID: effectiveCategoryID) {
                await responseCache.setExhibitIDs(persisted, forCategoryID: effectiveCategoryID)
                await logger.logEvent(
                    source: "中国国家博物馆展品池",
                    summary: "命中本地缓存，类别=\(categoryDisplayName)，共 \(persisted.count) 条"
                )
                await onLog?("已命中本地缓存，类别 \(categoryDisplayName)，共 \(persisted.count) 条。")
                return persisted
            }
        } else {
            await onLog?("网络直连模式，跳过中国国家博物馆展品池缓存读取。")
        }

        await onLog?("开始从中国国家博物馆批量列表接口拉取展品 ID，类别 \(categoryDisplayName)...")

        let ids = try await fetchAllExhibitIDsFromListAPI(
            categoryID: effectiveCategoryID,
            categoryDisplayName: categoryDisplayName,
            onLog: onLog
        )
        if cachePolicy.usesCaches {
            await responseCache.setExhibitIDs(ids, forCategoryID: effectiveCategoryID)
            await persistentCache.setExhibitIDs(ids, forCategoryID: effectiveCategoryID)
        }
        await logger.logEvent(
            source: "中国国家博物馆展品池",
            summary: "批量接口拉取完成，类别=\(categoryDisplayName)，共 \(ids.count) 条"
        )
        await onLog?("中国国家博物馆展品 ID 已就绪，类别 \(categoryDisplayName)，当前可用 \(ids.count) 条。")
        return ids
    }

    func fetchExhibit(
        exhibitID: Int,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> Artwork {
        let logger = RequestLogger.shared

        if cachePolicy.usesCaches {
            if let cached = await responseCache.artwork(forID: exhibitID) {
                await logger.logEvent(source: "中国国家博物馆详情", summary: "命中内存缓存，exhibitID=\(exhibitID)")
                return cached
            }

            if let persisted = await persistentCache.artwork(forID: exhibitID) {
                await responseCache.setArtwork(persisted, forID: exhibitID)
                await logger.logEvent(source: "中国国家博物馆详情", summary: "命中本地缓存，exhibitID=\(exhibitID)")
                return persisted
            }
        }

        let url = try makeShareURL(exhibitID: exhibitID)
        let request = makeRequest(url: url)
        let throttleDelay = try await Self.requestThrottle.waitForTurn()
        if throttleDelay > 0 {
            let delayText = String(format: "%.2f", throttleDelay)
            await logger.logEvent(
                source: "中国国家博物馆详情",
                summary: "触发限流保护，等待 \(delayText)s 后再请求，exhibitID=\(exhibitID)"
            )
        }
        let start = Date()
        await logger.logRequestStart(source: "中国国家博物馆详情", url: url)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)

            let html = String(decoding: data, as: UTF8.self)
            let page = try NationalMuseumChinaExhibitPageParser.parse(
                html: html,
                exhibitID: exhibitID,
                shareURL: url,
                baseURL: Constants.baseURL
            )
            let artwork = page.toArtwork(
                repositoryName: Constants.repositoryName,
                countryName: Constants.countryName
            )

            await logger.logRequestSuccess(
                source: "中国国家博物馆详情",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            if cachePolicy.usesCaches {
                await responseCache.setArtwork(artwork, forID: exhibitID)
                await persistentCache.setArtwork(artwork, forID: exhibitID)
            }
            return artwork
        } catch {
            await logger.logRequestFailure(
                source: "中国国家博物馆详情",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func makeShareURL(exhibitID: Int) throws -> URL {
        var components = URLComponents(url: Constants.baseURL.appending(path: "api/exhibit/share_link"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "p", value: "i"),
            URLQueryItem(name: "exhibit_id", value: String(exhibitID))
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func makeExhibitListURL(categoryID: Int, page: Int, limit: Int) throws -> URL {
        var components = URLComponents(url: Constants.baseURL.appending(path: "api/exhibit_list"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "cate_id", value: String(categoryID)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "p", value: "i"),
            URLQueryItem(name: "son_cate_id", value: "0")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private func makeListRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func fetchAllExhibitIDsFromListAPI(
        categoryID: Int,
        categoryDisplayName: String,
        onLog: (@Sendable (String) async -> Void)?
    ) async throws -> [Int] {
        var page = 1
        var collectedIDs: [Int] = []
        var totalPages = 1

        repeat {
            let response = try await fetchExhibitListPage(
                categoryID: categoryID,
                page: page,
                limit: Constants.listPageSize
            )

            let pageIDs = response.data.list.map(\.exhibitID)
            collectedIDs.append(contentsOf: pageIDs)
            totalPages = max(1, response.data.pageCount)
            await onLog?("中国国家博物馆批量列表接口已拉取第 \(page)/\(totalPages) 页，类别 \(categoryDisplayName)，累计 \(collectedIDs.count) 条。")
            page += 1
        } while page <= totalPages

        return Self.stableUniqueInts(collectedIDs)
    }

    private func fetchExhibitListPage(categoryID: Int, page: Int, limit: Int) async throws -> NationalMuseumChinaExhibitListResponse {
        let url = try makeExhibitListURL(categoryID: categoryID, page: page, limit: limit)
        let request = makeListRequest(url: url)
        let logger = RequestLogger.shared
        let throttleDelay = try await Self.requestThrottle.waitForTurn()
        if throttleDelay > 0 {
            let delayText = String(format: "%.2f", throttleDelay)
            await logger.logEvent(
                source: "中国国家博物馆列表",
                summary: "触发限流保护，等待 \(delayText)s 后再请求，cate_id=\(categoryID)，page=\(page)"
            )
        }

        let start = Date()
        await logger.logRequestStart(source: "中国国家博物馆列表", url: url)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let decoded = try JSONDecoder().decode(NationalMuseumChinaExhibitListResponse.self, from: data)
            await logger.logRequestSuccess(
                source: "中国国家博物馆列表",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return decoded
        } catch {
            await logger.logRequestFailure(
                source: "中国国家博物馆列表",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

actor NationalMuseumChinaRequestThrottle {
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

struct NationalMuseumChinaExhibitPage {
    let exhibitID: Int
    let title: String
    let objectDate: String?
    let department: String?
    let dimensions: String?
    let descriptionHTML: String?
    let primaryImageURL: URL?
    let shareURL: URL

    func toArtwork(repositoryName: String, countryName: String) -> Artwork {
        Artwork(
            id: "nmc-\(exhibitID)",
            museumID: .nmc,
            objectID: String(exhibitID),
            title: title,
            artworkDescription: descriptionHTML,
            artistDisplayName: nil,
            objectDate: objectDate,
            medium: nil,
            dimensions: dimensions,
            department: department,
            culture: nil,
            country: countryName,
            repository: repositoryName,
            primaryImageURL: primaryImageURL,
            primaryImageSmallURL: primaryImageURL,
            objectURL: shareURL
        )
    }
}

enum NationalMuseumChinaExhibitPageParser {
    static func parse(
        html: String,
        exhibitID: Int,
        shareURL: URL,
        baseURL: URL
    ) throws -> NationalMuseumChinaExhibitPage {
        let briefHTML = firstCapture(
            in: html,
            pattern: #"<div\s+class="content brief">\s*(.*?)\s*</div>"#
        )
        let title = firstCapture(
            in: briefHTML ?? html,
            pattern: #"<h1>(.*?)</h1>"#
        )?.htmlDecodedText.trimmedNonEmpty

        guard let title else {
            throw URLError(.cannotParseResponse)
        }

        let briefParagraphs = captures(
            in: briefHTML ?? html,
            pattern: #"<p>(.*?)</p>"#
        )
        .map { $0.htmlDecodedText.trimmedNonEmpty }

        let detailHTML = firstCapture(
            in: html,
            pattern: #"<div\s+class="content detail">\s*<h1>.*?</h1>\s*(.*?)\s*</div>"#
        )?.trimmedNonEmpty

        let imagePath = captures(
            in: html,
            pattern: #"<img\s+src=["'](.*?)["']"#
        ).first?.trimmedNonEmpty

        return NationalMuseumChinaExhibitPage(
            exhibitID: exhibitID,
            title: title,
            objectDate: briefParagraphs.element(at: 0),
            department: briefParagraphs.element(at: 1),
            dimensions: briefParagraphs.element(at: 2),
            descriptionHTML: detailHTML,
            primaryImageURL: imagePath.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
            shareURL: shareURL
        )
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

struct NationalMuseumChinaExhibitIDPage: Equatable, Sendable {
    let categoryID: Int
    let categoryDisplayName: String
    let page: Int
    let pageCount: Int
    let ids: [Int]
}

private struct NationalMuseumChinaExhibitListResponse: Decodable {
    let status: Int
    let msg: String
    let data: DataPayload

    struct DataPayload: Decodable {
        let count: Int
        let list: [ExhibitSummary]
        let page: Int
        let perPage: Int
        let pageCount: Int

        enum CodingKeys: String, CodingKey {
            case count
            case list
            case page
            case perPage = "per_page"
            case pageCount = "page_count"
        }
    }

    struct ExhibitSummary: Decodable {
        let exhibitID: Int

        enum CodingKeys: String, CodingKey {
            case exhibitID = "exhibit_id"
        }
    }
}

private actor NationalMuseumChinaResponseCache {
    static let shared = NationalMuseumChinaResponseCache()

    private var artworkStorage: [Int: Artwork] = [:]
    private var exhibitIDStorage: [Int: [Int]] = [:]

    func artwork(forID id: Int) -> Artwork? {
        artworkStorage[id]
    }

    func setArtwork(_ artwork: Artwork, forID id: Int) {
        artworkStorage[id] = artwork
    }

    func exhibitIDs(forCategoryID categoryID: Int) -> [Int]? {
        exhibitIDStorage[categoryID]
    }

    func setExhibitIDs(_ ids: [Int], forCategoryID categoryID: Int) {
        exhibitIDStorage[categoryID] = ids
    }
}

private actor NationalMuseumChinaPersistentCache {
    static let shared = NationalMuseumChinaPersistentCache()

    private struct CachedArtwork: Codable {
        let artwork: Artwork
        let createdAt: Date
    }

    private struct CachedExhibitIDs: Codable {
        let ids: [Int]
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
            .appendingPathComponent("NationalMuseumChina", isDirectory: true)
    }

    func artwork(forID id: Int) -> Artwork? {
        let fileURL = fileURL(forID: id)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(CachedArtwork.self, from: data) else {
            return nil
        }
        return cached.artwork
    }

    func setArtwork(_ artwork: Artwork, forID id: Int) {
        let cached = CachedArtwork(artwork: artwork, createdAt: Date())
        let fileURL = fileURL(forID: id)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore cache write failures and keep network path as fallback.
        }
    }

    func exhibitIDs(forCategoryID categoryID: Int) -> [Int]? {
        let fileURL = exhibitIDFileURL(forCategoryID: categoryID)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(CachedExhibitIDs.self, from: data) else {
            return nil
        }
        return cached.ids
    }

    func setExhibitIDs(_ ids: [Int], forCategoryID categoryID: Int) {
        let cached = CachedExhibitIDs(ids: ids, createdAt: Date())
        let fileURL = exhibitIDFileURL(forCategoryID: categoryID)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore cache write failures and keep network path as fallback.
        }
    }

    private func fileURL(forID id: Int) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }

    private func exhibitIDFileURL(forCategoryID categoryID: Int) -> URL {
        directoryURL.appendingPathComponent("exhibit-list-\(categoryID).json")
    }
}

private extension String {
    var htmlDecodedText: String {
        self
            .decodingCommonHTMLEntities(punctuationStyle: .chinese)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String? {
    func element(at index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return self[index] ?? nil
    }
}

private extension NationalMuseumChinaAPI {
    static func stableUniqueInts(_ values: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []
        result.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
