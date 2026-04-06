import Foundation

@MainActor
final class ArtworkFeedCache {
    static let shared = ArtworkFeedCache()

    struct Snapshot {
        let items: [ArtworkFeedItem]
        let objectIDPool: [Int]
        let loadedObjectIDs: Set<Int>
        let hasMoreItems: Bool
    }

    private struct Key: Hashable {
        let museumID: MuseumID
        let randomOrder: Bool
    }

    private var storage: [Key: Snapshot] = [:]

    private init() {}

    func snapshot(for museumID: MuseumID, randomOrder: Bool) -> Snapshot? {
        storage[Key(museumID: museumID, randomOrder: randomOrder)]
    }

    func store(museumID: MuseumID, randomOrder: Bool, items: [ArtworkFeedItem], objectIDPool: [Int], loadedObjectIDs: Set<Int>, hasMoreItems: Bool) {
        storage[Key(museumID: museumID, randomOrder: randomOrder)] = Snapshot(
            items: items,
            objectIDPool: objectIDPool,
            loadedObjectIDs: loadedObjectIDs,
            hasMoreItems: hasMoreItems
        )
    }

    func clear(museumID: MuseumID, randomOrder: Bool) {
        storage.removeValue(forKey: Key(museumID: museumID, randomOrder: randomOrder))
    }
}
