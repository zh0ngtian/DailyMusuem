import Foundation

struct WidgetArtworkService {
    private enum Constants {
        static let candidateSelectionMaxAttempts = 12
        static let imageRetryBaseDelayNanoseconds: UInt64 = 400_000_000
    }

    let settings: WidgetSettingsReader
    private let metAPI: MetMuseumAPI
    private let japanSearchAPI: JapanSearchAPI
    private let nationalMuseumChinaAPI: NationalMuseumChinaAPI
    private let shanghaiMuseumAPI: ShanghaiMuseumAPI
    private let snapshotStore: WidgetArtworkSnapshotStore
    private let urlSession: URLSession
    private let manualRefreshExecutionNonce: Int?
    private let familyKey: String
    private let chooseRandomMuseum: ([Museum]) -> Museum?
    private let randomIndex: (Range<Int>) -> Int
    private let shuffleStrings: ([String]) -> [String]

    init(
        settings: WidgetSettingsReader = WidgetSettingsReader(),
        metAPI: MetMuseumAPI = MetMuseumAPI(),
        japanSearchAPI: JapanSearchAPI = JapanSearchAPI(),
        nationalMuseumChinaAPI: NationalMuseumChinaAPI = NationalMuseumChinaAPI(),
        shanghaiMuseumAPI: ShanghaiMuseumAPI = ShanghaiMuseumAPI(),
        snapshotStore: WidgetArtworkSnapshotStore = .shared,
        urlSession: URLSession = .shared,
        manualRefreshExecutionNonce: Int? = nil,
        familyKey: String = "",
        chooseRandomMuseum: @escaping ([Museum]) -> Museum? = { museums in
            museums.randomElement()
        },
        randomIndex: @escaping (Range<Int>) -> Int = { range in
            Int.random(in: range)
        },
        shuffleStrings: @escaping ([String]) -> [String] = { values in
            values.shuffled()
        }
    ) {
        self.settings = settings
        self.metAPI = metAPI
        self.japanSearchAPI = japanSearchAPI
        self.nationalMuseumChinaAPI = nationalMuseumChinaAPI
        self.shanghaiMuseumAPI = shanghaiMuseumAPI
        self.snapshotStore = snapshotStore
        self.urlSession = urlSession
        self.manualRefreshExecutionNonce = manualRefreshExecutionNonce
        self.familyKey = familyKey
        self.chooseRandomMuseum = chooseRandomMuseum
        self.randomIndex = randomIndex
        self.shuffleStrings = shuffleStrings
    }

    func makeLoadingEntry(date: Date) async -> WidgetArtworkEntry {
        if let snapshot = await snapshotStore.loadLatest() {
            return WidgetArtworkEntry(
                date: date,
                renderID: "loading-\(snapshot.cycleKey)",
                museumName: snapshot.museumName,
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                imageFileName: snapshot.imageFileName,
                appURL: snapshot.appURL,
                isRefreshing: true
            )
        }

        return WidgetArtworkEntry(
            date: date,
            renderID: "loading-\(date.timeIntervalSince1970)",
            museumName: "DailyMuseum",
            title: "刷新中",
            subtitle: "正在拉取最新展品",
            imageFileName: nil,
            appURL: nil,
            isRefreshing: true
        )
    }

    func fetchEntry(date: Date) async throws -> WidgetArtworkEntry {
        try throwIfManualRefreshInterrupted()
        let cycleKey = makeCycleKey(date: date)
        if let targetRenderID = await settings.reusableManualRefreshTargetRenderID(
            forFamilyKey: familyKey,
            now: date
        ),
           let entry = await manualRefreshEntry(date: date, targetRenderID: targetRenderID) {
            let reuseSummary = settings.manualRefreshInProgress(forFamilyKey: familyKey, now: date)
                ? "命中当前手动刷新结果"
                : "命中最近一次手动刷新结果"
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "\(reuseSummary)，直接复用 \(entry.museumName) / \(entry.title)"
            )
            return entry
        }

        let snapshot = try await snapshotStore.generateSnapshot(
            lockKey: resolvedFamilyKey,
            manualRefreshNonce: manualRefreshExecutionNonce,
            shouldAbortWaiting: { [settings, manualRefreshExecutionNonce] in
                guard let manualRefreshExecutionNonce else {
                    return false
                }
                return settings.shouldInterruptManualRefreshExecution(nonce: manualRefreshExecutionNonce)
            }
        ) { latestSnapshot in
            try throwIfManualRefreshInterrupted()
            if WidgetSnapshotReuseDecision.shouldReuseLatestSnapshot(
                latestSnapshotCycleKey: latestSnapshot?.cycleKey,
                requestedCycleKey: cycleKey
            ),
               let latestSnapshot {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "命中同周期快照，直接复用 \(latestSnapshot.museumName) / \(latestSnapshot.title)"
                )
                return latestSnapshot
            }

