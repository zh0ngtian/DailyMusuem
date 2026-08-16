import Foundation

actor MuseumMetadataStore {
    static let shared = MuseumMetadataStore()

    private static let snapshotKey = "museum.metadata.snapshot.v1"

    private let defaults: UserDefaults
    private let refresher: @Sendable (MuseumRequestCachePolicy) async throws -> MuseumMetadataSnapshot
    private let encoder = JSONEncoder()
    private var inMemorySnapshot: MuseumMetadataSnapshot?

    init(
        defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard,
        refresher: @escaping @Sendable (MuseumRequestCachePolicy) async throws -> MuseumMetadataSnapshot = { cachePolicy in
            try await MuseumBackendClient.shared.museumMetadata(cachePolicy: cachePolicy)
        }
    ) {
        self.defaults = defaults
        self.refresher = refresher
    }

    func refresh(cachePolicy: MuseumRequestCachePolicy = .useCaches) async throws -> [MuseumMetadata] {
        let snapshot = try await refresher(cachePolicy)
        inMemorySnapshot = snapshot
        persist(snapshot)
        return snapshot.museums
    }

    func cachedMuseums() -> [MuseumMetadata] {
        cachedSnapshot()?.museums ?? []
    }

    func museum(id: MuseumIdentifier) -> MuseumMetadata? {
        cachedMuseums().first { $0.id == id }
    }

    func categories(museumID: MuseumIdentifier, sourceKey: String?) -> [MuseumCategoryMetadata] {
        guard let museum = museum(id: museumID) else {
            return []
        }
        let effectiveSourceKey = sourceKey ?? museum.defaultSourceKey
        return museum.categories.filter { $0.sourceKey == effectiveSourceKey }
    }

    func waterfallImageFetchPolicy(museumID: MuseumIdentifier) -> WaterfallImageFetchPolicy {
        museum(id: museumID)?.waterfallImageFetchPolicy ?? WaterfallImageFetchPolicy(qps: nil)
    }

    func cachedSnapshot() -> MuseumMetadataSnapshot? {
        if let inMemorySnapshot {
            return inMemorySnapshot
        }
        guard let snapshot = Self.cachedSnapshot(defaults: defaults) else {
            return nil
        }
        inMemorySnapshot = snapshot
        return snapshot
    }

    nonisolated static func cachedSnapshot(
        defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
    ) -> MuseumMetadataSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey),
              let cached = try? JSONDecoder().decode(PersistedMuseumMetadataSnapshot.self, from: data) else {
            return nil
        }
        return MuseumMetadataSnapshot(
            dataVersion: cached.dataVersion,
            museums: cached.museums
        )
    }

    nonisolated static func cachedMuseum(
        id: MuseumIdentifier,
        defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
    ) -> MuseumMetadata? {
        cachedSnapshot(defaults: defaults)?.museums.first { $0.id == id }
    }

    nonisolated static func cachedSourceMetadata(
        museumID: MuseumIdentifier,
        sourceKey: String?,
        defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
    ) -> MuseumSourceMetadata? {
        guard let metadata = cachedMuseum(id: museumID, defaults: defaults) else {
            return nil
        }
        let effectiveSourceKey = sourceKey ?? metadata.defaultSourceKey
        return metadata.sources.first { $0.sourceKey == effectiveSourceKey }
            ?? metadata.sources.first { $0.sourceKey == metadata.defaultSourceKey }
    }

    private func persist(_ snapshot: MuseumMetadataSnapshot) {
        let persisted = PersistedMuseumMetadataSnapshot(
            dataVersion: snapshot.dataVersion,
            updatedAt: Date(),
            museums: snapshot.museums
        )
        guard let data = try? encoder.encode(persisted) else {
            return
        }
        defaults.set(data, forKey: Self.snapshotKey)
        defaults.synchronize()
    }
}

private struct PersistedMuseumMetadataSnapshot: Codable {
    let dataVersion: String
    let updatedAt: Date
    let museums: [MuseumMetadata]
}

struct MuseumMetadataLoadGate {
    private(set) var isLoading = false
    private var shouldRetryWhenCurrentLoadFinishes = false

    mutating func beginLoad() -> Bool {
        guard !isLoading else {
            return false
        }
        isLoading = true
        return true
    }

    mutating func requestForegroundRetry(hasVisibleMetadata: Bool) -> Bool {
        guard !hasVisibleMetadata else {
            shouldRetryWhenCurrentLoadFinishes = false
            return false
        }
        guard isLoading else {
            return true
        }
        shouldRetryWhenCurrentLoadFinishes = true
        return false
    }

    mutating func finishLoad(hasVisibleMetadata: Bool) -> Bool {
        isLoading = false
        guard !hasVisibleMetadata, shouldRetryWhenCurrentLoadFinishes else {
            shouldRetryWhenCurrentLoadFinishes = false
            return false
        }
        shouldRetryWhenCurrentLoadFinishes = false
        return true
    }
}
