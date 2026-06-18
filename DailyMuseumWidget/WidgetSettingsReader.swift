import Foundation

struct WidgetSettingsReader {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    func categories(for museumID: MuseumID) -> [MuseumCategory] {
        let naraDataSource = museumID == .nnm ? naraMuseumDataSource() : nil
        let storedValue = defaults.string(forKey: SettingsKeys.feedCategoryKey(for: museumID, naraDataSource: naraDataSource))
        if museumID == .nnm, let naraDataSource {
            return museumID.feedCategories(withStoredValue: storedValue, naraDataSource: naraDataSource)
        }
        return museumID.feedCategories(withStoredValue: storedValue)
    }

    func naraMuseumDataSource() -> NaraMuseumDataSource {
        NaraMuseumDataSource.storedValue(in: defaults)
    }

    func metShowsOnlyOnViewArtworks() -> Bool {
        defaults.bool(forKey: SettingsKeys.metShowsOnlyOnViewArtworks)
    }

    func widgetRefreshInterval() -> WidgetRefreshInterval {
        WidgetRefreshInterval.storedValue(in: defaults)
    }

    func widgetAutoRefreshWindow() -> WidgetAutoRefreshWindow {
        WidgetAutoRefreshWindow.storedValue(in: defaults)
    }

    func widgetAutoRefreshStartMinutes() -> Int {
        widgetAutoRefreshWindow().startMinutes
    }

    func widgetAutoRefreshEndMinutes() -> Int {
        widgetAutoRefreshWindow().endMinutes
    }

    func widgetAutoRefreshSchedule(
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> WidgetAutoRefreshSchedule? {
        let window = widgetAutoRefreshWindow()
        return WidgetAutoRefreshSchedule(
            interval: widgetRefreshInterval(),
            startMinutes: window.startMinutes,
            endMinutes: window.endMinutes,
            calendar: calendar,
            timeZone: timeZone
        )
    }
}

enum WidgetScheduledRefreshPolicy {
    struct Resolution: Equatable {
        let shouldRefresh: Bool
        let scheduledAt: Date?
        let nextAutomaticRefreshAt: Date?
        let scheduleSignature: String?
    }