            let previousReference = latestSnapshot?.appURL.flatMap(AppDeepLink.parse)
            let museum = pickMuseum()
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "开始生成新条目，博物馆=\(museum.displayName)，类别=\(categorySummary(for: museum.id))"
            )

            switch museum.id {
            case .met:
                let ids = try await metObjectIDs()
                return try await resolveSnapshot(
                    from: ids.map(String.init),
                    museum: museum,
                    previousReference: previousReference,
                    cycleKey: cycleKey
                ) { id in
                    guard let objectID = Int(id) else {
                        throw URLError(.cannotParseResponse)
                    }
                    let object = try await metAPI.fetchObject(objectID: objectID)
                    return object.toArtwork()
                }
            case .tnm:
                let searchPool = try await tnmItemIDs()
                return try await resolveSnapshot(
                    from: searchPool,
                    museum: museum,
                    previousReference: previousReference,
                    cycleKey: cycleKey
                ) { id in
                    let item = try await japanSearchAPI.fetchItem(itemID: id)
                    return item.toArtwork()
                }
            case .nmc:
                let ids = try await nmcExhibitIDs()
                return try await resolveSnapshot(
                    from: ids.map(String.init),
                    museum: museum,
                    previousReference: previousReference,
                    cycleKey: cycleKey
                ) { id in
                    guard let exhibitID = Int(id) else {
                        throw URLError(.cannotParseResponse)
                    }
                    return try await nationalMuseumChinaAPI.fetchExhibit(exhibitID: exhibitID)
                }
            case .shm:
                let codes = try await shmArtworkCodes()
                return try await resolveSnapshot(
                    from: codes,
                    museum: museum,
                    previousReference: previousReference,
                    cycleKey: cycleKey
                ) { code in
                    if let cached = await shanghaiMuseumAPI.cachedSearchArtwork(objectCode: code) {
                        return cached
                    }
                    return try await shanghaiMuseumAPI.fetchArtwork(objectCode: code)
                }
            }
        }

        return WidgetArtworkEntry(
            date: date,
            renderID: snapshot.cycleKey,
            museumName: snapshot.museumName,
            title: snapshot.title,
            subtitle: snapshot.subtitle,
            imageFileName: snapshot.imageFileName,
            appURL: snapshot.appURL,
            isRefreshing: false
        )
    }

    func manualRefreshEntry(date: Date, targetRenderID: String) async -> WidgetArtworkEntry? {
        guard let snapshot = await snapshotStore.loadLatest(),
              snapshot.cycleKey == targetRenderID else {
            return nil
        }

        return WidgetArtworkEntry(
            date: date,
            renderID: snapshot.cycleKey,
            museumName: snapshot.museumName,
            title: snapshot.title,
            subtitle: snapshot.subtitle,
            imageFileName: snapshot.imageFileName,
            appURL: snapshot.appURL,
            isRefreshing: false
        )
    }

    private func resolveSnapshot(
        from candidateIDs: [String],
        museum: Museum,
        previousReference: ArtworkReference?,
        cycleKey: String,
        loadArtwork: @escaping @Sendable (String) async throws -> Artwork
    ) async throws -> WidgetArtworkSnapshotStore.Snapshot {
        let orderedCandidateIDs = prioritizedCandidateIDs(
            from: candidateIDs,
            previousReference: previousReference,
            museum: museum
        )
        guard !orderedCandidateIDs.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        var fallbackArtwork: Artwork?
        var lastError: Error?

        for candidateID in orderedCandidateIDs {
            do {
                try throwIfManualRefreshInterrupted()
                let artwork = try await loadArtwork(candidateID)
                try throwIfManualRefreshInterrupted()
                switch try await makeValidatedSnapshot(
                    for: artwork,
                    museum: museum,
                    cycleKey: cycleKey
                ) {
                case .ready(let snapshot):
                    return snapshot
                case .missingImage:
                    if fallbackArtwork == nil {
                        fallbackArtwork = artwork
                    }
                case .imageFetchFailed:
                    if fallbackArtwork == nil {
                        fallbackArtwork = artwork
                    }
                case .invalidImageData:
                    if fallbackArtwork == nil {
                        fallbackArtwork = artwork
                    }
                }
            } catch {
                if error is CancellationError || error is WidgetManualRefreshInterruptedError {
                    throw error
                }
                lastError = error
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "候选展品拉取失败，继续尝试 \(museum.displayName) / \(candidateID)：\(error.localizedDescription)"
                )
            }
        }

        if let fallbackArtwork {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "未找到可用图片，回退为无图条目 \(museum.displayName) / \(fallbackArtwork.title)"
            )
            return await snapshot(
                for: fallbackArtwork,
                museum: museum,
                cycleKey: cycleKey,
                imageData: nil
            )
        }

        if let lastError {
            throw lastError
        }

        throw URLError(.cannotParseResponse)
    }

    private func makeValidatedSnapshot(
        for artwork: Artwork,
        museum: Museum,
        cycleKey: String
    ) async throws -> WidgetValidatedSnapshotResult {
        let imageURLs = preferredWidgetImageURLs(for: artwork, museum: museum)
        guard !imageURLs.isEmpty else {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "候选展品缺少图片，继续尝试 \(museum.displayName) / \(artwork.title)"
            )
            return .missingImage
        }

        var sawImageFetchFailure = false

        for (index, imageURL) in imageURLs.enumerated() {
            try throwIfManualRefreshInterrupted()
            guard let imageData = try await fetchImageData(url: imageURL) else {
                sawImageFetchFailure = true
                continue
            }

            guard let dimensions = WidgetArtworkSnapshotStore.imageDimensions(from: imageData) else {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "候选展品图片无法解析尺寸，继续尝试 \(museum.displayName) / \(artwork.title)"
                )
                continue
            }

            guard WidgetImageSuitabilityDecision.isAcceptableForWidget(dimensions: dimensions) else {
                let candidatePosition = index + 1
                let candidateCount = imageURLs.count
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "候选展品图片尺寸不适合 widget，继续尝试 \(museum.displayName) / \(artwork.title)，图片尺寸=\(dimensions.summary)，候选 \(candidatePosition)/\(candidateCount)"
                )
                continue
            }

            return .ready(await snapshot(
                for: artwork,
                museum: museum,
                cycleKey: cycleKey,
                imageData: imageData
            ))
        }

        if sawImageFetchFailure {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "候选展品图片拉取失败，继续尝试 \(museum.displayName) / \(artwork.title)"
            )
            return .imageFetchFailed
        }

        return .invalidImageData
    }

    private func snapshot(
        for artwork: Artwork,
        museum: Museum,
        cycleKey: String,
        imageData: Data?
    ) async -> WidgetArtworkSnapshotStore.Snapshot {
        let reference = ArtworkReference(
            museumID: museum.id,
            objectID: artwork.objectID,
            imageAspectRatio: nil
        )

        let snapshot = WidgetArtworkSnapshotStore.Snapshot(
            cycleKey: cycleKey,
            museumName: museum.displayName,
            title: artwork.title,
            subtitle: artwork.objectDate,
            imageFileName: nil,
            appURL: AppDeepLink.artworkURL(reference: reference),
            generatedAt: Date().timeIntervalSince1970,
            manualRefreshNonce: effectiveManualRefreshNonce
        )
        let storedSnapshot = await snapshotStore.store(snapshot, imageData: imageData)
        let imageSummary = storedSnapshot.imageFileName
            .flatMap { WidgetArtworkSnapshotStore.imageDimensions(for: $0)?.summary }
            ?? "无图"
        if storedSnapshot.cycleKey == snapshot.cycleKey {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "刷新完成，已缓存 \(museum.displayName) / \(artwork.title)，图片尺寸=\(imageSummary)"
            )
        } else {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "检测到较新的快照已写入，忽略较旧结果 \(museum.displayName) / \(artwork.title)，继续保留 \(storedSnapshot.museumName) / \(storedSnapshot.title)，图片尺寸=\(imageSummary)"
            )
        }
        return storedSnapshot
    }

    private func preferredWidgetImageURLs(for artwork: Artwork, museum: Museum) -> [URL] {
        WidgetPreferredImageURLDecision.resolveCandidates(for: artwork, museumID: museum.id)
    }

    private func metObjectIDs() async throws -> [Int] {
        try throwIfManualRefreshInterrupted()
        let selectedCategories = settings.categories(for: .met)
        guard !MuseumID.met.areAllFeedCategoriesSelected(selectedCategories) else {
            let ids = try await metAPI.searchObjectIDs(
                hasImages: settings.preferHasImages,
                isOnView: true,
                query: "*"
            )
            try throwIfManualRefreshInterrupted()
            return ids
        }

        var mergedIDs: [Int] = []
        for category in selectedCategories {
            try throwIfManualRefreshInterrupted()
            guard let departmentID = category.metDepartmentID else { continue }
            let categoryIDs = try await metAPI.searchObjectIDs(
                hasImages: settings.preferHasImages,
                isOnView: true,
                query: "*",
                departmentID: departmentID
            )
            try throwIfManualRefreshInterrupted()
            mergedIDs.append(contentsOf: categoryIDs)
        }
        return Self.stableUniqueInts(mergedIDs)
    }

    private func tnmItemIDs() async throws -> [String] {
        try throwIfManualRefreshInterrupted()
        let selectedCategories = settings.categories(for: .tnm)
        guard !MuseumID.tnm.areAllFeedCategoriesSelected(selectedCategories) else {
            let searchPool = try await japanSearchAPI.searchItemIDs(preferHasImages: settings.preferHasImages)
            try throwIfManualRefreshInterrupted()
            return searchPool.itemIDs
        }

        var mergedIDs: [String] = []
        for category in selectedCategories {
            try throwIfManualRefreshInterrupted()
            guard let typeCode = category.japanSearchTypeCode else { continue }
            let categoryResult = try await japanSearchAPI.searchItemIDs(
                preferHasImages: settings.preferHasImages,
                categoryTypeCode: typeCode
            )
            try throwIfManualRefreshInterrupted()
            mergedIDs.append(contentsOf: categoryResult.itemIDs)
        }
        return Self.stableUniqueStrings(mergedIDs)
    }

    private func nmcExhibitIDs() async throws -> [Int] {
        try throwIfManualRefreshInterrupted()
        let selectedCategories = settings.categories(for: .nmc)
        guard !MuseumID.nmc.areAllFeedCategoriesSelected(selectedCategories) else {
            let ids = try await nationalMuseumChinaAPI.allExhibitIDs()
            try throwIfManualRefreshInterrupted()
            return ids
        }

        var mergedIDs: [Int] = []
        for category in selectedCategories {
            try throwIfManualRefreshInterrupted()
            guard let categoryID = category.nationalMuseumChinaCategoryID else { continue }
            let categoryItemIDs = try await nationalMuseumChinaAPI.allExhibitIDs(
                categoryID: categoryID,
                categoryDisplayName: category.displayName
            )
            try throwIfManualRefreshInterrupted()
            mergedIDs.append(contentsOf: categoryItemIDs)
        }
        return Self.stableUniqueInts(mergedIDs)
    }

    private func shmArtworkCodes() async throws -> [String] {
        try throwIfManualRefreshInterrupted()
        let selectedCategories = settings.categories(for: .shm)
        let selectedSubtypes: [String]? = if MuseumID.shm.areAllFeedCategoriesSelected(selectedCategories) {
            nil
        } else {
            selectedCategories.compactMap(\.shanghaiMuseumSubtype)
        }
        // Widget only needs a small candidate pool per refresh. Pulling the entire
        // Shanghai collection forces hundreds of paginated requests before we can
        // choose a single artwork, which makes refresh effectively unbounded.
        let minimumPoolCount = max(Constants.candidateSelectionMaxAttempts, 10)
        let snapshot = try await shanghaiMuseumAPI.searchArtworkCodes(
            subtypes: selectedSubtypes,
            minimumCount: minimumPoolCount
        )
        try throwIfManualRefreshInterrupted()
        return snapshot.artworkCodes
    }

    private func categorySummary(for museumID: MuseumID) -> String {
        let categories = settings.categories(for: museumID)
        if museumID.areAllFeedCategoriesSelected(categories) {
            return "全部"
        }
        return categories.map(\.displayName).joined(separator: "、")
    }

    private func prioritizedCandidateIDs(
        from ids: [String],
        previousReference: ArtworkReference?,
        museum: Museum
    ) -> [String] {
        guard !ids.isEmpty else { return [] }

        let excludedObjectID = previousReference?.museumID == museum.id ? previousReference?.objectID : nil
        let candidatePool: [String]
        if let excludedObjectID {
            let filtered = ids.filter { $0 != excludedObjectID }
            candidatePool = filtered.isEmpty ? ids : filtered
        } else {
            candidatePool = ids
        }

        guard candidatePool.count > Constants.candidateSelectionMaxAttempts else {
            return shuffleStrings(candidatePool)
        }

        var sampledIndices: Set<Int> = []
        sampledIndices.reserveCapacity(Constants.candidateSelectionMaxAttempts)
        while sampledIndices.count < Constants.candidateSelectionMaxAttempts {
            sampledIndices.insert(randomIndex(0..<candidatePool.count))
        }

        return shuffleStrings(sampledIndices.map { candidatePool[$0] })
    }

    private func pickMuseum() -> Museum {
        switch settings.museumScope {
        case .all:
            return chooseRandomMuseum(MuseumRepository.widgetSupportedMuseums)
                ?? MuseumRepository.widgetSupportedMuseums[0]
        case .single(let id):
            return MuseumRepository.widgetSupportedMuseums.first(where: { $0.id == id }) ?? MuseumRepository.widgetSupportedMuseums[0]
        }
    }

    private func fetchImageData(url: URL?) async throws -> Data? {
        guard let url else { return nil }
        let requestTimeout = WidgetImageFetchPolicy.requestTimeout(
            manualRefreshInProgress: isManualRefreshExecution
        )
        let maxAttempts = WidgetImageFetchPolicy.maxAttempts(
            manualRefreshInProgress: isManualRefreshExecution
        )
        for attempt in 1...maxAttempts {
            try throwIfManualRefreshInterrupted()
            let start = Date()
            let request = WidgetImageRequestPolicy.makeRequest(
                url: url,
                timeout: requestTimeout
            )
            await RequestLogger.shared.logRequestStart(source: "Widget 图片", url: url)

            do {
                let (data, response) = try await urlSession.data(for: request)
                try throwIfManualRefreshInterrupted()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                await RequestLogger.shared.logRequestSuccess(
                    source: "Widget 图片",
                    url: url,
                    statusCode: http.statusCode,
                    duration: Date().timeIntervalSince(start),
                    responseBytes: data.count
                )
                let dimensionSummary = WidgetArtworkSnapshotStore.imageDimensions(from: data)?.summary ?? "未知"
                await RequestLogger.shared.logEvent(
                    source: "Widget 图片",
                    summary: "图片像素尺寸=\(dimensionSummary)"
                )
                if attempt > 1 {
                    await RequestLogger.shared.logEvent(
                        source: "Widget 图片",
                        summary: "第 \(attempt) 次尝试成功，结束重试"
                    )
                }
                return data
            } catch {
                if error is CancellationError || error is WidgetManualRefreshInterruptedError {
                    throw error
                }
                await RequestLogger.shared.logRequestFailure(
                    source: "Widget 图片",
                    url: url,
                    duration: Date().timeIntervalSince(start),
                    error: error
                )

                guard attempt < maxAttempts else {
                    await RequestLogger.shared.logEvent(
                        source: "Widget 图片",
                        summary: "图片请求已达到最大重试次数 \(maxAttempts)"
                    )
                    return nil
                }

                let nextAttempt = attempt + 1
                await RequestLogger.shared.logEvent(
                    source: "Widget 图片",
                    summary: "准备第 \(nextAttempt) 次重试"
                )
                let delay = Constants.imageRetryBaseDelayNanoseconds * UInt64(attempt)
                try await Task.sleep(nanoseconds: delay)
            }
        }

        return nil
    }

    private func makeCycleKey(date: Date) -> String {
        let refreshBucket = Int(date.timeIntervalSince1970 / settings.refreshInterval.seconds)
        return [
            resolvedFamilyKey,
            settings.museumScope.rawValue,
            settings.categorySelectionKey,
            settings.preferHasImages ? "images" : "all",
            String(effectiveManualRefreshNonce),
            String(refreshBucket)
        ].joined(separator: "|")
    }

    private var effectiveManualRefreshNonce: Int {
        guard isManualRefreshExecution else {
            return 0
        }
        return manualRefreshExecutionNonce ?? settings.manualRefreshNonceValue
    }

    private var isManualRefreshExecution: Bool {
        manualRefreshExecutionNonce != nil || settings.manualRefreshInProgress(forFamilyKey: familyKey)
    }

    private var resolvedFamilyKey: String {
        familyKey.isEmpty ? "unscoped" : familyKey
    }

    private func throwIfManualRefreshInterrupted(now: Date = .now) throws {
        guard let manualRefreshExecutionNonce else {
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
        guard settings.shouldInterruptManualRefreshExecution(
            nonce: manualRefreshExecutionNonce,
            now: now
        ) else {
            return
        }
        throw WidgetManualRefreshInterruptedError(
            executionNonce: manualRefreshExecutionNonce,
            activeNonce: settings.manualRefreshNonceValue
        )
    }

    private static func stableUniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func stableUniqueInts(_ values: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []
        result.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
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

enum WidgetSnapshotReuseDecision {
    static func shouldReuseLatestSnapshot(
        latestSnapshotCycleKey: String?,
        requestedCycleKey: String
    ) -> Bool {
        latestSnapshotCycleKey == requestedCycleKey
    }
}
