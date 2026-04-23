import Foundation
import WidgetKit

protocol WidgetArtworkCandidateLoading: Sendable {
    func nextCandidateArtwork() async throws -> Artwork?
    func isExhausted() async -> Bool
}

extension ArtworkBatchLoader: WidgetArtworkCandidateLoading {
    func nextCandidateArtwork() async throws -> Artwork? {
        try await nextBatch(count: 1).first
    }
}

enum WidgetRefreshError: LocalizedError, Equatable {
    case noRenderableArtwork

    var errorDescription: String? {
        switch self {
        case .noRenderableArtwork:
            return "未找到可展示的展品。"
        }
    }
}

struct WidgetRefreshPayload: Equatable {
    let museumID: MuseumID
    let artworkKey: String
    let museumName: String
    let title: String
    let subtitle: String?
    let imageData: Data
    let appURL: URL?

    func storedPayload(now: Date = .now) -> WidgetArtworkSnapshotStore.ArtworkPayload {
        WidgetArtworkSnapshotStore.ArtworkPayload(
            museumID: museumID,
            artworkKey: artworkKey,
            museumName: museumName,
            title: title,
            subtitle: subtitle,
            imageFileName: nil,
            appURL: appURL,
            updatedAt: now.timeIntervalSince1970
        )
    }
}

enum WidgetDisplayedArtworkKey {
    static func make(museumID: MuseumID, objectID: String) -> String {
        "\(museumID.rawValue)|\(objectID)"
    }
}

actor WidgetRefreshCoordinator {
    static let shared = WidgetRefreshCoordinator()

    private let store: WidgetArtworkSnapshotStore
    private let widgetCenter: WidgetCenter
    private let makeEngine: @Sendable () -> WidgetRefreshEngine
    private var activeRefreshes: [String: (nonce: Int, task: Task<WidgetRefreshPayload, Error>)] = [:]

    init(
        store: WidgetArtworkSnapshotStore = .shared,
        widgetCenter: WidgetCenter = .shared,
        makeEngine: @escaping @Sendable () -> WidgetRefreshEngine = { WidgetRefreshEngine() }
    ) {
        self.store = store
        self.widgetCenter = widgetCenter
        self.makeEngine = makeEngine
    }

    func refresh(
        refreshKey: String,
        scope: WidgetMuseumScope,
        familyToken: String? = nil,
        logSource: String = "Widget 刷新",
        reloadTimelines: Bool = true
    ) async {
        let state = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: scope.rawValue,
            familyToken: familyToken
        )
        let nonce = state.nonce

        if let activeRefresh = activeRefreshes[refreshKey] {
            activeRefresh.task.cancel()
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "收到新的刷新请求，nonce=\(nonce) 抢占旧任务 nonce=\(activeRefresh.nonce)",
                instanceToken: refreshKey
            )
        }

        if reloadTimelines {
            widgetCenter.reloadTimelines(ofKind: SettingsKeys.widgetKind)
        }

        let engine = makeEngine()
        let task = Task {
            try await engine.fetchRenderableArtwork(
                scope: scope,
                refreshKey: refreshKey,
                logSource: logSource
            )
        }
        activeRefreshes[refreshKey] = (nonce, task)

        do {
            let payload = try await task.value
            _ = await store.markSuccess(
                instanceToken: refreshKey,
                expectedNonce: nonce,
                payload: payload.storedPayload(),
                imageData: payload.imageData,
                familyToken: familyToken
            )
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "刷新成功：\(payload.museumName) / \(payload.title)",
                instanceToken: refreshKey
            )
        } catch is CancellationError {
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "旧刷新任务 nonce=\(nonce) 已取消",
                instanceToken: refreshKey
            )
        } catch let error as WidgetRefreshError {
            _ = await store.markFailure(
                instanceToken: refreshKey,
                expectedNonce: nonce,
                message: error.localizedDescription,
                familyToken: familyToken
            )
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "刷新失败：\(error.localizedDescription)",
                instanceToken: refreshKey
            )
        } catch {
            _ = await store.markFailure(
                instanceToken: refreshKey,
                expectedNonce: nonce,
                message: error.localizedDescription,
                familyToken: familyToken
            )
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "刷新出错：\(error.localizedDescription)",
                instanceToken: refreshKey
            )
        }

        if activeRefreshes[refreshKey]?.nonce == nonce {
            activeRefreshes[refreshKey] = nil
        }
        if reloadTimelines {
            widgetCenter.reloadTimelines(ofKind: SettingsKeys.widgetKind)
        }
    }

    func refreshAllKnownInstances(logSource: String = "App 快捷操作") async {
        let instances = await store.knownInstances()
        for instance in instances {
            guard let scope = WidgetMuseumScope(rawValue: instance.scopeRawValue) else {
                continue
            }
            await refresh(
                refreshKey: instance.instanceToken,
                scope: scope,
                familyToken: instance.familyToken,
                logSource: logSource
            )
        }
    }
}

