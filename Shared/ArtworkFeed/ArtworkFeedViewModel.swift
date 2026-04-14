import Foundation
import SwiftUI

@MainActor
final class ArtworkFeedViewModel: ObservableObject {
    private enum Constants {
        static let initialBatchSize = 10
        static let loadMoreBatchSize = 10
    }

    private enum FeedLoadingError: LocalizedError {
        case noDisplayableArtworks

        var errorDescription: String? {
            switch self {
            case .noDisplayableArtworks:
                return "暂时没有可展示的展品，请稍后重试。"
            }
        }
    }

    private enum BatchLoadResult {
        case artwork(Artwork)
        case failure(String)
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var items: [ArtworkFeedItem] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMoreItems = true
    @Published private(set) var loadingLogs: [String] = []
    @Published private(set) var selectedCategories: [MuseumCategory]

    private let museum: Museum
    private let metAPI = MetMuseumAPI()
    private let japanSearchAPI = JapanSearchAPI()
    private let nationalMuseumChinaAPI = NationalMuseumChinaAPI()
    private let shanghaiMuseumAPI = ShanghaiMuseumAPI()
    private var objectIDPool: [String] = []
    private var loadedObjectIDs: Set<String> = []
    private var hasMoreRemoteItemIDs = false

    init(museum: Museum) {
        self.museum = museum
        self.selectedCategories = SettingsStore.shared.feedCategories(for: museum.id)
    }

    var availableCategories: [MuseumCategory] {
        museum.id.selectableFeedCategories
    }

    func loadInitialIfNeeded() async {
        guard state == .idle else { return }
        if restoreCachedFeedIfAvailable() { return }
        await reload()
    }

    var isAllCategoriesSelected: Bool {
        museum.id.areAllFeedCategoriesSelected(selectedCategories)
    }

    var selectedCategoriesSummary: String {
        if isAllCategoriesSelected {
            return "全部"
        }

        if selectedCategories.count <= 2 {
            return selectedCategories.map(\.displayName).joined(separator: "、")
        }

        return "已选 \(selectedCategories.count) 类"
    }

    func selectAllCategories() async {
        await updateSelectedCategories(museum.id.defaultFeedCategories)
    }

    func applySelectedCategories(_ categories: [MuseumCategory]) async {
        await updateSelectedCategories(categories)
    }

    func toggleCategorySelection(_ category: MuseumCategory) async {
        guard category.museumID == museum.id else { return }
        guard state != .loading, !isLoadingMore else { return }

        var nextCategoryIDs = Set(selectedCategories.map(\.id))
        if nextCategoryIDs.contains(category.id) {
            guard selectedCategories.count > 1 else { return }
            nextCategoryIDs.remove(category.id)
        } else {
            nextCategoryIDs.insert(category.id)
        }

        let nextCategories = availableCategories.filter { nextCategoryIDs.contains($0.id) }
        await updateSelectedCategories(nextCategories)
    }

    func reload() async {
        ArtworkFeedCache.shared.clear(
            museumID: museum.id,
            randomOrder: isRandomOrder,
            categorySelectionKey: categorySelectionKey
        )
        if museum.id == .tnm {
            if let typeCodes = selectedJapanSearchTypeCodes {
                for typeCode in typeCodes {
                    await japanSearchAPI.resetSearchCache(
                        preferHasImages: true,
                        categoryTypeCode: typeCode
                    )
                }
            } else {
                await japanSearchAPI.resetSearchCache(
                    preferHasImages: true,
                    categoryTypeCode: nil
                )
            }
        } else if museum.id == .shm {
            await shanghaiMuseumAPI.resetSearchCache(subtypes: selectedShanghaiMuseumSubtypes)
        }
        state = .loading
        items = []
        objectIDPool = []
        loadedObjectIDs = []
        hasMoreItems = true
        hasMoreRemoteItemIDs = museum.id == .tnm || museum.id == .shm
        isLoadingMore = false
        loadingLogs = []
        appendLoadingLog("开始加载 \(museum.displayName) 展品，当前类别：\(selectedCategoriesLogLabel)。")

        do {
            try await warmPoolIfNeeded()
            try await loadNextBatch(count: Constants.initialBatchSize)
            guard !items.isEmpty else {
                appendLoadingLog("首批加载后仍无可展示展品，转为失败态，避免空白页面。")
                throw FeedLoadingError.noDisplayableArtworks
            }
            appendLoadingLog("首批 \(items.count) 个展品已准备完成。")
            state = .loaded
        } catch {
            appendLoadingLog("加载失败：\(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded() async {
        guard state == .loaded, hasMoreItems, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            try await warmPoolIfNeeded()
            try await ensureTokyoPoolIfNeeded(minimumRemainingCount: Constants.loadMoreBatchSize)
            try await ensureShanghaiPoolIfNeeded(minimumRemainingCount: Constants.loadMoreBatchSize)
            try await loadNextBatch(count: Constants.loadMoreBatchSize)
        } catch {
            appendLoadingLog("加载更多失败：\(error.localizedDescription)")
        }
    }

    func loadMoreAfterExplicitSwipeIfNeeded() async {
        guard state == .loaded, hasMoreItems, !isLoadingMore else { return }
        appendLoadingLog("检测到底部明确上滑，开始加载下一批展品。")
        await loadMoreIfNeeded()
    }

    func updateAspectRatio(for id: String, aspectRatio: CGFloat) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0.05, Double(aspectRatio))
        if items[index].imageAspectRatio != clamped {
            items[index].imageAspectRatio = clamped
            persistCache()
        }
    }

