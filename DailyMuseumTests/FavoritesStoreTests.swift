import XCTest

final class FavoritesStoreTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "FavoritesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaults = nil
        defaultsSuiteName = nil
        try super.tearDownWithError()
    }

    func testToggleFavoritePersistsAcrossReload() throws {
        let store = FavoritesStore(defaults: defaults)
        let artwork = makeArtwork(museumID: .met, objectID: "100", title: "睡莲")

        store.toggleFavorite(
            artwork: artwork,
            favoritedAt: Date(timeIntervalSince1970: 100),
            imageAspectRatio: 1.5
        )

        XCTAssertTrue(store.isFavorite(museumID: .met, objectID: "100"))
        XCTAssertEqual(store.favorites.count, 1)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.count, 1)
        XCTAssertEqual(reloaded.favorites.first?.artwork.title, "睡莲")
        XCTAssertEqual(reloaded.favorites.first?.imageAspectRatio, 1.5)
    }

    func testRemoveFavoriteUpdatesPersistedState() {
        let store = FavoritesStore(defaults: defaults)
        let artwork = makeArtwork(museumID: .tnm, objectID: "200", title: "太刀")

        store.toggleFavorite(artwork: artwork, favoritedAt: Date(timeIntervalSince1970: 200))
        store.removeFavorite(museumID: .tnm, objectID: "200")

        XCTAssertFalse(store.isFavorite(museumID: .tnm, objectID: "200"))
        XCTAssertTrue(store.favorites.isEmpty)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertTrue(reloaded.favorites.isEmpty)
    }

    func testLoadingFavoritesDeduplicatesSameArtworkKeyKeepingNewestSnapshot() throws {
        let older = FavoriteArtworkSnapshot(
            museumID: .met,
            objectID: "300",
            favoritedAt: Date(timeIntervalSince1970: 300),
            artwork: makeArtwork(museumID: .met, objectID: "300", title: "旧标题"),
            imageAspectRatio: 0.8
        )
        let newer = FavoriteArtworkSnapshot(
            museumID: .met,
            objectID: "300",
            favoritedAt: Date(timeIntervalSince1970: 400),
            artwork: makeArtwork(museumID: .met, objectID: "300", title: "新标题"),
            imageAspectRatio: 1.2
        )

        let data = try JSONEncoder().encode([older, newer])
        defaults.set(data, forKey: SettingsKeys.favoritesArtworks)

        let store = FavoritesStore(defaults: defaults)

        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(store.favorites.first?.artwork.title, "新标题")
        XCTAssertEqual(store.favorites.first?.imageAspectRatio, 1.2)
    }

    func testGroupedFavoritesFollowMuseumOrderAndSortNewestFirstWithinSection() {
        let store = FavoritesStore(defaults: defaults)

        store.toggleFavorite(
            artwork: makeArtwork(museumID: .met, objectID: "1", title: "A"),
            favoritedAt: Date(timeIntervalSince1970: 100)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: .tnm, objectID: "2", title: "B"),
            favoritedAt: Date(timeIntervalSince1970: 200)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: .met, objectID: "3", title: "C"),
            favoritedAt: Date(timeIntervalSince1970: 300)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: .shm, objectID: "4", title: "D"),
            favoritedAt: Date(timeIntervalSince1970: 400)
        )

        let sections = store.groupedFavorites(orderedMuseumIDs: [.shm, .met, .tnm])

        XCTAssertEqual(sections.map(\.museumID), [.shm, .met, .tnm])
        XCTAssertEqual(sections[0].items.map(\.objectID), ["4"])
        XCTAssertEqual(sections[1].items.map(\.objectID), ["3", "1"])
        XCTAssertEqual(sections[2].items.map(\.objectID), ["2"])
    }

    private func makeArtwork(museumID: MuseumID, objectID: String, title: String) -> Artwork {
        Artwork(
            id: "\(museumID.rawValue)-\(objectID)",
            museumID: museumID,
            objectID: objectID,
            title: title,
            artworkDescription: nil,
            artistDisplayName: "作者",
            objectDate: "2026",
            medium: nil,
            dimensions: nil,
            department: nil,
            culture: nil,
            country: nil,
            repository: nil,
            primaryImageURL: URL(string: "https://example.com/\(objectID).jpg"),
            primaryImageSmallURL: URL(string: "https://example.com/\(objectID)-small.jpg"),
            objectURL: URL(string: "https://example.com/object/\(objectID)")
        )
    }
}
