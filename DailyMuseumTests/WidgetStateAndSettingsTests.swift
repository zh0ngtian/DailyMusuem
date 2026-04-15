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

        let deliveringState = await tracker.transitionToDelivering(
            nonce: 42,
            targetRenderID: "render-42",
            now: now
        )
        let delivering = try XCTUnwrap(deliveringState)
        XCTAssertEqual(delivering.phase, .delivering)

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

        let reusableWithinWindow = await tracker.reusableTargetRenderID(
            expectedNonce: 11,
            now: now.addingTimeInterval(10)
        )
        let reusableAfterWindow = await tracker.reusableTargetRenderID(
            expectedNonce: 11,
            now: now.addingTimeInterval(16)
        )

        XCTAssertEqual(reusableWithinWindow, "render-11")
        XCTAssertNil(reusableAfterWindow)
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
