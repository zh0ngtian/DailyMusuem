import Foundation
import XCTest

@MainActor
final class ArtworkFeedViewModelTests: XCTestCase {
    func testLoadMoreFetchesNextBackendCursorPage() async throws {
        let testID = UUID().uuidString
        let backendRequestCounter = LockedCounter()
        let session = makeStubSession(testID: testID) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            guard url.path == "/v1/museums/tnm/artworks" else {
                XCTFail("Unexpected URL: \(url.absoluteString)")
                throw URLError(.badURL)
            }

            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )
            XCTAssertEqual(queryItems["limit"], "10")

            let requestCount = backendRequestCounter.increment()
            let ids: [Int]
            let nextCursor: Any
            let hasMore: Bool
            switch queryItems["cursor"] {
            case nil:
                XCTAssertEqual(requestCount, 1)
                ids = Array(1...10)
                nextCursor = "cursor-10"
                hasMore = true
            case "cursor-10":
                XCTAssertEqual(requestCount, 2)
                ids = Array(11...20)
                nextCursor = NSNull()
                hasMore = false
            default:
                XCTFail("Unexpected cursor: \(queryItems["cursor"] ?? "nil")")
                ids = []
                nextCursor = NSNull()
                hasMore = false
            }

            return FeedViewModelStubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: try JSONSerialization.data(withJSONObject: [
                    "dataVersion": "test-version",
                    "data": [
                        "items": ids.map {
                            Self.makeBackendArtwork(id: "item-\($0)", title: "Title item-\($0)")
                        },
                        "nextCursor": nextCursor,
                        "hasMore": hasMore
                    ]
                ])
            )
        }
        let backendClient = MuseumBackendClient(
            baseURL: URL(string: "https://backend.example")!,
            session: session
        )
        let viewModel = ArtworkFeedViewModel(
            museum: MuseumRepository.museum(for: .tnm),
            settings: StubArtworkFeedSettings(),
            cache: StubArtworkFeedCache(),
            backendClient: backendClient
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.displayItems.count, 10)
        XCTAssertTrue(viewModel.hasMoreItems)

        await viewModel.loadMoreIfNeeded()

        XCTAssertEqual(viewModel.displayItems.count, 20)
        XCTAssertFalse(viewModel.hasMoreItems)
    }

    func testPullToRefreshKeepsRenderedItemsVisibleWhileInlineInitialLoadingIsShown() async {
        let itemID = "refresh-\(UUID().uuidString)"
        let refreshSearchStarted = expectation(description: "refresh search started")
        let backendResponseGate = DispatchSemaphore(value: 0)
        let backendRequestCounter = LockedCounter()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/v1/museums/tnm/artworks" {
                let currentRequestCount = backendRequestCounter.increment()

                if currentRequestCount > 1 {
                    refreshSearchStarted.fulfill()
                    _ = backendResponseGate.wait(timeout: .now() + 2)
                }

                return FeedViewModelStubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: try JSONSerialization.data(withJSONObject: [
                        "dataVersion": "test-version",
                        "data": [
                            "items": [Self.makeBackendArtwork(id: itemID, title: "Refresh Test Item")],
                            "nextCursor": NSNull(),
                            "hasMore": false
                        ]
                    ])
                )
            }

            throw URLError(.badURL)
        }
        let backendClient = MuseumBackendClient(
            baseURL: URL(string: "https://backend.example")!,
            session: session
        )

        let viewModel = ArtworkFeedViewModel(
            museum: MuseumRepository.museum(for: .tnm),
            settings: StubArtworkFeedSettings(),
            cache: StubArtworkFeedCache(),
            backendClient: backendClient
        )

        await viewModel.reload()

        let renderedItemIDs = viewModel.displayItems.map(\.id)
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(renderedItemIDs, ["tnm-\(itemID)"])

        let refreshTask = Task {
            await viewModel.refresh()
        }
        await fulfillment(of: [refreshSearchStarted], timeout: 1.0)

        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertTrue(viewModel.showsInlineInitialLoading)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(viewModel.displayItems.map(\.id), renderedItemIDs)

        backendResponseGate.signal()
        await refreshTask.value

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertFalse(viewModel.showsInlineInitialLoading)
        XCTAssertEqual(viewModel.displayItems.map(\.id), ["tnm-\(itemID)"])
    }

    private func makeStubSession(
        testID: String,
        handler: @escaping @Sendable (URLRequest) throws -> FeedViewModelStubbedResponse
    ) -> URLSession {
        FeedViewModelStubURLProtocol.register(handler: handler, for: testID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedViewModelStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [FeedViewModelStubURLProtocol.testIDHeader: testID]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func makeBackendArtwork(id: String, title: String) -> [String: Any] {
        [
            "id": "tnm-\(id)",
            "museumID": "tnm",
            "objectID": id,
            "title": title,
            "artworkDescription": NSNull(),
            "artistDisplayName": NSNull(),
            "objectDate": "江户时代",
            "medium": NSNull(),
            "dimensions": NSNull(),
            "department": NSNull(),
            "culture": NSNull(),
            "country": NSNull(),
            "repository": "东京国立博物馆",
            "primaryImageURL": "https://example.com/\(id).jpg",
            "primaryImageSmallURL": "https://example.com/\(id)-thumb.jpg",
            "objectURL": "https://example.com/\(id)"
        ]
    }
}

@MainActor
private final class StubArtworkFeedSettings: ArtworkFeedSettingsProviding {
    func feedCategories(for museumID: MuseumID) -> [MuseumCategory] {
        museumID.defaultFeedCategories
    }

    func saveFeedCategories(_ categories: [MuseumCategory], for museumID: MuseumID) {}
}

@MainActor
private final class StubArtworkFeedCache: ArtworkFeedCaching {
    func snapshot(for museumID: MuseumID, randomOrder: Bool, categorySelectionKey: String) -> ArtworkFeedCache.Snapshot? {
        nil
    }

    func store(
        museumID: MuseumID,
        randomOrder: Bool,
        categorySelectionKey: String,
        items: [ArtworkFeedItem],
        objectIDPool: [String],
        loadedObjectIDs: Set<String>,
        hasMoreItems: Bool,
        hasMoreRemoteItemIDs: Bool,
        nextCursor: String?,
        seed: Int,
        dataVersion: String?,
        hasRequestedBackendPage: Bool
    ) {}

    func clear(museumID: MuseumID, randomOrder: Bool, categorySelectionKey: String) {}
}

private struct FeedViewModelStubbedResponse {
    let response: HTTPURLResponse
    let data: Data
}

private final class FeedViewModelStubURLProtocol: URLProtocol {
    static let testIDHeader = "X-Feed-ViewModel-Test-ID"

    private static var handlers: [String: @Sendable (URLRequest) throws -> FeedViewModelStubbedResponse] = [:]
    private static let lock = NSLock()

    static func register(
        handler: @escaping @Sendable (URLRequest) throws -> FeedViewModelStubbedResponse,
        for testID: String
    ) {
        lock.lock()
        handlers[testID] = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let testID = request.value(forHTTPHeaderField: Self.testIDHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let handler = Self.handlers[testID]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        do {
            let stubbed = try handler(request)
            client?.urlProtocol(self, didReceive: stubbed.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stubbed.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
