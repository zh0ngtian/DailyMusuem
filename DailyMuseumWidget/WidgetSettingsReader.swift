import Foundation

struct WidgetSettingsReader {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    func categories(for museumID: MuseumID) -> [MuseumCategory] {
        museumID.feedCategories(withStoredValue: defaults.string(forKey: SettingsKeys.feedCategoryPrefix + museumID.rawValue))
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
    private let cachePolicy: MuseumRequestCachePolicy
    private let onLog: (@Sendable (String) async -> Void)?
    private let metAPI: MetMuseumAPI
    private let japanSearchAPI: JapanSearchAPI
    private let nationalMuseumChinaAPI: NationalMuseumChinaAPI
    private let shanghaiMuseumAPI: ShanghaiMuseumAPI

    private var objectIDPool: [String] = []
    private var loadedObjectIDs: Set<String> = []
    private var hasMoreRemoteItemIDs: Bool

    init(
        museumID: MuseumID,
        categories: [MuseumCategory],
        randomOrder: Bool,
        cachePolicy: MuseumRequestCachePolicy,
        onLog: (@Sendable (String) async -> Void)? = nil,
        metAPI: MetMuseumAPI = MetMuseumAPI(),
        japanSearchAPI: JapanSearchAPI = JapanSearchAPI(),
        nationalMuseumChinaAPI: NationalMuseumChinaAPI = NationalMuseumChinaAPI(),
        shanghaiMuseumAPI: ShanghaiMuseumAPI = ShanghaiMuseumAPI()
    ) {
        self.museumID = museumID
        self.categories = museumID.normalizedFeedCategories(categories)
        self.randomOrder = randomOrder
        self.cachePolicy = cachePolicy
        self.onLog = onLog
        self.metAPI = metAPI
        self.japanSearchAPI = japanSearchAPI
        self.nationalMuseumChinaAPI = nationalMuseumChinaAPI
        self.shanghaiMuseumAPI = shanghaiMuseumAPI
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

    func nextBatch(count: Int = Constants.defaultBatchSize) async throws -> [Artwork] {
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

        let artworks = try await fetchArtworks(for: nextCandidateIDs)
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
                        isOnView: true,
                        query: "*",
                        departmentID: departmentID,
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
                    isOnView: true,
                    query: "*",
                    cachePolicy: cachePolicy,
                    onLog: onLog
                )
            }
            await log("开始按\(randomOrder ? "随机" : "objectID 顺序")模式整理 objectIDs...")
            objectIDPool = randomOrder ? ids.map(String.init).shuffled() : ids.sorted().map(String.init)
            hasMoreRemoteItemIDs = false
            await log("objectIDs 已就绪，当前可用 \(objectIDPool.count) 条。")
        case .tnm:
            try await ensureTokyoPool(targetCount: targetCount, reason: "首次进入")
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
            try await ensureTokyoPool(targetCount: nextTargetCount, reason: "继续浏览")
        case .shm:
            try await ensureShanghaiPool(targetCount: nextTargetCount, reason: "继续浏览")
        case .met, .nmc:
            break
        }
    }

    private func ensureTokyoPool(targetCount: Int, reason: String) async throws {
        let mergedResult: JapanSearchAPI.SearchPoolSnapshot

        if let typeCodes = selectedJapanSearchTypeCodes {
            var mergedItemIDs: [String] = []
            var hasMoreRemoteItems = false

            for (category, typeCode) in zip(categories, typeCodes) {
                try Task.checkCancellation()
                let categoryResult = try await japanSearchAPI.searchItemIDs(
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
            await log("东京国立博物馆搜索结果存在重复 itemID，已去重 \(mergedResult.itemIDs.count - uniqueIDs.count) 条。")
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

    private func fetchArtworks(for candidateIDs: [String]) async throws -> [Artwork] {
        switch museumID {
        case .met:
            return await withTaskGroup(of: Artwork?.self) { group in
                for idString in candidateIDs {
                    group.addTask { [metAPI, cachePolicy] in
                        do {
                            try Task.checkCancellation()
                            guard let id = Int(idString) else { return nil }
                            let object = try await metAPI.fetchObject(objectID: id, cachePolicy: cachePolicy)
                            try Task.checkCancellation()
                            let artwork = object.toArtwork()
                            guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                                return nil
                            }
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
                    group.addTask { [japanSearchAPI, cachePolicy] in
                        do {
                            try Task.checkCancellation()
                            let item = try await japanSearchAPI.fetchItem(itemID: itemID, cachePolicy: cachePolicy)
                            try Task.checkCancellation()
                            return .artwork(item.toArtwork())
                        } catch {
                            return .failure("itemID=\(itemID) 详情获取失败：\(error.localizedDescription)")
                        }
                    }
                }
                let results = await collectBatchResults(from: &group)
                let failures = results.compactMap(\.failureMessage)
                if !failures.isEmpty {
                    await log("东京国立博物馆本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        await log(message)
                    }
                }
                return results.compactMap(\.artwork)
            }
        case .nmc:
            return await withTaskGroup(of: Artwork?.self) { group in
                for idString in candidateIDs {
                    group.addTask { [nationalMuseumChinaAPI, cachePolicy] in
                        do {
                            try Task.checkCancellation()
                            guard let id = Int(idString) else { return nil }
                            let artwork = try await nationalMuseumChinaAPI.fetchExhibit(exhibitID: id, cachePolicy: cachePolicy)
                            try Task.checkCancellation()
                            guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                                return nil
                            }
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
                    group.addTask { [shanghaiMuseumAPI, cachePolicy] in
                        do {
                            try Task.checkCancellation()
                            let artwork = try await shanghaiMuseumAPI.fetchArtwork(
                                objectCode: objectCode,
                                cachePolicy: cachePolicy
                            )
                            try Task.checkCancellation()
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
        museumID.areAllFeedCategoriesSelected(categories)
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

    private var selectedNationalMuseumChinaCategoryIDs: [Int]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.nationalMuseumChinaCategoryID)
    }

    private var selectedShanghaiMuseumSubtypes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return categories.compactMap(\.shanghaiMuseumSubtype)
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
