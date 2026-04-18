import Foundation

final class MetMuseumAPI {
    private let baseURL = URL(string: "https://collectionapi.metmuseum.org/public/collection/v1")!
    private let session: URLSession
    private let responseCache = MetMuseumResponseCache.shared
    private let persistentCache = MetMuseumPersistentCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchObjectIDs(
        hasImages: Bool,
        isOnView: Bool,
        query: String,
        departmentID: Int? = nil,
        cachePolicy: MuseumRequestCachePolicy = .useCaches,
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> [Int] {
        let logger = RequestLogger.shared
        let cacheKey = "\(hasImages ? "images-only" : "all-images")-\(isOnView)-\(query)-\(departmentID.map(String.init) ?? "all")"
        if cachePolicy.usesCaches {
            await onLog?("检查 objectIDs 内存缓存...")
            if let cached = await responseCache.searchObjectIDs(forKey: cacheKey) {
                await logger.logEvent(source: "Met 搜索", summary: "命中内存缓存，复用 \(cached.count) 条 objectIDs")
                await onLog?("已命中内存缓存，直接复用 \(cached.count) 条 objectIDs。")
                return cached
            }

            await onLog?("未命中内存缓存，检查本地磁盘缓存...")
            if let persisted = await persistentCache.objectIDs(forKey: cacheKey) {
                await responseCache.setSearchObjectIDs(persisted, forKey: cacheKey)
                await logger.logEvent(source: "Met 搜索", summary: "命中本地缓存，复用 \(persisted.count) 条 objectIDs")
                await onLog?("已命中本地缓存，读取到 \(persisted.count) 条 objectIDs。")
                return persisted
            }
        } else {
            await onLog?("网络直连模式，跳过 objectIDs 缓存读取。")
        }

        await onLog?("未命中本地缓存，开始从大都会艺术博物馆拉取全量 objectIDs，首次可能较慢...")

        var components = URLComponents(url: baseURL.appending(path: "search"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "isOnView", value: isOnView ? "true" : "false"),
            URLQueryItem(name: "q", value: query)
        ]
        if hasImages {
            queryItems.append(URLQueryItem(name: "hasImages", value: "true"))
        }
        if let departmentID {
            queryItems.append(URLQueryItem(name: "departmentId", value: "\(departmentID)"))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let start = Date()
        await logger.logRequestStart(source: "Met 搜索", url: url)

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let decoded = try JSONDecoder().decode(MetMuseumSearchResponse.self, from: data)
            let objectIDs = decoded.objectIDs ?? []
            await logger.logRequestSuccess(
                source: "Met 搜索",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            if cachePolicy.usesCaches {
                await onLog?("全量 objectIDs 拉取完成，共 \(objectIDs.count) 条，正在写入本地缓存...")
                await responseCache.setSearchObjectIDs(objectIDs, forKey: cacheKey)
                await persistentCache.setObjectIDs(objectIDs, forKey: cacheKey)
                await onLog?("objectIDs 缓存写入完成。")
            } else {
                await onLog?("全量 objectIDs 拉取完成，共 \(objectIDs.count) 条，网络直连模式不写入缓存。")
            }
            return objectIDs
        } catch {
            await logger.logRequestFailure(
                source: "Met 搜索",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    func fetchObject(
        objectID: Int,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> MetMuseumObject {
        let logger = RequestLogger.shared
        if cachePolicy.usesCaches {
            if let cached = await responseCache.object(forID: objectID) {
                await logger.logEvent(source: "Met 详情", summary: "命中内存缓存，objectID=\(objectID)")
                return cached
            }
        }

        let url = baseURL.appending(path: "objects").appending(path: "\(objectID)")
        let start = Date()
        await logger.logRequestStart(source: "Met 详情", url: url)

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let object = try JSONDecoder().decode(MetMuseumObject.self, from: data)
            await logger.logRequestSuccess(
                source: "Met 详情",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            if cachePolicy.usesCaches {
                await responseCache.setObject(object, forID: objectID)
            }
            return object
        } catch {
            await logger.logRequestFailure(
                source: "Met 详情",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    func fetchObjectWebDescription(objectID: Int, objectURL: URL?) async -> String? {
        guard let objectURL else { return nil }

        let logger = RequestLogger.shared
        if let cached = await responseCache.webDescription(forID: objectID) {
            await logger.logEvent(source: "Met 官网", summary: "命中内存缓存，objectID=\(objectID)")
            return cached
        }

        let start = Date()
        await logger.logRequestStart(source: "Met 官网", url: objectURL)

        do {
            let (data, response) = try await session.data(from: objectURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let html = String(data: data, encoding: .utf8) ?? ""
            let description = Self.extractWebDescription(from: html)
            await logger.logRequestSuccess(
                source: "Met 官网",
                url: objectURL,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            if let description, !description.isEmpty {
                await responseCache.setWebDescription(description, forID: objectID)
            }
            return description
        } catch {
            await logger.logRequestFailure(
                source: "Met 官网",
                url: objectURL,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            return nil
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    static func extractWebDescription(from html: String) -> String? {
        let renderedHTML = renderedObjectHTML(from: html)
        if let labelHTML = extractElementHTML(
            from: renderedHTML,
            marker: "class=\"object-overview-module-scss-module__bIfq1G__label\""
        ) {
            let cleaned = sanitizeHTMLFragment(labelHTML)
            return cleaned.isEmpty ? nil : cleaned
        }

        let patterns = [
            "<meta[^>]*name=[\"']description[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>",
            "<meta[^>]*property=[\"']og:description[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  let descriptionRange = Range(match.range(at: 1), in: html) else {
                continue
            }

            let cleaned = decodeHTMLEntities(String(html[descriptionRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }
    private static func renderedObjectHTML(from html: String) -> String {
        let bodyStart = html.range(of: "<body", options: [.caseInsensitive])?.lowerBound ?? html.startIndex
        let beforeFlightScripts = html.range(of: "(self.__next_f=self.__next_f||[]).push([0])")?.lowerBound
            ?? html.range(of: "self.__next_f.push([1,")?.lowerBound
            ?? html.endIndex

        let bodySlice = html[bodyStart..<beforeFlightScripts]
        guard let mainStart = bodySlice.range(of: "<main", options: [.caseInsensitive])?.lowerBound,
              let mainEnd = bodySlice.range(of: "</main>", options: [.caseInsensitive])?.upperBound else {
            return String(bodySlice)
        }

        return String(bodySlice[mainStart..<mainEnd])
    }

    private static func sanitizeHTMLFragment(_ html: String) -> String {
        let withLineBreaks = html
            .replacingOccurrences(
                of: "(?i)<br\\s*/?>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)</p\\s*>",
                with: "\n\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)<p[^>]*>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)</div\\s*>",
                with: "\n",
                options: .regularExpression
            )

        let withoutTags = withLineBreaks.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        let normalizedLines = withoutTags
            .components(separatedBy: .newlines)
            .map(cleanDescriptionLine)
            .map { $0.decodingCommonHTMLEntities() }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return normalizedLines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractElementHTML(from html: String, marker: String) -> String? {
        guard let markerRange = html.range(of: marker, options: [.caseInsensitive]),
              let start = html[..<markerRange.lowerBound].lastIndex(of: "<") else {
            return nil
        }

        let source = html[start...]
        guard source.lowercased().hasPrefix("<div") else {
            return nil
        }

        var searchIndex = source.startIndex
        var depth = 0
        var endIndex: String.Index?

        while searchIndex < source.endIndex {
            guard let nextTagStart = source[searchIndex...].firstIndex(of: "<"),
                  let nextTagEnd = source[nextTagStart...].firstIndex(of: ">") else {
                break
            }

            let tag = source[nextTagStart...nextTagEnd].lowercased()
            if tag.hasPrefix("<div") {
                depth += 1
            } else if tag.hasPrefix("</div") {
                depth -= 1
                if depth == 0 {
                    endIndex = source.index(after: nextTagEnd)
                    break
                }
            }

            searchIndex = source.index(after: nextTagEnd)
        }

        guard let endIndex else {
            return nil
        }

        return String(source[..<endIndex])
    }

    private static func cleanDescriptionLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"^\[\s*"?\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*"?\s*\]$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^\[\]$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^[\[\]",\s]+$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^->\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^>+\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value.decodingCommonHTMLEntities()
    }
}

actor MetMuseumResponseCache {
    static let shared = MetMuseumResponseCache()

    private var searchStorage: [String: [Int]] = [:]
    private var objectStorage: [Int: MetMuseumObject] = [:]
    private var webDescriptionStorage: [Int: String] = [:]

    func searchObjectIDs(forKey key: String) -> [Int]? {
        searchStorage[key]
    }

    func setSearchObjectIDs(_ ids: [Int], forKey key: String) {
        searchStorage[key] = ids
    }

    func object(forID id: Int) -> MetMuseumObject? {
        objectStorage[id]
    }

    func setObject(_ object: MetMuseumObject, forID id: Int) {
        objectStorage[id] = object
    }

    func webDescription(forID id: Int) -> String? {
        webDescriptionStorage[id]
    }

    func setWebDescription(_ description: String, forID id: Int) {
        webDescriptionStorage[id] = description
    }
}