    private func warmPoolIfNeeded() async throws {
        guard objectIDPool.isEmpty else { return }

        switch museum.id {
        case .met:
            let ids: [Int]
            if let departmentIDs = selectedMetDepartmentIDs {
                var mergedIDs: [Int] = []
                for (category, departmentID) in zip(selectedCategories, departmentIDs) {
                    let categoryIDs = try await metAPI.searchObjectIDs(
                        hasImages: true,
                        isOnView: true,
                        query: "*",
                        departmentID: departmentID
                    ) { [weak self] message in
                        await self?.appendLoadingLog("\(category.displayName)：\(message)")
                    }
                    mergedIDs.append(contentsOf: categoryIDs)
                }
                ids = Self.stableUniqueInts(mergedIDs)
                appendLoadingLog("已合并 \(selectedCategories.count) 个类别，共 \(ids.count) 条 objectIDs。")
            } else {
                ids = try await metAPI.searchObjectIDs(
                    hasImages: true,
                    isOnView: true,
                    query: "*"
                ) { [weak self] message in
                    await self?.appendLoadingLog(message)
                }
            }
            appendLoadingLog("开始按\(isRandomOrder ? "随机" : "objectID 顺序")模式整理 objectIDs...")
            if isRandomOrder {
                objectIDPool = Array(ids.map(String.init).shuffled())
            } else {
                objectIDPool = ids.sorted().map(String.init)
            }
            appendLoadingLog("objectIDs 已就绪，当前可用 \(objectIDPool.count) 条。")
        case .tnm:
            try await ensureTokyoPool(targetCount: Constants.initialBatchSize, reason: "首次进入")
        case .nmc:
            let ids: [Int]
            if let categoryIDs = selectedNationalMuseumChinaCategoryIDs {
                var mergedIDs: [Int] = []
                for (category, categoryID) in zip(selectedCategories, categoryIDs) {
                    let categoryItemIDs = try await nationalMuseumChinaAPI.allExhibitIDs(
                        categoryID: categoryID,
                        categoryDisplayName: category.displayName
                    ) { [weak self] message in
                        await self?.appendLoadingLog(message)
                    }
                    mergedIDs.append(contentsOf: categoryItemIDs)
                }
                ids = Self.stableUniqueInts(mergedIDs)
                appendLoadingLog("已合并 \(selectedCategories.count) 个类别，共 \(ids.count) 条展品 ID。")
            } else {
                ids = try await nationalMuseumChinaAPI.allExhibitIDs(
                    categoryDisplayName: selectedCategoriesLogLabel
                ) { [weak self] message in
                    await self?.appendLoadingLog(message)
                }
            }
            appendLoadingLog("开始按\(isRandomOrder ? "随机" : "objectID 顺序")模式整理展品 ID...")
            if isRandomOrder {
                objectIDPool = Array(ids.map(String.init).shuffled())
            } else {
                objectIDPool = ids.sorted().map(String.init)
            }
            appendLoadingLog("展品 ID 已就绪，当前可用 \(objectIDPool.count) 条。")
        case .shm:
            try await ensureShanghaiPool(targetCount: Constants.initialBatchSize, reason: "首次进入")
        }
    }

