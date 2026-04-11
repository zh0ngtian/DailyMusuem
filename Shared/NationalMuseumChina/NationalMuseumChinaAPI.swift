import Foundation

final class NationalMuseumChinaAPI {
    private enum Constants {
        static let baseURL = URL(string: "https://appapi.chnmuseum.cn")!
        static let requestTimeout: TimeInterval = 20
        static let repositoryName = "中国国家博物馆"
        static let countryName = "中国"
    }

    private let session: URLSession
    private let responseCache = NationalMuseumChinaResponseCache.shared
    private let persistentCache = NationalMuseumChinaPersistentCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func allExhibitIDs(onLog: (@Sendable (String) async -> Void)? = nil) async -> [Int] {
        let ids = NationalMuseumChinaExhibitIDs.curatedIDs
        await onLog?("检查中国国家博物馆展品 ID 池...")
        await RequestLogger.shared.logEvent(
            source: "中国国家博物馆展品池",
            summary: "使用内置展品 ID 池，共 \(ids.count) 条"
        )
        await onLog?("中国国家博物馆展品 ID 已就绪，当前可用 \(ids.count) 条。")
        return ids
    }

    func fetchExhibit(exhibitID: Int) async throws -> Artwork {
        let logger = RequestLogger.shared

        if let cached = await responseCache.artwork(forID: exhibitID) {
            await logger.logEvent(source: "中国国家博物馆详情", summary: "命中内存缓存，exhibitID=\(exhibitID)")
            return cached
        }

        if let persisted = await persistentCache.artwork(forID: exhibitID) {
            await responseCache.setArtwork(persisted, forID: exhibitID)
            await logger.logEvent(source: "中国国家博物馆详情", summary: "命中本地缓存，exhibitID=\(exhibitID)")
            return persisted
        }

        let url = try makeShareURL(exhibitID: exhibitID)
        let request = makeRequest(url: url)
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
            await responseCache.setArtwork(artwork, forID: exhibitID)
            await persistentCache.setArtwork(artwork, forID: exhibitID)
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

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

private struct NationalMuseumChinaExhibitPage {
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

private enum NationalMuseumChinaExhibitPageParser {
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

private actor NationalMuseumChinaResponseCache {
    static let shared = NationalMuseumChinaResponseCache()

    private var artworkStorage: [Int: Artwork] = [:]

    func artwork(forID id: Int) -> Artwork? {
        artworkStorage[id]
    }

    func setArtwork(_ artwork: Artwork, forID id: Int) {
        artworkStorage[id] = artwork
    }
}

private actor NationalMuseumChinaPersistentCache {
    static let shared = NationalMuseumChinaPersistentCache()

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

    private func fileURL(forID id: Int) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }
}

private extension String {
    var htmlDecodedText: String {
        self
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
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
