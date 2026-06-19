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

    func testGuimetMuseumAPIParsesOfficialDetailPageFields() throws {
        let detailURL = URL(string: "https://www.guimet.fr/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya")!
        let html = """
        <main role="main">
          <div class="artwork-header">
            <h1 class="artwork-title field field--name-field-title field--type-text-long field--label-hidden field__items">弥勒菩萨</h1>
            <div class="tag field field--name-field-text-period field--type-string field--label-hidden field__items">4-5世纪</div>
            <div class="main-artwork">
              <figure>
                <img loading="lazy" src="/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE" />
                <figcaption class="field field--name-field-copyright field--type-text-long field--label-hidden field__items"><p>Photo (C) MNAAG</p></figcaption>
              </figure>
            </div>
          </div>
          <div class="field--name-field-teaser field field--type-text-long field--label-hidden field__items">
            <p>这件作品是安德烈·马尔罗收藏中的一件传奇之作。</p>
          </div>
          <div class="field--name-field_ref_widgets field field--name-field-ref-widgets field--type-entity-reference-revisions field--label-hidden field__items">
            <div class="paragraph paragraph--type--wysiwyg paragraph--view-mode--default">
              <p>亚洲宗教对时间的看法是循环往复的。</p>
              <p>这件作品可追溯到公元4至5世纪。</p>
            </div>
          </div>
          <div class="paragraph--type--accordion small-container">
            <div class="info-table">
              <div class="cell field field--name-field-object-type field--type-string field--label-above">
                <span class="label field__label">分类</span>
                <span class="value field__items">雕塑</span>
              </div>
              <div class="cell field field--name-field-materials field--type-string field--label-above">
                <span class="label field__label">材质</span>
                <span class="value field__items">灰泥</span>
              </div>
              <div class="cell field field--name-field-dimensions field--type-string field--label-above field__items">
                <span class="label field__label">尺寸</span>
                <span class="value field__item">55 x 34 x 19 cm</span>
              </div>
              <div class="cell field field--name-field-object-number field--type-string field--label-above">
                <span class="label field__label">藏品编号</span>
                <span class="value field__items">MA 12974</span>
              </div>
              <div class="cell field field--name-field-ref-taxo-region field--type-entity-reference field--label-above field__items">
                <span class="label field__label">地区或地点</span>
                <span class="value field__item">阿富汗/巴基斯坦</span>
              </div>
            </div>
          </div>
          <div class="block-wrapper view-display-id-other_artwork_detail">
            <h2>了解更多藏品</h2>
            <p>这里不应进入当前展品介绍。</p>
          </div>
        </main>
        """

        let artwork = try GuimetMuseumAPI.parseDetailPage(html, detailURL: detailURL)

        XCTAssertEqual(artwork.id, "guimet-afghanistan-pakistan~bodhisattva-maitreya")
        XCTAssertEqual(artwork.museumID, .guimet)
        XCTAssertEqual(artwork.objectID, "afghanistan-pakistan~bodhisattva-maitreya")
        XCTAssertEqual(artwork.title, "弥勒菩萨")
        XCTAssertEqual(artwork.objectDate, "4-5世纪")
        XCTAssertEqual(artwork.department, "雕塑")
        XCTAssertEqual(artwork.medium, "灰泥")
        XCTAssertEqual(artwork.dimensions, "55 x 34 x 19 cm")
        XCTAssertEqual(artwork.culture, "阿富汗/巴基斯坦")
        XCTAssertEqual(artwork.repository, "吉美国立亚洲艺术博物馆")
        XCTAssertEqual(
            artwork.primaryImageURL?.absoluteString,
            "https://www.guimet.fr/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE"
        )
        XCTAssertEqual(artwork.objectURL, detailURL)
        XCTAssertEqual(
            artwork.normalizedDescriptionText,
            """
            这件作品是安德烈·马尔罗收藏中的一件传奇之作。
            亚洲宗教对时间的看法是循环往复的。
            这件作品可追溯到公元4至5世纪。
            """
        )
        XCTAssertFalse(artwork.normalizedDescriptionText?.contains("了解更多藏品") ?? true)
    }

    func testGuimetMuseumAPISearchUsesOfficialCollectionPage() async throws {
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(request)

            XCTAssertEqual(url.host, "www.guimet.fr")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mobile/15E148 Safari/604.1") == true)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true)

            let html: String
            if url.path == "/zh-hans/collections/afghanistan-et-gandhara" {
                html = """
                <div role="article" about="/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya" class="node--view-mode-teaser node--type-art-work">
                  <div class="image-wrapper">
                    <img src="https://www.guimet.fr/sites/default/files/styles/mosaic_list/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=crNarYT1" width="225" height="285" />
                  </div>
                  <div class="taxo-row">
                    <span class="field field--name-field-ref-taxo-work-category field--type-entity-reference field--label-hidden field__items">雕塑</span>
                  </div>
                  <h2>弥勒菩萨摘要标题</h2>
                  <a href="https://www.guimet.fr/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya" class="read-more-link">了解更多</a>
                </div>
                """
            } else if url.path == "/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya" {
                html = """
                <main role="main">
                  <div class="artwork-header">
                    <h1 class="artwork-title field field--name-field-title field--type-text-long field--label-hidden field__items">弥勒菩萨详情标题</h1>
                    <div class="tag field field--name-field-text-period field--type-string field--label-hidden field__items">4-5世纪</div>
                    <div class="main-artwork"><figure><img src="/sites/default/files/styles/width_1220px/public/2023-07/detail.jpg" /></figure></div>
                  </div>
                  <div class="field--name-field-teaser field field--type-text-long field--label-hidden field__items"><p>详情页介绍。</p></div>
                  <div class="paragraph--type--accordion small-container">
                    <div class="info-table">
                      <div class="cell"><span class="label field__label">分类</span><span class="value field__items">雕塑</span></div>
                    </div>
                  </div>
                </main>
                """
            } else {
                XCTFail("Unexpected Guimet URL: \(url.absoluteString)")
                html = ""
            }
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: Data(html.utf8)
            )
        }
        let api = GuimetMuseumAPI(session: session)

        let snapshot = try await api.searchArtworkReferences(
            collectionPaths: ["/zh-hans/collections/afghanistan-et-gandhara"],
            minimumCount: 1,
            cachePolicy: .networkOnly
        )

        XCTAssertEqual(snapshot.artworkReferences, ["afghanistan-pakistan~bodhisattva-maitreya"])
        XCTAssertFalse(snapshot.hasMoreRemoteItems)

        let artwork = try await api.fetchArtwork(
            reference: "afghanistan-pakistan~bodhisattva-maitreya",
            cachePolicy: .useCaches
        )
        XCTAssertEqual(artwork.title, "弥勒菩萨详情标题")
        XCTAssertEqual(artwork.department, "雕塑")
        XCTAssertEqual(artwork.normalizedDescriptionText, "详情页介绍。")
        XCTAssertEqual(
            recorder.urls.map(\.path),
            [
                "/zh-hans/collections/afghanistan-et-gandhara",
                "/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya"
            ]
        )
    }

    func testNaraMuseumOfficialSearchPageParserParsesCandidatesAndNormalizesURLs() {
        let html = """
        <div class="list clearfix">
          <p data-href="1032-0.html">
            <a href="1032-0.html">
              <i><img src="http://www.narahaku.go.jp/photo/exhibition/D025456.jpg" data-original="http://www.narahaku.go.jp/photo/exhibition/D025456.jpg" alt="浮雕佛传图" /></i>
              <span>浮雕佛传图<br>贵霜王朝<br /> 2世纪</span>
            </a>
          </p>
          <p data-href="1324-0.html">
            <a href="1324-0.html">
              <i><img src="//www.narahaku.go.jp/photo/exhibition/H017708.jpg" alt="菩萨立像" /></i>
              <span>菩萨立像<br>贵霜王朝<br /> 3世纪</span>
            </a>
          </p>
        </div>
        """

        let summaries = NaraMuseumAPI.parseSearchPage(
            html,
            baseURL: URL(string: "https://www.narahaku.go.jp/chinese/collection/")!
        )

        XCTAssertEqual(summaries.map(\.rawID), ["1032-0", "1324-0"])
        XCTAssertEqual(summaries.first?.objectID, "narahaku-1032-0")
        XCTAssertEqual(summaries.first?.title, "浮雕佛传图")
        XCTAssertEqual(summaries.first?.summary, "浮雕佛传图 / 贵霜王朝 / 2世纪")
        XCTAssertEqual(
            summaries.first?.thumbnailURL?.absoluteString,
            "https://www.narahaku.go.jp/photo/exhibition/D025456.jpg"
        )
        XCTAssertEqual(
            summaries.first?.detailURL.absoluteString,
            "https://www.narahaku.go.jp/chinese/collection/1032-0.html"
        )
    }

    func testNaraMuseumOfficialDetailPageParserMapsArtworkFields() throws {
        let html = """
        <div id="content" class="gallery-detail">
          <div class="description">
            <h2>浮雕佛传图</h2>
            <p><br>
              石造　浮雕　圆雕<br>
              高8.9cm　长34.0～74.0cm<br>
              印度　贵霜王朝　2世纪<br>
            </p>
            <div class="btnOperation"></div>
          </div>
          <div class="main">
            <img src="//www.narahaku.go.jp/photo/exhibition/D025456.jpg" data-id="1032-0" data-original="//www.narahaku.go.jp/photo/exhibition/D025456.jpg" palm="//www.narahaku.go.jp/_fKkxXPHb/D025456.jpg" alt="浮雕佛传图" class="mainPicture" />
          </div>
          <div class="text" id="kaisetsu">
            <p>该作品是将佛教创始人释迦牟尼传记的场面表现出来的浮雕的一部分。</p>
          </div>
          <table class="dbdetail">
            <tr><th>门类</th><td>雕刻</td></tr>
          </table>
        </div>
        """
        let detailURL = URL(string: "https://www.narahaku.go.jp/chinese/collection/1032-0.html")!

        let artwork = try NaraMuseumAPI.parseDetailPage(html, rawID: "1032-0", detailURL: detailURL)

        XCTAssertEqual(artwork.id, "nnm-narahaku-1032-0")
        XCTAssertEqual(artwork.objectID, "narahaku-1032-0")
        XCTAssertEqual(artwork.museumID, .nnm)
        XCTAssertEqual(artwork.title, "浮雕佛传图")
        XCTAssertEqual(artwork.medium, "石造　浮雕　圆雕")
        XCTAssertEqual(artwork.dimensions, "高8.9cm　长34.0～74.0cm")
        XCTAssertEqual(artwork.country, "印度")
        XCTAssertEqual(artwork.objectDate, "贵霜王朝 2世纪")
        XCTAssertEqual(artwork.department, "雕刻")
        XCTAssertEqual(artwork.normalizedDescriptionText, "该作品是将佛教创始人释迦牟尼传记的场面表现出来的浮雕的一部分。")
        XCTAssertEqual(artwork.repository, "奈良国立博物馆")
        XCTAssertEqual(artwork.primaryImageURL?.absoluteString, "https://www.narahaku.go.jp/_fKkxXPHb/D025456.jpg")
        XCTAssertEqual(artwork.primaryImageSmallURL?.absoluteString, "https://www.narahaku.go.jp/photo/exhibition/D025456.jpg")
        XCTAssertEqual(artwork.objectURL, detailURL)
    }

    func testNaraMuseumOfficialDetailPageParserCleansDescriptionSegments() throws {
        let html = """
        <div id="content" class="gallery-detail">
          <div class="description">
            <h2>阿弥陀如来坐像</h2>
            <p><br>
              木造<br>
              高42.0cm<br>
              日本　奈良时代　8世纪<br>
            </p>
            <div class="btnOperation"></div>
          </div>
          <div class="text" id="kaisetsu">
            <p>　　该造像平稳柔和、姿态优美。像体的立体感和衣褶处都表现出下一个 时代的要素。造像体内空洞，密密麻麻写着阿弥陀佛的种子，应该是受到了密宗的影响。<br />&nbsp;<br /><span style="display:block; text-align:right;">内藤航</span><span style="display:block; text-align:right;">(翻译： 张小娟)</span>奈良博三昧 －佛教美术品精选－. 奈良国立博物馆, 2021.7, 317</p>
            <p>　　该像明显具有平安时代后期造像稳健的作风。双手交叠腹前，拇指和食指相捻，呈阿弥陀定印。像内中空部分，以墨书密密麻麻地写着阿弥陀佛的种子符号（象征佛的梵文）。语音导览</p>
          </div>
          <table class="dbdetail">
            <tr><th>门类</th><td>雕刻</td></tr>
          </table>
        </div>
        """
        let detailURL = URL(string: "https://www.narahaku.go.jp/chinese/collection/1324-0.html")!

        let artwork = try NaraMuseumAPI.parseDetailPage(html, rawID: "1324-0", detailURL: detailURL)

        XCTAssertEqual(
            artwork.normalizedDescriptionText,
            """
            该造像平稳柔和、姿态优美。像体的立体感和衣褶处都表现出下一个 时代的要素。造像体内空洞，密密麻麻写着阿弥陀佛的种子，应该是受到了密宗的影响。
            该像明显具有平安时代后期造像稳健的作风。双手交叠腹前，拇指和食指相捻，呈阿弥陀定印。像内中空部分，以墨书密密麻麻地写着阿弥陀佛的种子符号（象征佛的梵文）。
            """
        )
        XCTAssertFalse(artwork.normalizedDescriptionText?.contains("翻译") ?? true)
        XCTAssertFalse(artwork.normalizedDescriptionText?.contains("语音导览") ?? true)
    }

    func testNaraMuseumOfficialDetailPageParserHandlesMissingMediumLine() throws {
        let html = """
        <div id="content" class="gallery-detail">
          <div class="description">
            <h2>銮</h2>
            <p><br>
              <br>
              高17.8cm<br>
              中国　中国・西周　公元前11世纪<br>
            </p>
            <div class="btnOperation"></div>
          </div>
          <div class="main">
            <img src="//www.narahaku.go.jp/photo/exhibition/D037178.jpg" data-id="1317-331" data-original="//www.narahaku.go.jp/photo/exhibition/D037178.jpg" palm="//www.narahaku.go.jp/_fKkxXPHb/D037178.jpg" alt="銮" class="mainPicture" />
          </div>
          <div class="text" id="kaisetsu"></div>
          <table class="dbdetail">
            <tr><th>门类</th><td>考古</td></tr>
          </table>
        </div>
        """
        let detailURL = URL(string: "https://www.narahaku.go.jp/chinese/collection/1317-331.html")!

        let artwork = try NaraMuseumAPI.parseDetailPage(html, rawID: "1317-331", detailURL: detailURL)

        XCTAssertEqual(artwork.title, "銮")
        XCTAssertNil(artwork.medium)
        XCTAssertEqual(artwork.dimensions, "高17.8cm")
        XCTAssertEqual(artwork.country, "中国")
        XCTAssertEqual(artwork.objectDate, "中国・西周 公元前11世纪")
        XCTAssertEqual(artwork.department, "考古")
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

    func testJapanSearchAPINaraProfileFallsBackAndDoesNotShareTokyoCacheKey() async throws {
        let categoryTypeCode = "nara-\(UUID().uuidString)"
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

            if let contributor = query["q-contributor"] {
                if contributor == "Nara National Museum" {
                    return StubbedResponse(
                        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        data: self.makeSearchResponse(list: [], hit: 0)
                    )
                }

                XCTAssertEqual(contributor, "東京国立博物館")
                let list = [
                    self.makeJapanSearchItem(id: "tokyo-01", sortValue: "1", contributor: ["東京国立博物館"], provider: "tnm")
                ]
                return StubbedResponse(
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data: self.makeSearchResponse(list: list, hit: list.count)
                )
            }

            let list = [
                self.makeJapanSearchItem(id: "nara-20", sortValue: "20", contributor: ["奈良国立博物館"], provider: nil),
                self.makeJapanSearchItem(id: "nara-10", sortValue: "10", contributor: ["Other"], provider: "narahaku"),
                self.makeJapanSearchItem(id: "other-99", sortValue: "99", contributor: ["Other"], provider: "other")
            ]
            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: self.makeSearchResponse(list: list, hit: list.count)
            )
        }
        let api = JapanSearchAPI(session: session)
        await api.resetSearchCache(museumID: .nnm, preferHasImages: true, categoryTypeCode: categoryTypeCode)
        await api.resetSearchCache(museumID: .tnm, preferHasImages: true, categoryTypeCode: categoryTypeCode)

        let naraSnapshot = try await api.searchItemIDs(
            museumID: .nnm,
            preferHasImages: true,
            categoryTypeCode: categoryTypeCode
        )
        let tokyoSnapshot = try await api.searchItemIDs(
            museumID: .tnm,
            preferHasImages: true,
            categoryTypeCode: categoryTypeCode
        )

        XCTAssertEqual(naraSnapshot.itemIDs, ["nara-10", "nara-20"])
        XCTAssertEqual(tokyoSnapshot.itemIDs, ["tokyo-01"])
        XCTAssertEqual(recorder.urls.count, 3)
        XCTAssertEqual(queryValue("q-contributor", in: recorder.urls[0]), "Nara National Museum")
        XCTAssertNil(queryValue("q-contributor", in: recorder.urls[1]))
        XCTAssertEqual(queryValue("q-contributor", in: recorder.urls[2]), "東京国立博物館")
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

    func testMuseumLatencyServiceUsesBackendProbePerMuseum() async throws {
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
        let backendClient = MuseumBackendClient(
            baseURL: URL(string: "https://backend.example")!,
            session: session
        )
        let service = MuseumLatencyService(session: session, backendClient: backendClient)

        let measurements = await service.measureLatencies(for: MuseumRepository.homepageMuseumIDs)

        XCTAssertEqual(Set(measurements.keys), Set(MuseumRepository.homepageMuseumIDs))
        XCTAssertEqual(recorder.requests.count, MuseumRepository.homepageMuseumIDs.count)

        let requestedPaths = Set(recorder.requests.compactMap { $0.url?.path })
        let expectedPaths = Set(MuseumRepository.homepageMuseumIDs.map { "/v1/museums/\($0.rawValue)/probe" })
        XCTAssertEqual(requestedPaths, expectedPaths)
        XCTAssertTrue(recorder.requests.allSatisfy { request in
            request.httpMethod == "GET" && request.url?.host == "backend.example"
        })
    }

    func testMuseumBackendDebugAuthProviderIssuesSignedBusinessHeaders() async throws {
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(request)

            let json: [String: Any]
            switch url.path {
            case "/v1/auth/challenge":
                let challenge = recorder.requests.count == 1 ? "register-challenge" : "session-challenge"
                json = [
                    "challenge": challenge,
                    "expiresAt": 4_102_444_800,
                    "mode": "debug"
                ]
            case "/v1/auth/register":
                json = [
                    "deviceID": "device-1",
                    "keyID": "debug-key",
                    "registered": true
                ]
            case "/v1/auth/session":
                json = [
                    "accessToken": "debug-session-token",
                    "tokenType": "Bearer",
                    "expiresAt": 4_102_444_800
                ]
            default:
                XCTFail("Unexpected auth URL: \(url.absoluteString)")
                json = [:]
            }

            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: try JSONSerialization.data(withJSONObject: json)
            )
        }
        let provider = MuseumBackendDebugAuthProvider(
            baseURL: URL(string: "https://backend.example")!,
            session: session,
            secret: "debug-secret",
            deviceID: "device-1",
            appVersion: "1.0 1"
        )

        let headers = try await provider.authenticatedHeaders(
            method: "GET",
            path: "/v1/museums",
            queryItems: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "category", value: "space value")
            ],
            body: nil
        )

        XCTAssertEqual(
            recorder.requests.compactMap { $0.url?.path },
            ["/v1/auth/challenge", "/v1/auth/register", "/v1/auth/challenge", "/v1/auth/session"]
        )
        XCTAssertEqual(headers["Authorization"], "Bearer debug-session-token")
        XCTAssertEqual(headers["X-MuseumMuse-App-Attest-KeyID"], "debug-key")
        XCTAssertEqual(headers["X-MuseumMuse-App-Version"], "1.0 1")

        let timestamp = try XCTUnwrap(headers["X-MuseumMuse-Timestamp"])
        let nonce = try XCTUnwrap(headers["X-MuseumMuse-Nonce"])
        let expectedHash = MuseumBackendDebugAuthProvider.canonicalRequestHash(
            method: "GET",
            path: "/v1/museums",
            queryItems: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "category", value: "space value")
            ],
            body: Data(),
            timestamp: timestamp,
            nonce: nonce
        )
        XCTAssertEqual(headers["X-MuseumMuse-Request-Hash"], expectedHash)
        XCTAssertEqual(
            headers["X-MuseumMuse-App-Attest-Assertion"],
            MuseumBackendDebugAuthProvider.debugAssertion(for: expectedHash, secret: "debug-secret")
        )
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
