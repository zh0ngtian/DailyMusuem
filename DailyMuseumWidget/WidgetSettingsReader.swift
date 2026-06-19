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
        let nextCursor: String?
        let seed: Int
        let dataVersion: String?
        let hasRequestedBackendPage: Bool

        init(
            objectIDPool: [String],
            loadedObjectIDs: Set<String>,
            hasMoreRemoteItemIDs: Bool,
            nextCursor: String? = nil,
            seed: Int = 0,
            dataVersion: String? = nil,
            hasRequestedBackendPage: Bool = false
        ) {
            self.objectIDPool = objectIDPool
            self.loadedObjectIDs = loadedObjectIDs
            self.hasMoreRemoteItemIDs = hasMoreRemoteItemIDs
            self.nextCursor = nextCursor
            self.seed = seed
            self.dataVersion = dataVersion
            self.hasRequestedBackendPage = hasRequestedBackendPage
        }
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
    private let backendClient: MuseumBackendClient

    private var objectIDPool: [String] = []
    private var loadedObjectIDs: Set<String> = []
    private var hasMoreRemoteItemIDs: Bool
    private var nextCursor: String?
    private var seed: Int
    private var dataVersion: String?
    private var hasRequestedBackendPage: Bool

    init(
        museumID: MuseumID,
        categories: [MuseumCategory],
        randomOrder: Bool,
        metShowsOnlyOnViewArtworks: Bool = false,
        cachePolicy: MuseumRequestCachePolicy,
        onLog: (@Sendable (String) async -> Void)? = nil,
        backendClient: MuseumBackendClient = .shared
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
        self.backendClient = backendClient
        hasMoreRemoteItemIDs = true
        nextCursor = nil
        seed = Int.random(in: 1...Int(Int32.max))
        dataVersion = nil
        hasRequestedBackendPage = false
    }

    func restore(from snapshot: StateSnapshot) {
        objectIDPool = Self.stableUniqueStrings(snapshot.objectIDPool)
        loadedObjectIDs = snapshot.loadedObjectIDs
        hasMoreRemoteItemIDs = snapshot.hasMoreRemoteItemIDs
        nextCursor = snapshot.nextCursor
        if snapshot.seed > 0 {
            seed = snapshot.seed
        }
        dataVersion = snapshot.dataVersion
        if let dataVersion = snapshot.dataVersion {
            MuseumBackendDataVersionCache.update(dataVersion)
        }
        hasRequestedBackendPage = snapshot.hasRequestedBackendPage || !snapshot.objectIDPool.isEmpty || snapshot.nextCursor != nil || snapshot.dataVersion != nil
    }

    func snapshotState() -> StateSnapshot {
        StateSnapshot(
            objectIDPool: objectIDPool,
            loadedObjectIDs: loadedObjectIDs,
            hasMoreRemoteItemIDs: hasMoreRemoteItemIDs,
            nextCursor: nextCursor,
            seed: seed,
            dataVersion: dataVersion,
            hasRequestedBackendPage: hasRequestedBackendPage
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
        guard hasMoreRemoteItemIDs || !hasRequestedBackendPage else {
            return []
        }

        let batchLabel = loadedObjectIDs.isEmpty ? "首批" : "下一批"
        await log("通过服务端请求\(batchLabel) \(count) 个展品，类别：\(selectedCategoriesLogLabel)。")

        let page = try await backendClient.artworks(
            query: backendListQuery(limit: count)
        )
        hasRequestedBackendPage = true
        dataVersion = page.dataVersion
        MuseumBackendDataVersionCache.update(page.dataVersion)
        nextCursor = page.nextCursor
        hasMoreRemoteItemIDs = page.hasMore

        let deduplicated = deduplicatedBackendArtworks(page.items)
        objectIDPool.append(contentsOf: deduplicated.map(\.objectID))
        loadedObjectIDs.formUnion(deduplicated.map(\.objectID))

        for artwork in deduplicated {
            try Task.checkCancellation()
            await onArtworkReady?(artwork)
        }

        await log("\(batchLabel)服务端加载完成，新增 \(deduplicated.count) 个展品，\(hasMoreRemoteItemIDs ? "后续可继续拉取" : "已无更多后端数据")。")
        return deduplicated
    }

    private func backendListQuery(limit: Int) -> ArtworkListQuery {
        ArtworkListQuery(
            museumID: museumID,
            source: backendSource,
            categoryIDs: backendCategoryIDs,
            limit: limit,
            cursor: nextCursor,
            order: randomOrder ? .random : .stable,
            seed: randomOrder ? seed : nil,
            onlyOnView: metShowsOnlyOnViewArtworks,
            hasImage: true,
            cachePolicy: cachePolicy
        )
    }

    private var backendSource: String? {
        guard museumID == .nnm else { return nil }
        return naraMuseumDataSource.rawValue
    }

    private var backendCategoryIDs: [String] {
        isAllCategoriesSelected ? [] : categories.map(\.id)
    }

    private func deduplicatedBackendArtworks(_ artworks: [Artwork]) -> [Artwork] {
        var seen = loadedObjectIDs
        var result: [Artwork] = []
        result.reserveCapacity(artworks.count)

        for artwork in artworks where seen.insert(artwork.objectID).inserted {
            result.append(artwork)
        }
        return result
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

    private var naraMuseumDataSource: NaraMuseumDataSource {
        Self.inferredNaraDataSource(museumID: museumID, categories: categories)
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

    private static func inferredNaraDataSource(museumID: MuseumID, categories: [MuseumCategory]) -> NaraMuseumDataSource {
        guard museumID == .nnm else { return .colbase }
        if categories.contains(where: { $0.kind == .naraMuseumOfficialDepartment }) {
            return .official
        }
        return .colbase
    }
}
