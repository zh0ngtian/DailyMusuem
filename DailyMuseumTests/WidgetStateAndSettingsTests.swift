import WidgetKit
import XCTest

final class WidgetStateAndSettingsTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "WidgetStateAndSettingsTests.\(UUID().uuidString)"
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

    func testWidgetSettingsReaderUsesFeedCategoriesFromDefaults() {
        defaults.set(
            "modern-art,american-decorative-arts",
            forKey: SettingsKeys.feedCategoryPrefix + MuseumID.met.rawValue
        )

        let reader = WidgetSettingsReader(defaults: defaults)
        let categories = reader.categories(for: .met)

        XCTAssertEqual(categories.map(\.id), ["american-decorative-arts", "modern-art"])
    }

    func testWidgetInstanceTokenResolverPreservesPersistedToken() {
        let token = WidgetInstanceTokenResolver.resolve(
            from: "instance-123",
            scope: .single(.met),
            family: .systemLarge
        )

        XCTAssertEqual(token, "instance-123")
    }

    func testWidgetInstanceTokenResolverUsesStableLegacyFallbackForMissingToken() {
        let token = WidgetInstanceTokenResolver.resolve(
            from: "   ",
            scope: .single(.tnm),
            family: .systemMedium
        )

        XCTAssertEqual(token, "legacy-single-tnm-medium")
    }

    func testWidgetInstanceTokenResolverGeneratesNonEmptyDefaultToken() {
        let first = WidgetInstanceTokenResolver.makeDefaultToken()
        let second = WidgetInstanceTokenResolver.makeDefaultToken()

        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(first, second)
    }

    func testArtworkBatchLoaderLoadsTokyoInTenItemPagesAndAdvancesSearchWindow() async throws {
        let recorder = WidgetRequestRecorder()
        let testID = UUID().uuidString

        let session = makeStubSession(testID: testID) { [self] request in
            let url = try XCTUnwrap(request.url)
            recorder.record(url)

            if url.path.contains("/item/search/jps-cross") {
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let queryItems = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(queryItems["size"], "10")
                let fromValue = queryItems["from"] ?? "0"
                let ids: [Int]
                switch fromValue {
                case "0":
                    ids = Array(1...10)
                case "10":
                    ids = Array(11...20)
                default:
                    XCTFail("Unexpected from value: \(fromValue)")
                    ids = []
                }

                let list = ids.map {
                    self.makeJapanSearchItemDictionary(id: "item-\($0)", sortValue: "\($0)")
                }
                return self.makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "list": list,
                        "hit": 20,
                        "from": Int(fromValue) ?? 0
                    ]
                )
            }

            let itemID = url.lastPathComponent
            return self.makeJSONResponse(
                url: url,
                jsonObject: self.makeJapanSearchItemDictionary(
                    id: itemID,
                    sortValue: itemID.replacingOccurrences(of: "item-", with: "")
                )
            )
        }

        let loader = ArtworkBatchLoader(
            museumID: .tnm,
            categories: MuseumID.tnm.defaultFeedCategories,
            randomOrder: false,
            cachePolicy: .networkOnly,
            japanSearchAPI: JapanSearchAPI(session: session)
        )

        let firstBatch = try await loader.nextBatch(count: 10)
        let secondBatch = try await loader.nextBatch(count: 10)

        XCTAssertEqual(firstBatch.count, 10)
        XCTAssertEqual(secondBatch.count, 10)

        let searchRequests = recorder.urls.filter { $0.path.contains("/item/search/jps-cross") }
        let fromValues = searchRequests.map {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "from" })?
                .value ?? "0"
        }
        XCTAssertEqual(searchRequests.count, 3)
        XCTAssertEqual(fromValues, ["0", "0", "10"])
    }

    func testArtworkBatchLoaderMetIsNotInitiallyExhaustedAndLoadsFirstBatch() async throws {
        let testID = UUID().uuidString

        let session = makeStubSession(testID: testID) { [self] request in
            let url = try XCTUnwrap(request.url)

            if url.path.contains("/search") {
                return self.makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "total": 1,
                        "objectIDs": [101]
                    ]
                )
            }

            if url.path.contains("/objects/101") {
                return self.makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "objectID": 101,
                        "title": "Met Test Artwork",
                        "artistDisplayName": "Tester",
                        "objectDate": "2026",
                        "medium": "Oil on canvas",
                        "dimensions": "10 x 10 cm",
                        "department": "Modern Art",
                        "culture": "Test Culture",
                        "country": "USA",
                        "repository": "The Metropolitan Museum of Art",
                        "primaryImage": "https://example.com/met-101-large.jpg",
                        "primaryImageSmall": "https://example.com/met-101-small.jpg",
                        "objectURL": "https://example.com/met-101"
                    ]
                )
            }

            XCTFail("Unexpected URL: \(url.absoluteString)")
            return self.makeJSONResponse(url: url, jsonObject: [:])
        }

        let loader = ArtworkBatchLoader(
            museumID: .met,
            categories: MuseumID.met.defaultFeedCategories,
            randomOrder: false,
            cachePolicy: .networkOnly,
            metAPI: MetMuseumAPI(session: session)
        )

        let isInitiallyExhausted = await loader.isExhausted()
        XCTAssertFalse(isInitiallyExhausted)

        let batch = try await loader.nextBatch(count: 10)

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.museumID, .met)
        XCTAssertEqual(batch.first?.title, "Met Test Artwork")
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

    func testNationalMuseumChinaRequestThrottleCancelsDuringWait() async throws {
        let throttle = NationalMuseumChinaRequestThrottle(minimumInterval: 1)
        let now = Date(timeIntervalSince1970: 2_000)
        _ = try await throttle.waitForTurn(now: now)

        let task = Task {
            try await throttle.waitForTurn(now: now)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWidgetPreferredImageURLDecisionUsesThumbnailForTokyoWidget() {
        let smallURL = URL(string: "https://example.com/small.jpg")
        let largeURL = URL(string: "https://example.com/large.jpg")
        let artwork = Artwork(
            id: "tnm-1",
            museumID: .tnm,
            objectID: "1",
            title: "Test",
            artworkDescription: nil,
            artistDisplayName: nil,
            objectDate: nil,
            medium: nil,
            dimensions: nil,
            department: nil,
            culture: nil,
            country: nil,
            repository: nil,
            primaryImageURL: largeURL,
            primaryImageSmallURL: smallURL,
            objectURL: nil
        )

        XCTAssertEqual(
            WidgetPreferredImageURLDecision.resolve(for: artwork, museumID: .tnm),
            smallURL
        )
        XCTAssertEqual(
            WidgetPreferredImageURLDecision.resolveCandidates(for: artwork, museumID: .tnm),
            [smallURL!, largeURL!]
        )
    }

    func testWidgetImageRequestPolicyAddsBrowserHeadersForTokyoColbaseImage() {
        let url = URL(string: "https://colbase.nich.go.jp/media/tnm/A-9900/image/slideshow_s/A-9900_E0175464.jpg")!

        let request = WidgetImageRequestPolicy.makeRequest(url: url, timeout: 3)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://colbase.nich.go.jp/")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testWidgetImageRequestPolicyKeepsDefaultHeadersForNonColbaseImage() {
        let url = URL(string: "https://images.metmuseum.org/CRDImages/ep/original/DT1567.jpg")!

        let request = WidgetImageRequestPolicy.makeRequest(url: url, timeout: 8)

        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testWidgetRefreshEngineSkipsMissingImagesAndRepeatedImageFailures() async throws {
        let flakyURL = URL(string: "https://example.com/flaky.jpg")!
        let successURL = URL(string: "https://example.com/success.jpg")!
        let attempts = AttemptRecorder()
        let loader = StubBatchLoader(
            batches: [[
                makeArtwork(museumID: .met, objectID: "missing", title: "No Image", imageURL: nil),
                makeArtwork(museumID: .met, objectID: "flaky", title: "Flaky", imageURL: flakyURL),
                makeArtwork(museumID: .met, objectID: "success", title: "Success", imageURL: successURL),
            ]]
        )

        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            loaderFactory: { _, _, _ in
                loader
            },
            randomIndex: { _ in 0 },
            imageDataFetcher: { url, _ in
                _ = await attempts.increment(for: url)
                if url == flakyURL {
                    throw URLError(.timedOut)
                }
                if url == successURL {
                    return widgetValidPNGData
                }
                XCTFail("Unexpected URL: \(url)")
                return nil
            }
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: .single(.met),
            instanceToken: "widget-met",
            logSource: "WidgetEngineTest"
        )

        XCTAssertEqual(payload.title, "Success")
        XCTAssertEqual(payload.museumID, .met)
        let requestedCandidates = await loader.requestedCandidateCount()
        let flakyAttempts = await attempts.value(for: flakyURL)
        let successAttempts = await attempts.value(for: successURL)
        XCTAssertEqual(requestedCandidates, 3)
        XCTAssertEqual(flakyAttempts, 3)
        XCTAssertEqual(successAttempts, 1)
    }

    func testWidgetRefreshEngineStopsAfterFirstRenderableCandidate() async throws {
        let loader = StubBatchLoader(
            batches: [[
                makeArtwork(
                    museumID: .tnm,
                    objectID: "first",
                    title: "First Success",
                    imageURL: URL(string: "https://example.com/first.jpg")
                ),
                makeArtwork(
                    museumID: .tnm,
                    objectID: "second",
                    title: "Second Should Not Load",
                    imageURL: URL(string: "https://example.com/second.jpg")
                ),
            ]]
        )

        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            loaderFactory: { _, _, _ in
                loader
            },
            randomIndex: { _ in 0 },
            imageDataFetcher: { _, _ in widgetValidPNGData }
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: .single(.tnm),
            instanceToken: "widget-tnm",
            logSource: "WidgetEngineSingleSuccess"
        )

        XCTAssertEqual(payload.title, "First Success")
        XCTAssertEqual(payload.museumID, .tnm)
        let requestedCandidates = await loader.requestedCandidateCount()
        XCTAssertEqual(requestedCandidates, 1)
    }

    func testWidgetRefreshEngineSkipsPreviouslyDisplayedArtworkForSameInstance() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let instanceToken = "widget-history"
        let scope = WidgetMuseumScope.single(.met)
        _ = await store.beginRefresh(instanceToken: instanceToken, scopeRawValue: scope.rawValue)
        _ = await store.markSuccess(
            instanceToken: instanceToken,
            expectedNonce: 1,
            payload: WidgetRefreshPayload(
                museumID: .met,
                artworkKey: WidgetDisplayedArtworkKey.make(museumID: .met, objectID: "seen"),
                museumName: MuseumID.met.displayName,
                title: "Seen",
                subtitle: "2026",
                imageData: widgetValidPNGData,
                appURL: URL(string: "https://example.com/seen")
            ).storedPayload(),
            imageData: nil
        )

        let loader = StubBatchLoader(
            batches: [[
                makeArtwork(
                    museumID: .met,
                    objectID: "seen",
                    title: "Seen",
                    imageURL: URL(string: "https://example.com/seen.jpg")
                ),
                makeArtwork(
                    museumID: .met,
                    objectID: "fresh",
                    title: "Fresh",
                    imageURL: URL(string: "https://example.com/fresh.jpg")
                ),
            ]]
        )

        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            snapshotStore: store,
            loaderFactory: { _, _, _ in loader },
            randomIndex: { _ in 0 },
            imageDataFetcher: { _, _ in widgetValidPNGData }
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: scope,
            instanceToken: instanceToken,
            logSource: "WidgetHistorySkip"
        )

        XCTAssertEqual(payload.title, "Fresh")
        XCTAssertEqual(payload.artworkKey, WidgetDisplayedArtworkKey.make(museumID: .met, objectID: "fresh"))
        let requestedCandidates = await loader.requestedCandidateCount()
        XCTAssertEqual(requestedCandidates, 2)
    }

    func testWidgetRefreshEngineClearsDisplayedHistoryOnceWhenOnlySeenCandidatesRemain() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let instanceToken = "widget-history-reset"
        let scope = WidgetMuseumScope.single(.met)
        _ = await store.beginRefresh(instanceToken: instanceToken, scopeRawValue: scope.rawValue)
        _ = await store.markSuccess(
            instanceToken: instanceToken,
            expectedNonce: 1,
            payload: WidgetRefreshPayload(
                museumID: .met,
                artworkKey: WidgetDisplayedArtworkKey.make(museumID: .met, objectID: "repeat"),
                museumName: MuseumID.met.displayName,
                title: "Repeat",
                subtitle: "2026",
                imageData: widgetValidPNGData,
                appURL: URL(string: "https://example.com/repeat")
            ).storedPayload(),
            imageData: nil
        )

        let loaderFactoryCount = IntRecorder()
        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            snapshotStore: store,
            loaderFactory: { [self] _, _, _ in
                loaderFactoryCount.increment()
                return StubBatchLoader(batches: [[
                    self.makeArtwork(
                        museumID: .met,
                        objectID: "repeat",
                        title: "Repeat",
                        imageURL: URL(string: "https://example.com/repeat.jpg")
                    )
                ]])
            },
            randomIndex: { _ in 0 },
            imageDataFetcher: { _, _ in widgetValidPNGData }
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: scope,
            instanceToken: instanceToken,
            logSource: "WidgetHistoryReset"
        )

        XCTAssertEqual(payload.title, "Repeat")
        XCTAssertEqual(loaderFactoryCount.value, 2)
        let displayedKeys = await store.displayedArtworkKeys(
            for: instanceToken,
            scopeRawValue: scope.rawValue
        )
        XCTAssertEqual(displayedKeys, [])
    }

    func testWidgetRefreshEngineAllMuseumsUsesInjectedSelectionOrder() async throws {
        let selectedRanges = RangeRecorder()
        let metArtwork = makeArtwork(
            museumID: .met,
            objectID: "met-1",
            title: "Met",
            imageURL: URL(string: "https://example.com/met.jpg")
        )
        let tnmArtwork = makeArtwork(
            museumID: .tnm,
            objectID: "tnm-1",
            title: "TNM",
            imageURL: URL(string: "https://example.com/tnm.jpg")
        )

        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            loaderFactory: { museumID, _, _ in
                switch museumID {
                case .met:
                    return StubBatchLoader(batches: [[metArtwork]])
                case .tnm:
                    return StubBatchLoader(batches: [[tnmArtwork]])
                case .nmc, .shm:
                    return StubBatchLoader(batches: [])
                }
            },
            randomIndex: { range in
                selectedRanges.record(range)
                return 1
            },
            imageDataFetcher: { _, _ in widgetValidPNGData }
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: .all,
            instanceToken: "widget-all",
            logSource: "WidgetEngineAllMuseums"
        )

        XCTAssertEqual(payload.museumID, .tnm)
        XCTAssertEqual(selectedRanges.recordedRanges, [0..<2])
    }

    func testWidgetRefreshCoordinatorPreemptsSameInstanceRefresh() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let factory = SequentialEngineFactory()
        let coordinator = WidgetRefreshCoordinator(
            store: store,
            widgetCenter: .shared,
            makeEngine: {
                factory.makeEngine()
            }
        )

        let firstTask = Task {
            await coordinator.refresh(
                instanceToken: "shared-instance",
                scope: .single(.met),
                logSource: "CoordinatorPreempt"
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let secondTask = Task {
            await coordinator.refresh(
                instanceToken: "shared-instance",
                scope: .single(.met),
                logSource: "CoordinatorPreempt"
            )
        }

        await firstTask.value
        await secondTask.value

        let state = await store.state(for: "shared-instance")
        XCTAssertEqual(state?.phase, .success)
        XCTAssertEqual(state?.artwork?.title, "Second Result")
    }

    func testWidgetRefreshCoordinatorKeepsInstancesIndependent() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let settingsSuiteName = try XCTUnwrap(defaultsSuiteName)
        let coordinator = WidgetRefreshCoordinator(
            store: store,
            widgetCenter: .shared,
            makeEngine: { [self] in
                WidgetRefreshEngine(
                    settingsReader: WidgetSettingsReader(
                        defaults: UserDefaults(suiteName: settingsSuiteName) ?? .standard
                    ),
                    loaderFactory: { [self] museumID, _, _ in
                        StubBatchLoader(batches: [[
                            self.makeArtwork(
                                museumID: museumID,
                                objectID: "\(museumID.rawValue)-1",
                                title: museumID.displayName,
                                imageURL: URL(string: "https://example.com/\(museumID.rawValue).jpg")
                            )
                        ]])
                    },
                    randomIndex: { _ in 0 },
                    imageDataFetcher: { _, _ in widgetValidPNGData }
                )
            }
        )

        async let firstRefresh: Void = coordinator.refresh(
            instanceToken: "instance-1",
            scope: .single(.met),
            logSource: "CoordinatorIndependent"
        )
        async let secondRefresh: Void = coordinator.refresh(
            instanceToken: "instance-2",
            scope: .single(.tnm),
            logSource: "CoordinatorIndependent"
        )
        _ = await (firstRefresh, secondRefresh)

        let firstState = await store.state(for: "instance-1")
        let secondState = await store.state(for: "instance-2")

        XCTAssertEqual(firstState?.artwork?.museumID, .met)
        XCTAssertEqual(secondState?.artwork?.museumID, .tnm)
        XCTAssertEqual(firstState?.phase, .success)
        XCTAssertEqual(secondState?.phase, .success)
    }

    func testWidgetRefreshCoordinatorKeepsSameScopeInstancesIndependent() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let factory = SequentialEngineFactory()
        let coordinator = WidgetRefreshCoordinator(
            store: store,
            widgetCenter: .shared,
            makeEngine: {
                factory.makeEngine(snapshotStore: store)
            }
        )

        async let firstRefresh: Void = coordinator.refresh(
            instanceToken: "same-scope-1",
            scope: .single(.met),
            logSource: "CoordinatorSameScope"
        )
        async let secondRefresh: Void = coordinator.refresh(
            instanceToken: "same-scope-2",
            scope: .single(.met),
            logSource: "CoordinatorSameScope"
        )
        _ = await (firstRefresh, secondRefresh)

        let firstState = await store.state(for: "same-scope-1")
        let secondState = await store.state(for: "same-scope-2")

        XCTAssertEqual(firstState?.phase, .success)
        XCTAssertEqual(secondState?.phase, .success)
        XCTAssertNotEqual(firstState?.artwork?.title, secondState?.artwork?.title)
        XCTAssertEqual(firstState?.scopeRawValue, WidgetMuseumScope.single(.met).rawValue)
        XCTAssertEqual(secondState?.scopeRawValue, WidgetMuseumScope.single(.met).rawValue)
    }

    private func makeStubSession(
        testID: String,
        handler: @escaping @Sendable (URLRequest) throws -> WidgetStubbedResponse
    ) -> URLSession {
        WidgetStubURLProtocol.register(handler: handler, for: testID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [WidgetStubURLProtocol.testIDHeader: testID]
        return URLSession(configuration: configuration)
    }

    private func makeJSONResponse(url: URL, jsonObject: Any) -> WidgetStubbedResponse {
        WidgetStubbedResponse(
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            data: try! JSONSerialization.data(withJSONObject: jsonObject)
        )
    }

    private func makeJapanSearchItemDictionary(id: String, sortValue: String) -> [String: Any] {
        [
            "id": id,
            "common": [
                "id": id,
                "title": "Title \(id)",
                "thumbnailUrl": ["https://example.com/\(id).jpg"],
                "contentsUrl": ["https://example.com/\(id)-content.jpg"],
                "contributor": ["東京国立博物館"],
                "temporal": ["2026"],
                "linkUrl": "https://example.com/\(id)"
            ],
            "cobas-16-s": "東京国立博物館",
            "cobas-22-s": sortValue
        ]
    }

    private func makeArtwork(
        museumID: MuseumID,
        objectID: String,
        title: String,
        imageURL: URL?
    ) -> Artwork {
        Artwork(
            id: "\(museumID.rawValue)-\(objectID)",
            museumID: museumID,
            objectID: objectID,
            title: title,
            artworkDescription: nil,
            artistDisplayName: nil,
            objectDate: "2026",
            medium: nil,
            dimensions: nil,
            department: nil,
            culture: nil,
            country: nil,
            repository: museumID.displayName,
            primaryImageURL: imageURL,
            primaryImageSmallURL: imageURL,
            objectURL: URL(string: "https://example.com/\(objectID)")
        )
    }

    private func temporaryBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetStateAndSettingsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct WidgetStubbedResponse {
    let response: HTTPURLResponse
    let data: Data
}

private final class WidgetStubURLProtocol: URLProtocol {
    static let testIDHeader = "X-Widget-Stub-Test-ID"

    private static var handlers: [String: @Sendable (URLRequest) throws -> WidgetStubbedResponse] = [:]
    private static let lock = NSLock()

    static func register(
        handler: @escaping @Sendable (URLRequest) throws -> WidgetStubbedResponse,
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

private final class WidgetRequestRecorder {
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

private actor StubBatchLoader: WidgetArtworkCandidateLoading {
    private var queuedArtworks: [Artwork]
    private var requestedCandidates = 0

    init(batches: [[Artwork]]) {
        queuedArtworks = batches.flatMap { $0 }
    }

    func nextCandidateArtwork() async throws -> Artwork? {
        requestedCandidates += 1
        guard !queuedArtworks.isEmpty else {
            return nil
        }
        return queuedArtworks.removeFirst()
    }

    func isExhausted() async -> Bool {
        queuedArtworks.isEmpty
    }

    func requestedCandidateCount() async -> Int {
        requestedCandidates
    }
}

private actor AttemptRecorder {
    private var storage: [URL: Int] = [:]

    func increment(for url: URL) -> Int {
        storage[url, default: 0] += 1
        return storage[url, default: 0]
    }

    func value(for url: URL) -> Int {
        storage[url, default: 0]
    }
}

private final class RangeRecorder {
    private let lock = NSLock()
    private var storage: [Range<Int>] = []

    func record(_ range: Range<Int>) {
        lock.lock()
        storage.append(range)
        lock.unlock()
    }

    var recordedRanges: [Range<Int>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class IntRecorder {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class SequentialEngineFactory {
    private let lock = NSLock()
    private var creationCount = 0

    func makeEngine(snapshotStore: WidgetArtworkSnapshotStore = .shared) -> WidgetRefreshEngine {
        lock.lock()
        creationCount += 1
        let index = creationCount
        lock.unlock()

        return WidgetRefreshEngine(
            snapshotStore: snapshotStore,
            loaderFactory: { museumID, _, _ in
                StubBatchLoader(batches: [[
                    Artwork(
                        id: "\(museumID.rawValue)-\(index)",
                        museumID: museumID,
                        objectID: "\(index)",
                        title: index == 1 ? "First Result" : "Second Result",
                        artworkDescription: nil,
                        artistDisplayName: nil,
                        objectDate: "2026",
                        medium: nil,
                        dimensions: nil,
                        department: nil,
                        culture: nil,
                        country: nil,
                        repository: museumID.displayName,
                        primaryImageURL: URL(string: "https://example.com/\(index).png"),
                        primaryImageSmallURL: URL(string: "https://example.com/\(index).png"),
                        objectURL: URL(string: "https://example.com/\(index)")
                    )
                ]])
            },
            randomIndex: { _ in 0 },
            imageDataFetcher: { _, _ in
                if index == 1 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                return widgetValidPNGData
            }
        )
    }
}

private let widgetValidPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+Gk0AAAAASUVORK5CYII=")!
