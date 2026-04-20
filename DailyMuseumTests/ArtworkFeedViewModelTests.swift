import Foundation
import XCTest

@MainActor
final class ArtworkFeedViewModelTests: XCTestCase {
    func testPullToRefreshKeepsRenderedItemsVisibleWhileInlineInitialLoadingIsShown() async {
        let itemID = "refresh-\(UUID().uuidString)"
        let refreshSearchStarted = expectation(description: "refresh search started")
        let searchResponseGate = DispatchSemaphore(value: 0)
        let searchRequestCounter = LockedCounter()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path.contains("/item/search/jps-cross") {
                let currentSearchRequestCount = searchRequestCounter.increment()

                if currentSearchRequestCount > 1 {
                    refreshSearchStarted.fulfill()
                    _ = searchResponseGate.wait(timeout: .now() + 2)
                }

                let item = Self.makeJapanSearchItem(id: itemID, title: "Refresh Test Item")
                return FeedViewModelStubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: try JSONSerialization.data(withJSONObject: [
                        "list": [item],
                        "hit": 1,
                        "from": 0
                    ])
                )
            }

            if url.path.contains("/item/\(itemID)") {
                Thread.sleep(forTimeInterval: 0.25)
                let item = Self.makeJapanSearchItem(id: itemID, title: "Refresh Test Item")
                return FeedViewModelStubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: try JSONSerialization.data(withJSONObject: item)
                )
            }

            throw URLError(.badURL)
        }

        let viewModel = ArtworkFeedViewModel(
            museum: MuseumRepository.museum(for: .tnm),
            settings: StubArtworkFeedSettings(),
            cache: StubArtworkFeedCache(),
            metAPI: MetMuseumAPI(session: session),
            japanSearchAPI: JapanSearchAPI(session: session),
            nationalMuseumChinaAPI: NationalMuseumChinaAPI(session: session),
            shanghaiMuseumAPI: ShanghaiMuseumAPI(session: session)
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

        searchResponseGate.signal()
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

    private nonisolated static func makeJapanSearchItem(id: String, title: String) -> [String: Any] {
        [
            "id": id,
            "common": [
                "id": id,
                "title": title,
                "linkUrl": "https://example.com/\(id)",
                "thumbnailUrl": ["https://example.com/\(id)-thumb.jpg"],
                "contentsUrl": ["https://example.com/\(id).jpg"],
                "contributor": ["東京国立博物館"],
                "temporal": ["江户时代"]
            ],
            "cobas-22-s": "10"
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
        hasMoreRemoteItemIDs: Bool
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
