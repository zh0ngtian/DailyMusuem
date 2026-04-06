import Foundation
import SwiftUI

@MainActor
final class ArtworkFeedViewModel: ObservableObject {
    private enum Constants {
        static let initialBatchSize = 10
        static let loadMoreBatchSize = 10
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

    private let museum: Museum
    private let metAPI = MetMuseumAPI()
    private var objectIDPool: [Int] = []
    private var loadedObjectIDs: Set<Int> = []

    init(museum: Museum) {
        self.museum = museum
    }

    func loadInitialIfNeeded() async {
        guard state == .idle else { return }
        if restoreCachedFeedIfAvailable() { return }
        await reload()
    }

    func reload() async {
        ArtworkFeedCache.shared.clear(museumID: museum.id, randomOrder: isRandomOrder)
        state = .loading
        items = []
        objectIDPool = []
        loadedObjectIDs = []
        hasMoreItems = true
        isLoadingMore = false
        loadingLogs = []
        appendLoadingLog("开始加载 \(museum.displayName) 展品...")

        do {
            try await warmPoolIfNeeded()
            try await loadNextBatch(count: Constants.initialBatchSize)
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
            try await loadNextBatch(count: Constants.loadMoreBatchSize)
        } catch {
            appendLoadingLog("加载更多失败：\(error.localizedDescription)")
        }
    }

    func updateAspectRatio(for id: String, aspectRatio: CGFloat) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0.2, min(3.0, Double(aspectRatio)))
        if items[index].imageAspectRatio != clamped {
            items[index].imageAspectRatio = clamped
            persistCache()
        }
    }

    private func warmPoolIfNeeded() async throws {
        guard objectIDPool.isEmpty else { return }

        switch museum.id {
        case .met:
            let ids = try await metAPI.searchObjectIDs(
                hasImages: true,
                isOnView: false,
                query: "a"
            ) { [weak self] message in
                await self?.appendLoadingLog(message)
            }
            appendLoadingLog("开始按\(isRandomOrder ? "随机" : "objectID 顺序")模式整理 objectIDs...")
            if isRandomOrder {
                objectIDPool = Array(ids.shuffled())
            } else {
                objectIDPool = ids.sorted()
            }
            appendLoadingLog("objectIDs 已就绪，当前可用 \(objectIDPool.count) 条。")
        }
    }

    private func loadNextBatch(count: Int) async throws {
        var candidates = objectIDPool.filter { !loadedObjectIDs.contains($0) }
        var collected: [Artwork] = []

        let batchLabel = items.isEmpty ? "首批" : "下一批"
        appendLoadingLog("开始拉取\(batchLabel) \(count) 个展品详情...")

        while collected.count < count, !candidates.isEmpty {
            let chunkSize = max(count - collected.count, 10)
            let next = Array(candidates.prefix(chunkSize))
            candidates.removeFirst(min(chunkSize, candidates.count))
            loadedObjectIDs.formUnion(next)

            switch museum.id {
            case .met:
                let artworks = await withTaskGroup(of: Artwork?.self) { group in
                    for id in next {
                        group.addTask {
                            do {
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
            }
        }

        hasMoreItems = objectIDPool.contains { !loadedObjectIDs.contains($0) }

        let orderIndex = Dictionary(uniqueKeysWithValues: objectIDPool.enumerated().map { ($0.element, $0.offset) })

        let feedItems = collected
            .sorted { lhs, rhs in
                if isRandomOrder {
                    return (orderIndex[lhs.objectID] ?? .max) < (orderIndex[rhs.objectID] ?? .max)
                }
                return lhs.objectID < rhs.objectID
            }
            .map { ArtworkFeedItem(id: $0.id, artwork: $0, imageAspectRatio: nil) }

        items.append(contentsOf: feedItems)
        appendLoadingLog("\(batchLabel)详情加载完成，新增 \(feedItems.count) 个展品。")
        persistCache()
    }

    private var isRandomOrder: Bool {
        SettingsStore.shared.feedRandomOrder
    }

    private func restoreCachedFeedIfAvailable() -> Bool {
        guard let snapshot = ArtworkFeedCache.shared.snapshot(for: museum.id, randomOrder: isRandomOrder) else {
            return false
        }

        items = snapshot.items
        objectIDPool = snapshot.objectIDPool
        loadedObjectIDs = snapshot.loadedObjectIDs
        hasMoreItems = snapshot.hasMoreItems
        isLoadingMore = false
        state = .loaded
        return true
    }

    private func persistCache() {
        ArtworkFeedCache.shared.store(
            museumID: museum.id,
            randomOrder: isRandomOrder,
            items: items,
            objectIDPool: objectIDPool,
            loadedObjectIDs: loadedObjectIDs,
            hasMoreItems: hasMoreItems
        )
    }

    private func appendLoadingLog(_ message: String) {
        let timestamp = Self.logTimeFormatter.string(from: Date())
        loadingLogs.append("[\(timestamp)] \(message)")
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
