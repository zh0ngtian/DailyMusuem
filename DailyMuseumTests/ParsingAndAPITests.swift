import Foundation
import XCTest

final class ParsingAndAPITests: XCTestCase {
    func testMetMuseumExtractWebDescriptionUsesOverviewBlockAndSkipsOtherSections() throws {
        let html = try loadFixture(named: "met-overview.html")

        let description = MetMuseumAPI.extractWebDescription(from: html)

        XCTAssertEqual(
            description,
            """
            First line & detail
            Second line
            Third line
            """
        )
        XCTAssertFalse(description?.contains("Provenance") ?? true)
        XCTAssertFalse(description?.contains("References") ?? true)
    }

    func testMetMuseumExtractWebDescriptionFallsBackToMetaDescription() throws {
        let html = try loadFixture(named: "met-meta-fallback.html")

        XCTAssertEqual(
            MetMuseumAPI.extractWebDescription(from: html),
            "Meta description fallback & details."
        )
    }

    func testNationalMuseumChinaExhibitPageParserParsesFixtureAndMapsArtwork() throws {
        let html = try loadFixture(named: "nmc-detail.html")
        let shareURL = try XCTUnwrap(URL(string: "https://appapi.chnmuseum.cn/api/exhibit/share_link?p=i&exhibit_id=1"))
        let page = try NationalMuseumChinaExhibitPageParser.parse(
            html: html,
            exhibitID: 1,
            shareURL: shareURL,
            baseURL: URL(string: "https://appapi.chnmuseum.cn")!
        )
        let artwork = page.toArtwork(repositoryName: "中国国家博物馆", countryName: "中国")

        XCTAssertEqual(page.title, "后母戊鼎")
        XCTAssertEqual(page.objectDate, "商后期")
        XCTAssertEqual(page.department, "青铜器")
        XCTAssertEqual(page.dimensions, "高133厘米")
        XCTAssertEqual(page.primaryImageURL?.absoluteString, "https://appapi.chnmuseum.cn/images/ding.jpg")
        XCTAssertTrue(page.descriptionHTML?.contains("这是展品介绍。") == true)
        XCTAssertTrue(page.descriptionHTML?.contains("用于解析详情 HTML。") == true)
        XCTAssertEqual(artwork.repository, "中国国家博物馆")
        XCTAssertEqual(artwork.country, "中国")
        XCTAssertEqual(artwork.objectURL, shareURL)
    }

    func testNationalMuseumChinaExhibitPageParserThrowsWhenTitleIsMissing() {
        XCTAssertThrowsError(
            try NationalMuseumChinaExhibitPageParser.parse(
                html: "<div class=\"content brief\"><p>missing</p></div>",
                exhibitID: 1,
                shareURL: URL(string: "https://example.com")!,
                baseURL: URL(string: "https://example.com")!
            )
        )
    }

