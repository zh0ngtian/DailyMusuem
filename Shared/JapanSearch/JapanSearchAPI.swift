import Foundation

final class JapanSearchAPI {
    struct SearchPoolSnapshot {
        let itemIDs: [String]
        let hasMoreRemoteItems: Bool
    }

    private enum Constants {
        static let databaseID = "cobas"
        // Japan Search returns empty lists on iPhone for large `size` values like 1000.
        // Keep pages small and aligned with the feed's 10-item batch loading.
        static let pageSize = 10
        static let requestTimeout: TimeInterval = 20
        static let searchUserAgent = "curl/8.7.1"
        static let searchAccept = "application/json, text/plain, */*"
        static let searchAcceptLanguage = "ja-JP,ja;q=0.9,en-US;q=0.8,zh-CN;q=0.7"
    }

    private let baseURL = URL(string: "https://jpsearch.go.jp/api")!
    private let session: URLSession
    private let responseCache = JapanSearchResponseCache.shared
    private let persistentCache = JapanSearchPersistentCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchItemIDs(
        museumID: MuseumID = .tnm,
        preferHasImages: Bool,
        categoryTypeCode: String? = nil,
        minimumCount: Int = Constants.pageSize,
        cachePolicy: MuseumRequestCachePolicy = .useCaches,
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> SearchPoolSnapshot {
        let profile = try profile(for: museumID)
        let logger = RequestLogger.shared
        let cacheKey = cacheKey(museumID: museumID, preferHasImages: preferHasImages, categoryTypeCode: categoryTypeCode)

        var itemIDs: [String] = []
        var summaryArtworks: [Artwork] = []
        var nextFrom = 0
        var hasMore = true
        var usedContributorFilter = true

        if cachePolicy.usesCaches {
            await onLog?("检查\(profile.logName) itemIDs 内存缓存...")
            if let cached = await responseCache.searchState(forKey: cacheKey), !cached.itemIDs.isEmpty {
                itemIDs = cached.itemIDs
                nextFrom = cached.nextFrom
                hasMore = cached.hasMore
                usedContributorFilter = cached.usedContributorFilter
                await logger.logEvent(source: "\(profile.logName)搜索", summary: "命中内存缓存，复用 \(cached.itemIDs.count) 条 itemIDs")
                await onLog?("已命中内存缓存，直接复用 \(cached.itemIDs.count) 条 itemIDs。")
                if cached.itemIDs.count >= minimumCount || !cached.hasMore {
                    return SearchPoolSnapshot(itemIDs: cached.itemIDs, hasMoreRemoteItems: cached.hasMore)
                }
                await onLog?("现有\(profile.logName)缓存不足 \(minimumCount) 条，继续拉取下一页...")
            }

            if itemIDs.isEmpty {
                await onLog?("未命中内存缓存，检查\(profile.logName)本地缓存...")
                if let persisted = await persistentCache.searchSnapshot(forKey: cacheKey), !persisted.itemIDs.isEmpty {
                    itemIDs = persisted.itemIDs
                    summaryArtworks = persisted.summaryArtworks
                    nextFrom = persisted.nextFrom
                    hasMore = persisted.hasMore
                    usedContributorFilter = persisted.usedContributorFilter
                    await responseCache.setSearchState(
                        itemIDs: persisted.itemIDs,
                        nextFrom: persisted.nextFrom,
                        hasMore: persisted.hasMore,
                        usedContributorFilter: persisted.usedContributorFilter,
                        forKey: cacheKey
                    )
                    if !persisted.summaryArtworks.isEmpty {
                        await responseCache.setSearchArtworks(persisted.summaryArtworks)
                        await onLog?("已从本地缓存恢复 \(persisted.summaryArtworks.count) 条\(profile.logName)摘要数据。")
                    }
                    await logger.logEvent(source: "\(profile.logName)搜索", summary: "命中本地缓存，复用 \(persisted.itemIDs.count) 条 itemIDs")
                    await onLog?("已命中本地缓存，读取到 \(persisted.itemIDs.count) 条 itemIDs。")
                    if persisted.itemIDs.count >= minimumCount || !persisted.hasMore {
                        return SearchPoolSnapshot(itemIDs: persisted.itemIDs, hasMoreRemoteItems: persisted.hasMore)
                    }
                    await onLog?("本地缓存条目不足 \(minimumCount) 条，继续拉取下一页...")
                }
            }
        } else {
            await onLog?("网络直连模式，跳过\(profile.logName)搜索缓存读取。")
        }

        if itemIDs.isEmpty {
            await onLog?("未命中本地缓存，开始从\(profile.logName)拉取分页 itemIDs...")
        }

        var knownIDs = Set(itemIDs)
        while itemIDs.count < minimumCount, hasMore {
            let response = try await searchItems(
                profile: profile,
                preferHasImages: preferHasImages,
                categoryTypeCode: categoryTypeCode,
                from: nextFrom,
                size: Constants.pageSize,
                useContributorFilter: usedContributorFilter
            )

            if response.list.isEmpty {
                if usedContributorFilter && itemIDs.isEmpty {
                    await onLog?("\(profile.logName) contributor 筛选返回空结果，改为拉取 cobas 全库并在本地过滤\(profile.logName)数据...")
                    usedContributorFilter = false
                    nextFrom = 0
                    hasMore = true
                    continue
                }
                hasMore = false
                break
            }

            let pageItems: [JapanSearchItem]
            if usedContributorFilter {
                pageItems = response.list
            } else {
                pageItems = response.list.filter { profile.matches($0) }
            }

            let uniquePageItems = Self.stableUniqueItems(pageItems).filter { knownIDs.insert($0.id).inserted }
            let orderedPageItems = uniquePageItems.sorted { lhs, rhs in lhs.sortValue < rhs.sortValue }
            itemIDs.append(contentsOf: orderedPageItems.map(\.id))
            let pageSummaries = orderedPageItems.map { $0.toArtwork(museumID: museumID) }
            summaryArtworks.append(contentsOf: pageSummaries)
            if cachePolicy.usesCaches {
                await responseCache.setSearchArtworks(pageSummaries)
            }

            nextFrom += response.list.count
            hasMore = response.list.count >= Constants.pageSize && nextFrom < response.hit
            await onLog?("\(profile.logName)已缓存 \(itemIDs.count) 条 itemIDs，后续按需继续拉取。")

            if cachePolicy.usesCaches {
                await responseCache.setSearchState(
                    itemIDs: itemIDs,
                    nextFrom: nextFrom,
                    hasMore: hasMore,
                    usedContributorFilter: usedContributorFilter,
                    forKey: cacheKey
                )
                await persistentCache.setSearchSnapshot(
                    itemIDs: itemIDs,
                    summaryArtworks: summaryArtworks,
                    nextFrom: nextFrom,
                    hasMore: hasMore,
                    usedContributorFilter: usedContributorFilter,
                    forKey: cacheKey
                )
            }

            if response.list.count < Constants.pageSize || nextFrom >= response.hit {
                hasMore = false
            }
        }

        guard !itemIDs.isEmpty else {
            await logger.logEvent(source: "\(profile.logName)搜索", summary: "搜索结果为空，忽略空缓存并返回空数组")
            await onLog?("\(profile.logName)未返回任何 itemIDs，本次不写入空缓存。")
            return SearchPoolSnapshot(itemIDs: [], hasMoreRemoteItems: false)
        }

        if cachePolicy.usesCaches {
            await responseCache.setSearchState(
                itemIDs: itemIDs,
                nextFrom: nextFrom,
                hasMore: hasMore,
                usedContributorFilter: usedContributorFilter,
                forKey: cacheKey
            )
            await persistentCache.setSearchSnapshot(
                itemIDs: itemIDs,
                summaryArtworks: summaryArtworks,
                nextFrom: nextFrom,
                hasMore: hasMore,
                usedContributorFilter: usedContributorFilter,
                forKey: cacheKey
            )
            await onLog?("\(profile.logName) itemIDs 已就绪，当前缓存 \(itemIDs.count) 条。")
        } else {
            await onLog?("\(profile.logName) itemIDs 已就绪，共 \(itemIDs.count) 条，网络直连模式不写入缓存。")
        }
        return SearchPoolSnapshot(itemIDs: itemIDs, hasMoreRemoteItems: hasMore)
    }

    func resetSearchCache(
        museumID: MuseumID = .tnm,
        preferHasImages: Bool,
        categoryTypeCode: String? = nil
    ) async {
        let key = cacheKey(museumID: museumID, preferHasImages: preferHasImages, categoryTypeCode: categoryTypeCode)
        await responseCache.removeSearchState(forKey: key)
        await persistentCache.removeSearchSnapshot(forKey: key)
    }

    func fetchItem(
        museumID: MuseumID = .tnm,
        itemID: String,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> JapanSearchItem {
        let profile = try profile(for: museumID)
        let logger = RequestLogger.shared
        if cachePolicy.usesCaches {
            if let cached = await responseCache.item(forID: itemID) {
                await logger.logEvent(source: "\(profile.logName)详情", summary: "命中内存缓存，itemID=\(itemID)")
                return cached
            }
        }

        let url = baseURL.appending(path: "item").appending(path: itemID)
        let start = Date()
        await logger.logRequestStart(source: "\(profile.logName)详情", url: url)

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let item = try JSONDecoder().decode(JapanSearchItem.self, from: data)
            await logger.logRequestSuccess(
                source: "\(profile.logName)详情",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            if cachePolicy.usesCaches {
                await responseCache.setItem(item, forID: itemID)
            }
            return item
        } catch {
            await logger.logRequestFailure(
                source: "\(profile.logName)详情",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    func cachedSearchArtwork(museumID: MuseumID = .tnm, itemID: String) async -> Artwork? {
        await responseCache.searchArtwork(forKey: searchArtworkKey(museumID: museumID, itemID: itemID))
    }

    private func profile(for museumID: MuseumID) throws -> JapanSearchMuseumProfile {
        guard let profile = JapanSearchMuseumProfile.profile(for: museumID) else {
            throw URLError(.badURL)
        }
        return profile
    }

    private func cacheKey(museumID: MuseumID, preferHasImages: Bool, categoryTypeCode: String?) -> String {
        let contributor = JapanSearchMuseumProfile.profile(for: museumID)?.contributorQuery ?? museumID.rawValue
        return "\(Constants.databaseID)-\(contributor)-\(preferHasImages)-\(categoryTypeCode ?? "all")"
    }

    private func searchArtworkKey(museumID: MuseumID, itemID: String) -> String {
        "\(museumID.rawValue)|\(itemID)"
    }

    private func searchItems(
        profile: JapanSearchMuseumProfile,
        preferHasImages: Bool,
        categoryTypeCode: String?,
        from: Int,
        size: Int,
        useContributorFilter: Bool
    ) async throws -> JapanSearchSearchResponse {
        var components = URLComponents(url: baseURL.appending(path: "item/search/jps-cross"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "f-db", value: Constants.databaseID),
            URLQueryItem(name: "from", value: "\(from)"),
            URLQueryItem(name: "size", value: "\(size)")
        ]
        if useContributorFilter {
            queryItems.append(URLQueryItem(name: "q-contributor", value: profile.contributorQuery))
        }
        if let categoryTypeCode {
            queryItems.append(URLQueryItem(name: "f-type", value: categoryTypeCode))
        }
        if preferHasImages {
            queryItems.append(URLQueryItem(name: "f-contents", value: "image"))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let request = makeSearchRequest(url: url)
        let start = Date()
        await RequestLogger.shared.logRequestStart(source: "\(profile.logName)搜索", url: url)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let decoded = try JSONDecoder().decode(JapanSearchSearchResponse.self, from: data)
            await RequestLogger.shared.logRequestSuccess(
                source: "\(profile.logName)搜索",
                url: url,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return decoded
        } catch {
            await RequestLogger.shared.logRequestFailure(
                source: "\(profile.logName)搜索",
                url: url,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func makeSearchRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Constants.searchUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Constants.searchAccept, forHTTPHeaderField: "Accept")
        request.setValue(Constants.searchAcceptLanguage, forHTTPHeaderField: "Accept-Language")
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

    private static func stableUniqueItems(_ items: [JapanSearchItem]) -> [JapanSearchItem] {
        var seen: Set<String> = []
        var result: [JapanSearchItem] = []
        result.reserveCapacity(items.count)

        for item in items where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }
}

actor JapanSearchResponseCache {
    static let shared = JapanSearchResponseCache()

    struct SearchState {
        let itemIDs: [String]
        let nextFrom: Int
        let hasMore: Bool
        let usedContributorFilter: Bool
    }

    private var searchStateStorage: [String: SearchState] = [:]
    private var itemStorage: [String: JapanSearchItem] = [:]
    private var searchArtworkStorage: [String: Artwork] = [:]

    func searchState(forKey key: String) -> SearchState? {
        searchStateStorage[key]
    }

    func setSearchState(
        itemIDs: [String],
        nextFrom: Int,
        hasMore: Bool,
        usedContributorFilter: Bool,
        forKey key: String
    ) {
        searchStateStorage[key] = SearchState(
            itemIDs: itemIDs,
            nextFrom: nextFrom,
            hasMore: hasMore,
            usedContributorFilter: usedContributorFilter
        )
    }

    func removeSearchState(forKey key: String) {
        searchStateStorage.removeValue(forKey: key)
    }

    func item(forID id: String) -> JapanSearchItem? {
        itemStorage[id]
    }

    func setItem(_ item: JapanSearchItem, forID id: String) {
        itemStorage[id] = item
    }

    func searchArtwork(forKey key: String) -> Artwork? {
        searchArtworkStorage[key]
    }

    func setSearchArtworks(_ artworks: [Artwork]) {
        for artwork in artworks {
            searchArtworkStorage["\(artwork.museumID.rawValue)|\(artwork.objectID)"] = artwork
        }
    }
}
