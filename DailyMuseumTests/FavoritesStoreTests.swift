import XCTest

final class FavoritesStoreTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try seedTestMuseumMetadata()
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
        let artwork = makeArtwork(museumID: MuseumIdentifier("met"), objectID: "100", title: "睡莲")

        store.toggleFavorite(
            artwork: artwork,
            favoritedAt: Date(timeIntervalSince1970: 100),
            imageAspectRatio: 1.5
        )

        XCTAssertTrue(store.isFavorite(museumID: MuseumIdentifier("met"), objectID: "100"))
        XCTAssertEqual(store.favorites.count, 1)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.count, 1)
        XCTAssertEqual(reloaded.favorites.first?.artwork.title, "睡莲")
        XCTAssertEqual(reloaded.favorites.first?.imageAspectRatio, 1.5)
    }

    func testRemoveFavoriteUpdatesPersistedState() {
        let store = FavoritesStore(defaults: defaults)
        let artwork = makeArtwork(museumID: MuseumIdentifier("tnm"), objectID: "200", title: "太刀")

        store.toggleFavorite(artwork: artwork, favoritedAt: Date(timeIntervalSince1970: 200))
        store.removeFavorite(museumID: MuseumIdentifier("tnm"), objectID: "200")

        XCTAssertFalse(store.isFavorite(museumID: MuseumIdentifier("tnm"), objectID: "200"))
        XCTAssertTrue(store.favorites.isEmpty)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertTrue(reloaded.favorites.isEmpty)
    }

    func testSetFavoriteFalseMatchesUnfavoriteBehaviorUsedByDetailPage() {
        let store = FavoritesStore(defaults: defaults)
        let artwork = makeArtwork(museumID: MuseumIdentifier("met"), objectID: "201", title: "牡丹图")

        store.setFavorite(true, artwork: artwork, favoritedAt: Date(timeIntervalSince1970: 100))
        store.setFavorite(false, artwork: artwork)

        XCTAssertFalse(store.isFavorite(museumID: MuseumIdentifier("met"), objectID: "201"))
        XCTAssertTrue(store.favorites.isEmpty)
    }

    func testRemoveFavoriteSnapshotMatchesSwipeToDeleteBehavior() {
        let store = FavoritesStore(defaults: defaults)
        let artwork = makeArtwork(museumID: MuseumIdentifier("shm"), objectID: "202", title: "青铜鼎")

        store.toggleFavorite(
            artwork: artwork,
            favoritedAt: Date(timeIntervalSince1970: 100),
            imageAspectRatio: 1.4
        )

        guard let snapshot = store.favorites.first else {
            return XCTFail("Expected a favorite snapshot after toggling favorite on")
        }

        store.removeFavorite(snapshot)

        XCTAssertFalse(store.isFavorite(museumID: MuseumIdentifier("shm"), objectID: "202"))
        XCTAssertTrue(store.favorites.isEmpty)
    }

    func testLoadingFavoritesDeduplicatesSameArtworkKeyKeepingNewestSnapshot() throws {
        let older = FavoriteArtworkSnapshot(
            museumID: MuseumIdentifier("met"),
            objectID: "300",
            favoritedAt: Date(timeIntervalSince1970: 300),
            artwork: makeArtwork(museumID: MuseumIdentifier("met"), objectID: "300", title: "旧标题"),
            imageAspectRatio: 0.8
        )
        let newer = FavoriteArtworkSnapshot(
            museumID: MuseumIdentifier("met"),
            objectID: "300",
            favoritedAt: Date(timeIntervalSince1970: 400),
            artwork: makeArtwork(museumID: MuseumIdentifier("met"), objectID: "300", title: "新标题"),
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
            artwork: makeArtwork(museumID: MuseumIdentifier("met"), objectID: "1", title: "A"),
            favoritedAt: Date(timeIntervalSince1970: 100)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("tnm"), objectID: "2", title: "B"),
            favoritedAt: Date(timeIntervalSince1970: 200)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("met"), objectID: "3", title: "C"),
            favoritedAt: Date(timeIntervalSince1970: 300)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("shm"), objectID: "4", title: "D"),
            favoritedAt: Date(timeIntervalSince1970: 400)
        )

        let sections = store.groupedFavorites(orderedMuseumIDs: [MuseumIdentifier("shm"), MuseumIdentifier("met"), MuseumIdentifier("tnm")])

        XCTAssertEqual(sections.map(\.museumID), [MuseumIdentifier("shm"), MuseumIdentifier("met"), MuseumIdentifier("tnm")])
        XCTAssertEqual(sections[0].items.map(\.objectID), ["4"])
        XCTAssertEqual(sections[1].items.map(\.objectID), ["3", "1"])
        XCTAssertEqual(sections[2].items.map(\.objectID), ["2"])
    }

    func testGroupedFavoritesUseHomepageMuseumOrderForChinaFirstLayout() {
        let store = FavoritesStore(defaults: defaults)

        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("met"), objectID: "1", title: "A"),
            favoritedAt: Date(timeIntervalSince1970: 100)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("shm"), objectID: "2", title: "B"),
            favoritedAt: Date(timeIntervalSince1970: 200)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("nmc"), objectID: "3", title: "C"),
            favoritedAt: Date(timeIntervalSince1970: 300)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("tnm"), objectID: "4", title: "D"),
            favoritedAt: Date(timeIntervalSince1970: 400)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("nnm"), objectID: "5", title: "E"),
            favoritedAt: Date(timeIntervalSince1970: 500)
        )

        let sections = store.groupedFavorites(orderedMuseumIDs: MuseumRepository.homepageMuseumIDs)

        XCTAssertEqual(sections.map(\.museumID), [MuseumIdentifier("nmc"), MuseumIdentifier("shm"), MuseumIdentifier("met"), MuseumIdentifier("tnm"), MuseumIdentifier("nnm")])
    }

    func testNaraOfficialAndColbaseFavoritesRemainDistinctWhenDataSourceChanges() {
        let store = FavoritesStore(defaults: defaults)

        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("nnm"), objectID: "narahaku-1032-0", title: "馆方源展品"),
            favoritedAt: Date(timeIntervalSince1970: 100)
        )
        store.toggleFavorite(
            artwork: makeArtwork(museumID: MuseumIdentifier("nnm"), objectID: "cobas-16086", title: "ColBase 展品"),
            favoritedAt: Date(timeIntervalSince1970: 200)
        )

        let reloaded = FavoritesStore(defaults: defaults)
        let sections = reloaded.groupedFavorites(orderedMuseumIDs: MuseumRepository.homepageMuseumIDs)
        let naraSection = sections.first { $0.museumID == MuseumIdentifier("nnm") }

        XCTAssertEqual(naraSection?.items.map(\.objectID), ["cobas-16086", "narahaku-1032-0"])
        XCTAssertTrue(reloaded.isFavorite(museumID: MuseumIdentifier("nnm"), objectID: "narahaku-1032-0"))
        XCTAssertTrue(reloaded.isFavorite(museumID: MuseumIdentifier("nnm"), objectID: "cobas-16086"))
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
