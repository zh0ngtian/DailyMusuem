import Foundation

struct WidgetArtworkService {
    private enum Constants {
        static let candidateSelectionMaxAttempts = 12
        static let imageDownloadMaxAttempts = 3
        static let imageRequestTimeout: TimeInterval = 8
        static let imageRetryBaseDelayNanoseconds: UInt64 = 400_000_000
    }

    let settings: WidgetSettingsReader
    private let metAPI: MetMuseumAPI
    private let japanSearchAPI: JapanSearchAPI
    private let nationalMuseumChinaAPI: NationalMuseumChinaAPI
    private let shanghaiMuseumAPI: ShanghaiMuseumAPI
    private let snapshotStore: WidgetArtworkSnapshotStore
    private let urlSession: URLSession
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
        let cycleKey = makeCycleKey(date: date)
        if let targetRenderID = await settings.reusableManualRefreshTargetRenderID(now: date),
           let snapshot = await snapshotStore.loadLatest(),
           snapshot.cycleKey == targetRenderID {
            let reuseSummary = settings.manualRefreshInProgress
                ? "命中当前手动刷新结果"
                : "命中最近一次手动刷新结果"
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "\(reuseSummary)，直接复用 \(snapshot.museumName) / \(snapshot.title)"
            )
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

        let snapshot = try await snapshotStore.generateSnapshot { latestSnapshot in
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
                let artwork = try await loadArtwork(candidateID)
                if let snapshot = try await makeValidatedSnapshot(
                    for: artwork,
                    museum: museum,
                    cycleKey: cycleKey
                ) {
                    return snapshot
                }
                if fallbackArtwork == nil {
                    fallbackArtwork = artwork
                }
            } catch {
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
    ) async throws -> WidgetArtworkSnapshotStore.Snapshot? {
        guard let imageURL = preferredWidgetImageURL(for: artwork, museum: museum) else {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "候选展品缺少图片，继续尝试 \(museum.displayName) / \(artwork.title)"
            )
            return nil
        }

        guard let imageData = try await fetchImageData(url: imageURL) else {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "候选展品图片拉取失败，继续尝试 \(museum.displayName) / \(artwork.title)"
            )
            return nil
        }

        return await snapshot(
            for: artwork,
            museum: museum,
            cycleKey: cycleKey,
            imageData: imageData
        )
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
            appURL: AppDeepLink.artworkURL(reference: reference)
        )
        let storedSnapshot = await snapshotStore.store(snapshot, imageData: imageData)
        await RequestLogger.shared.logEvent(
            source: "Widget 刷新",
            summary: "刷新完成，已缓存 \(museum.displayName) / \(artwork.title)"
        )
        return storedSnapshot
    }

    private func preferredWidgetImageURL(for artwork: Artwork, museum: Museum) -> URL? {
        switch museum.id {
        case .tnm:
            return artwork.primaryImageURL ?? artwork.primaryImageSmallURL
        case .met, .nmc, .shm:
            return artwork.primaryImageSmallURL ?? artwork.primaryImageURL
        }
    }

    private func metObjectIDs() async throws -> [Int] {
        let selectedCategories = settings.categories(for: .met)
        guard !MuseumID.met.areAllFeedCategoriesSelected(selectedCategories) else {
            return try await metAPI.searchObjectIDs(
                hasImages: settings.preferHasImages,
                isOnView: true,
                query: "*"
            )
        }

        var mergedIDs: [Int] = []
        for category in selectedCategories {
            guard let departmentID = category.metDepartmentID else { continue }
            let categoryIDs = try await metAPI.searchObjectIDs(
                hasImages: settings.preferHasImages,
                isOnView: true,
                query: "*",
                departmentID: departmentID
            )
            mergedIDs.append(contentsOf: categoryIDs)
        }
        return Self.stableUniqueInts(mergedIDs)
    }

    private func tnmItemIDs() async throws -> [String] {
        let selectedCategories = settings.categories(for: .tnm)
        guard !MuseumID.tnm.areAllFeedCategoriesSelected(selectedCategories) else {
            let searchPool = try await japanSearchAPI.searchItemIDs(preferHasImages: settings.preferHasImages)
            return searchPool.itemIDs
        }

        var mergedIDs: [String] = []
        for category in selectedCategories {
            guard let typeCode = category.japanSearchTypeCode else { continue }
            let categoryResult = try await japanSearchAPI.searchItemIDs(
                preferHasImages: settings.preferHasImages,
                categoryTypeCode: typeCode
            )
            mergedIDs.append(contentsOf: categoryResult.itemIDs)
        }
        return Self.stableUniqueStrings(mergedIDs)
    }

    private func nmcExhibitIDs() async throws -> [Int] {
        let selectedCategories = settings.categories(for: .nmc)
        guard !MuseumID.nmc.areAllFeedCategoriesSelected(selectedCategories) else {
            return try await nationalMuseumChinaAPI.allExhibitIDs()
        }

        var mergedIDs: [Int] = []
        for category in selectedCategories {
            guard let categoryID = category.nationalMuseumChinaCategoryID else { continue }
            let categoryItemIDs = try await nationalMuseumChinaAPI.allExhibitIDs(
                categoryID: categoryID,
                categoryDisplayName: category.displayName
            )
            mergedIDs.append(contentsOf: categoryItemIDs)
        }
        return Self.stableUniqueInts(mergedIDs)
    }

    private func shmArtworkCodes() async throws -> [String] {
        let selectedCategories = settings.categories(for: .shm)
        let selectedSubtypes: [String]? = if MuseumID.shm.areAllFeedCategoriesSelected(selectedCategories) {
            nil
        } else {
            selectedCategories.compactMap(\.shanghaiMuseumSubtype)
        }
        return try await shanghaiMuseumAPI.allArtworkCodes(subtypes: selectedSubtypes)
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
        for attempt in 1...Constants.imageDownloadMaxAttempts {
            let start = Date()
            let request = URLRequest(url: url, timeoutInterval: Constants.imageRequestTimeout)
            await RequestLogger.shared.logRequestStart(source: "Widget 图片", url: url)

            do {
                let (data, response) = try await urlSession.data(for: request)
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
                if attempt > 1 {
                    await RequestLogger.shared.logEvent(
                        source: "Widget 图片",
                        summary: "第 \(attempt) 次尝试成功，结束重试"
                    )
                }
                return data
            } catch {
                await RequestLogger.shared.logRequestFailure(
                    source: "Widget 图片",
                    url: url,
                    duration: Date().timeIntervalSince(start),
                    error: error
                )

                guard attempt < Constants.imageDownloadMaxAttempts else {
                    await RequestLogger.shared.logEvent(
                        source: "Widget 图片",
                        summary: "图片请求已达到最大重试次数 \(Constants.imageDownloadMaxAttempts)"
                    )
                    return nil
                }

                let nextAttempt = attempt + 1
                await RequestLogger.shared.logEvent(
                    source: "Widget 图片",
                    summary: "准备第 \(nextAttempt) 次重试"
                )
                let delay = Constants.imageRetryBaseDelayNanoseconds * UInt64(attempt)
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        return nil
    }

    private func makeCycleKey(date: Date) -> String {
        let refreshBucket = Int(date.timeIntervalSince1970 / settings.refreshInterval.seconds)
        return [
            settings.museumScope.rawValue,
            settings.categorySelectionKey,
            settings.preferHasImages ? "images" : "all",
            String(settings.manualRefreshNonce),
            String(refreshBucket)
        ].joined(separator: "|")
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
