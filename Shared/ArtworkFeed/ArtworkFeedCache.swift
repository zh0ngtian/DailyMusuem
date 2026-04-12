import Foundation

@MainActor
final class ArtworkFeedCache {
    static let shared = ArtworkFeedCache()

    struct Snapshot {
        let items: [ArtworkFeedItem]
        let objectIDPool: [String]
        let loadedObjectIDs: Set<String>
        let hasMoreItems: Bool
        let hasMoreRemoteItemIDs: Bool
    }

    private struct Key: Hashable {
        let museumID: MuseumID
        let randomOrder: Bool
        let categorySelectionKey: String
    }

    private var storage: [Key: Snapshot] = [:]

    private init() {}

    func snapshot(for museumID: MuseumID, randomOrder: Bool, categorySelectionKey: String) -> Snapshot? {
        storage[Key(museumID: museumID, randomOrder: randomOrder, categorySelectionKey: categorySelectionKey)]
    }

    func store(
        museumID: MuseumID,
        randomOrder: Bool,
        categorySelectionKey: String,
        items: [ArtworkFeedItem],
        objectIDPool: [String],
        loadedObjectIDs: Set<String>,
        hasMoreItems: Bool,
        hasMoreRemoteItemIDs: Bool
    ) {
        storage[Key(museumID: museumID, randomOrder: randomOrder, categorySelectionKey: categorySelectionKey)] = Snapshot(
            items: items,
            objectIDPool: objectIDPool,
            loadedObjectIDs: loadedObjectIDs,
            hasMoreItems: hasMoreItems,
            hasMoreRemoteItemIDs: hasMoreRemoteItemIDs
        )
    }

    func clear(museumID: MuseumID, randomOrder: Bool, categorySelectionKey: String) {
        storage.removeValue(forKey: Key(museumID: museumID, randomOrder: randomOrder, categorySelectionKey: categorySelectionKey))
    }
}