    private func loadNextBatch(count: Int) async throws {
        var candidates = objectIDPool.filter { !loadedObjectIDs.contains($0) }
        var collected: [Artwork] = []
        var remainingRequestQuota = (museum.id == .met || museum.id == .nmc || museum.id == .shm) ? count : Int.max

        let batchLabel = items.isEmpty ? "首批" : "下一批"
        appendLoadingLog("开始拉取\(batchLabel) \(count) 个展品详情...")

        while ((museum.id == .met || museum.id == .nmc || museum.id == .shm) ? remainingRequestQuota > 0 : collected.count < count), !candidates.isEmpty {
            let chunkSize = (museum.id == .met || museum.id == .nmc || museum.id == .shm)
                ? min(remainingRequestQuota, count)
                : max(count - collected.count, 10)
            let next = Array(candidates.prefix(chunkSize))
            candidates.removeFirst(min(chunkSize, candidates.count))
            loadedObjectIDs.formUnion(next)
            if museum.id == .met || museum.id == .nmc || museum.id == .shm {
                remainingRequestQuota -= next.count
            }

            switch museum.id {
            case .met:
                let artworks = await withTaskGroup(of: Artwork?.self) { group in
                    for idString in next {
                        group.addTask {
                            do {
                                guard let id = Int(idString) else { return nil }
                                let object = try await self.metAPI.fetchObject(objectID: id)
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

                    var output: [Artwork] = []
                    for await result in group {
                        if let artwork = result {
                            output.append(artwork)
                        }
                    }
                    return output
                }

                collected.append(contentsOf: artworks)
            case .nmc:
                let artworks = await withTaskGroup(of: Artwork?.self) { group in
                    for idString in next {
                        group.addTask {
                            do {
                                guard let id = Int(idString) else { return nil }
                                let artwork = try await self.nationalMuseumChinaAPI.fetchExhibit(exhibitID: id)
                                guard artwork.primaryImageSmallURL != nil || artwork.primaryImageURL != nil else {
                                    return nil
                                }
                                return artwork
                            } catch {
                                return nil
                            }
                        }
                    }

                    var output: [Artwork] = []
                    for await result in group {
                        if let artwork = result {
                            output.append(artwork)
                        }
                    }
                    return output
                }

                collected.append(contentsOf: artworks)
            case .shm:
                let batchResults = await withTaskGroup(of: BatchLoadResult.self) { group in
                    for objectCode in next {
                        group.addTask {
                            if let summaryArtwork = await self.shanghaiMuseumAPI.cachedSearchArtwork(objectCode: objectCode) {
                                return .artwork(summaryArtwork)
                            }

                            do {
                                let artwork = try await self.shanghaiMuseumAPI.fetchArtwork(objectCode: objectCode)
                                return .artwork(artwork)
                            } catch {
                                return .failure("code=\(objectCode) 详情获取失败：\(error.localizedDescription)")
                            }
                        }
                    }

                    var output: [BatchLoadResult] = []
                    for await result in group {
                        output.append(result)
                    }
                    return output
                }
                let artworks = batchResults.compactMap { result -> Artwork? in
                    guard case .artwork(let artwork) = result else { return nil }
                    return artwork
                }
                let failures = batchResults.compactMap { result -> String? in
                    guard case .failure(let message) = result else { return nil }
                    return message
                }
                collected.append(contentsOf: artworks)
                if !failures.isEmpty {
                    appendLoadingLog("上海博物馆本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        appendLoadingLog(message)
                    }
                }
            case .tnm:
                let batchResults = await withTaskGroup(of: BatchLoadResult.self) { group in
                    for itemID in next {
                        group.addTask {
                            if let summaryArtwork = await self.japanSearchAPI.cachedSearchArtwork(itemID: itemID) {
                                return .artwork(summaryArtwork)
                            }

                            do {
                                let item = try await self.japanSearchAPI.fetchItem(itemID: itemID)
                                return .artwork(item.toArtwork())
                            } catch {
                                return .failure("itemID=\(itemID) 详情获取失败：\(error.localizedDescription)")
                            }
                        }
                    }
                    var output: [BatchLoadResult] = []
                    for await result in group {
                        output.append(result)
                    }
                    return output
                }
                let artworks = batchResults.compactMap { result -> Artwork? in
                    guard case .artwork(let artwork) = result else { return nil }
                    return artwork
                }
                let failures = batchResults.compactMap { result -> String? in
                    guard case .failure(let message) = result else { return nil }
                    return message
                }
                collected.append(contentsOf: artworks)
                if !failures.isEmpty {
                    appendLoadingLog("东京国立博物馆本批详情失败 \(failures.count) 条。")
                    for message in failures.prefix(3) {
                        appendLoadingLog(message)
                    }
                }
            }
        }

        let hasLocalMoreItems = objectIDPool.contains { !loadedObjectIDs.contains($0) }
        hasMoreItems = hasLocalMoreItems || ((museum.id == .tnm || museum.id == .shm) && hasMoreRemoteItemIDs)

        let orderIndex = Dictionary(
            objectIDPool.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        let feedItems = collected
            .sorted { lhs, rhs in
                (orderIndex[lhs.objectID] ?? .max) < (orderIndex[rhs.objectID] ?? .max)
            }
            .reduce(into: [ArtworkFeedItem]()) { partial, artwork in
                guard !partial.contains(where: { $0.artwork.objectID == artwork.objectID }) else { return }
                partial.append(ArtworkFeedItem(id: artwork.id, artwork: artwork, imageAspectRatio: nil))
            }

        items.append(contentsOf: feedItems)
        appendLoadingLog("\(batchLabel)详情加载完成，新增 \(feedItems.count) 个展品。")
        persistCache()
    }

    private var isRandomOrder: Bool {
        SettingsStore.shared.feedRandomOrder
    }

    private var categorySelectionKey: String {
        museum.id.feedCategoryStorageValue(for: selectedCategories)
    }

    private var selectedCategoriesLogLabel: String {
        isAllCategoriesSelected ? "全部" : selectedCategories.map(\.displayName).joined(separator: "、")
    }

    private var selectedMetDepartmentIDs: [Int]? {
        guard !isAllCategoriesSelected else { return nil }
        return selectedCategories.compactMap(\.metDepartmentID)
    }

    private var selectedJapanSearchTypeCodes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return selectedCategories.compactMap(\.japanSearchTypeCode)
    }

    private var selectedNationalMuseumChinaCategoryIDs: [Int]? {
        guard !isAllCategoriesSelected else { return nil }
        return selectedCategories.compactMap(\.nationalMuseumChinaCategoryID)
    }

    private var selectedShanghaiMuseumSubtypes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return selectedCategories.compactMap(\.shanghaiMuseumSubtype)
    }

    private func updateSelectedCategories(_ categories: [MuseumCategory]) async {
        let normalized = museum.id.normalizedFeedCategories(categories)
        guard normalized.map(\.id) != selectedCategories.map(\.id) else { return }

        selectedCategories = normalized
        SettingsStore.shared.saveFeedCategories(normalized, for: museum.id)
        await reload()
    }

    private func restoreCachedFeedIfAvailable() -> Bool {
        guard let snapshot = ArtworkFeedCache.shared.snapshot(
            for: museum.id,
            randomOrder: isRandomOrder,
            categorySelectionKey: categorySelectionKey
        ) else {
            return false
        }
        guard !snapshot.items.isEmpty else {
            return false
        }

        items = snapshot.items
        objectIDPool = Self.stableUniqueStrings(snapshot.objectIDPool)
        loadedObjectIDs = snapshot.loadedObjectIDs
        hasMoreItems = snapshot.hasMoreItems
        hasMoreRemoteItemIDs = snapshot.hasMoreRemoteItemIDs
        isLoadingMore = false
        state = .loaded
        return true
    }

    private func persistCache() {
        guard !items.isEmpty else { return }
        ArtworkFeedCache.shared.store(
            museumID: museum.id,
            randomOrder: isRandomOrder,
            categorySelectionKey: categorySelectionKey,
            items: items,
            objectIDPool: objectIDPool,
            loadedObjectIDs: loadedObjectIDs,
            hasMoreItems: hasMoreItems,
            hasMoreRemoteItemIDs: hasMoreRemoteItemIDs
        )
    }

    private func appendLoadingLog(_ message: String) {
        let timestamp = Self.logTimeFormatter.string(from: Date())
        loadingLogs.append("[\(timestamp)] \(message)")
        let source = "\(museum.displayName) 展品流"
        Task {
            await RequestLogger.shared.logEvent(source: source, summary: message)
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func ensureTokyoPoolIfNeeded(minimumRemainingCount: Int) async throws {
        guard museum.id == .tnm else { return }
        let remainingCount = objectIDPool.filter { !loadedObjectIDs.contains($0) }.count
        guard remainingCount < minimumRemainingCount, hasMoreRemoteItemIDs else { return }

        let nextTargetCount = max(objectIDPool.count, loadedObjectIDs.count + minimumRemainingCount)
        try await ensureTokyoPool(targetCount: nextTargetCount, reason: "继续浏览")
    }

    private func ensureTokyoPool(targetCount: Int, reason: String) async throws {
        let mergedResult: JapanSearchAPI.SearchPoolSnapshot
        if let typeCodes = selectedJapanSearchTypeCodes {
            var mergedItemIDs: [String] = []
            var hasMoreRemoteItems = false

            for (category, typeCode) in zip(selectedCategories, typeCodes) {
                let categoryResult = try await japanSearchAPI.searchItemIDs(
                    preferHasImages: true,
                    categoryTypeCode: typeCode,
                    minimumCount: targetCount
                ) { [weak self] message in
                    await self?.appendLoadingLog("\(category.displayName)：\(message)")
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
                minimumCount: targetCount
            ) { [weak self] message in
                await self?.appendLoadingLog(message)
            }
        }

        appendLoadingLog("\(reason)时按\(isRandomOrder ? "随机" : "ID 顺序")模式整理 itemIDs，类别：\(selectedCategoriesLogLabel)。")
        let uniqueIDs = Self.stableUniqueStrings(mergedResult.itemIDs)
        if uniqueIDs.count != mergedResult.itemIDs.count {
            appendLoadingLog("东京国立博物馆搜索结果存在重复 itemID，已去重 \(mergedResult.itemIDs.count - uniqueIDs.count) 条。")
        }

        if objectIDPool.isEmpty {
            objectIDPool = isRandomOrder ? Array(uniqueIDs.shuffled()) : uniqueIDs.sorted()
        } else if isRandomOrder {
            let existing = Set(objectIDPool)
            let appended = uniqueIDs.filter { !existing.contains($0) }.shuffled()
            objectIDPool.append(contentsOf: appended)
        } else {
            objectIDPool = uniqueIDs.sorted()
        }

        hasMoreRemoteItemIDs = mergedResult.hasMoreRemoteItems
        appendLoadingLog("itemIDs 已就绪，当前缓存 \(objectIDPool.count) 条，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多远端数据")。")
    }

    private func ensureShanghaiPoolIfNeeded(minimumRemainingCount: Int) async throws {
        guard museum.id == .shm else { return }
        let remainingCount = objectIDPool.filter { !loadedObjectIDs.contains($0) }.count
        guard remainingCount < minimumRemainingCount, hasMoreRemoteItemIDs else { return }

        let nextTargetCount = max(objectIDPool.count, loadedObjectIDs.count + minimumRemainingCount)
        try await ensureShanghaiPool(targetCount: nextTargetCount, reason: "继续浏览")
    }

    private func ensureShanghaiPool(targetCount: Int, reason: String) async throws {
        let result = try await shanghaiMuseumAPI.searchArtworkCodes(
            subtypes: selectedShanghaiMuseumSubtypes,
            minimumCount: targetCount
        ) { [weak self] message in
            await self?.appendLoadingLog(message)
        }

        appendLoadingLog("\(reason)时按\(isRandomOrder ? "随机" : "编码顺序")模式整理上海博物馆展品，类别：\(selectedCategoriesLogLabel)。")
        let uniqueIDs = Self.stableUniqueStrings(result.artworkCodes)
        if uniqueIDs.count != result.artworkCodes.count {
            appendLoadingLog("上海博物馆搜索结果存在重复编码，已去重 \(result.artworkCodes.count - uniqueIDs.count) 条。")
        }

        if objectIDPool.isEmpty {
            objectIDPool = isRandomOrder ? Array(uniqueIDs.shuffled()) : uniqueIDs.sorted()
        } else if isRandomOrder {
            let existing = Set(objectIDPool)
            let appended = uniqueIDs.filter { !existing.contains($0) }.shuffled()
            objectIDPool.append(contentsOf: appended)
        } else {
            objectIDPool = uniqueIDs.sorted()
        }

        hasMoreRemoteItemIDs = result.hasMoreRemoteItems
        appendLoadingLog("上海博物馆展品编码已就绪，当前缓存 \(objectIDPool.count) 条，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多远端数据")。")
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