struct WidgetRefreshEngine {
    typealias LoaderFactory = @Sendable (MuseumID, [MuseumCategory], (@Sendable (String) async -> Void)?) -> any WidgetArtworkCandidateLoading
    typealias RandomIndex = @Sendable (Range<Int>) -> Int
    typealias ImageDataFetcher = @Sendable (URL, Int) async throws -> Data?

    private enum Constants {
        static let imageRetryLimit = 3
        static let imageRequestTimeout: TimeInterval = 8
        static let imageRetryBaseDelayNanoseconds: UInt64 = 400_000_000
    }

    let settingsReader: WidgetSettingsReader
    let snapshotStore: WidgetArtworkSnapshotStore
    let loaderFactory: LoaderFactory
    let randomIndex: RandomIndex
    let imageDataFetcher: ImageDataFetcher?
    let urlSession: URLSession

    init(
        settingsReader: WidgetSettingsReader = WidgetSettingsReader(),
        snapshotStore: WidgetArtworkSnapshotStore = .shared,
        loaderFactory: LoaderFactory? = nil,
        randomIndex: @escaping RandomIndex = { range in
            Int.random(in: range)
        },
        imageDataFetcher: ImageDataFetcher? = nil,
        urlSession: URLSession = .shared
    ) {
        self.settingsReader = settingsReader
        self.snapshotStore = snapshotStore
        self.loaderFactory = loaderFactory ?? { museumID, categories, onLog in
            ArtworkBatchLoader(
                museumID: museumID,
                categories: categories,
                randomOrder: true,
                cachePolicy: MuseumRequestCachePolicy.networkOnly,
                onLog: onLog
            )
        }
        self.randomIndex = randomIndex
        self.imageDataFetcher = imageDataFetcher
        self.urlSession = urlSession
    }

