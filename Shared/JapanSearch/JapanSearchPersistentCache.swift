import Foundation

actor JapanSearchPersistentCache {
    static let shared = JapanSearchPersistentCache()

    struct SearchSnapshot {
        let itemIDs: [String]
        let summaryArtworks: [Artwork]
        let nextFrom: Int
        let hasMore: Bool
        let usedContributorFilter: Bool
    }

    private struct CachedSearchSnapshot: Codable {
        let itemIDs: [String]
        let summaryArtworks: [Artwork]
        let nextFrom: Int
        let hasMore: Bool
        let usedContributorFilter: Bool
        let createdAt: Date
    }

    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL
            .appendingPathComponent("DailyMuseum", isDirectory: true)
            .appendingPathComponent("JapanSearch", isDirectory: true)
    }

    func searchSnapshot(forKey key: String) -> SearchSnapshot? {
        let fileURL = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(CachedSearchSnapshot.self, from: data) else {
            return nil
        }
        return SearchSnapshot(
            itemIDs: cached.itemIDs,
            summaryArtworks: cached.summaryArtworks,
            nextFrom: cached.nextFrom,
            hasMore: cached.hasMore,
            usedContributorFilter: cached.usedContributorFilter
        )
    }

    func setSearchSnapshot(
        itemIDs: [String],
        summaryArtworks: [Artwork],
        nextFrom: Int,
        hasMore: Bool,
        usedContributorFilter: Bool,
        forKey key: String
    ) {
        let fileURL = fileURL(forKey: key)
        let cached = CachedSearchSnapshot(
            itemIDs: itemIDs,
            summaryArtworks: summaryArtworks,
            nextFrom: nextFrom,
            hasMore: hasMore,
            usedContributorFilter: usedContributorFilter,
            createdAt: Date()
        )

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore cache write failures and keep network path as fallback.
        }
    }

    func removeSearchSnapshot(forKey key: String) {
        let fileURL = fileURL(forKey: key)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func fileURL(forKey key: String) -> URL {
        let sanitized = key.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return directoryURL.appendingPathComponent(String(sanitized) + ".json")
    }
}
