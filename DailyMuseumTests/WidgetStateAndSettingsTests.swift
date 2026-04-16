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

    func testLoadLatestMigratesLegacyEmbeddedImageDataToFile() async throws {
        let baseURL = temporaryBaseURL()
        let cacheDirectory = baseURL.appendingPathComponent("WidgetCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let imageData = Data("legacy-image".utf8)
        let legacySnapshot = LegacySnapshot(
            cycleKey: "cycle+/=",
            museumName: "大都会艺术博物馆",
            title: "Legacy",
            subtitle: "2026",
            imageData: imageData,
            appURL: URL(string: "dailymuseum://artwork/met/1")
        )
        let snapshotURL = cacheDirectory.appendingPathComponent("current-artwork.json")
        try JSONEncoder().encode(legacySnapshot).write(to: snapshotURL)

        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let migratedSnapshot = await store.loadLatest()
        let reloadedSnapshot = await store.loadLatest()
        let migrated = try XCTUnwrap(migratedSnapshot)
        let reloaded = try XCTUnwrap(reloadedSnapshot)

        let imageFileName = try XCTUnwrap(migrated.imageFileName)
        XCTAssertFalse(imageFileName.contains("+"))
        XCTAssertFalse(imageFileName.contains("/"))
        XCTAssertFalse(imageFileName.contains("="))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(imageFileName).path))
        XCTAssertNil(reloaded.legacyEmbeddedImageData)
    }

    func testStoreAndLoadLatestRoundTripsSnapshotWithImageFile() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let snapshot = WidgetArtworkSnapshotStore.Snapshot(
            cycleKey: "cycle-1",
            museumName: "东京国立博物馆",
            title: "Artwork",
            subtitle: "2026",
            imageFileName: nil,
            appURL: URL(string: "dailymuseum://artwork/tnm/1")
        )

        let stored = await store.store(snapshot, imageData: Data("image".utf8))
        let loadedSnapshot = await store.loadLatest()
        let loaded = try XCTUnwrap(loadedSnapshot)

        XCTAssertEqual(loaded.cycleKey, stored.cycleKey)
        XCTAssertEqual(loaded.museumName, stored.museumName)
        XCTAssertEqual(loaded.title, stored.title)
        XCTAssertEqual(loaded.imageFileName, stored.imageFileName)
        XCTAssertNotNil(loaded.imageFileName)
    }

    func testTrackerTransitionsDeduplicatesDeliveriesAndCompletesOnMatchingRender() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 1_000)
        _ = await tracker.begin(
            nonce: 42,
            configurationCount: 3,
            expectedCounts: ["systemSmall": 2, "systemMedium": 1],
            requestedFamilyKey: WidgetFamily.systemSmall.logKey,
            startedAt: now
        )

        let deliveringState = await tracker.completeGeneratedRefresh(
            nonce: 42,
            targetRenderID: "render-42",
            now: now
        )
        let delivering = try XCTUnwrap(deliveringState)
        XCTAssertEqual(delivering.phase, .delivering)
        XCTAssertEqual(delivering.targetRenderID, "render-42")

        let firstDeliveryState = await tracker.recordDelivery(
            nonce: 42,
            family: .systemSmall,
            displaySize: CGSize(width: 100, height: 100),
            deliveryID: "delivery-1",
            now: now
        )
        let firstDelivery = try XCTUnwrap(firstDeliveryState)
        XCTAssertEqual(firstDelivery.deliveredCounts["systemSmall"], 1)

        let duplicateDelivery = await tracker.recordDelivery(
            nonce: 42,
            family: .systemSmall,
            displaySize: CGSize(width: 100, height: 100),
            deliveryID: "delivery-1",
            now: now
        )
        XCTAssertNil(duplicateDelivery)

        let secondDeliveryState = await tracker.recordDelivery(
            nonce: 42,
            family: .systemSmall,
            displaySize: CGSize(width: 200, height: 100),
            deliveryID: "delivery-2",
            now: now
        )
        let secondDelivery = try XCTUnwrap(secondDeliveryState)
        XCTAssertEqual(secondDelivery.deliveredCounts["systemSmall"], 2)

        let invalidRender = await tracker.recordRender(family: .systemMedium, renderID: "render-42", now: now)
        XCTAssertNil(invalidRender)

        let completedState = await tracker.recordRender(
            family: .systemSmall,
            renderID: "render-42",
            now: now
        )
        let completed = try XCTUnwrap(completedState)
        XCTAssertEqual(completed.phase, .completed)

        let status = await tracker.status(for: 42, now: now)
        guard case .completed(let state) = status else {
            return XCTFail("Expected completed status.")
        }
        XCTAssertTrue(state.isComplete)
    }

    func testTrackerRemovesStaleState() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let startedAt = Date(timeIntervalSince1970: 1_000)
        _ = await tracker.begin(
            nonce: 7,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: startedAt
        )

        let staleCheckDate = startedAt.addingTimeInterval(91)
        let activeState = await tracker.activeState(expectedNonce: 7, now: staleCheckDate)
        XCTAssertNil(activeState)

        let status = await tracker.status(for: 7, now: staleCheckDate)
        guard case .missing = status else {
            return XCTFail("Expected stale tracker state to be removed.")
        }
    }

    func testTrackerReusableTargetRenderIDExpiresAfterGracePeriod() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 2_000)
        _ = await tracker.begin(
            nonce: 11,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 11,
            targetRenderID: "render-11",
            now: now
        )
        _ = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-11",
            now: now.addingTimeInterval(1)
        )

        let reusableWithinWindow = await tracker.reusableTargetRenderID(
            expectedNonce: 11,
            now: now.addingTimeInterval(21)
        )
        let reusableAfterWindow = await tracker.reusableTargetRenderID(
            expectedNonce: 11,
            now: now.addingTimeInterval(32)
        )

        XCTAssertEqual(reusableWithinWindow, "render-11")
        XCTAssertNil(reusableAfterWindow)
    }

    func testWidgetImageFetchPolicyUsesFastPathDuringManualRefresh() {
        XCTAssertEqual(WidgetImageFetchPolicy.requestTimeout(manualRefreshInProgress: true), 3)
        XCTAssertEqual(WidgetImageFetchPolicy.maxAttempts(manualRefreshInProgress: true), 1)
        XCTAssertEqual(WidgetImageFetchPolicy.requestTimeout(manualRefreshInProgress: false), 8)
        XCTAssertEqual(WidgetImageFetchPolicy.maxAttempts(manualRefreshInProgress: false), 3)
    }

    func testWidgetManualRefreshFallbackDecisionFallsBackAfterRepeatedImageFailures() {
        XCTAssertTrue(
            WidgetManualRefreshFallbackDecision.shouldFallbackToTextOnly(
                manualRefreshInProgress: true,
                imageFetchFailureCount: 2,
                elapsed: 4
            )
        )
        XCTAssertTrue(
            WidgetManualRefreshFallbackDecision.shouldFallbackToTextOnly(
                manualRefreshInProgress: true,
                imageFetchFailureCount: 1,
                elapsed: 12
            )
        )
        XCTAssertFalse(
            WidgetManualRefreshFallbackDecision.shouldFallbackToTextOnly(
                manualRefreshInProgress: true,
                imageFetchFailureCount: 1,
                elapsed: 5
            )
        )
        XCTAssertFalse(
            WidgetManualRefreshFallbackDecision.shouldFallbackToTextOnly(
                manualRefreshInProgress: false,
                imageFetchFailureCount: 3,
                elapsed: 20
            )
        )
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

    func testWidgetSettingsReaderKeepsDeliveringStateActiveForRepeatedManualRefreshReuse() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 3_000)
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(now.timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(23, forKey: SettingsKeys.widgetManualRefreshNonce)

        _ = await tracker.begin(
            nonce: 23,
            configurationCount: 2,
            expectedCounts: ["systemSmall": 1, "systemMedium": 1],
            requestedFamilyKey: WidgetFamily.systemSmall.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 23,
            targetRenderID: "render-23",
            now: now
        )

        let reader = WidgetSettingsReader(defaults: defaults, refreshTracker: tracker)
        let firstState = await reader.activeManualRefreshDeliveryState(now: now.addingTimeInterval(2))
        let secondState = await reader.activeManualRefreshDeliveryState(now: now.addingTimeInterval(6))
        let reusableTargetRenderID = await reader.reusableManualRefreshTargetRenderID(now: now.addingTimeInterval(6))

        XCTAssertEqual(firstState?.phase, .delivering)
        XCTAssertEqual(secondState?.phase, .delivering)
        XCTAssertEqual(firstState?.targetRenderID, "render-23")
        XCTAssertEqual(secondState?.targetRenderID, "render-23")
        XCTAssertEqual(reusableTargetRenderID, "render-23")
    }

    func testWidgetSettingsReaderBuildsCategorySelectionKeyFromInjectedDefaults() {
        defaults.set(WidgetMuseumScope.single(.met).rawValue, forKey: SettingsKeys.widgetMuseumScope)
        defaults.set(
            "modern-art,american-decorative-arts",
            forKey: SettingsKeys.feedCategoryPrefix + MuseumID.met.rawValue
        )

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.categorySelectionKey, "met:american-decorative-arts,modern-art")
    }

    func testWidgetSettingsReaderClearsStaleManualRefreshState() {
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(
            Date().addingTimeInterval(-91).timeIntervalSince1970,
            forKey: SettingsKeys.widgetManualRefreshStartedAt
        )

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertFalse(reader.manualRefreshInProgress)
        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress))
        XCTAssertNil(defaults.object(forKey: SettingsKeys.widgetManualRefreshStartedAt))
    }

    func testWidgetManualRefreshInterruptionDecisionInterruptsWhenNonceIsSuperseded() {
        XCTAssertFalse(
            WidgetManualRefreshInterruptionDecision.shouldInterrupt(
                executionNonce: 51,
                isManualRefreshInProgress: true,
                activeNonce: 51
            )
        )
        XCTAssertTrue(
            WidgetManualRefreshInterruptionDecision.shouldInterrupt(
                executionNonce: 51,
                isManualRefreshInProgress: true,
                activeNonce: 52
            )
        )
        XCTAssertTrue(
            WidgetManualRefreshInterruptionDecision.shouldInterrupt(
                executionNonce: 51,
                isManualRefreshInProgress: false,
                activeNonce: 51
            )
        )
    }

    func testWidgetSettingsReaderClearsManualRefreshStateOnlyForMatchingNonce() {
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(5_000.0, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(61, forKey: SettingsKeys.widgetManualRefreshNonce)

        let reader = WidgetSettingsReader(defaults: defaults)
        reader.clearManualRefreshStateIfCurrentNonce(60)

        XCTAssertTrue(defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress))
        XCTAssertEqual(defaults.double(forKey: SettingsKeys.widgetManualRefreshStartedAt), 5_000.0)

        reader.clearManualRefreshStateIfCurrentNonce(61)

        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress))
        XCTAssertNil(defaults.object(forKey: SettingsKeys.widgetManualRefreshStartedAt))
    }

    func testWidgetSettingsReaderClearsStaleTrackerWhenManualRefreshFlagIsInactive() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 3_500)
        defaults.set(false, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(29, forKey: SettingsKeys.widgetManualRefreshNonce)

        _ = await tracker.begin(
            nonce: 29,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 29,
            targetRenderID: "render-29",
            now: now
        )

        let reader = WidgetSettingsReader(defaults: defaults, refreshTracker: tracker)
        let activeState = await reader.activeManualRefreshDeliveryState(now: now.addingTimeInterval(1))
        let trackerStateAfterRead = await tracker.activeState(expectedNonce: 29, now: now.addingTimeInterval(1))

        XCTAssertNil(activeState)
        XCTAssertNil(trackerStateAfterRead)
    }

    func testWidgetSettingsReaderClearsCompletedManualRefreshAfterReuseWindow() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 4_000)
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(now.timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(31, forKey: SettingsKeys.widgetManualRefreshNonce)

        _ = await tracker.begin(
            nonce: 31,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 31,
            targetRenderID: "render-31",
            now: now
        )
        _ = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-31",
            now: now.addingTimeInterval(1)
        )

        let reader = WidgetSettingsReader(defaults: defaults, refreshTracker: tracker)
        let activeState = await reader.activeManualRefreshDeliveryState(now: now.addingTimeInterval(32))

        XCTAssertNil(activeState)
        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress))
        XCTAssertNil(defaults.object(forKey: SettingsKeys.widgetManualRefreshStartedAt))
    }

    func testWidgetSettingsReaderKeepsCompletedStateActiveWithinDesktopSyncWindow() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 4_500)
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(now.timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(41, forKey: SettingsKeys.widgetManualRefreshNonce)

        _ = await tracker.begin(
            nonce: 41,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 41,
            targetRenderID: "render-41",
            now: now
        )
        _ = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-41",
            now: now.addingTimeInterval(1)
        )

        let reader = WidgetSettingsReader(defaults: defaults, refreshTracker: tracker)
        let activeState = await reader.activeManualRefreshDeliveryState(now: now.addingTimeInterval(21))
        let reusableTargetRenderID = await reader.reusableManualRefreshTargetRenderID(now: now.addingTimeInterval(21))

        XCTAssertEqual(activeState?.phase, .completed)
        XCTAssertEqual(activeState?.targetRenderID, "render-41")
        XCTAssertEqual(reusableTargetRenderID, "render-41")
        XCTAssertTrue(defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress))
    }

    func testWidgetRenderFollowUpReloadDecisionOnlyTriggersForCompletedTargetFamily() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 5_000)
        _ = await tracker.begin(
            nonce: 55,
            configurationCount: 2,
            expectedCounts: ["systemLarge": 1, "systemMedium": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )

        let generatingState = await tracker.activeState(expectedNonce: 55, now: now)
        XCTAssertFalse(
            WidgetRenderFollowUpReloadDecision.shouldRequestReload(
                deliveryState: generatingState,
                familyKey: WidgetFamily.systemLarge.logKey
            )
        )

        let deliveringState = await tracker.completeGeneratedRefresh(
            nonce: 55,
            targetRenderID: "render-55",
            now: now
        )
        XCTAssertFalse(
            WidgetRenderFollowUpReloadDecision.shouldRequestReload(
                deliveryState: deliveringState,
                familyKey: WidgetFamily.systemLarge.logKey
            )
        )

        let completedState = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-55",
            now: now.addingTimeInterval(1)
        )
        XCTAssertTrue(
            WidgetRenderFollowUpReloadDecision.shouldRequestReload(
                deliveryState: completedState,
                familyKey: WidgetFamily.systemLarge.logKey
            )
        )
        XCTAssertFalse(
            WidgetRenderFollowUpReloadDecision.shouldRequestReload(
                deliveryState: completedState,
                familyKey: WidgetFamily.systemMedium.logKey
            )
        )
    }

    func testWidgetRenderLoggingDecisionSuppressesCompletedSyncReplayLogsOnly() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 5_500)
        _ = await tracker.begin(
            nonce: 56,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 56,
            targetRenderID: "render-56",
            now: now
        )
        let completedState = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-56",
            now: now.addingTimeInterval(1)
        )

        XCTAssertFalse(
            WidgetRenderLoggingDecision.shouldSuppressRenderLog(
                entryRenderID: "render-56",
                deliveryID: "delivery-base",
                activeManualRefreshState: completedState
            )
        )
        XCTAssertTrue(
            WidgetRenderLoggingDecision.shouldSuppressRenderLog(
                entryRenderID: "render-56",
                deliveryID: "delivery-base-sync-123",
                activeManualRefreshState: completedState
            )
        )
        XCTAssertFalse(
            WidgetRenderLoggingDecision.shouldSuppressRenderLog(
                entryRenderID: "render-other",
                deliveryID: "delivery-base-sync-123",
                activeManualRefreshState: completedState
            )
        )

        let deliveringState = await tracker.begin(
            nonce: 57,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now.addingTimeInterval(10)
        )
        XCTAssertFalse(
            WidgetRenderLoggingDecision.shouldSuppressRenderLog(
                entryRenderID: "render-57",
                deliveryID: "delivery-base-sync-456",
                activeManualRefreshState: deliveringState
            )
        )
    }

    func testWidgetRenderLoggingDecisionCollapsesCompletedSyncWindowLogKeyAcrossDeliveries() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 5_800)
        _ = await tracker.begin(
            nonce: 58,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 58,
            targetRenderID: "render-58",
            now: now
        )
        let completedState = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-58",
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            WidgetRenderLoggingDecision.renderLogKey(
                entryRenderID: "render-58",
                familyKey: WidgetFamily.systemLarge.logKey,
                deliveryID: "delivery-a",
                activeManualRefreshState: completedState
            ),
            WidgetRenderLoggingDecision.renderLogKey(
                entryRenderID: "render-58",
                familyKey: WidgetFamily.systemLarge.logKey,
                deliveryID: "delivery-b",
                activeManualRefreshState: completedState
            )
        )
        XCTAssertNotEqual(
            WidgetRenderLoggingDecision.renderLogKey(
                entryRenderID: "render-58",
                familyKey: WidgetFamily.systemLarge.logKey,
                deliveryID: "delivery-a",
                activeManualRefreshState: completedState
            ),
            WidgetRenderLoggingDecision.renderLogKey(
                entryRenderID: "render-58",
                familyKey: WidgetFamily.systemMedium.logKey,
                deliveryID: "delivery-b",
                activeManualRefreshState: completedState
            )
        )
    }

    func testWidgetSnapshotReuseDecisionReusesOnlyMatchingCycleKey() {
        XCTAssertTrue(
            WidgetSnapshotReuseDecision.shouldReuseLatestSnapshot(
                latestSnapshotCycleKey: "single:tnm|tnm:all|images|36.0|493431",
                requestedCycleKey: "single:tnm|tnm:all|images|36.0|493431"
            )
        )
        XCTAssertFalse(
            WidgetSnapshotReuseDecision.shouldReuseLatestSnapshot(
                latestSnapshotCycleKey: "single:tnm|tnm:all|images|36.0|493431",
                requestedCycleKey: "single:tnm|tnm:all|images|37.0|493431"
            )
        )
        XCTAssertFalse(
            WidgetSnapshotReuseDecision.shouldReuseLatestSnapshot(
                latestSnapshotCycleKey: nil,
                requestedCycleKey: "single:tnm|tnm:all|images|37.0|493431"
            )
        )
    }

    func testWidgetImageSuitabilityDecisionRejectsExtremeStripImages() {
        XCTAssertFalse(
            WidgetImageSuitabilityDecision.isAcceptableForWidget(
                dimensions: WidgetImageDimensions(width: 328, height: 30)
            )
        )
        XCTAssertTrue(
            WidgetImageSuitabilityDecision.isAcceptableForWidget(
                dimensions: WidgetImageDimensions(width: 328, height: 211)
            )
        )
        XCTAssertTrue(
            WidgetImageSuitabilityDecision.isAcceptableForWidget(
                dimensions: WidgetImageDimensions(width: 138, height: 328)
            )
        )
    }

    func testWidgetDesktopSyncScheduleReturnsExpectedCheckpoints() async throws {
        let tracker = WidgetRefreshDeliveryTracker(baseURL: temporaryBaseURL())
        let now = Date(timeIntervalSince1970: 6_000)
        _ = await tracker.begin(
            nonce: 61,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            startedAt: now
        )
        _ = await tracker.completeGeneratedRefresh(
            nonce: 61,
            targetRenderID: "render-61",
            now: now
        )
        let completedState = await tracker.recordRender(
            family: .systemLarge,
            renderID: "render-61",
            now: now.addingTimeInterval(1)
        )
        let state = try XCTUnwrap(completedState)

        let syncStart = Date(timeIntervalSince1970: state.lastUpdatedAt)
        XCTAssertEqual(
            WidgetDesktopSyncSchedule.nextReloadDate(for: state, now: syncStart),
            syncStart.addingTimeInterval(2)
        )
        XCTAssertEqual(
            WidgetDesktopSyncSchedule.nextReloadDate(for: state, now: syncStart.addingTimeInterval(2.5)),
            syncStart.addingTimeInterval(5)
        )
        XCTAssertEqual(
            WidgetDesktopSyncSchedule.nextReloadDate(for: state, now: syncStart.addingTimeInterval(10.5)),
            syncStart.addingTimeInterval(20)
        )
        XCTAssertEqual(
            WidgetDesktopSyncSchedule.nextReloadDate(for: state, now: syncStart.addingTimeInterval(20.5)),
            syncStart.addingTimeInterval(30)
        )
        XCTAssertNil(
            WidgetDesktopSyncSchedule.nextReloadDate(for: state, now: syncStart.addingTimeInterval(30))
        )
    }

    func testRenderedArtworkPersistenceDecisionRejectsLoadingEntryDuringManualRefresh() {
        let activeState = WidgetRefreshDeliveryTracker.State(
            nonce: 71,
            startedAt: 7_000,
            phase: .delivering,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1, "systemMedium": 0, "systemSmall": 0],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            deliveredCounts: ["systemLarge": 0, "systemMedium": 0, "systemSmall": 0],
            deliveredTokens: [:],
            targetRenderID: "render-71",
            renderedFamilyRenderIDs: [:],
            lastUpdatedAt: 7_001
        )

        XCTAssertFalse(
            WidgetRenderedArtworkPersistenceDecision.shouldPersist(
                entryRenderID: "loading-render-70",
                isRefreshing: true,
                activeManualRefreshState: activeState
            )
        )
    }

    func testRenderedArtworkPersistenceDecisionRejectsStaleRenderWhenNewerManualRefreshExists() {
        let activeState = WidgetRefreshDeliveryTracker.State(
            nonce: 81,
            startedAt: 8_000,
            phase: .delivering,
            configurationCount: 1,
            expectedCounts: ["systemLarge": 1, "systemMedium": 0, "systemSmall": 0],
            requestedFamilyKey: WidgetFamily.systemLarge.logKey,
            deliveredCounts: ["systemLarge": 0, "systemMedium": 0, "systemSmall": 0],
            deliveredTokens: [:],
            targetRenderID: "render-81",
            renderedFamilyRenderIDs: [:],
            lastUpdatedAt: 8_001
        )

        XCTAssertFalse(
            WidgetRenderedArtworkPersistenceDecision.shouldPersist(
                entryRenderID: "render-79",
                isRefreshing: false,
                activeManualRefreshState: activeState
            )
        )
        XCTAssertTrue(
            WidgetRenderedArtworkPersistenceDecision.shouldPersist(
                entryRenderID: "render-81",
                isRefreshing: false,
                activeManualRefreshState: activeState
            )
        )
    }

    private func temporaryBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetStateAndSettingsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct LegacySnapshot: Codable {
    let cycleKey: String
    let museumName: String
    let title: String
    let subtitle: String?
    let imageData: Data?
    let appURL: URL?
}

extension WidgetFamily {
    var logKey: String {
        switch self {
        case .systemSmall:
            return "systemSmall"
        case .systemMedium:
            return "systemMedium"
        case .systemLarge:
            return "systemLarge"
        default:
            return String(describing: self)
        }
    }
}