    func testNationalMuseumChinaRequestThrottleEnforcesMinimumInterval() async throws {
        let throttle = NationalMuseumChinaRequestThrottle(minimumInterval: 0.002)
        let now = Date(timeIntervalSince1970: 1_000)

        let firstDelay = try await throttle.waitForTurn(now: now)
        let secondDelay = try await throttle.waitForTurn(now: now)
        let thirdDelay = try await throttle.waitForTurn(now: now.addingTimeInterval(0.01))

        XCTAssertEqual(firstDelay, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(secondDelay, 0.001)
        XCTAssertEqual(thirdDelay, 0, accuracy: 0.0001)
    }

    func testJapanSearchAPIFallsBackFromContributorSearchAndFiltersSortsDedupes() async throws {
        let categoryTypeCode = "fallback-\(UUID().uuidString)"
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .reduce(into: [String: String]()) { partial, item in
                    partial[item.name] = item.value ?? ""
                } ?? [:]

            if query["q-contributor"] != nil {
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: self.makeSearchResponse(list: [], hit: 0)
                )
            }

            let list = [
                self.makeJapanSearchItem(id: "tokyo-20", sortValue: "20", contributor: ["東京国立博物館"], provider: nil),
                self.makeJapanSearchItem(id: "tokyo-10", sortValue: "10", contributor: ["Else", "東京国立博物館"], provider: nil),
                self.makeJapanSearchItem(id: "tokyo-20", sortValue: "20", contributor: ["東京国立博物館"], provider: nil),
                self.makeJapanSearchItem(id: "other-99", sortValue: "99", contributor: ["Other Museum"], provider: "other"),
                self.makeJapanSearchItem(id: "tokyo-provider-30", sortValue: "30", contributor: ["Other Museum"], provider: "tnm")
            ]
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: self.makeSearchResponse(list: list, hit: list.count)
            )
        }
        let api = JapanSearchAPI(session: session)
        await api.resetSearchCache(preferHasImages: true, categoryTypeCode: categoryTypeCode)

        let snapshot = try await api.searchItemIDs(
            preferHasImages: true,
            categoryTypeCode: categoryTypeCode
        )

        XCTAssertEqual(snapshot.itemIDs, ["tokyo-10", "tokyo-20", "tokyo-provider-30"])
        XCTAssertFalse(snapshot.hasMoreRemoteItems)

        let recordedURLs = recorder.urls
        XCTAssertEqual(recordedURLs.count, 2)
        XCTAssertTrue(recordedURLs[0].absoluteString.contains("q-contributor"))
        XCTAssertFalse(recordedURLs[1].absoluteString.contains("q-contributor"))
    }

    func testJapanSearchAPIPaginatesAndDedupesAcrossPages() async throws {
        let categoryTypeCode = "pagination-\(UUID().uuidString)"
        let recorder = RequestRecorder()
        let page1: [[String: Any]] = [
            makeJapanSearchItem(id: "id-08", sortValue: "8", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-03", sortValue: "3", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-05", sortValue: "5", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-01", sortValue: "1", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-04", sortValue: "4", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-05", sortValue: "5", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-09", sortValue: "9", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-02", sortValue: "2", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-10", sortValue: "10", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-07", sortValue: "7", contributor: ["東京国立博物館"], provider: nil)
        ]
        let page2: [[String: Any]] = [
            makeJapanSearchItem(id: "id-10", sortValue: "10", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-12", sortValue: "12", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-11", sortValue: "11", contributor: ["東京国立博物館"], provider: nil),
            makeJapanSearchItem(id: "id-13", sortValue: "13", contributor: ["東京国立博物館"], provider: nil)
        ]
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(url)
            let from = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "from" })?
                .value
            let list = from == "10" ? page2 : page1
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: self.makeSearchResponse(list: list, hit: 20, from: Int(from ?? "0") ?? 0)
            )
        }
        let api = JapanSearchAPI(session: session)
        await api.resetSearchCache(preferHasImages: true, categoryTypeCode: categoryTypeCode)

        let snapshot = try await api.searchItemIDs(
            preferHasImages: true,
            categoryTypeCode: categoryTypeCode,
            minimumCount: 12
        )

        XCTAssertEqual(
            snapshot.itemIDs,
            ["id-01", "id-02", "id-03", "id-04", "id-05", "id-07", "id-08", "id-09", "id-10", "id-11", "id-12", "id-13"]
        )
        XCTAssertFalse(snapshot.hasMoreRemoteItems)
        XCTAssertEqual(recorder.urls.count, 2)
    }

    func testJapanSearchAPIEmptyResultsAreNotCached() async throws {
        let categoryTypeCode = "empty-\(UUID().uuidString)"
        let callCounter = Counter()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            let call = callCounter.increment()
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .reduce(into: [String: String]()) { partial, item in
                    partial[item.name] = item.value ?? ""
                } ?? [:]

            let list: [[String: Any]]
            switch call {
            case 1, 2, 3:
                list = []
            default:
                if query["q-contributor"] != nil {
                    list = []
                } else {
                    list = [self.makeJapanSearchItem(id: "id-01", sortValue: "1", contributor: ["東京国立博物館"], provider: nil)]
                }
            }

            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: self.makeSearchResponse(list: list, hit: list.count)
            )
        }
        let api = JapanSearchAPI(session: session)
        await api.resetSearchCache(preferHasImages: true, categoryTypeCode: categoryTypeCode)

        let firstSnapshot = try await api.searchItemIDs(
            preferHasImages: true,
            categoryTypeCode: categoryTypeCode,
            minimumCount: 1
        )
        let secondSnapshot = try await api.searchItemIDs(
            preferHasImages: true,
            categoryTypeCode: categoryTypeCode,
            minimumCount: 1
        )

        XCTAssertTrue(firstSnapshot.itemIDs.isEmpty)
        XCTAssertEqual(secondSnapshot.itemIDs, ["id-01"])
        XCTAssertEqual(callCounter.value, 4)
    }

    private func loadFixture(named fileName: String) throws -> String {
        let fileName = fileName as NSString
        let resourceURL = try XCTUnwrap(
            Bundle(for: type(of: self)).url(
                forResource: fileName.deletingPathExtension,
                withExtension: fileName.pathExtension
            )
        )
        return try String(contentsOf: resourceURL, encoding: .utf8)
    }

    private func makeStubSession(
        testID: String,
        handler: @escaping @Sendable (URLRequest) throws -> StubbedResponse
    ) -> URLSession {
        StubURLProtocol.register(handler: handler, for: testID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.testIDHeader: testID]
        return URLSession(configuration: configuration)
    }

    private func makeSearchResponse(list: [[String: Any]], hit: Int, from: Int = 0) -> Data {
        let payload: [String: Any] = [
            "list": list,
            "hit": hit,
            "from": from
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeJapanSearchItem(
        id: String,
        sortValue: String,
        contributor: [String],
        provider: String?
    ) -> [String: Any] {
        var common: [String: Any] = [
            "id": id,
            "title": "Title \(id)",
            "thumbnailUrl": [],
            "contentsUrl": [],
            "contributor": contributor,
            "temporal": [],
        ]
        if let provider {
            common["provider"] = provider
        }

        return [
            "id": id,
            "common": common,
            "cobas-22-s": sortValue
        ]
    }
}

private struct StubbedResponse {
    let response: HTTPURLResponse
    let data: Data
}

private final class StubURLProtocol: URLProtocol {
    static let testIDHeader = "X-Stub-Test-ID"

    private static var handlers: [String: @Sendable (URLRequest) throws -> StubbedResponse] = [:]
    private static let lock = NSLock()

    static func register(
        handler: @escaping @Sendable (URLRequest) throws -> StubbedResponse,
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

private final class RequestRecorder {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}

private final class Counter {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }
}
