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

    func testMetMuseumExtractWebDescriptionHandles318330OverviewWithChangedClassHash() throws {
        let html = """
        <html>
        <body>
        <main>
          <h1>Crucifix with Saint Anthony of Padua</h1>
          <div class="object-overview-module-scss-module__x8Q2kL__label">
            <p>This cross has been assembled from distinct components. The cross itself is composed of two pieces of wood with the horizontal element fitted into a notch in the vertical one so that both sections lie flush. In addition, niches have been carved into the surface of the wood for the inclusion of metalwork embellishments. The cross culminates in a rounded knob and a small band of cross-hatch patterning is carved at the center of the horizontal beam.</p>
            <p>The figure of a standing male, positioned in the niche at center, was originally a pendant that features a metal loop incorporated on the figure’s back. The loop has been employed to attach the figure to the wooden frame (see 1999.295.1 for a detached pendant). The figure wears the tonsure and triple-knotted belt of the Franciscan order and in his proper right hand he holds a cross. At his proper left side he supports a standing figure of Christ balanced on an open book and holding a bird.</p>
            <p>These distinctive attributes are based on a European prototype for depictions of Saint Anthony of Padua, a patron saint of Italy and Portugal. From the late fifteenth century, when the Kongo leadership adopted Christianity, they employed such devotional objects to demonstrate their political and religious authority. Saint Anthony became popular in Kongo after Italian Capuchin missionaries spread his cult in the mid-seventeenth century.</p>
          </div>
          <section>
            <h2>Provenance</h2>
            <p>This section should not be used as the overview fallback.</p>
          </section>
        </main>
        </body>
        </html>
        """

        XCTAssertEqual(
            MetMuseumAPI.extractWebDescription(from: html),
            """
            This cross has been assembled from distinct components. The cross itself is composed of two pieces of wood with the horizontal element fitted into a notch in the vertical one so that both sections lie flush. In addition, niches have been carved into the surface of the wood for the inclusion of metalwork embellishments. The cross culminates in a rounded knob and a small band of cross-hatch patterning is carved at the center of the horizontal beam.
            The figure of a standing male, positioned in the niche at center, was originally a pendant that features a metal loop incorporated on the figure’s back. The loop has been employed to attach the figure to the wooden frame (see 1999.295.1 for a detached pendant). The figure wears the tonsure and triple-knotted belt of the Franciscan order and in his proper right hand he holds a cross. At his proper left side he supports a standing figure of Christ balanced on an open book and holding a bird.
            These distinctive attributes are based on a European prototype for depictions of Saint Anthony of Padua, a patron saint of Italy and Portugal. From the late fifteenth century, when the Kongo leadership adopted Christianity, they employed such devotional objects to demonstrate their political and religious authority. Saint Anthony became popular in Kongo after Italian Capuchin missionaries spread his cult in the mid-seventeenth century.
            """
        )
    }

    func testMetMuseumExtractWebDescriptionHandles454054LeadBeforeArtworkDetails() throws {
        let expectedDescription = "Scenes of courtly pleasure, garden settings, and longlegged female figures dressed in high-waisted, flowing angarkhas (tunics) typify paintings attributed to the northern Indian court of Farrukhabad, a cultural satellite of Lucknow. The present work depicts twelve courtly ladies and a child gathered around a fountain, set in a lush landscape with fantastic loop-necked swans and the pairs of animals found in many Indian paintings."
        let html = """
        <html>
        <body>
        <main>
          <section class="collection-object-hero">
            <h1>Princesses Gather at a Fountain</h1>
            <div>ca. 1770</div>
            <div>Not on view</div>
            <section class="collection-object-lead">
              <p>\(expectedDescription)</p>
            </section>
            <a href="/art/collection/search/454054">Image: Princesses Gather at a Fountain, Opaque watercolor and gold on paper</a>
            <div>Public Domain</div>
          </section>
          <section>
            <h2>Artwork Details</h2>
            <p>Object Information</p>
          </section>
        </main>
        </body>
        </html>
        """

        let description = MetMuseumAPI.extractWebDescription(from: html)

        XCTAssertEqual(description, expectedDescription)
        XCTAssertFalse(description?.contains("Artwork Details") ?? true)
        XCTAssertFalse(description?.contains("Image:") ?? true)
    }

    func testMetMuseumFetchObjectWebDescriptionPrefersChinesePageWhenAvailable() async {
        let objectID = 39668
        let englishURL = URL(string: "https://www.metmuseum.org/art/collection/search/39668")!
        let chineseURL = URL(string: "https://www.metmuseum.org/zh/art/collection/search/39668")!
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(url)

            if url == chineseURL {
                let html = """
                <html><body><main>
                <div class="object-overview-module-scss-module__bIfq1G__label">
                  <p>中文概述</p>
                </div>
                </main></body></html>
                """
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            XCTFail("Unexpected fallback request: \(url.absoluteString)")
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                data: Data()
            )
        }
        let api = MetMuseumAPI(session: session)

        let description = await api.fetchObjectWebDescription(
            objectID: objectID,
            objectURL: englishURL
        )

        XCTAssertEqual(description, "中文概述")
        XCTAssertEqual(recorder.urls, [chineseURL])
    }

    func testMetMuseumFetchObjectWebDescriptionFallsBackToEnglishWhenChinesePageHasNoOverview() async {
        let objectID = 39669
        let englishURL = URL(string: "https://www.metmuseum.org/art/collection/search/39669")!
        let chineseURL = URL(string: "https://www.metmuseum.org/zh/art/collection/search/39669")!
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(url)

            if url == chineseURL {
                let html = "<html><body><main><h1>无中文概述</h1></main></body></html>"
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            if url == englishURL {
                let html = """
                <html><body><main>
                <div class="object-overview-module-scss-module__bIfq1G__label">
                  <p>English fallback overview</p>
                </div>
                </main></body></html>
                """
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            throw URLError(.badURL)
        }
        let api = MetMuseumAPI(session: session)

        let description = await api.fetchObjectWebDescription(
            objectID: objectID,
            objectURL: englishURL
        )

        XCTAssertEqual(description, "English fallback overview")
        XCTAssertEqual(recorder.urls, [chineseURL, englishURL])
    }

    func testMetMuseumFetchObjectWebDescriptionFallsBackToEnglishLeadWhenChinesePageHasNoDescription() async {
        let objectID = 454054
        let expectedDescription = "Scenes of courtly pleasure, garden settings, and longlegged female figures dressed in high-waisted, flowing angarkhas (tunics) typify paintings attributed to the northern Indian court of Farrukhabad, a cultural satellite of Lucknow. The present work depicts twelve courtly ladies and a child gathered around a fountain, set in a lush landscape with fantastic loop-necked swans and the pairs of animals found in many Indian paintings."
        let englishURL = URL(string: "https://www.metmuseum.org/art/collection/search/454054")!
        let chineseURL = URL(string: "https://www.metmuseum.org/zh/art/collection/search/454054")!
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(url)

            if url == chineseURL {
                let html = "<html><body><main><h1>无中文概述</h1></main></body></html>"
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            if url == englishURL {
                let html = """
                <html><body><main>
                <h1>Princesses Gather at a Fountain</h1>
                <div>ca. 1770</div>
                <div>Not on view</div>
                <section>
                  <p>\(expectedDescription)</p>
                </section>
                <h2>Artwork Details</h2>
                </main></body></html>
                """
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            throw URLError(.badURL)
        }
        let api = MetMuseumAPI(session: session)

        let description = await api.fetchObjectWebDescription(
            objectID: objectID,
            objectURL: englishURL
        )

        XCTAssertEqual(description, expectedDescription)
        XCTAssertEqual(recorder.urls, [chineseURL, englishURL])
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

    func testShanghaiMuseumAPIFetchArtworkPublishesTextBeforeResolvingImageURLs() async throws {
        let recorder = EventRecorder()
        let objectCode = "A-100"
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path.contains("/frontend/pg/article/id/") {
                recorder.record("article-request")
                let html = """
                <div class="title">青铜鼎</div>
                <ul>
                  <li><div class="left">时代：</div><ul class="site-list right"><li>商后期</li></ul></li>
                  <li><div class="left">材质：</div><ul class="site-list right"><li>青铜</li></ul></li>
                  <li><div class="left">尺寸：</div><ul class="site-list right"><li>高10厘米</li></ul></li>
                </ul>
                <div class="subtitle">简介</div>
                <p>这是文字详情。</p>
                """
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            if url.path.contains("/frontend/pg/article/aid/") {
                recorder.record("image-request")
                let html = """
                <figure data-src="/mu/images/large.jpg"></figure>
                <img src="/mu/images/small.jpg" />
                """
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: Data(html.utf8)
                )
            }

            XCTFail("Unexpected URL: \(url.absoluteString)")
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                data: Data()
            )
        }
        let api = ShanghaiMuseumAPI(session: session)

        let artwork = try await api.fetchArtwork(
            objectCode: objectCode,
            cachePolicy: .networkOnly
        ) { artwork in
            recorder.record("text-ready:\(artwork.primaryImageURL == nil && artwork.primaryImageSmallURL == nil)")
        }

        XCTAssertEqual(artwork.title, "青铜鼎")
        XCTAssertEqual(artwork.objectDate, "商后期")
        XCTAssertEqual(artwork.medium, "青铜")
        XCTAssertEqual(artwork.primaryImageURL?.absoluteString, "https://www.shanghaimuseum.net/mu/images/large.jpg")
        XCTAssertEqual(artwork.primaryImageSmallURL?.absoluteString, "https://www.shanghaimuseum.net/mu/images/small.jpg")
        XCTAssertEqual(
            recorder.values,
            ["article-request", "text-ready:true", "image-request"]
        )
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

    func testMuseumLatencyServiceUsesOneLightweightEndpointPerMuseum() async throws {
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(request)
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: Data("{}".utf8)
            )
        }
        let service = MuseumLatencyService(session: session)

        let measurements = await service.measureLatencies(for: MuseumRepository.homepageMuseumIDs)

        XCTAssertEqual(Set(measurements.keys), Set(MuseumRepository.homepageMuseumIDs))
        XCTAssertEqual(recorder.requests.count, MuseumRepository.homepageMuseumIDs.count)

        XCTAssertTrue(recorder.requests.contains { request in
            request.httpMethod == "GET"
                && request.url?.host == "collectionapi.metmuseum.org"
                && request.url?.path == "/public/collection/v1/departments"
        })
        XCTAssertTrue(recorder.requests.contains { request in
            request.httpMethod == "GET"
                && request.url?.host == "jpsearch.go.jp"
                && request.url?.path == "/api/item/search/jps-cross"
                && queryValue("size", in: request.url) == "1"
                && queryValue("f-db", in: request.url) == "cobas"
        })
        XCTAssertTrue(recorder.requests.contains { request in
            request.httpMethod == "GET"
                && request.url?.host == "appapi.chnmuseum.cn"
                && request.url?.path == "/api/exhibit_list"
                && queryValue("cate_id", in: request.url) == "0"
                && queryValue("limit", in: request.url) == "1"
        })
        XCTAssertTrue(recorder.requests.contains { request in
            request.httpMethod == "POST"
                && request.url?.host == "www.shanghaimuseum.net"
                && request.url?.path == "/mu/frontend/pg/collection/search-antique"
        })
    }

    func testMuseumLatencyServiceTreatsRequestFailureAsTimeout() async throws {
        let session = makeStubSession(testID: UUID().uuidString) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let service = MuseumLatencyService(session: session)

        let measurement = await service.measureLatency(for: .met)

        XCTAssertEqual(measurement, .timeout(museumID: .met))
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

    private func queryValue(_ name: String, in url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
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
    private var requestStorage: [URLRequest] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func record(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    func record(_ request: URLRequest) {
        lock.lock()
        if let url = request.url {
            storage.append(url)
        }
        requestStorage.append(request)
        lock.unlock()
    }
}

private final class EventRecorder {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
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
