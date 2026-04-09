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
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> [Int] {
        let logger = RequestLogger.shared
        let cacheKey = "\(hasImages)-\(isOnView)-\(query)"
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

        await onLog?("未命中本地缓存，开始从大都会艺术博物馆拉取全量 objectIDs，首次可能较慢...")

        var components = URLComponents(url: baseURL.appending(path: "search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "hasImages", value: hasImages ? "true" : "false"),
            URLQueryItem(name: "isOnView", value: isOnView ? "true" : "false"),
            URLQueryItem(name: "q", value: query)
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let start = Date()
        await logger.logRequestStart(source: "Met 搜索", url: url)

        do {
            let (data, response) = try await session.data(from: url)
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
            await onLog?("全量 objectIDs 拉取完成，共 \(objectIDs.count) 条，正在写入本地缓存...")
            await responseCache.setSearchObjectIDs(objectIDs, forKey: cacheKey)
            await persistentCache.setObjectIDs(objectIDs, forKey: cacheKey)
            await onLog?("objectIDs 缓存写入完成。")
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

    func fetchObject(objectID: Int) async throws -> MetMuseumObject {
        let logger = RequestLogger.shared
        if let cached = await responseCache.object(forID: objectID) {
            await logger.logEvent(source: "Met 详情", summary: "命中内存缓存，objectID=\(objectID)")
            return cached
        }

        let url = baseURL.appending(path: "objects").appending(path: "\(objectID)")
        let start = Date()
        await logger.logRequestStart(source: "Met 详情", url: url)

        do {
            let (data, response) = try await session.data(from: url)
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
            await responseCache.setObject(object, forID: objectID)
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

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

actor MetMuseumResponseCache {
    static let shared = MetMuseumResponseCache()

    private var searchStorage: [String: [Int]] = [:]
    private var objectStorage: [Int: MetMuseumObject] = [:]

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
}
