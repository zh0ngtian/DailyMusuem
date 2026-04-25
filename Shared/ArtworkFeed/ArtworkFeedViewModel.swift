import Foundation
import SwiftUI

@MainActor
protocol ArtworkFeedSettingsProviding: AnyObject {
    func feedCategories(for museumID: MuseumID) -> [MuseumCategory]
    func saveFeedCategories(_ categories: [MuseumCategory], for museumID: MuseumID)
}

extension SettingsStore: ArtworkFeedSettingsProviding {}

@MainActor
protocol ArtworkFeedCaching: AnyObject {
    func snapshot(for museumID: MuseumID, randomOrder: Bool, categorySelectionKey: String) -> ArtworkFeedCache.Snapshot?
    func store(
        museumID: MuseumID,
        randomOrder: Bool,
        categorySelectionKey: String,
        items: [ArtworkFeedItem],
        objectIDPool: [String],
        loadedObjectIDs: Set<String>,
        hasMoreItems: Bool,
        hasMoreRemoteItemIDs: Bool
    )
    func clear(museumID: MuseumID, randomOrder: Bool, categorySelectionKey: String)
}

extension ArtworkFeedCache: ArtworkFeedCaching {}

@MainActor
final class ArtworkFeedViewModel: ObservableObject {
    private enum Constants {
        static let initialBatchSize = 10
        static let loadMoreBatchSize = 10
    }

    private enum LoadingPresentation {
        case fullScreen
        case inlineInitialBatch
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
    @Published private(set) var showsInlineInitialLoading = false
    @Published private(set) var preservedItemsDuringRefresh: [ArtworkFeedItem] = []

    private let museum: Museum
    private let settings: ArtworkFeedSettingsProviding
    private let cache: ArtworkFeedCaching
    private let metAPI: MetMuseumAPI
    private let japanSearchAPI: JapanSearchAPI
    private let nationalMuseumChinaAPI: NationalMuseumChinaAPI
    private let shanghaiMuseumAPI: ShanghaiMuseumAPI

    private var batchLoader: ArtworkBatchLoader?
    private var objectIDPool: [String] = []
    private var loadedObjectIDs: Set<String> = []
    private var hasMoreRemoteItemIDs = false

    init(
        museum: Museum,
        settings: ArtworkFeedSettingsProviding? = nil,
        cache: ArtworkFeedCaching? = nil,
        metAPI: MetMuseumAPI = MetMuseumAPI(),
        japanSearchAPI: JapanSearchAPI = JapanSearchAPI(),
        nationalMuseumChinaAPI: NationalMuseumChinaAPI = NationalMuseumChinaAPI(),
        shanghaiMuseumAPI: ShanghaiMuseumAPI = ShanghaiMuseumAPI()
    ) {
        self.museum = museum
        self.settings = settings ?? SettingsStore.shared
        self.cache = cache ?? ArtworkFeedCache.shared
        self.metAPI = metAPI
        self.japanSearchAPI = japanSearchAPI
        self.nationalMuseumChinaAPI = nationalMuseumChinaAPI
        self.shanghaiMuseumAPI = shanghaiMuseumAPI
        self.selectedCategories = self.settings.feedCategories(for: museum.id)
    }

    var availableCategories: [MuseumCategory] {
        museum.id.selectableFeedCategories
    }

    var displayItems: [ArtworkFeedItem] {
        if showsInlineInitialLoading, !preservedItemsDuringRefresh.isEmpty {
            return preservedItemsDuringRefresh
        }
        return items
    }

    func loadInitialIfNeeded() async {
        guard state == .idle else { return }
        batchLoader = makeBatchLoader()
        if await restoreCachedFeedIfAvailable() { return }
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
        await performReload(presentation: .fullScreen)
    }

    func refresh() async {
        await performReload(presentation: .inlineInitialBatch)
    }