    static func resolve(
        state: WidgetArtworkSnapshotStore.InstanceState?,
        scopeRawValue: String,
        schedule: WidgetAutoRefreshSchedule?,
        now: Date
    ) -> Resolution {
        guard let schedule else {
            return Resolution(
                shouldRefresh: false,
                scheduledAt: nil,
                nextAutomaticRefreshAt: nil,
                scheduleSignature: nil
            )
        }

        guard let state,
              state.scopeRawValue == scopeRawValue,
              state.automaticRefreshScheduleSignature == schedule.signature,
              let nextAutomaticRefreshAt = state.nextAutomaticRefreshAt.map(Date.init(timeIntervalSince1970:)) else {
            return Resolution(
                shouldRefresh: false,
                scheduledAt: nil,
                nextAutomaticRefreshAt: schedule.nextRefreshDate(after: now),
                scheduleSignature: schedule.signature
            )
        }

        if nextAutomaticRefreshAt <= now {
            return Resolution(
                shouldRefresh: true,
                scheduledAt: nextAutomaticRefreshAt,
                nextAutomaticRefreshAt: schedule.nextRefreshDate(after: nextAutomaticRefreshAt),
                scheduleSignature: schedule.signature
            )
        }

        return Resolution(
            shouldRefresh: false,
            scheduledAt: nil,
            nextAutomaticRefreshAt: nextAutomaticRefreshAt,
            scheduleSignature: schedule.signature
        )
    }
}

actor ArtworkBatchLoader {
    struct StateSnapshot: Sendable, Equatable {
        let objectIDPool: [String]
        let loadedObjectIDs: Set<String>
        let hasMoreRemoteItemIDs: Bool
    }

    private enum Constants {
        static let defaultBatchSize = 10
    }

    private let museumID: MuseumID
    private let categories: [MuseumCategory]
    private let randomOrder: Bool
    private let metShowsOnlyOnViewArtworks: Bool
    private let cachePolicy: MuseumRequestCachePolicy
    private let onLog: (@Sendable (String) async -> Void)?
    private let metAPI: MetMuseumAPI
    private let japanSearchAPI: JapanSearchAPI
    private let naraMuseumAPI: NaraMuseumAPI
    private let nationalMuseumChinaAPI: NationalMuseumChinaAPI
    private let shanghaiMuseumAPI: ShanghaiMuseumAPI
    private let guimetMuseumAPI: GuimetMuseumAPI

    private var objectIDPool: [String] = []
    private var loadedObjectIDs: Set<String> = []
    private var hasMoreRemoteItemIDs: Bool

    init(
        museumID: MuseumID,
        categories: [MuseumCategory],
        randomOrder: Bool,
        metShowsOnlyOnViewArtworks: Bool = false,
        cachePolicy: MuseumRequestCachePolicy,
        onLog: (@Sendable (String) async -> Void)? = nil,
        metAPI: MetMuseumAPI = MetMuseumAPI(),
        japanSearchAPI: JapanSearchAPI = JapanSearchAPI(),
        naraMuseumAPI: NaraMuseumAPI = NaraMuseumAPI(),
        nationalMuseumChinaAPI: NationalMuseumChinaAPI = NationalMuseumChinaAPI(),
        shanghaiMuseumAPI: ShanghaiMuseumAPI = ShanghaiMuseumAPI(),
        guimetMuseumAPI: GuimetMuseumAPI = GuimetMuseumAPI()
    ) {
        self.museumID = museumID
        let naraDataSource = Self.inferredNaraDataSource(museumID: museumID, categories: categories)
        self.categories = museumID == .nnm
            ? museumID.normalizedFeedCategories(categories, naraDataSource: naraDataSource)
            : museumID.normalizedFeedCategories(categories)
        self.randomOrder = randomOrder
        self.metShowsOnlyOnViewArtworks = museumID == .met && metShowsOnlyOnViewArtworks
        self.cachePolicy = cachePolicy
        self.onLog = onLog
        self.metAPI = metAPI
        self.japanSearchAPI = japanSearchAPI
        self.naraMuseumAPI = naraMuseumAPI
        self.nationalMuseumChinaAPI = nationalMuseumChinaAPI
        self.shanghaiMuseumAPI = shanghaiMuseumAPI
        self.guimetMuseumAPI = guimetMuseumAPI
        hasMoreRemoteItemIDs = true
    }

    func restore(from snapshot: StateSnapshot) {
        objectIDPool = Self.stableUniqueStrings(snapshot.objectIDPool)
        loadedObjectIDs = snapshot.loadedObjectIDs
        hasMoreRemoteItemIDs = snapshot.hasMoreRemoteItemIDs
    }

    func snapshotState() -> StateSnapshot {
        StateSnapshot(
            objectIDPool: objectIDPool,
            loadedObjectIDs: loadedObjectIDs,
            hasMoreRemoteItemIDs: hasMoreRemoteItemIDs
        )
    }

    func isExhausted() -> Bool {
        let hasRemainingCandidates = objectIDPool.contains { !loadedObjectIDs.contains($0) }
        return !hasRemainingCandidates && !hasMoreRemoteItemIDs
    }

    func nextBatch(
        count: Int = Constants.defaultBatchSize,
        onArtworkReady: (@Sendable (Artwork) async -> Void)? = nil
    ) async throws -> [Artwork] {
        try Task.checkCancellation()
        try await warmPoolIfNeeded(targetCount: count)
        try await ensureRemotePoolIfNeeded(minimumRemainingCount: count)
        try Task.checkCancellation()

        let candidates = objectIDPool.filter { !loadedObjectIDs.contains($0) }
        guard !candidates.isEmpty else {
            return []
        }

        let batchLabel = loadedObjectIDs.isEmpty ? "首批" : "下一批"
        await log("开始拉取\(batchLabel) \(count) 个展品详情...")

        let nextCandidateIDs = Array(candidates.prefix(count))
        loadedObjectIDs.formUnion(nextCandidateIDs)

        let artworks = try await fetchArtworks(
            for: nextCandidateIDs,
            onArtworkReady: onArtworkReady
        )
        let deduplicated = deduplicatedArtworksPreservingPoolOrder(artworks)
        await log("\(batchLabel)详情加载完成，新增 \(deduplicated.count) 个展品。")
        return deduplicated
    }

    private func warmPoolIfNeeded(targetCount: Int) async throws {
        guard objectIDPool.isEmpty else {
            return
        }

        switch museumID {
        case .met:
            let ids: [Int]
            if let departmentIDs = selectedMetDepartmentIDs {
                var mergedIDs: [Int] = []
                for (category, departmentID) in zip(categories, departmentIDs) {
                    try Task.checkCancellation()
                    let categoryIDs = try await metAPI.searchObjectIDs(
                        hasImages: true,
                        query: "*",
                        departmentID: departmentID,
                        onlyOnView: metShowsOnlyOnViewArtworks,
                        cachePolicy: cachePolicy
                    ) { [log = onLog] message in
                        if let log {
                            await log("\(category.displayName)：\(message)")
                        }
                    }
                    mergedIDs.append(contentsOf: categoryIDs)
                }
                ids = Self.stableUniqueInts(mergedIDs)
                await log("已合并 \(categories.count) 个类别，共 \(ids.count) 条 objectIDs。")
            } else {
                ids = try await metAPI.searchObjectIDs(
                    hasImages: true,
                    query: "*",
                    onlyOnView: metShowsOnlyOnViewArtworks,
                    cachePolicy: cachePolicy,
                    onLog: onLog
                )
            }
            await log("开始按\(randomOrder ? "随机" : "objectID 顺序")模式整理 objectIDs...")
            objectIDPool = randomOrder ? ids.map(String.init).shuffled() : ids.sorted().map(String.init)
            hasMoreRemoteItemIDs = false
            await log("objectIDs 已就绪，当前可用 \(objectIDPool.count) 条。")
        case .tnm:
            try await ensureJapanSearchPool(targetCount: targetCount, reason: "首次进入")
        case .nnm:
            if naraMuseumDataSource == .official {
                try await ensureNaraOfficialPool(targetCount: targetCount, reason: "首次进入")
            } else {
                try await ensureJapanSearchPool(targetCount: targetCount, reason: "首次进入")
            }
        case .nmc:
            let ids: [Int]
            if let categoryIDs = selectedNationalMuseumChinaCategoryIDs {
                var mergedIDs: [Int] = []
                for (category, categoryID) in zip(categories, categoryIDs) {
                    try Task.checkCancellation()
                    let categoryItemIDs = try await nationalMuseumChinaAPI.allExhibitIDs(
                        categoryID: categoryID,
                        categoryDisplayName: category.displayName,
                        cachePolicy: cachePolicy
                    ) { [log = onLog] message in
                        if let log {
                            await log("\(category.displayName)：\(message)")
                        }
                    }
                    mergedIDs.append(contentsOf: categoryItemIDs)
                }
                ids = Self.stableUniqueInts(mergedIDs)
                await log("已合并 \(categories.count) 个类别，共 \(ids.count) 条展品 ID。")
            } else {
                ids = try await nationalMuseumChinaAPI.allExhibitIDs(
                    categoryDisplayName: selectedCategoriesLogLabel,
                    cachePolicy: cachePolicy,
                    onLog: onLog
                )
            }
            await log("开始按\(randomOrder ? "随机" : "objectID 顺序")模式整理展品 ID...")
            objectIDPool = randomOrder ? ids.map(String.init).shuffled() : ids.sorted().map(String.init)
            hasMoreRemoteItemIDs = false
            await log("展品 ID 已就绪，当前可用 \(objectIDPool.count) 条。")
        case .shm:
            try await ensureShanghaiPool(targetCount: targetCount, reason: "首次进入")
        case .guimet:
            try await ensureGuimetPool(targetCount: targetCount, reason: "首次进入")
        }
    }

    private func ensureRemotePoolIfNeeded(minimumRemainingCount: Int) async throws {
        let remainingCount = objectIDPool.filter { !loadedObjectIDs.contains($0) }.count
        guard remainingCount < minimumRemainingCount, hasMoreRemoteItemIDs else {
            return
        }

        let nextTargetCount = max(objectIDPool.count, loadedObjectIDs.count + minimumRemainingCount)
        switch museumID {
        case .tnm:
            try await ensureJapanSearchPool(targetCount: nextTargetCount, reason: "继续浏览")
        case .nnm:
            if naraMuseumDataSource == .official {
                try await ensureNaraOfficialPool(targetCount: nextTargetCount, reason: "继续浏览")
            } else {
                try await ensureJapanSearchPool(targetCount: nextTargetCount, reason: "继续浏览")
            }
        case .shm:
            try await ensureShanghaiPool(targetCount: nextTargetCount, reason: "继续浏览")
        case .guimet:
            try await ensureGuimetPool(targetCount: nextTargetCount, reason: "继续浏览")
        case .met, .nmc:
            break
        }
    }

    private func ensureJapanSearchPool(targetCount: Int, reason: String) async throws {
        let mergedResult: JapanSearchAPI.SearchPoolSnapshot

        if let typeCodes = selectedJapanSearchTypeCodes {
            var mergedItemIDs: [String] = []
            var hasMoreRemoteItems = false

            for (category, typeCode) in zip(categories, typeCodes) {
                try Task.checkCancellation()
                let categoryResult = try await japanSearchAPI.searchItemIDs(
                    museumID: museumID,
                    preferHasImages: true,
                    categoryTypeCode: typeCode,
                    minimumCount: targetCount,
                    cachePolicy: cachePolicy
                ) { [log = onLog] message in
                    if let log {
                        await log("\(category.displayName)：\(message)")
                    }
                }
                mergedItemIDs.append(contentsOf: categoryResult.itemIDs)
                hasMoreRemoteItems = hasMoreRemoteItems || categoryResult.hasMoreRemoteItems
            }

            mergedResult = JapanSearchAPI.SearchPoolSnapshot(
                itemIDs: Self.stableUniqueStrings(mergedItemIDs),
                hasMoreRemoteItems: hasMoreRemoteItems
            )
        } else {
            mergedResult = try await japanSearchAPI.searchItemIDs(
                museumID: museumID,
                preferHasImages: true,
                categoryTypeCode: nil,
                minimumCount: targetCount,
                cachePolicy: cachePolicy,
                onLog: onLog
            )
        }

        await log("\(reason)时按\(randomOrder ? "随机" : "ID 顺序")模式整理 itemIDs，类别：\(selectedCategoriesLogLabel)。")
        let uniqueIDs = Self.stableUniqueStrings(mergedResult.itemIDs)
        if uniqueIDs.count != mergedResult.itemIDs.count {
            await log("\(museumID.displayName)搜索结果存在重复 itemID，已去重 \(mergedResult.itemIDs.count - uniqueIDs.count) 条。")
        }

        if objectIDPool.isEmpty {
            objectIDPool = randomOrder ? uniqueIDs.shuffled() : uniqueIDs.sorted()
        } else if randomOrder {
            let existing = Set(objectIDPool)
            objectIDPool.append(contentsOf: uniqueIDs.filter { !existing.contains($0) }.shuffled())
        } else {
            objectIDPool = uniqueIDs.sorted()
        }

        hasMoreRemoteItemIDs = mergedResult.hasMoreRemoteItems
        await log("itemIDs 已就绪，当前缓存 \(objectIDPool.count) 条，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多远端数据")。")
    }

    private func ensureNaraOfficialPool(targetCount: Int, reason: String) async throws {
        let result = try await naraMuseumAPI.searchArtworkIDs(
            departments: selectedNaraOfficialDepartments,
            minimumCount: targetCount,
            cachePolicy: cachePolicy,
            onLog: onLog
        )

        await log("\(reason)时按\(randomOrder ? "随机" : "ID 顺序")模式整理奈良馆方展品，类别：\(selectedCategoriesLogLabel)。")
        let uniqueIDs = Self.stableUniqueStrings(result.objectIDs)
        if uniqueIDs.count != result.objectIDs.count {
            await log("奈良馆方搜索结果存在重复 objectID，已去重 \(result.objectIDs.count - uniqueIDs.count) 条。")
        }

        if objectIDPool.isEmpty {
            objectIDPool = randomOrder ? uniqueIDs.shuffled() : uniqueIDs.sorted()
        } else if randomOrder {
            let existing = Set(objectIDPool)
            objectIDPool.append(contentsOf: uniqueIDs.filter { !existing.contains($0) }.shuffled())
        } else {
            objectIDPool = uniqueIDs.sorted()
        }

        hasMoreRemoteItemIDs = result.hasMoreRemoteItems
        await log("奈良馆方 objectIDs 已就绪，当前缓存 \(objectIDPool.count) 条，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多远端数据")。")
    }

    private func ensureShanghaiPool(targetCount: Int, reason: String) async throws {
        let result = try await shanghaiMuseumAPI.searchArtworkCodes(
            subtypes: selectedShanghaiMuseumSubtypes,
            minimumCount: targetCount,
            cachePolicy: cachePolicy,
            onLog: onLog
        )

        await log("\(reason)时按\(randomOrder ? "随机" : "编码顺序")模式整理上海博物馆展品，类别：\(selectedCategoriesLogLabel)。")
        let uniqueIDs = Self.stableUniqueStrings(result.artworkCodes)
        if uniqueIDs.count != result.artworkCodes.count {
            await log("上海博物馆搜索结果存在重复编码，已去重 \(result.artworkCodes.count - uniqueIDs.count) 条。")
        }

        if objectIDPool.isEmpty {
            objectIDPool = randomOrder ? uniqueIDs.shuffled() : uniqueIDs.sorted()
        } else if randomOrder {
            let existing = Set(objectIDPool)
            objectIDPool.append(contentsOf: uniqueIDs.filter { !existing.contains($0) }.shuffled())
        } else {
            objectIDPool = uniqueIDs.sorted()
        }

        hasMoreRemoteItemIDs = result.hasMoreRemoteItems
        await log("上海博物馆展品编码已就绪，当前缓存 \(objectIDPool.count) 条，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多远端数据")。")
    }

    private func ensureGuimetPool(targetCount: Int, reason: String) async throws {
        let mergedResult: GuimetMuseumAPI.SearchPoolSnapshot

        if let collectionPaths = selectedGuimetCollectionPaths {
            var mergedReferences: [String] = []
            var hasMoreRemoteItems = false

            for (category, collectionPath) in zip(categories, collectionPaths) {
                try Task.checkCancellation()
                let categoryResult = try await guimetMuseumAPI.searchArtworkReferences(
                    collectionPaths: [collectionPath],
                    minimumCount: targetCount,
                    cachePolicy: cachePolicy
                ) { [log = onLog] message in
                    if let log {
                        await log("\(category.displayName)：\(message)")
                    }
                }
                mergedReferences.append(contentsOf: categoryResult.artworkReferences)
                hasMoreRemoteItems = hasMoreRemoteItems || categoryResult.hasMoreRemoteItems
            }

            mergedResult = GuimetMuseumAPI.SearchPoolSnapshot(
                artworkReferences: Self.stableUniqueStrings(mergedReferences),
                hasMoreRemoteItems: hasMoreRemoteItems
            )
        } else {
            mergedResult = try await guimetMuseumAPI.searchArtworkReferences(
                collectionPaths: nil,
                minimumCount: targetCount,
                cachePolicy: cachePolicy,
                onLog: onLog
            )
        }

        await log("\(reason)时按\(randomOrder ? "随机" : "网页路径顺序")模式整理吉美国立亚洲艺术博物馆展品，类别：\(selectedCategoriesLogLabel)。")
        let uniqueReferences = Self.stableUniqueStrings(mergedResult.artworkReferences)
        if objectIDPool.isEmpty {
            objectIDPool = randomOrder ? uniqueReferences.shuffled() : uniqueReferences.sorted()
        } else if randomOrder {
            let existing = Set(objectIDPool)
            objectIDPool.append(contentsOf: uniqueReferences.filter { !existing.contains($0) }.shuffled())
        } else {
            objectIDPool = uniqueReferences.sorted()
        }

        hasMoreRemoteItemIDs = mergedResult.hasMoreRemoteItems
        await log("吉美官网藏品路径已就绪，当前缓存 \(objectIDPool.count) 条，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多远端数据")。")
    }

    private func fetchArtworks(
        for candidateIDs: [String],
        onArtworkReady: (@Sendable (Artwork) async -> Void)?
    ) async throws -> [Artwork] {
        switch museumID {
        case .met:
            return await withTaskGroup(of: Artwork?.self) { group in
                for idString in candidateIDs {
                    group.addTask { [metAPI, cachePolicy, onArtworkReady] in
                        do {
                            try Task.checkCancellation()
                            guard let id = Int(idString) else { return nil }
                            let object = try await metAPI.fetchObject(objectID: id, cachePolicy: cachePolicy)
                            try Task.checkCancellation()
                            let artwork = object.toArtwork()
                            guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                                return nil
                            }
                            await onArtworkReady?(artwork)
                            return artwork
                        } catch {
                            return nil
                        }
                    }
                }
                return await collectArtworks(from: &group)
            }
        case .tnm:
            return await withTaskGroup(of: BatchLoadResult.self) { group in
                for itemID in candidateIDs {
                    group.addTask { [japanSearchAPI, cachePolicy, onArtworkReady, museumID] in
                        do {
                            try Task.checkCancellation()
                            let item = try await japanSearchAPI.fetchItem(
                                museumID: museumID,
                                itemID: itemID,
                                cachePolicy: cachePolicy
                            )
                            try Task.checkCancellation()
                            let artwork = item.toArtwork(museumID: museumID)
                            await onArtworkReady?(artwork)
                            return .artwork(artwork)
                        } catch {
                            return .failure("itemID=\(itemID) 详情获取失败：\(error.localizedDescription)")
                        }
                    }
                }
                let results = await collectBatchResults(from: &group)
                let failures = results.compactMap(\.failureMessage)
                if !failures.isEmpty {
                    await log("\(museumID.displayName)本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        await log(message)
                    }
                }
                return results.compactMap(\.artwork)
            }
        case .nnm:
            if naraMuseumDataSource == .official {
                return await withTaskGroup(of: BatchLoadResult.self) { group in
                    for objectID in candidateIDs {
                        group.addTask { [naraMuseumAPI, cachePolicy, onArtworkReady] in
                            do {
                                try Task.checkCancellation()
                                let artwork = try await naraMuseumAPI.fetchArtwork(
                                    objectID: objectID,
                                    cachePolicy: cachePolicy
                                )
                                try Task.checkCancellation()
                                await onArtworkReady?(artwork)
                                return .artwork(artwork)
                            } catch {
                                return .failure("objectID=\(objectID) 详情获取失败：\(error.localizedDescription)")
                            }
                        }
                    }
                    let results = await collectBatchResults(from: &group)
                    let failures = results.compactMap(\.failureMessage)
                    if !failures.isEmpty {
                        await log("奈良国立博物馆馆方本批详情失败 \(failures.count) 条。")
                        for message in failures.prefix(3) {
                            await log(message)
                        }
                    }
                    return results.compactMap(\.artwork)
                }
            }
            return await withTaskGroup(of: BatchLoadResult.self) { group in
                for itemID in candidateIDs {
                    group.addTask { [japanSearchAPI, cachePolicy, onArtworkReady, museumID] in
                        do {
                            try Task.checkCancellation()
                            let item = try await japanSearchAPI.fetchItem(
                                museumID: museumID,
                                itemID: itemID,
                                cachePolicy: cachePolicy
                            )
                            try Task.checkCancellation()
                            let artwork = item.toArtwork(museumID: museumID)
                            await onArtworkReady?(artwork)
                            return .artwork(artwork)
                        } catch {
                            return .failure("itemID=\(itemID) 详情获取失败：\(error.localizedDescription)")
                        }
                    }
                }
                let results = await collectBatchResults(from: &group)
                let failures = results.compactMap(\.failureMessage)
                if !failures.isEmpty {
                    await log("\(museumID.displayName)本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        await log(message)
                    }
                }
                return results.compactMap(\.artwork)
            }
        case .nmc:
            return await withTaskGroup(of: Artwork?.self) { group in
                for idString in candidateIDs {
                    group.addTask { [nationalMuseumChinaAPI, cachePolicy, onArtworkReady] in
                        do {
                            try Task.checkCancellation()
                            guard let id = Int(idString) else { return nil }
                            let artwork = try await nationalMuseumChinaAPI.fetchExhibit(exhibitID: id, cachePolicy: cachePolicy)
                            try Task.checkCancellation()
                            guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                                return nil
                            }
                            await onArtworkReady?(artwork)
                            return artwork
                        } catch {
                            return nil
                        }
                    }
                }
                return await collectArtworks(from: &group)
            }
        case .shm:
            return await withTaskGroup(of: BatchLoadResult.self) { group in
                for objectCode in candidateIDs {
                    group.addTask { [shanghaiMuseumAPI, cachePolicy, onArtworkReady] in
                        do {
                            try Task.checkCancellation()
                            let artwork = try await shanghaiMuseumAPI.fetchArtwork(
                                objectCode: objectCode,
                                cachePolicy: cachePolicy,
                                onTextResolved: onArtworkReady
                            )
                            try Task.checkCancellation()
                            await onArtworkReady?(artwork)
                            return .artwork(artwork)
                        } catch {
                            return .failure("code=\(objectCode) 详情获取失败：\(error.localizedDescription)")
                        }
                    }
                }
                let results = await collectBatchResults(from: &group)
                let failures = results.compactMap(\.failureMessage)
                if !failures.isEmpty {
                    await log("上海博物馆本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        await log(message)
                    }
                }
                return results.compactMap(\.artwork)
            }
        case .guimet:
            return await withTaskGroup(of: BatchLoadResult.self) { group in
                for reference in candidateIDs {
                    group.addTask { [guimetMuseumAPI, cachePolicy, onArtworkReady] in
                        do {
                            try Task.checkCancellation()
                            let artwork = try await guimetMuseumAPI.fetchArtwork(
                                reference: reference,
                                cachePolicy: cachePolicy
                            )
                            try Task.checkCancellation()
                            guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                                return .failure("path=\(reference) 缺少可用图片")
                            }
                            await onArtworkReady?(artwork)
                            return .artwork(artwork)
                        } catch {
                            return .failure("path=\(reference) 详情获取失败：\(error.localizedDescription)")
                        }
                    }
                }
                let results = await collectBatchResults(from: &group)
                let failures = results.compactMap(\.failureMessage)
                if !failures.isEmpty {
                    await log("吉美国立亚洲艺术博物馆本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        await log(message)
                    }
                }
                return results.compactMap(\.artwork)
            }
        }
    }

    private func deduplicatedArtworksPreservingPoolOrder(_ artworks: [Artwork]) -> [Artwork] {
        let orderIndex = Dictionary(
            objectIDPool.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        return artworks
            .sorted { lhs, rhs in
                (orderIndex[lhs.objectID] ?? .max) < (orderIndex[rhs.objectID] ?? .max)
            }
            .reduce(into: [Artwork]()) { partial, artwork in
                guard !partial.contains(where: { $0.objectID == artwork.objectID }) else { return }
                partial.append(artwork)
            }
    }

    private func collectArtworks(
        from group: inout TaskGroup<Artwork?>
    ) async -> [Artwork] {
        var output: [Artwork] = []
        for await result in group {
            if let artwork = result {
                output.append(artwork)
            }
        }
        return output
    }

    private func collectBatchResults(
        from group: inout TaskGroup<BatchLoadResult>
    ) async -> [BatchLoadResult] {
        var output: [BatchLoadResult] = []
        for await result in group {
            output.append(result)
        }
        return output
    }

    private func log(_ message: String) async {
        await onLog?(message)
    }

    private var isAllCategoriesSelected: Bool {
        if museumID == .nnm {
            return museumID.areAllFeedCategoriesSelected(categories, naraDataSource: naraMuseumDataSource)
        }
        return museumID.areAllFeedCategoriesSelected(categories)
    }

    private var selectedCategoriesLogLabel: String {
        isAllCategoriesSelected ? "全部" : categories.map(\.displayName).joined(separator: "、")
    }

    private var selectedMetDepartmentIDs: [Int]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.metDepartmentID)
    }

    private var selectedJapanSearchTypeCodes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.japanSearchTypeCode)
    }

    private var selectedNaraOfficialDepartments: [String]? {
        guard museumID == .nnm, naraMuseumDataSource == .official, !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.naraMuseumOfficialDepartment)
    }

    private var naraMuseumDataSource: NaraMuseumDataSource {
        Self.inferredNaraDataSource(museumID: museumID, categories: categories)
    }

    private var selectedNationalMuseumChinaCategoryIDs: [Int]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.nationalMuseumChinaCategoryID)
    }

    private var selectedShanghaiMuseumSubtypes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.shanghaiMuseumSubtype)
    }

    private var selectedGuimetCollectionPaths: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.guimetCollectionPath)
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

    private static func inferredNaraDataSource(museumID: MuseumID, categories: [MuseumCategory]) -> NaraMuseumDataSource {
        guard museumID == .nnm else { return .colbase }
        if categories.contains(where: { $0.kind == .naraMuseumOfficialDepartment }) {
            return .official
        }
        return .colbase
    }

    private enum BatchLoadResult {
        case artwork(Artwork)
        case failure(String)

        var artwork: Artwork? {
            guard case .artwork(let artwork) = self else { return nil }
            return artwork
        }

        var failureMessage: String? {
            guard case .failure(let message) = self else { return nil }
            return message
        }
    }
}