    func fetchRenderableArtwork(
        scope: WidgetMuseumScope,
        refreshKey: String,
        logSource: String = "Widget 刷新"
    ) async throws -> WidgetRefreshPayload {
        var didResetDisplayedHistory = false

        while true {
            var loaders = makeLoaders(
                for: scope,
                instanceToken: refreshKey,
                logSource: logSource
            )
            let displayedArtworkKeys = await snapshotStore.displayedArtworkKeys(
                for: refreshKey,
                scopeRawValue: scope.rawValue
            )
            var candidateAttempt = 0
            var skippedDisplayedArtwork = false
            var rejectedUnseenArtwork = false

            while true {
                try Task.checkCancellation()

                let availableMuseumIDs = await selectableMuseumIDs(from: loaders)
                guard !availableMuseumIDs.isEmpty else {
                    break
                }

                let museumIndex = availableMuseumIDs.count == 1 ? 0 : randomIndex(0..<availableMuseumIDs.count)
                let selectedMuseumID = availableMuseumIDs[museumIndex]
                guard let loader = loaders[selectedMuseumID] else {
                    continue
                }

                let museum = MuseumRepository.museum(for: selectedMuseumID)
                candidateAttempt += 1
                await Self.logEvent(
                    logSource: logSource,
                    instanceToken: refreshKey,
                    summary: "开始尝试候选 \(candidateAttempt)：\(museum.displayName)，类别=\(categorySummary(for: selectedMuseumID))"
                )

                guard let artwork = try await loader.nextCandidateArtwork() else {
                    if await loader.isExhausted() {
                        await Self.logEvent(
                            logSource: logSource,
                            instanceToken: refreshKey,
                            summary: "候选 \(candidateAttempt) 未产出展品且该博物馆候选已耗尽：\(museum.displayName)"
                        )
                        loaders.removeValue(forKey: selectedMuseumID)
                    } else {
                        await Self.logEvent(
                            logSource: logSource,
                            instanceToken: refreshKey,
                            summary: "候选 \(candidateAttempt) 未产出展品，继续尝试下一个候选"
                        )
                    }
                    continue
                }

                await Self.logEvent(
                    logSource: logSource,
                    instanceToken: refreshKey,
                    summary: "候选 \(candidateAttempt) 详情拉取成功：\(artwork.museumID.displayName) / \(artwork.title)"
                )

                let artworkKey = WidgetDisplayedArtworkKey.make(
                    museumID: artwork.museumID,
                    objectID: artwork.objectID
                )
                if displayedArtworkKeys.contains(artworkKey) {
                    skippedDisplayedArtwork = true
                    await Self.logEvent(
                        logSource: logSource,
                        instanceToken: refreshKey,
                        summary: "候选 \(candidateAttempt) 已在当前共享组展示过，跳过 \(artwork.museumID.displayName) / \(artwork.title)"
                    )
                    continue
                }

                if let payload = try await makePayload(
                    for: artwork,
                    artworkKey: artworkKey,
                    logSource: logSource,
                    instanceToken: refreshKey,
                    candidateAttempt: candidateAttempt
                ) {
                    await Self.logEvent(
                        logSource: logSource,
                        instanceToken: refreshKey,
                        summary: "候选 \(candidateAttempt) 命中可渲染展品并停止继续拉取：\(payload.museumName) / \(payload.title)"
                    )
                    return payload
                }

                rejectedUnseenArtwork = true
                await Self.logEvent(
                    logSource: logSource,
                    instanceToken: refreshKey,
                    summary: "候选 \(candidateAttempt) 未通过渲染校验，继续尝试下一个候选"
                )
            }

            if skippedDisplayedArtwork && !rejectedUnseenArtwork && !didResetDisplayedHistory {
                _ = await snapshotStore.resetDisplayedArtworkHistory(
                    for: refreshKey,
                    scopeRawValue: scope.rawValue
                )
                didResetDisplayedHistory = true
                await Self.logEvent(
                    logSource: logSource,
                    instanceToken: refreshKey,
                    summary: "当前范围内没有新的未展示展品，清空当前共享组历史后重试一次"
                )
                continue
            }

            throw WidgetRefreshError.noRenderableArtwork
        }
    }

    private func makeLoaders(
        for scope: WidgetMuseumScope,
        instanceToken: String,
        logSource: String
    ) -> [MuseumID: any WidgetArtworkCandidateLoading] {
        let logger: @Sendable (String) async -> Void = { message in
            await Self.logEvent(
                logSource: logSource,
                instanceToken: instanceToken,
                summary: message
            )
        }

        switch scope {
        case .all:
            return Dictionary(
                uniqueKeysWithValues: MuseumRepository.widgetSupportedMuseums.map { museum in
                    let categories = settingsReader.categories(for: museum.id)
                    return (museum.id, loaderFactory(museum.id, categories, logger))
                }
            )
        case .single(let museumID):
            return [
                museumID: loaderFactory(
                    museumID,
                    settingsReader.categories(for: museumID),
                    logger
                )
            ]
        }
    }

