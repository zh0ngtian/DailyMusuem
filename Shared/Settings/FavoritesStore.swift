import Combine
import Foundation

struct FavoriteArtworkSnapshot: Identifiable, Hashable, Codable {
    let museumID: MuseumID
    let objectID: String
    let favoritedAt: Date
    let artwork: Artwork
    let imageAspectRatio: Double?

    var id: String {
        Self.makeID(museumID: museumID, objectID: objectID)
    }

    var reference: ArtworkReference {
        ArtworkReference(
            museumID: museumID,
            objectID: objectID,
            imageAspectRatio: imageAspectRatio
        )
    }

    static func makeID(museumID: MuseumID, objectID: String) -> String {
        "\(museumID.rawValue)::\(objectID)"
    }
}

struct FavoriteSection: Identifiable, Hashable {
    let museumID: MuseumID
    let items: [FavoriteArtworkSnapshot]

    var id: MuseumID { museumID }
    var title: String { museumID.displayName }
}

final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [FavoriteArtworkSnapshot]

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard) {
        self.defaults = defaults
        favorites = []
        favorites = loadFavorites()
    }

    func isFavorite(museumID: MuseumID, objectID: String) -> Bool {
        favorites.contains { $0.museumID == museumID && $0.objectID == objectID }
    }

    func toggleFavorite(
        artwork: Artwork,
        favoritedAt: Date = .now,
        imageAspectRatio: Double? = nil
    ) {
        setFavorite(
            !isFavorite(museumID: artwork.museumID, objectID: artwork.objectID),
            artwork: artwork,
            favoritedAt: favoritedAt,
            imageAspectRatio: imageAspectRatio
        )
    }

    func setFavorite(
        _ isFavorite: Bool,
        artwork: Artwork,
        favoritedAt: Date = .now,
        imageAspectRatio: Double? = nil
    ) {
        if isFavorite {
            let snapshot = FavoriteArtworkSnapshot(
                museumID: artwork.museumID,
                objectID: artwork.objectID,
                favoritedAt: favoritedAt,
                artwork: artwork,
                imageAspectRatio: imageAspectRatio
            )

            favorites = normalizedFavorites([snapshot] + favorites)
            persistFavorites()
            return
        }

        removeFavorite(museumID: artwork.museumID, objectID: artwork.objectID)
    }

    func removeFavorite(museumID: MuseumID, objectID: String) {
        favorites.removeAll { $0.museumID == museumID && $0.objectID == objectID }
        persistFavorites()
    }

    func removeFavorite(_ snapshot: FavoriteArtworkSnapshot) {
        removeFavorite(museumID: snapshot.museumID, objectID: snapshot.objectID)
    }

    func reloadFromDefaults() {
        favorites = loadFavorites()
    }

    func groupedFavorites(orderedMuseumIDs: [MuseumID]) -> [FavoriteSection] {
        let grouped = Dictionary(grouping: favorites, by: \.museumID)
        let metadataMuseumIDs = MuseumMetadataStore.cachedSnapshot()?.museums
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map(\.id) ?? []
        let favoriteMuseumIDs = favorites.map(\.museumID)
        var seen: Set<MuseumID> = []
        let museumOrder = (orderedMuseumIDs + metadataMuseumIDs + favoriteMuseumIDs).filter { seen.insert($0).inserted }

        return museumOrder.compactMap { museumID in
            guard let items = grouped[museumID], !items.isEmpty else {
                return nil
            }

            return FavoriteSection(
                museumID: museumID,
                items: items.sorted { $0.favoritedAt > $1.favoritedAt }
            )
        }
    }

    private func loadFavorites() -> [FavoriteArtworkSnapshot] {
        guard let data = defaults.data(forKey: SettingsKeys.favoritesArtworks) else {
            return []
        }

        guard let decoded = try? decoder.decode([FavoriteArtworkSnapshot].self, from: data) else {
            return []
        }

        return normalizedFavorites(decoded)
    }

    private func persistFavorites() {
        guard let data = try? encoder.encode(favorites) else {
            return
        }

        defaults.set(data, forKey: SettingsKeys.favoritesArtworks)
        defaults.synchronize()
    }

    private func normalizedFavorites(_ snapshots: [FavoriteArtworkSnapshot]) -> [FavoriteArtworkSnapshot] {
        var deduplicated: [String: FavoriteArtworkSnapshot] = [:]

        for snapshot in snapshots.sorted(by: { $0.favoritedAt > $1.favoritedAt }) {
            deduplicated[snapshot.id] = deduplicated[snapshot.id] ?? snapshot
        }

        return deduplicated.values.sorted { $0.favoritedAt > $1.favoritedAt }
    }
}