actor NationalMuseumChinaWidgetCandidateLoader: WidgetArtworkCandidateLoading {
    private struct CategoryChoice: Sendable {
        let categoryID: Int?
        let displayName: String

        var key: Int {
            categoryID ?? 0
        }
    }

    private struct PageKey: Hashable, Sendable {
        let categoryID: Int
        let page: Int
    }

    private enum Constants {
        static let pageSize = 10
        static let maxListPageRequests = 4
    }

    private let categories: [MuseumCategory]
    private let randomIndex: @Sendable (Range<Int>) -> Int
    private let onLog: (@Sendable (String) async -> Void)?
    private let nationalMuseumChinaAPI: NationalMuseumChinaAPI

    private var queuedIDs: [Int] = []
    private var loadedIDs: Set<Int> = []
    private var requestedListPages: Set<PageKey> = []
    private var consumedCandidatePages: Set<PageKey> = []
    private var storedPageIDs: [PageKey: [Int]] = [:]
    private var pageCountsByCategory: [Int: Int] = [:]
    private var exhaustedCategoryKeys: Set<Int> = []
    private var exhausted = false

    init(
        categories: [MuseumCategory],
        randomIndex: @escaping @Sendable (Range<Int>) -> Int,
        onLog: (@Sendable (String) async -> Void)? = nil,
        nationalMuseumChinaAPI: NationalMuseumChinaAPI = NationalMuseumChinaAPI()
    ) {
        self.categories = MuseumID.nmc.normalizedFeedCategories(categories)
        self.randomIndex = randomIndex
        self.onLog = onLog
        self.nationalMuseumChinaAPI = nationalMuseumChinaAPI
    }

    func nextCandidateArtwork() async throws -> Artwork? {
        while true {
            if let exhibitID = nextQueuedID() {
                do {
                    let artwork = try await nationalMuseumChinaAPI.fetchExhibit(
                        exhibitID: exhibitID,
                        cachePolicy: .networkOnly
                    )
                    guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                        await log("中国国家博物馆 Widget 候选缺少可用图片，跳过 exhibitID=\(exhibitID)。")
                        continue
                    }
                    return artwork
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await log("中国国家博物馆 Widget 候选详情失败，exhibitID=\(exhibitID)：\(error.localizedDescription)")
                    continue
                }
            }

            if exhausted {
                return nil
            }

            try await refillQueuedIDs()
        }
    }

    func isExhausted() async -> Bool {
        let hasQueuedCandidates = queuedIDs.contains { !loadedIDs.contains($0) }
        return exhausted && !hasQueuedCandidates
    }

    private func refillQueuedIDs() async throws {
        while requestedListPages.count < Constants.maxListPageRequests {
            guard let choice = nextCategoryChoice() else {
                exhausted = true
                return
            }

            if pageCountsByCategory[choice.key] == nil {
                let firstPage = try await fetchIDPage(choice: choice, page: 1)
                let key = PageKey(categoryID: choice.key, page: 1)
                pageCountsByCategory[choice.key] = firstPage.pageCount
                storedPageIDs[key] = firstPage.ids
            }

            let pageCount = pageCountsByCategory[choice.key] ?? 1
            let availablePages = (1...pageCount).filter {
                !consumedCandidatePages.contains(PageKey(categoryID: choice.key, page: $0))
            }

            guard !availablePages.isEmpty else {
                exhaustedCategoryKeys.insert(choice.key)
                continue
            }

            let selectedPage = availablePages[randomIndex(0..<availablePages.count)]
            let pageKey = PageKey(categoryID: choice.key, page: selectedPage)
            let ids: [Int]
            if let storedIDs = storedPageIDs.removeValue(forKey: pageKey) {
                ids = storedIDs
            } else {
                guard requestedListPages.count < Constants.maxListPageRequests else {
                    exhausted = true
                    return
                }
                let page = try await fetchIDPage(choice: choice, page: selectedPage)
                pageCountsByCategory[choice.key] = page.pageCount
                ids = page.ids
            }

            consumedCandidatePages.insert(pageKey)
            let newIDs = randomized(ids).filter { id in
                !loadedIDs.contains(id) && !queuedIDs.contains(id)
            }
            queuedIDs.append(contentsOf: newIDs)
            await log("中国国家博物馆 Widget 已准备候选页 \(selectedPage)/\(pageCount)，类别 \(choice.displayName)，新增 \(newIDs.count) 个候选。")

            if !queuedIDs.isEmpty {
                return
            }
        }

        exhausted = true
    }

    private func fetchIDPage(choice: CategoryChoice, page: Int) async throws -> NationalMuseumChinaExhibitIDPage {
        let result = try await nationalMuseumChinaAPI.exhibitIDPage(
            categoryID: choice.categoryID,
            categoryDisplayName: choice.displayName,
            page: page,
            limit: Constants.pageSize
        )
        requestedListPages.insert(PageKey(categoryID: choice.key, page: result.page))
        await log("中国国家博物馆 Widget 列表接口已拉取第 \(result.page)/\(result.pageCount) 页，类别 \(choice.displayName)，本页 \(result.ids.count) 条。")
        return result
    }

    private func nextQueuedID() -> Int? {
        queuedIDs.removeAll { loadedIDs.contains($0) }
        guard !queuedIDs.isEmpty else {
            return nil
        }
        let index = queuedIDs.count == 1 ? 0 : randomIndex(0..<queuedIDs.count)
        let id = queuedIDs.remove(at: index)
        loadedIDs.insert(id)
        return id
    }

    private func nextCategoryChoice() -> CategoryChoice? {
        let availableChoices = categoryChoices.filter { !exhaustedCategoryKeys.contains($0.key) }
        guard !availableChoices.isEmpty else {
            return nil
        }
        let index = availableChoices.count == 1 ? 0 : randomIndex(0..<availableChoices.count)
        return availableChoices[index]
    }

    private var categoryChoices: [CategoryChoice] {
        guard !MuseumID.nmc.areAllFeedCategoriesSelected(categories) else {
            return [CategoryChoice(categoryID: nil, displayName: "全部")]
        }

        let choices = categories.compactMap { category -> CategoryChoice? in
            guard let categoryID = category.nationalMuseumChinaCategoryID else {
                return nil
            }
            return CategoryChoice(categoryID: categoryID, displayName: category.displayName)
        }
        return choices.isEmpty ? [CategoryChoice(categoryID: nil, displayName: "全部")] : choices
    }

    private func randomized(_ ids: [Int]) -> [Int] {
        var remaining = Self.stableUniqueInts(ids)
        var output: [Int] = []
        output.reserveCapacity(remaining.count)

        while !remaining.isEmpty {
            let index = remaining.count == 1 ? 0 : randomIndex(0..<remaining.count)
            output.append(remaining.remove(at: index))
        }
        return output
    }

    private func log(_ message: String) async {
        await onLog?(message)
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