    private func selectableMuseumIDs(
        from loaders: [MuseumID: any WidgetArtworkCandidateLoading]
    ) async -> [MuseumID] {
        var museumIDs: [MuseumID] = []
        for museumID in loaders.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let loader = loaders[museumID], !(await loader.isExhausted()) else {
                continue
            }
            museumIDs.append(museumID)
        }
        return museumIDs
    }

    private func makePayload(
        for artwork: Artwork,
        artworkKey: String,
        logSource: String,
        instanceToken: String,
        candidateAttempt: Int
    ) async throws -> WidgetRefreshPayload? {
        guard let imageURL = WidgetPreferredImageURLDecision.resolve(
            for: artwork,
            museumID: artwork.museumID
        ) else {
            await Self.logEvent(
                logSource: logSource,
                instanceToken: instanceToken,
                summary: "候选 \(candidateAttempt) 缺少可用图片，跳过 \(artwork.museumID.displayName) / \(artwork.title)"
            )
            return nil
        }

        guard let imageData = try await fetchImageData(
            url: imageURL,
            artwork: artwork,
            logSource: logSource,
            instanceToken: instanceToken,
            candidateAttempt: candidateAttempt
        ) else {
            await Self.logEvent(
                logSource: logSource,
                instanceToken: instanceToken,
                summary: "候选 \(candidateAttempt) 图片连续失败 3 次，跳过 \(artwork.museumID.displayName) / \(artwork.title)"
            )
            return nil
        }

        return WidgetRefreshPayload(
            museumID: artwork.museumID,
            artworkKey: artworkKey,
            museumName: artwork.museumID.displayName,
            title: artwork.title,
            subtitle: artwork.objectDate,
            imageData: imageData,
            appURL: AppDeepLink.artworkURL(
                reference: ArtworkReference(
                    museumID: artwork.museumID,
                    objectID: artwork.objectID,
                    imageAspectRatio: nil
                )
            )
        )
    }

    private func fetchImageData(
        url: URL,
        artwork: Artwork,
        logSource: String,
        instanceToken: String,
        candidateAttempt: Int
    ) async throws -> Data? {
        for attempt in 1...Constants.imageRetryLimit {
            try Task.checkCancellation()
            let start = Date()

            do {
                let data: Data
                if let imageDataFetcher {
                    guard let customData = try await imageDataFetcher(url, attempt) else {
                        throw URLError(.resourceUnavailable)
                    }
                    data = customData
                } else {
                    let request = WidgetImageRequestPolicy.makeRequest(
                        url: url,
                        timeout: Constants.imageRequestTimeout
                    )
                    let (responseData, response) = try await urlSession.data(for: request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    data = responseData
                }

                guard WidgetArtworkSnapshotStore.imageDimensions(from: data) != nil else {
                    throw URLError(.cannotDecodeContentData)
                }

                await Self.logEvent(
                    logSource: logSource,
                    instanceToken: instanceToken,
                    summary: "候选 \(candidateAttempt) 图片拉取成功，尝试 \(attempt)/\(Constants.imageRetryLimit)，\(artwork.museumID.displayName) / \(artwork.title)，耗时 \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
                )
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await Self.logEvent(
                    logSource: logSource,
                    instanceToken: instanceToken,
                    summary: "候选 \(candidateAttempt) 图片拉取失败，尝试 \(attempt)/\(Constants.imageRetryLimit)，\(artwork.museumID.displayName) / \(artwork.title)：\(error.localizedDescription)"
                )

                guard attempt < Constants.imageRetryLimit else {
                    return nil
                }

                let delay = Constants.imageRetryBaseDelayNanoseconds * UInt64(attempt)
                try await Task.sleep(nanoseconds: delay)
            }
        }

        return nil
    }

    private func categorySummary(for museumID: MuseumID) -> String {
        let categories = settingsReader.categories(for: museumID)
        if museumID.areAllFeedCategoriesSelected(categories) {
            return "全部"
        }
        return categories.map(\.displayName).joined(separator: "、")
    }

    private static func logEvent(
        logSource: String,
        instanceToken: String,
        summary: String
    ) async {
        await RequestLogger.shared.logEvent(
            source: logSource,
            summary: summary,
            instanceToken: instanceToken
        )
    }
}

enum WidgetImageRequestPolicy {
    private enum Constants {
        static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        static let accept = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
        static let acceptLanguage = "ja-JP,ja;q=0.9,en-US;q=0.8,zh-CN;q=0.7"
    }

    static func makeRequest(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if requiresBrowserLikeHeaders(url: url) {
            request.setValue(Constants.safariUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Constants.accept, forHTTPHeaderField: "Accept")
            request.setValue(Constants.acceptLanguage, forHTTPHeaderField: "Accept-Language")
            request.setValue("https://colbase.nich.go.jp/", forHTTPHeaderField: "Referer")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }

        return request
    }

    private static func requiresBrowserLikeHeaders(url: URL) -> Bool {
        url.host?.contains("colbase.nich.go.jp") == true
    }
}

enum WidgetPreferredImageURLDecision {
    static func resolve(for artwork: Artwork, museumID: MuseumID) -> URL? {
        resolveCandidates(for: artwork, museumID: museumID).first
    }

    static func resolveCandidates(for artwork: Artwork, museumID: MuseumID) -> [URL] {
        switch museumID {
        case .tnm:
            return compactUniqueURLs([artwork.primaryImageSmallURL, artwork.primaryImageURL])
        case .met, .nmc, .shm:
            return compactUniqueURLs([artwork.primaryImageURL, artwork.primaryImageSmallURL])
        }
    }

    private static func compactUniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen: Set<URL> = []
        return urls.compactMap { url in
            guard let url, seen.insert(url).inserted else {
                return nil
            }
            return url
        }
    }
}