    private func performReload(presentation: LoadingPresentation) async {
        cache.clear(
            museumID: museum.id,
            randomOrder: isRandomOrder,
            categorySelectionKey: categorySelectionKey
        )

        if museum.id == .tnm || museum.id == .nnm {
            if let typeCodes = selectedJapanSearchTypeCodes {
                for typeCode in typeCodes {
                    await japanSearchAPI.resetSearchCache(
                        museumID: museum.id,
                        preferHasImages: true,
                        categoryTypeCode: typeCode
                    )
                }
            } else {
                await japanSearchAPI.resetSearchCache(
                    museumID: museum.id,
                    preferHasImages: true,
                    categoryTypeCode: nil
                )
            }
        } else if museum.id == .shm {
            await shanghaiMuseumAPI.resetSearchCache(subtypes: selectedShanghaiMuseumSubtypes)
        }

        showsInlineInitialLoading = presentation == .inlineInitialBatch
        preservedItemsDuringRefresh = presentation == .inlineInitialBatch ? items : []
        defer {
            showsInlineInitialLoading = false
            preservedItemsDuringRefresh = []
        }

        state = .loading
        items = []
        objectIDPool = []
        loadedObjectIDs = []
        hasMoreItems = true
        hasMoreRemoteItemIDs = museum.id == .tnm || museum.id == .nnm || museum.id == .shm
        isLoadingMore = false
        loadingLogs = []
        appendLoadingLog("开始加载 \(museum.displayName) 展品，当前类别：\(selectedCategoriesLogLabel)。")

        batchLoader = makeBatchLoader()

        do {
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
        let clamped = max(0.05, Double(aspectRatio))

        if let index = items.firstIndex(where: { $0.id == id }) {
            if items[index].imageAspectRatio != clamped {
                items[index].imageAspectRatio = clamped
                persistCache()
            }
            return
        }

        guard let index = preservedItemsDuringRefresh.firstIndex(where: { $0.id == id }) else { return }
        if preservedItemsDuringRefresh[index].imageAspectRatio != clamped {
            preservedItemsDuringRefresh[index].imageAspectRatio = clamped
        }
    }

    private func loadNextBatch(count: Int) async throws {
        guard let batchLoader else {
            return
        }

        let progressRelay = ArtworkFeedProgressRelay(owner: self)
        _ = try await batchLoader.nextBatch(count: count) { artwork in
            await progressRelay.publish(artwork)
        }
        await syncLoaderState()
        persistCache()
    }

    fileprivate func publishResolvedArtwork(_ artwork: Artwork) async {
        if objectIDPool.isEmpty || !objectIDPool.contains(artwork.objectID) {
            await syncLoaderState()
        }

        upsertFeedItem(for: artwork)
        persistCache()
    }

    private func upsertFeedItem(for artwork: Artwork) {
        let existingIndex = items.firstIndex(where: { $0.artwork.objectID == artwork.objectID })
        let preservedAspectRatio = existingIndex.flatMap { items[$0].imageAspectRatio }
        let item = ArtworkFeedItem(
            id: artwork.id,
            artwork: artwork,
            imageAspectRatio: preservedAspectRatio
        )

        if let existingIndex {
            items[existingIndex] = item
        } else {
            items.append(item)
        }

        let orderIndex = Dictionary(
            objectIDPool.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        items.sort { lhs, rhs in
            let lhsIndex = orderIndex[lhs.artwork.objectID] ?? .max
            let rhsIndex = orderIndex[rhs.artwork.objectID] ?? .max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.artwork.objectID < rhs.artwork.objectID
        }
    }

    private func syncLoaderState() async {
        guard let batchLoader else {
            objectIDPool = []
            loadedObjectIDs = []
            hasMoreRemoteItemIDs = false
            hasMoreItems = false
            return
        }

        let snapshot = await batchLoader.snapshotState()
        objectIDPool = snapshot.objectIDPool
        loadedObjectIDs = snapshot.loadedObjectIDs
        hasMoreRemoteItemIDs = snapshot.hasMoreRemoteItemIDs
        hasMoreItems = snapshot.hasMoreRemoteItemIDs || snapshot.objectIDPool.contains { !snapshot.loadedObjectIDs.contains($0) }
    }

    private func makeBatchLoader() -> ArtworkBatchLoader {
        let logRelay = ArtworkFeedLogRelay(owner: self)
        return ArtworkBatchLoader(
            museumID: museum.id,
            categories: selectedCategories,
            randomOrder: isRandomOrder,
            cachePolicy: .useCaches,
            onLog: { message in
                await logRelay.append(message)
            },
            metAPI: metAPI,
            japanSearchAPI: japanSearchAPI,
            nationalMuseumChinaAPI: nationalMuseumChinaAPI,
            shanghaiMuseumAPI: shanghaiMuseumAPI
        )
    }

    private var isRandomOrder: Bool {
        true
    }

    private var categorySelectionKey: String {
        museum.id.feedCategoryStorageValue(for: selectedCategories)
    }

    private var selectedCategoriesLogLabel: String {
        isAllCategoriesSelected ? "全部" : selectedCategories.map(\.displayName).joined(separator: "、")
    }

    private var selectedJapanSearchTypeCodes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return selectedCategories.compactMap(\.japanSearchTypeCode)
    }

    private var selectedShanghaiMuseumSubtypes: [String]? {
        guard !isAllCategoriesSelected else { return nil }
        return selectedCategories.compactMap(\.shanghaiMuseumSubtype)
    }

    private func updateSelectedCategories(_ categories: [MuseumCategory]) async {
        let normalized = museum.id.normalizedFeedCategories(categories)
        guard normalized.map(\.id) != selectedCategories.map(\.id) else { return }

        selectedCategories = normalized
        settings.saveFeedCategories(normalized, for: museum.id)
        await reload()
    }

    private func restoreCachedFeedIfAvailable() async -> Bool {
        guard let snapshot = cache.snapshot(
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
        objectIDPool = snapshot.objectIDPool
        loadedObjectIDs = snapshot.loadedObjectIDs
        hasMoreItems = snapshot.hasMoreItems
        hasMoreRemoteItemIDs = snapshot.hasMoreRemoteItemIDs
        isLoadingMore = false
        state = .loaded

        batchLoader = makeBatchLoader()
        await batchLoader?.restore(
            from: ArtworkBatchLoader.StateSnapshot(
                objectIDPool: snapshot.objectIDPool,
                loadedObjectIDs: snapshot.loadedObjectIDs,
                hasMoreRemoteItemIDs: snapshot.hasMoreRemoteItemIDs
            )
        )
        return true
    }

    private func persistCache() {
        guard !items.isEmpty else { return }
        cache.store(
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

    fileprivate func appendLoadingLog(_ message: String) {
        let timestamp = LogTimestampFormatter.feedLogTimestamp(from: Date())
        loadingLogs.append("[\(timestamp)] \(message)")
        let source = "\(museum.displayName) 展品流"
        Task {
            await RequestLogger.shared.logEvent(source: source, summary: message)
        }
    }
}

@MainActor
private final class ArtworkFeedLogRelay: @unchecked Sendable {
    weak var owner: ArtworkFeedViewModel?

    init(owner: ArtworkFeedViewModel) {
        self.owner = owner
    }

    func append(_ message: String) {
        owner?.appendLoadingLog(message)
    }
}

@MainActor
private final class ArtworkFeedProgressRelay: @unchecked Sendable {
    weak var owner: ArtworkFeedViewModel?

    init(owner: ArtworkFeedViewModel) {
        self.owner = owner
    }

    func publish(_ artwork: Artwork) async {
        await owner?.publishResolvedArtwork(artwork)
    }
}
