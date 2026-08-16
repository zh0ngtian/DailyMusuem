import UIKit
import WidgetKit
import XCTest

final class WidgetStateAndSettingsTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try seedTestMuseumMetadata()
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
        setFeedPreference(
            museumID: MuseumIdentifier("met"),
            categoriesBySource: [
                "met_all": ["modern-art", "american-decorative-arts"]
            ],
            in: defaults
        )

        let reader = WidgetSettingsReader(defaults: defaults)
        let categories = reader.categories(for: MuseumIdentifier("met"))

        XCTAssertEqual(categories.map(\.id), ["american-decorative-arts", "modern-art"])
    }

    func testWidgetSettingsReaderDefaultsMetToAllSource() {
        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.selectedSourceKey(for: MuseumIdentifier("met")), "met_all")
        XCTAssertEqual(
            reader.categories(for: MuseumIdentifier("met")).map(\.id),
            MuseumIdentifier("met").selectableFeedCategories(sourceKey: "met_all").map(\.id)
        )
    }

    func testWidgetSettingsReaderUsesStoredMetOnViewSource() {
        setFeedPreference(
            museumID: MuseumIdentifier("met"),
            selectedSourceKey: "met_on_view",
            categoriesBySource: [
                "met_on_view": ["modern-art"]
            ],
            in: defaults
        )

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.selectedSourceKey(for: MuseumIdentifier("met")), "met_on_view")
        XCTAssertEqual(reader.categories(for: MuseumIdentifier("met")).map(\.id), ["modern-art"])
    }

    func testWidgetSettingsReaderDefaultsNaraToOfficialSourceAndCategories() {
        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.selectedSourceKey(for: MuseumIdentifier("nnm")), "official")
        XCTAssertEqual(
            reader.categories(for: MuseumIdentifier("nnm")).map(\.id),
            MuseumIdentifier("nnm").selectableFeedCategories(sourceKey: "official").map(\.id)
        )
    }

    func testWidgetSettingsReaderKeepsNaraOfficialAndColbaseCategoryStorageSeparate() {
        setFeedPreference(
            museumID: MuseumIdentifier("nnm"),
            selectedSourceKey: "official",
            categoriesBySource: [
                "official": ["official-sculpture", "official-painting"],
                "colbase": ["paint", "sculpture"]
            ],
            in: defaults
        )

        var reader = WidgetSettingsReader(defaults: defaults)
        XCTAssertEqual(reader.categories(for: MuseumIdentifier("nnm")).map(\.id), ["official-sculpture", "official-painting"])

        setFeedPreference(
            museumID: MuseumIdentifier("nnm"),
            selectedSourceKey: "colbase",
            in: defaults
        )
        reader = WidgetSettingsReader(defaults: defaults)
        XCTAssertEqual(reader.categories(for: MuseumIdentifier("nnm")).map(\.id), ["paint", "sculpture"])
    }

    func testWidgetSettingsReaderUsesStoredRefreshInterval() {
        defaults.set(3, forKey: SettingsKeys.widgetRefreshIntervalHours)

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.widgetRefreshInterval(), .threeHours)
    }

    func testWidgetSettingsReaderDefaultsRefreshIntervalToTwentyFourHours() {
        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.widgetRefreshInterval(), .twentyFourHours)
    }

    func testWidgetSettingsReaderKeepsExplicitlyDisabledRefreshInterval() {
        defaults.set(WidgetRefreshInterval.off.rawValue, forKey: SettingsKeys.widgetRefreshIntervalHours)

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.widgetRefreshInterval(), .off)
    }

    func testWidgetSettingsReaderUsesStoredAutoRefreshWindow() {
        defaults.set(9 * 60, forKey: SettingsKeys.widgetAutoRefreshStartMinutes)
        defaults.set(18 * 60, forKey: SettingsKeys.widgetAutoRefreshEndMinutes)

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.widgetAutoRefreshStartMinutes(), 9 * 60)
        XCTAssertEqual(reader.widgetAutoRefreshEndMinutes(), 18 * 60)
    }

    func testWidgetSettingsReaderDefaultsAutoRefreshWindowToFullDay() {
        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.widgetAutoRefreshStartMinutes(), 0)
        XCTAssertEqual(reader.widgetAutoRefreshEndMinutes(), 23 * 60)
    }

    @MainActor
    func testSettingsStorePersistsArtworkDetailFontScaleStepGlobally() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.artworkDetailFontScaleStep, ArtworkDetailFontScale.defaultStep)

        store.saveArtworkDetailFontScaleStep(2)

        XCTAssertEqual(defaults.integer(forKey: SettingsKeys.artworkDetailFontScaleStep), 2)
        XCTAssertEqual(SettingsStore(defaults: defaults).artworkDetailFontScaleStep, 2)

        store.saveArtworkDetailFontScaleStep(99)

        XCTAssertEqual(
            defaults.integer(forKey: SettingsKeys.artworkDetailFontScaleStep),
            ArtworkDetailFontScale.maximumStep
        )
        XCTAssertEqual(SettingsStore(defaults: defaults).artworkDetailFontScaleStep, ArtworkDetailFontScale.maximumStep)
    }

    @MainActor
    func testSettingsStorePersistsRequestLogAccessUnlocked() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.isRequestLogAccessUnlocked)

        store.saveRequestLogAccessUnlocked(true)

        XCTAssertTrue(defaults.bool(forKey: SettingsKeys.requestLogAccessUnlocked))
        XCTAssertTrue(SettingsStore(defaults: defaults).isRequestLogAccessUnlocked)

        store.saveRequestLogAccessUnlocked(false)

        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.requestLogAccessUnlocked))
        XCTAssertFalse(SettingsStore(defaults: defaults).isRequestLogAccessUnlocked)
    }

    @MainActor
    func testSettingsStorePersistsSelectedSourceAndSeparateCategories() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.selectedSourceKey(for: MuseumIdentifier("nnm")), "official")
        store.saveFeedCategories(
            [MuseumIdentifier("nnm").selectableFeedCategories(sourceKey: "official")[0]],
            for: MuseumIdentifier("nnm"),
            sourceKey: "official"
        )
        store.saveSelectedSourceKey("colbase", for: MuseumIdentifier("nnm"))
        store.saveFeedCategories(
            [MuseumIdentifier("nnm").selectableFeedCategories(sourceKey: "colbase")[2]],
            for: MuseumIdentifier("nnm"),
            sourceKey: "colbase"
        )

        let reloaded = SettingsStore(defaults: defaults)

        XCTAssertEqual(reloaded.selectedSourceKey(for: MuseumIdentifier("nnm")), "colbase")
        XCTAssertEqual(reloaded.feedCategories(for: MuseumIdentifier("nnm")).map(\.id), ["paint"])
        XCTAssertEqual(
            reloaded.feedCategories(for: MuseumIdentifier("nnm"), sourceKey: "official").map(\.id),
            ["official-sculpture"]
        )
    }

    @MainActor
    func testSettingsStoreExportsAndImportsConfiguration() async throws {
        let sourceWidgetStore = WidgetArtworkSnapshotStore(baseURL: temporaryBaseURL())
        await sourceWidgetStore.replaceDisplayedArtworkHistory([
            MuseumIdentifier("met").rawValue: [WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "seen")]
        ])
        defaults.set(6, forKey: SettingsKeys.widgetRefreshIntervalHours)
        defaults.set(8 * 60, forKey: SettingsKeys.widgetAutoRefreshStartMinutes)
        defaults.set(20 * 60, forKey: SettingsKeys.widgetAutoRefreshEndMinutes)
        defaults.set(2, forKey: SettingsKeys.artworkDetailFontScaleStep)
        defaults.set(true, forKey: SettingsKeys.requestLogAccessUnlocked)
        setFeedPreference(
            museumID: MuseumIdentifier("met"),
            selectedSourceKey: "met_on_view",
            categoriesBySource: [
                "met_on_view": ["american-decorative-arts", "modern-art"]
            ],
            in: defaults
        )
        setFeedPreference(
            museumID: MuseumIdentifier("nnm"),
            selectedSourceKey: "colbase",
            in: defaults
        )
        defaults.set("list", forKey: SettingsKeys.feedDisplayModePrefix + MuseumIdentifier("met").rawValue)
        defaults.set(Data([1, 2, 3]), forKey: SettingsKeys.favoritesArtworks)

        let sourceStore = SettingsStore(defaults: defaults, widgetSnapshotStore: sourceWidgetStore)
        let exportedConfiguration = await sourceStore.makeConfigurationExport()

        let targetSuiteName = "WidgetStateAndSettingsTests.import.\(UUID().uuidString)"
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: targetSuiteName))
        defer {
            targetDefaults.removePersistentDomain(forName: targetSuiteName)
        }
        targetDefaults.set(1, forKey: SettingsKeys.widgetRefreshIntervalHours)
        targetDefaults.set(-1, forKey: SettingsKeys.artworkDetailFontScaleStep)
        setFeedPreference(
            museumID: MuseumIdentifier("met"),
            selectedSourceKey: "met_on_view",
            categoriesBySource: [
                "met_on_view": ["photographs"]
            ],
            in: targetDefaults
        )
        let targetWidgetStore = WidgetArtworkSnapshotStore(baseURL: temporaryBaseURL())
        await targetWidgetStore.replaceDisplayedArtworkHistory([
            MuseumIdentifier("tnm").rawValue: [WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("tnm"), objectID: "old")]
        ])
        let targetStore = SettingsStore(defaults: targetDefaults, widgetSnapshotStore: targetWidgetStore)

        await targetStore.importConfiguration(exportedConfiguration)

        XCTAssertEqual(targetStore.widgetRefreshInterval, .sixHours)
        XCTAssertEqual(targetStore.widgetAutoRefreshStartMinutes, 8 * 60)
        XCTAssertEqual(targetStore.widgetAutoRefreshEndMinutes, 20 * 60)
        XCTAssertEqual(targetStore.artworkDetailFontScaleStep, 2)
        XCTAssertEqual(targetDefaults.integer(forKey: SettingsKeys.artworkDetailFontScaleStep), 2)
        XCTAssertTrue(targetStore.isRequestLogAccessUnlocked)
        XCTAssertEqual(targetStore.selectedSourceKey(for: MuseumIdentifier("met")), "met_on_view")
        XCTAssertEqual(targetStore.selectedSourceKey(for: MuseumIdentifier("nnm")), "colbase")
        XCTAssertEqual(targetStore.feedCategories(for: MuseumIdentifier("met")).map(\.id), ["american-decorative-arts", "modern-art"])
        XCTAssertEqual(targetStore.feedDisplayModeRawValue(for: MuseumIdentifier("met")), "list")
        XCTAssertEqual(targetDefaults.data(forKey: SettingsKeys.favoritesArtworks), Data([1, 2, 3]))
        let importedMetHistory = await targetWidgetStore.displayedArtworkKeys(for: MuseumIdentifier("met"))
        let importedTokyoHistory = await targetWidgetStore.displayedArtworkKeys(for: MuseumIdentifier("tnm"))

        XCTAssertEqual(importedMetHistory, [WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "seen")])
        XCTAssertEqual(importedTokyoHistory, [])
    }

    func testWidgetAutoRefreshWindowNormalizesEndNotEarlierThanStart() {
        let window = WidgetAutoRefreshWindow(startMinutes: 18 * 60, endMinutes: 9 * 60)

        XCTAssertEqual(window.startMinutes, 18 * 60)
        XCTAssertEqual(window.endMinutes, 18 * 60)
    }

    func testWidgetAutoRefreshWindowRoundsStoredMinutesDownToWholeHour() {
        defaults.set(9 * 60 + 45, forKey: SettingsKeys.widgetAutoRefreshStartMinutes)
        defaults.set(18 * 60 + 59, forKey: SettingsKeys.widgetAutoRefreshEndMinutes)

        let reader = WidgetSettingsReader(defaults: defaults)

        XCTAssertEqual(reader.widgetAutoRefreshStartMinutes(), 9 * 60)
        XCTAssertEqual(reader.widgetAutoRefreshEndMinutes(), 18 * 60)
    }

    func testWidgetAutoRefreshScheduleGeneratesExpectedDailyDates() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let schedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .threeHours,
                startMinutes: 9 * 60,
                endMinutes: 18 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )

        let refreshDates = schedule.refreshDates(forDayContaining: date(hour: 8, minute: 0, calendar: calendar))

        XCTAssertEqual(
            refreshDates.map { timeText(for: $0, calendar: calendar) },
            ["09:00", "12:00", "15:00", "18:00"]
        )
    }

    func testWidgetAutoRefreshScheduleKeepsOnlyStartWhenWindowIsShorterThanInterval() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let schedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .threeHours,
                startMinutes: 10 * 60,
                endMinutes: 11 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )

        let refreshDates = schedule.refreshDates(forDayContaining: date(hour: 9, minute: 0, calendar: calendar))

        XCTAssertEqual(
            refreshDates.map { timeText(for: $0, calendar: calendar) },
            ["10:00"]
        )
    }

    func testWidgetAutoRefreshScheduleReturnsNextDayStartAfterWindowEnds() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let schedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .threeHours,
                startMinutes: 9 * 60,
                endMinutes: 18 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )

        let nextRefreshDate = schedule.nextRefreshDate(after: date(hour: 19, minute: 0, calendar: calendar))

        XCTAssertEqual(
            timeText(for: try XCTUnwrap(nextRefreshDate), calendar: calendar),
            "09:00"
        )
        XCTAssertFalse(
            calendar.isDate(
                date(hour: 19, minute: 0, calendar: calendar),
                inSameDayAs: try XCTUnwrap(nextRefreshDate)
            )
        )
    }

    func testWidgetScheduledRefreshPolicyDoesNotRefreshWhenAutomaticRefreshIsOff() {
        let now = Date(timeIntervalSince1970: 30_000)
        let resolution = WidgetScheduledRefreshPolicy.resolve(
            state: nil,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            schedule: nil,
            now: now
        )

        XCTAssertFalse(resolution.shouldRefresh)
        XCTAssertNil(resolution.scheduledAt)
        XCTAssertNil(resolution.nextAutomaticRefreshAt)
        XCTAssertNil(resolution.scheduleSignature)
    }

    func testWidgetScheduledRefreshPolicyRecomputesFutureSlotWhenScheduleChanges() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let now = date(hour: 10, minute: 30, calendar: calendar)
        let oldSchedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .oneHour,
                startMinutes: 9 * 60,
                endMinutes: 18 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )
        let newSchedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .threeHours,
                startMinutes: 9 * 60,
                endMinutes: 18 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )
        let state = makeWidgetState(
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            phase: .success,
            lastUpdatedAt: now.timeIntervalSince1970,
            nextAutomaticRefreshAt: date(hour: 11, minute: 0, calendar: calendar).timeIntervalSince1970,
            automaticRefreshScheduleSignature: oldSchedule.signature
        )

        let resolution = WidgetScheduledRefreshPolicy.resolve(
            state: state,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            schedule: newSchedule,
            now: now
        )

        XCTAssertFalse(resolution.shouldRefresh)
        XCTAssertNil(resolution.scheduledAt)
        XCTAssertEqual(resolution.nextAutomaticRefreshAt, date(hour: 12, minute: 0, calendar: calendar))
        XCTAssertEqual(resolution.scheduleSignature, newSchedule.signature)
    }

    func testWidgetScheduledRefreshPolicyRefreshesWhenDue() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let schedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .threeHours,
                startMinutes: 9 * 60,
                endMinutes: 18 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )
        let scheduledAt = date(hour: 12, minute: 0, calendar: calendar)
        let state = makeWidgetState(
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            phase: .success,
            lastUpdatedAt: scheduledAt.timeIntervalSince1970,
            nextAutomaticRefreshAt: scheduledAt.timeIntervalSince1970,
            automaticRefreshScheduleSignature: schedule.signature
        )

        let resolution = WidgetScheduledRefreshPolicy.resolve(
            state: state,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            schedule: schedule,
            now: scheduledAt
        )

        XCTAssertTrue(resolution.shouldRefresh)
        XCTAssertEqual(resolution.scheduledAt, scheduledAt)
        XCTAssertEqual(resolution.nextAutomaticRefreshAt, date(hour: 15, minute: 0, calendar: calendar))
    }

    func testWidgetScheduledRefreshPolicyKeepsFutureSlotBeforeItIsDue() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let schedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .sixHours,
                startMinutes: 8 * 60,
                endMinutes: 20 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )
        let nextAutomaticRefreshAt = date(hour: 14, minute: 0, calendar: calendar)
        let state = makeWidgetState(
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue,
            phase: .success,
            lastUpdatedAt: date(hour: 8, minute: 0, calendar: calendar).timeIntervalSince1970,
            nextAutomaticRefreshAt: nextAutomaticRefreshAt.timeIntervalSince1970,
            automaticRefreshScheduleSignature: schedule.signature
        )

        let resolution = WidgetScheduledRefreshPolicy.resolve(
            state: state,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue,
            schedule: schedule,
            now: date(hour: 13, minute: 59, calendar: calendar)
        )

        XCTAssertFalse(resolution.shouldRefresh)
        XCTAssertNil(resolution.scheduledAt)
        XCTAssertEqual(resolution.nextAutomaticRefreshAt, nextAutomaticRefreshAt)
    }

    func testWidgetRefreshGroupKeyUsesScopeOnly() {
        let key = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("met")),
            family: .systemLarge
        )

        XCTAssertEqual(key, "single:met")
    }

    func testWidgetRefreshGroupKeyIgnoresFamily() {
        let smallKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("tnm")),
            family: .systemSmall
        )
        let mediumKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("tnm")),
            family: .systemMedium
        )

        XCTAssertEqual(smallKey, mediumKey)
    }

    func testWidgetRefreshGroupKeyFallsBackToScopeForMissingFamily() {
        let key = WidgetRefreshGroupKey.make(
            scope: .all,
            family: nil
        )

        XCTAssertEqual(key, "all")
    }

    func testArtworkBatchLoaderLoadsTokyoFromBackendInTenItemPagesAndAdvancesCursor() async throws {
        let recorder = WidgetRequestRecorder()
        let testID = UUID().uuidString

        let session = makeStubSession(testID: testID) { [self] request in
            let url = try XCTUnwrap(request.url)
            recorder.record(url)

            if url.path == "/v1/museums/tnm/artworks" {
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let queryItems = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(queryItems["limit"], "10")
                XCTAssertEqual(queryItems["order"], "stable")
                let ids: [Int]
                let nextCursor: Any
                let hasMore: Bool
                switch queryItems["cursor"] {
                case nil:
                    ids = Array(1...10)
                    nextCursor = "cursor-10"
                    hasMore = true
                case "cursor-10":
                    ids = Array(11...20)
                    nextCursor = NSNull()
                    hasMore = false
                default:
                    XCTFail("Unexpected cursor: \(queryItems["cursor"] ?? "nil")")
                    ids = []
                    nextCursor = NSNull()
                    hasMore = false
                }

                return self.makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "dataVersion": "test-version",
                        "data": [
                            "items": ids.map {
                                self.makeBackendArtworkDictionary(
                                    museumID: MuseumIdentifier("tnm"),
                                    objectID: "item-\($0)",
                                    title: "Title item-\($0)"
                                )
                            },
                            "nextCursor": nextCursor,
                            "hasMore": hasMore
                        ]
                    ]
                )
            }

            XCTFail("Unexpected URL: \(url.absoluteString)")
            return self.makeJSONResponse(url: url, jsonObject: [:])
        }
        let backendClient = MuseumBackendClient(baseURL: URL(string: "https://backend.example")!, session: session)

        let loader = ArtworkBatchLoader(
            museumID: MuseumIdentifier("tnm"),
            categories: MuseumIdentifier("tnm").defaultFeedCategories,
            randomOrder: false,
            cachePolicy: .networkOnly,
            backendClient: backendClient
        )

        let firstBatch = try await loader.nextBatch(count: 10)
        let secondBatch = try await loader.nextBatch(count: 10)

        XCTAssertEqual(firstBatch.count, 10)
        XCTAssertEqual(secondBatch.count, 10)

        let backendRequests = recorder.urls.filter { $0.path == "/v1/museums/tnm/artworks" }
        let cursors = backendRequests.map {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "cursor" })?
                .value
        }
        XCTAssertEqual(backendRequests.count, 2)
        XCTAssertEqual(cursors, [nil, "cursor-10"])
    }

    func testArtworkBatchLoaderLoadsNaraOfficialSourceWithOfficialDepartment() async throws {
        let recorder = WidgetRequestRecorder()
        let testID = UUID().uuidString

        let session = makeStubSession(testID: testID) { [self] request in
            let url = try XCTUnwrap(request.url)
            recorder.record(url)

            if url.path == "/v1/museums/nnm/artworks" {
                let queryItems = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(queryItems["source"], "official")
                XCTAssertEqual(queryItems["category_ids"], "official-sculpture")
                return makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "dataVersion": "test-version",
                        "data": [
                            "items": [
                                makeBackendArtworkDictionary(
                                    museumID: MuseumIdentifier("nnm"),
                                    objectID: "narahaku-1032-0",
                                    title: "浮雕佛传图",
                                    department: "雕刻",
                                    primaryImageURL: "https://www.narahaku.go.jp/_fKkxXPHb/D025456.jpg"
                                )
                            ],
                            "nextCursor": NSNull(),
                            "hasMore": false
                        ]
                    ]
                )
            }

            XCTFail("Unexpected URL: \(url.absoluteString)")
            return WidgetStubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                data: Data()
            )
        }
        let backendClient = MuseumBackendClient(baseURL: URL(string: "https://backend.example")!, session: session)

        let loader = ArtworkBatchLoader(
            museumID: MuseumIdentifier("nnm"),
            sourceKey: "official",
            categories: [MuseumIdentifier("nnm").selectableFeedCategories(sourceKey: "official")[0]],
            randomOrder: false,
            cachePolicy: .networkOnly,
            backendClient: backendClient
        )

        let batch = try await loader.nextBatch(count: 1)

        XCTAssertEqual(batch.map(\.objectID), ["narahaku-1032-0"])
        XCTAssertEqual(batch.first?.title, "浮雕佛传图")
        XCTAssertEqual(batch.first?.department, "雕刻")
        XCTAssertEqual(batch.first?.primaryImageURL?.absoluteString, "https://www.narahaku.go.jp/_fKkxXPHb/D025456.jpg")
        XCTAssertTrue(recorder.urls.allSatisfy { $0.host == "backend.example" })
    }

    func testArtworkBatchLoaderMetIsNotInitiallyExhaustedAndLoadsFirstBatch() async throws {
        let testID = UUID().uuidString
        let recorder = WidgetRequestRecorder()

        let session = makeStubSession(testID: testID) { [self] request in
            let url = try XCTUnwrap(request.url)
            recorder.record(url)

            if url.path == "/v1/museums/met/artworks" {
                return self.makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "dataVersion": "test-version",
                        "data": [
                            "items": [
                                self.makeBackendArtworkDictionary(
                                    museumID: MuseumIdentifier("met"),
                                    objectID: "101",
                                    title: "Met Test Artwork"
                                )
                            ],
                            "nextCursor": NSNull(),
                            "hasMore": false
                        ]
                    ]
                )
            }

            XCTFail("Unexpected URL: \(url.absoluteString)")
            return self.makeJSONResponse(url: url, jsonObject: [:])
        }

        let loader = ArtworkBatchLoader(
            museumID: MuseumIdentifier("met"),
            categories: MuseumIdentifier("met").defaultFeedCategories,
            randomOrder: false,
            cachePolicy: .networkOnly,
            backendClient: MuseumBackendClient(baseURL: URL(string: "https://backend.example")!, session: session)
        )

        let isInitiallyExhausted = await loader.isExhausted()
        XCTAssertFalse(isInitiallyExhausted)

        let batch = try await loader.nextBatch(count: 10)

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.museumID, MuseumIdentifier("met"))
        XCTAssertEqual(batch.first?.title, "Met Test Artwork")

        let searchURL = try XCTUnwrap(recorder.urls.first(where: { $0.path == "/v1/museums/met/artworks" }))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        XCTAssertNil(queryItems["only_on_view"])
    }

    func testArtworkBatchLoaderMetOnViewSourceUsesSourceQuery() async throws {
        let testID = UUID().uuidString
        let recorder = WidgetRequestRecorder()

        let session = makeStubSession(testID: testID) { [self] request in
            let url = try XCTUnwrap(request.url)
            recorder.record(url)

            if url.path == "/v1/museums/met/artworks" {
                return self.makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "dataVersion": "test-version",
                        "data": [
                            "items": [
                                self.makeBackendArtworkDictionary(
                                    museumID: MuseumIdentifier("met"),
                                    objectID: "101",
                                    title: "Met On View Artwork"
                                )
                            ],
                            "nextCursor": NSNull(),
                            "hasMore": false
                        ]
                    ]
                )
            }

            XCTFail("Unexpected URL: \(url.absoluteString)")
            return self.makeJSONResponse(url: url, jsonObject: [:])
        }

        let loader = ArtworkBatchLoader(
            museumID: MuseumIdentifier("met"),
            sourceKey: "met_on_view",
            categories: MuseumIdentifier("met").defaultFeedCategories(sourceKey: "met_on_view"),
            randomOrder: false,
            cachePolicy: .networkOnly,
            backendClient: MuseumBackendClient(baseURL: URL(string: "https://backend.example")!, session: session)
        )

        let batch = try await loader.nextBatch(count: 10)

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.title, "Met On View Artwork")

        let searchURL = try XCTUnwrap(recorder.urls.first(where: { $0.path == "/v1/museums/met/artworks" }))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(queryItems["source"], "met_on_view")
        XCTAssertNil(queryItems["only_on_view"])
    }

    func testDefaultWidgetRefreshEngineUsesBackendForNationalMuseumChinaScope() async throws {
        let recorder = WidgetRequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { [self] request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(url)

            if url.path == "/v1/museums/nmc/artworks" {
                return makeJSONResponse(
                    url: url,
                    jsonObject: [
                        "dataVersion": "test-version",
                        "data": [
                            "items": [
                                makeBackendArtworkDictionary(museumID: MuseumIdentifier("nmc"), objectID: "801", title: "后母戊鼎")
                            ],
                            "nextCursor": NSNull(),
                            "hasMore": false
                        ]
                    ]
                )
            }

            throw URLError(.badURL)
        }
        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            randomIndex: { _ in 0 },
            imageDataFetcher: { _, _ in widgetValidPNGData },
            backendClient: MuseumBackendClient(baseURL: URL(string: "https://backend.example")!, session: session)
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: .single(MuseumIdentifier("nmc")),
            refreshKey: "nmc-backend",
            logSource: "WidgetBackendNMC"
        )

        XCTAssertEqual(payload.museumID, MuseumIdentifier("nmc"))
        XCTAssertEqual(payload.title, "后母戊鼎")
        XCTAssertTrue(recorder.urls.allSatisfy { $0.host == "backend.example" })
    }

    func testWidgetPreferredImageURLDecisionUsesThumbnailForColbaseWidgets() {
        let smallURL = URL(string: "https://example.com/small.jpg")
        let largeURL = URL(string: "https://example.com/large.jpg")
        let tokyoArtwork = Artwork(
            id: "tnm-1",
            museumID: MuseumIdentifier("tnm"),
            sourceKey: "japan_search",
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
        let naraArtwork = Artwork(
            id: "nnm-1",
            museumID: MuseumIdentifier("nnm"),
            sourceKey: "colbase",
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
        let naraOfficialArtwork = Artwork(
            id: "nnm-narahaku-1032-0",
            museumID: MuseumIdentifier("nnm"),
            sourceKey: "official",
            objectID: "narahaku-1032-0",
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
            WidgetPreferredImageURLDecision.resolve(for: tokyoArtwork, museumID: MuseumIdentifier("tnm")),
            smallURL
        )
        XCTAssertEqual(
            WidgetPreferredImageURLDecision.resolveCandidates(for: tokyoArtwork, museumID: MuseumIdentifier("tnm")),
            [smallURL!, largeURL!]
        )
        XCTAssertEqual(
            WidgetPreferredImageURLDecision.resolveCandidates(for: naraArtwork, museumID: MuseumIdentifier("nnm")),
            [smallURL!, largeURL!]
        )
        XCTAssertEqual(
            WidgetPreferredImageURLDecision.resolveCandidates(for: naraOfficialArtwork, museumID: MuseumIdentifier("nnm")),
            [largeURL!, smallURL!]
        )
    }

    func testWidgetImageRequestPolicyAddsBrowserHeadersForTokyoColbaseImage() {
        let url = URL(string: "https://colbase.nich.go.jp/media/tnm/A-9900/image/slideshow_s/A-9900_E0175464.jpg")!

        let request = WidgetImageRequestPolicy.makeRequest(
            url: url,
            timeout: 3,
            headers: MuseumMetadataStore.cachedSourceMetadata(museumID: MuseumIdentifier("tnm"), sourceKey: "japan_search")?.imageRequestHeaders ?? [:]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://colbase.nich.go.jp/")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testWidgetImageRequestPolicyAddsBrowserHeadersForNaraOfficialImage() {
        let url = URL(string: "https://www.narahaku.go.jp/photo/exhibition/D025456.jpg")!

        let request = WidgetImageRequestPolicy.makeRequest(
            url: url,
            timeout: 3,
            headers: MuseumMetadataStore.cachedSourceMetadata(museumID: MuseumIdentifier("nnm"), sourceKey: "official")?.imageRequestHeaders ?? [:]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.narahaku.go.jp/chinese/collection/")
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
                makeArtwork(museumID: MuseumIdentifier("met"), objectID: "missing", title: "No Image", imageURL: nil),
                makeArtwork(museumID: MuseumIdentifier("met"), objectID: "flaky", title: "Flaky", imageURL: flakyURL),
                makeArtwork(museumID: MuseumIdentifier("met"), objectID: "success", title: "Success", imageURL: successURL),
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
            scope: .single(MuseumIdentifier("met")),
            refreshKey: "widget-met",
            logSource: "WidgetEngineTest"
        )

        XCTAssertEqual(payload.title, "Success")
        XCTAssertEqual(payload.museumID, MuseumIdentifier("met"))
        let requestedCandidates = await loader.requestedCandidateCount()
        let flakyAttempts = await attempts.value(for: flakyURL)
        let successAttempts = await attempts.value(for: successURL)
        XCTAssertEqual(requestedCandidates, 3)
        XCTAssertEqual(flakyAttempts, 3)
        XCTAssertEqual(successAttempts, 1)
    }

    func testWidgetRefreshEngineDownsamplesPayloadImageBeforeReturning() async throws {
        let imageURL = URL(string: "https://example.com/nara-large.jpg")!
        let sourceData = makeJPEGData(size: CGSize(width: 2400, height: 1600))
        let sourceDimensions = try XCTUnwrap(WidgetArtworkSnapshotStore.imageDimensions(from: sourceData))
        let loader = StubBatchLoader(
            batches: [[
                makeArtwork(
                    museumID: MuseumIdentifier("nnm"),
                    objectID: "narahaku-large",
                    title: "Large Nara Image",
                    imageURL: imageURL
                )
            ]]
        )
        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            loaderFactory: { _, _, _ in loader },
            randomIndex: { _ in 0 },
            imageDataFetcher: { _, _ in sourceData }
        )

        let payload = try await engine.fetchRenderableArtwork(
            scope: .single(MuseumIdentifier("nnm")),
            refreshKey: "single:nnm",
            logSource: "WidgetEngineDownsample"
        )
        let payloadDimensions = try XCTUnwrap(WidgetArtworkSnapshotStore.imageDimensions(from: payload.imageData))

        XCTAssertGreaterThan(max(sourceDimensions.width, sourceDimensions.height), 1024)
        XCTAssertLessThanOrEqual(max(payloadDimensions.width, payloadDimensions.height), 1024)
        XCTAssertLessThanOrEqual(payloadDimensions.width * payloadDimensions.height, 1_000_000)
        XCTAssertEqual(
            CGFloat(payloadDimensions.width) / CGFloat(payloadDimensions.height),
            CGFloat(sourceDimensions.width) / CGFloat(sourceDimensions.height),
            accuracy: 0.02
        )
    }

    func testWidgetRefreshEngineStopsAfterFirstRenderableCandidate() async throws {
        let loader = StubBatchLoader(
            batches: [[
                makeArtwork(
                    museumID: MuseumIdentifier("tnm"),
                    objectID: "first",
                    title: "First Success",
                    imageURL: URL(string: "https://example.com/first.jpg")
                ),
                makeArtwork(
                    museumID: MuseumIdentifier("tnm"),
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
            scope: .single(MuseumIdentifier("tnm")),
            refreshKey: "widget-tnm",
            logSource: "WidgetEngineSingleSuccess"
        )

        XCTAssertEqual(payload.title, "First Success")
        XCTAssertEqual(payload.museumID, MuseumIdentifier("tnm"))
        let requestedCandidates = await loader.requestedCandidateCount()
        XCTAssertEqual(requestedCandidates, 1)
    }

    func testWidgetRefreshEngineSkipsPreviouslyDisplayedArtworkForSameMuseumAfterInstanceRemoval() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met"))
        let refreshKey = WidgetRefreshGroupKey.make(scope: scope, family: nil)
        _ = await store.beginRefresh(instanceToken: refreshKey, scopeRawValue: scope.rawValue)
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: WidgetRefreshPayload(
                museumID: MuseumIdentifier("met"),
                artworkKey: WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "seen"),
                museumName: MuseumIdentifier("met").displayName,
                title: "Seen",
                subtitle: "2026",
                imageData: widgetValidPNGData,
                appURL: URL(string: "https://example.com/seen")
            ).storedPayload(),
            imageData: nil
        )
        await store.removeInstances(excludingRefreshKeys: [])

        let loader = StubBatchLoader(
            batches: [[
                makeArtwork(
                    museumID: MuseumIdentifier("met"),
                    objectID: "seen",
                    title: "Seen",
                    imageURL: URL(string: "https://example.com/seen.jpg")
                ),
                makeArtwork(
                    museumID: MuseumIdentifier("met"),
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
            refreshKey: refreshKey,
            logSource: "WidgetHistorySkip"
        )

        XCTAssertEqual(payload.title, "Fresh")
        XCTAssertEqual(payload.artworkKey, WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "fresh"))
        let requestedCandidates = await loader.requestedCandidateCount()
        XCTAssertEqual(requestedCandidates, 2)
    }

    func testWidgetRefreshEngineClearsDisplayedHistoryOnceWhenOnlySeenCandidatesRemain() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met"))
        let refreshKey = WidgetRefreshGroupKey.make(scope: scope, family: nil)
        _ = await store.beginRefresh(instanceToken: refreshKey, scopeRawValue: scope.rawValue)
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: WidgetRefreshPayload(
                museumID: MuseumIdentifier("met"),
                artworkKey: WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "repeat"),
                museumName: MuseumIdentifier("met").displayName,
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
                        museumID: MuseumIdentifier("met"),
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
            refreshKey: refreshKey,
            logSource: "WidgetHistoryReset"
        )

        XCTAssertEqual(payload.title, "Repeat")
        XCTAssertEqual(loaderFactoryCount.value, 2)
        let displayedKeys = await store.displayedArtworkKeys(for: MuseumIdentifier("met"))
        XCTAssertEqual(displayedKeys, [])
    }

    func testWidgetRefreshEngineAllMuseumsUsesInjectedSelectionOrder() async throws {
        let selectedRanges = RangeRecorder()
        let metArtwork = makeArtwork(
            museumID: MuseumIdentifier("met"),
            objectID: "met-1",
            title: "Met",
            imageURL: URL(string: "https://example.com/met.jpg")
        )
        let tnmArtwork = makeArtwork(
            museumID: MuseumIdentifier("tnm"),
            objectID: "tnm-1",
            title: "TNM",
            imageURL: URL(string: "https://example.com/tnm.jpg")
        )

        let engine = WidgetRefreshEngine(
            settingsReader: WidgetSettingsReader(defaults: defaults),
            loaderFactory: { museumID, _, _ in
                switch museumID {
                case MuseumIdentifier("met"):
                    return StubBatchLoader(batches: [[metArtwork]])
                case MuseumIdentifier("tnm"):
                    return StubBatchLoader(batches: [[tnmArtwork]])
                case MuseumIdentifier("nnm"), MuseumIdentifier("nmc"), MuseumIdentifier("shm"), MuseumIdentifier("guimet"):
                    return StubBatchLoader(batches: [])
                default:
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
            refreshKey: "widget-all",
            logSource: "WidgetEngineAllMuseums"
        )

        XCTAssertEqual(payload.museumID, MuseumIdentifier("tnm"))
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
        let refreshKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("met")),
            family: .systemSmall
        )

        let firstTask = Task {
            await coordinator.refresh(
                refreshKey: refreshKey,
                scope: .single(MuseumIdentifier("met")),
                familyToken: WidgetFamily.systemSmall.debugToken,
                logSource: "CoordinatorPreempt"
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let secondTask = Task {
            await coordinator.refresh(
                refreshKey: refreshKey,
                scope: .single(MuseumIdentifier("met")),
                familyToken: WidgetFamily.systemSmall.debugToken,
                logSource: "CoordinatorPreempt"
            )
        }

        await firstTask.value
        await secondTask.value

        let state = await store.state(for: refreshKey)
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
        let metKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("met")),
            family: .systemSmall
        )
        let tnmKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("tnm")),
            family: .systemSmall
        )

        async let firstRefresh: Void = coordinator.refresh(
            refreshKey: metKey,
            scope: .single(MuseumIdentifier("met")),
            familyToken: WidgetFamily.systemSmall.debugToken,
            logSource: "CoordinatorIndependent"
        )
        async let secondRefresh: Void = coordinator.refresh(
            refreshKey: tnmKey,
            scope: .single(MuseumIdentifier("tnm")),
            familyToken: WidgetFamily.systemSmall.debugToken,
            logSource: "CoordinatorIndependent"
        )
        _ = await (firstRefresh, secondRefresh)

        let firstState = await store.state(for: metKey)
        let secondState = await store.state(for: tnmKey)

        XCTAssertEqual(firstState?.artwork?.museumID, MuseumIdentifier("met"))
        XCTAssertEqual(secondState?.artwork?.museumID, MuseumIdentifier("tnm"))
        XCTAssertEqual(firstState?.phase, .success)
        XCTAssertEqual(secondState?.phase, .success)
    }

    func testWidgetRefreshCoordinatorSharesSameScopeAcrossFamilies() async throws {
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

        let smallKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("met")),
            family: .systemSmall
        )
        let mediumKey = WidgetRefreshGroupKey.make(
            scope: .single(MuseumIdentifier("met")),
            family: .systemMedium
        )

        XCTAssertEqual(smallKey, mediumKey)

        async let firstRefresh: Void = coordinator.refresh(
            refreshKey: smallKey,
            scope: .single(MuseumIdentifier("met")),
            familyToken: WidgetFamily.systemSmall.debugToken,
            logSource: "CoordinatorSameScope"
        )
        async let secondRefresh: Void = coordinator.refresh(
            refreshKey: mediumKey,
            scope: .single(MuseumIdentifier("met")),
            familyToken: WidgetFamily.systemMedium.debugToken,
            logSource: "CoordinatorSameScope"
        )
        _ = await (firstRefresh, secondRefresh)

        let firstState = await store.state(for: smallKey)
        let secondState = await store.state(for: mediumKey)

        XCTAssertEqual(firstState?.phase, .success)
        XCTAssertEqual(secondState?.phase, .success)
        XCTAssertEqual(firstState?.artwork?.title, secondState?.artwork?.title)
        XCTAssertEqual(firstState?.scopeRawValue, WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue)
        XCTAssertEqual(secondState?.scopeRawValue, WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue)
    }

    func testWidgetRefreshCoordinatorRefreshesOnlyCurrentWidgetConfigurations() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let staleAllKey = WidgetMuseumScope.all.rawValue
        let metKey = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        _ = await store.renderState(
            for: staleAllKey,
            scopeRawValue: staleAllKey,
            familyToken: WidgetFamily.systemLarge.debugToken
        )
        _ = await store.renderState(
            for: metKey,
            scopeRawValue: metKey,
            familyToken: WidgetFamily.systemSmall.debugToken
        )

        let engineCreations = IntRecorder()
        let coordinator = WidgetRefreshCoordinator(
            store: store,
            widgetCenter: .shared,
            currentConfigurationResolver: StubCurrentConfigurationResolver(targets: [
                WidgetRefreshTarget(
                    refreshKey: metKey,
                    scope: .single(MuseumIdentifier("met")),
                    familyToken: WidgetFamily.systemSmall.debugToken
                ),
                WidgetRefreshTarget(
                    refreshKey: metKey,
                    scope: .single(MuseumIdentifier("met")),
                    familyToken: WidgetFamily.systemMedium.debugToken
                )
            ]),
            makeEngine: { [self] in
                engineCreations.increment()
                return WidgetRefreshEngine(
                    snapshotStore: store,
                    loaderFactory: { [self] museumID, _, _ in
                        StubBatchLoader(batches: [[
                            self.makeArtwork(
                                museumID: museumID,
                                objectID: "current",
                                title: "Current Widget",
                                imageURL: URL(string: "https://example.com/current.png")
                            )
                        ]])
                    },
                    randomIndex: { _ in 0 },
                    imageDataFetcher: { _, _ in widgetValidPNGData }
                )
            }
        )

        await coordinator.refreshAllKnownInstances(logSource: "CoordinatorCurrentConfigurations")

        let staleAllState = await store.state(for: staleAllKey)
        let metState = await store.state(for: metKey)

        XCTAssertEqual(engineCreations.value, 1)
        XCTAssertNil(staleAllState)
        XCTAssertEqual(metState?.phase, .success)
        XCTAssertEqual(metState?.artwork?.title, "Current Widget")
    }

    func testWidgetRefreshCoordinatorDoesNotFallBackToStaleInstancesWhenCurrentConfigurationsAreEmpty() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let staleAllKey = WidgetMuseumScope.all.rawValue
        _ = await store.renderState(
            for: staleAllKey,
            scopeRawValue: staleAllKey,
            familyToken: WidgetFamily.systemLarge.debugToken
        )

        let engineCreations = IntRecorder()
        let coordinator = WidgetRefreshCoordinator(
            store: store,
            widgetCenter: .shared,
            currentConfigurationResolver: StubCurrentConfigurationResolver(targets: []),
            makeEngine: {
                engineCreations.increment()
                return WidgetRefreshEngine(snapshotStore: store)
            }
        )

        await coordinator.refreshAllKnownInstances(logSource: "CoordinatorCurrentConfigurationsEmpty")

        let staleAllState = await store.state(for: staleAllKey)

        XCTAssertEqual(engineCreations.value, 0)
        XCTAssertNil(staleAllState)
    }

    func testWidgetRefreshCoordinatorSkipsWidgetButtonRefreshForMissingCurrentConfiguration() async throws {
        let baseURL = temporaryBaseURL()
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let staleAllKey = WidgetMuseumScope.all.rawValue
        let metKey = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        _ = await store.renderState(
            for: staleAllKey,
            scopeRawValue: staleAllKey,
            familyToken: WidgetFamily.systemLarge.debugToken
        )

        let engineCreations = IntRecorder()
        let coordinator = WidgetRefreshCoordinator(
            store: store,
            widgetCenter: .shared,
            currentConfigurationResolver: StubCurrentConfigurationResolver(targets: [
                WidgetRefreshTarget(
                    refreshKey: metKey,
                    scope: .single(MuseumIdentifier("met")),
                    familyToken: WidgetFamily.systemSmall.debugToken
                )
            ]),
            makeEngine: {
                engineCreations.increment()
                return WidgetRefreshEngine(snapshotStore: store)
            }
        )

        await coordinator.refreshCurrentConfiguration(
            refreshKey: staleAllKey,
            scope: .all,
            familyToken: WidgetFamily.systemLarge.debugToken,
            logSource: "CoordinatorMissingCurrentConfiguration"
        )

        let staleAllState = await store.state(for: staleAllKey)

        XCTAssertEqual(engineCreations.value, 0)
        XCTAssertNil(staleAllState)
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

    private func setFeedPreference(
        museumID: MuseumID,
        selectedSourceKey: String? = nil,
        categoriesBySource: [String: [String]] = [:],
        in defaults: UserDefaults
    ) {
        var preferences: FeedPreferences
        if let data = defaults.data(forKey: SettingsKeys.feedPreferences),
           let decoded = try? JSONDecoder().decode(FeedPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = FeedPreferences()
        }

        var preference = preferences.museums[museumID.rawValue] ?? MuseumFeedPreference()
        if let selectedSourceKey {
            preference.selectedSourceKey = selectedSourceKey
        }
        for (sourceKey, categoryIDs) in categoriesBySource {
            preference.selectedCategoryIDsBySource[sourceKey] = categoryIDs
        }
        preferences.museums[museumID.rawValue] = preference
        defaults.set(try! JSONEncoder().encode(preferences), forKey: SettingsKeys.feedPreferences)
    }

    private func makeJSONResponse(url: URL, jsonObject: Any) -> WidgetStubbedResponse {
        WidgetStubbedResponse(
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            data: try! JSONSerialization.data(withJSONObject: jsonObject)
        )
    }

    private static let naraOfficialSearchHTML = """
    <div class="list clearfix">
      <p data-href="1032-0.html">
        <a href="1032-0.html">
          <i><img src="http://www.narahaku.go.jp/photo/exhibition/D025456.jpg" data-original="http://www.narahaku.go.jp/photo/exhibition/D025456.jpg" alt="浮雕佛传图" /></i>
          <span>浮雕佛传图<br>贵霜王朝<br /> 2世纪</span>
        </a>
      </p>
    </div>
    """

    private static let naraOfficialDetailHTML = """
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

    private static let nationalMuseumChinaDetailHTML = """
    <!DOCTYPE html>
    <html>
    <body>
      <div class="content brief">
        <h1>后母戊鼎</h1>
        <p>商后期</p>
        <p>青铜器</p>
        <p>高133厘米</p>
      </div>
      <div class="content detail">
        <h1>后母戊鼎</h1>
        <p>这是展品介绍。</p>
      </div>
      <img src="/images/ding.jpg" />
    </body>
    </html>
    """

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

    private func makeBackendArtworkDictionary(
        museumID: MuseumID,
        objectID: String,
        title: String,
        department: String? = nil,
        primaryImageURL: String? = nil
    ) -> [String: Any] {
        [
            "id": "\(museumID.rawValue)-\(objectID)",
            "museumID": museumID.rawValue,
            "objectID": objectID,
            "title": title,
            "artworkDescription": NSNull(),
            "artistDisplayName": NSNull(),
            "objectDate": "2026",
            "medium": NSNull(),
            "dimensions": NSNull(),
            "department": department.map { $0 as Any } ?? NSNull(),
            "culture": NSNull(),
            "country": museumID.country,
            "repository": museumID.displayName,
            "primaryImageURL": primaryImageURL ?? "https://example.com/\(objectID)-large.jpg",
            "primaryImageSmallURL": "https://example.com/\(objectID)-small.jpg",
            "objectURL": "https://example.com/\(objectID)"
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

    private func makeJPEGData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor.white.setFill()
            context.fill(
                CGRect(
                    x: size.width / 3,
                    y: 0,
                    width: size.width / 3,
                    height: size.height
                )
            )
        }
    }

    private func temporaryBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetStateAndSettingsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeWidgetState(
        scopeRawValue: String,
        phase: WidgetRefreshPhase,
        lastUpdatedAt: TimeInterval,
        nextAutomaticRefreshAt: TimeInterval? = nil,
        automaticRefreshScheduleSignature: String? = nil
    ) -> WidgetArtworkSnapshotStore.InstanceState {
        WidgetArtworkSnapshotStore.InstanceState(
            instanceToken: scopeRawValue,
            scopeRawValue: scopeRawValue,
            familyToken: nil,
            nonce: 1,
            phase: phase,
            artwork: WidgetArtworkSnapshotStore.ArtworkPayload(
                museumID: MuseumIdentifier("met"),
                artworkKey: WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "1"),
                museumName: MuseumIdentifier("met").displayName,
                title: "Test Artwork",
                subtitle: "2026",
                imageFileName: nil,
                appURL: nil,
                updatedAt: lastUpdatedAt
            ),
            displayedArtworkKeys: [],
            failureMessage: nil,
            lastUpdatedAt: lastUpdatedAt,
            nextAutomaticRefreshAt: nextAutomaticRefreshAt,
            automaticRefreshScheduleSignature: automaticRefreshScheduleSignature
        )
    }

    private func makeCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(hour: Int, minute: Int, calendar: Calendar) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 4,
            day: 24,
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components) ?? .distantPast
    }

    private func timeText(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
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

private struct StubCurrentConfigurationResolver: WidgetCurrentConfigurationResolving {
    let targets: [WidgetRefreshTarget]

    func refreshTargets() async throws -> [WidgetRefreshTarget] {
        targets
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
