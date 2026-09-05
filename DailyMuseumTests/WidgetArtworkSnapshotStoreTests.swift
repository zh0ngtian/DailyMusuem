import UIKit
import WidgetKit
import XCTest

final class WidgetArtworkSnapshotStoreTests: XCTestCase {
    private var baseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetArtworkSnapshotStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
        baseURL = nil
        try super.tearDownWithError()
    }

    func testRegisterAndBeginRefreshCreatePerInstanceState() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(MuseumIdentifier("met")), family: nil)

        let registered = await store.registerInstance(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        )
        let refreshing = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        )
        let reloaded = await store.state(for: refreshKey)

        XCTAssertEqual(registered.phase, .idle)
        XCTAssertEqual(registered.displayedArtworkKeys, [])
        XCTAssertEqual(refreshing.phase, .refreshing)
        XCTAssertEqual(refreshing.nonce, 1)
        XCTAssertEqual(reloaded?.phase, .refreshing)
        XCTAssertEqual(reloaded?.scopeRawValue, WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue)
    }

    func testMarkSuccessStoresImageAndFailureRemovesPreviousPayload() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(MuseumIdentifier("tnm")), family: nil)
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue
        )

        let successState = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("tnm"),
                museumName: "东京国立博物馆",
                title: "一期"
            ),
            imageData: Data("image-a".utf8)
        )
        let imageFileName = try XCTUnwrap(successState?.artwork?.imageFileName)
        let imageURL = baseURL
            .appendingPathComponent("WidgetInstances", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(imageFileName)

        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(successState?.displayedArtworkKeys, [])
        let displayedHistory = await store.displayedArtworkKeys(for: MuseumIdentifier("tnm"))
        XCTAssertEqual(displayedHistory, [WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("tnm"), objectID: "1")])

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue
        )
        let failureState = await store.markFailure(
            instanceToken: refreshKey,
            expectedNonce: 2,
            message: "未找到可展示的展品。"
        )

        XCTAssertEqual(failureState?.phase, .failure)
        XCTAssertNil(failureState?.artwork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testMarkSuccessIgnoresSupersededNonce() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .all, family: nil)
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.all.rawValue
        )
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.all.rawValue
        )

        let outdatedWrite = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "旧结果"
            ),
            imageData: Data("old".utf8)
        )
        let currentState = await store.state(for: refreshKey)

        XCTAssertNil(outdatedWrite)
        XCTAssertEqual(currentState?.nonce, 2)
        XCTAssertEqual(currentState?.phase, .refreshing)
    }

    func testRenderStateDoesNotAdoptOtherInstanceStateForSameScope() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue

        _ = await store.beginRefresh(instanceToken: "success", scopeRawValue: scope)
        _ = await store.markSuccess(
            instanceToken: "success",
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "可展示结果"
            ),
            imageData: nil,
            now: Date(timeIntervalSince1970: 200)
        )

        let rendered = await store.renderState(
            for: "fresh-instance",
            scopeRawValue: scope,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(rendered.instanceToken, "fresh-instance")
        XCTAssertEqual(rendered.scopeRawValue, scope)
        XCTAssertEqual(rendered.phase, .idle)
        XCTAssertNil(rendered.artwork)
    }

    func testRenderStateMigratesLegacySameFamilyStateToSharedKey() async throws {
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        let familyToken = WidgetFamily.systemMedium.debugToken
        let sharedKey = WidgetRefreshGroupKey.make(
            scopeRawValue: scope,
            familyToken: familyToken
        )
        let directoryURL = baseURL.appendingPathComponent("WidgetInstances", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let persistedState = """
        {
          "instances" : [
            {
              "instanceToken" : "initial-token",
              "scopeRawValue" : "single:met",
              "familyToken" : "medium",
              "nonce" : 1,
              "phase" : "success",
              "artwork" : {
                "museumID" : "met",
                "artworkKey" : "met|1",
                "museumName" : "大都会艺术博物馆",
                "title" : "Recovered",
                "subtitle" : "2026",
                "imageFileName" : null,
                "appURL" : "dailymuseum://artwork/met/1",
                "updatedAt" : 20
              },
              "displayedArtworkKeys" : [
                "met|1"
              ],
              "failureMessage" : null,
              "lastUpdatedAt" : 20
            }
          ]
        }
        """
        try Data(persistedState.utf8).write(
            to: directoryURL.appendingPathComponent("instances.json"),
            options: [.atomic]
        )
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)

        let rendered = await store.renderState(
            for: sharedKey,
            scopeRawValue: scope,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(rendered.instanceToken, sharedKey)
        XCTAssertEqual(rendered.familyToken, familyToken)
        XCTAssertEqual(rendered.phase, .success)
        XCTAssertEqual(rendered.artwork?.title, "Recovered")
        let displayedHistory = await store.displayedArtworkKeys(for: MuseumIdentifier("met"))
        XCTAssertEqual(displayedHistory, [WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "1")])
        let migratedState = await store.state(for: sharedKey)
        let originalState = await store.state(for: "initial-token")
        XCTAssertEqual(migratedState?.phase, .success)
        XCTAssertNil(originalState)
    }

    func testRenderStateSharesAcrossDifferentFamilies() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        let sharedKey = WidgetRefreshGroupKey.make(scopeRawValue: scope, familyToken: WidgetFamily.systemLarge.debugToken)
        let mediumKey = WidgetRefreshGroupKey.make(
            scopeRawValue: scope,
            familyToken: WidgetFamily.systemMedium.debugToken
        )

        _ = await store.beginRefresh(
            instanceToken: sharedKey,
            scopeRawValue: scope,
            familyToken: WidgetFamily.systemLarge.debugToken,
            now: Date(timeIntervalSince1970: 10)
        )
        _ = await store.markSuccess(
            instanceToken: sharedKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "Large"
            ),
            imageData: nil,
            familyToken: WidgetFamily.systemLarge.debugToken,
            now: Date(timeIntervalSince1970: 20)
        )

        let rendered = await store.renderState(
            for: mediumKey,
            scopeRawValue: scope,
            familyToken: WidgetFamily.systemMedium.debugToken,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(rendered.instanceToken, mediumKey)
        XCTAssertEqual(rendered.phase, .success)
        XCTAssertEqual(rendered.artwork?.title, "Large")
    }

    func testRenderStateKeepsPreviousArtworkVisibleWhileRefreshIsInFlight() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        let refreshKey = WidgetRefreshGroupKey.make(scopeRawValue: scope, familyToken: "")

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: scope
        )
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "旧展品"
            ),
            imageData: nil
        )
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: scope
        )

        let rendered = await store.renderState(
            for: refreshKey,
            scopeRawValue: scope
        )
        let persisted = await store.state(for: refreshKey)

        XCTAssertEqual(rendered.phase, .success)
        XCTAssertEqual(rendered.artwork?.title, "旧展品")
        XCTAssertEqual(persisted?.phase, .refreshing)
        XCTAssertEqual(persisted?.artwork?.title, "旧展品")
    }

    func testRenderStateFallsBackToIdlePlaceholderWhenRefreshStartsWithoutArtwork() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue
        let refreshKey = WidgetRefreshGroupKey.make(scopeRawValue: scope, familyToken: "")

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: scope
        )

        let rendered = await store.renderState(
            for: refreshKey,
            scopeRawValue: scope
        )
        let persisted = await store.state(for: refreshKey)

        XCTAssertEqual(rendered.phase, .idle)
        XCTAssertNil(rendered.artwork)
        XCTAssertEqual(persisted?.phase, .refreshing)
        XCTAssertNil(persisted?.artwork)
    }

    func testPresentationStateDoesNotPersistMissingPreviewInstance() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.all.rawValue

        let previewState = await store.presentationState(
            for: scope,
            scopeRawValue: scope
        )
        let knownInstances = await store.knownInstances()

        XCTAssertNil(previewState)
        XCTAssertTrue(knownInstances.isEmpty)
    }

    func testRemoveInstancesExcludingRefreshKeysPrunesStaleStateAndImage() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let staleKey = WidgetMuseumScope.all.rawValue
        let currentKey = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue

        _ = await store.beginRefresh(instanceToken: staleKey, scopeRawValue: staleKey)
        let staleState = await store.markSuccess(
            instanceToken: staleKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "Stale"
            ),
            imageData: Data("stale-image".utf8)
        )
        _ = await store.renderState(
            for: currentKey,
            scopeRawValue: currentKey
        )

        let imageFileName = try XCTUnwrap(staleState?.artwork?.imageFileName)
        let imageURL = baseURL
            .appendingPathComponent("WidgetInstances", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        await store.removeInstances(excludingRefreshKeys: [currentKey])

        let removedState = await store.state(for: staleKey)
        let retainedState = await store.state(for: currentKey)

        XCTAssertNil(removedState)
        XCTAssertNotNil(retainedState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testRenderStateKeepsLatestMeaningfulLegacyStateWhenIdleWidgetJoinsSameGroup() async throws {
        let scope = WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        let familyToken = WidgetFamily.systemLarge.debugToken
        let sharedKey = WidgetRefreshGroupKey.make(
            scopeRawValue: scope,
            familyToken: familyToken
        )
        let directoryURL = baseURL.appendingPathComponent("WidgetInstances", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let persistedState = """
        {
          "instances" : [
            {
              "instanceToken" : "existing-token",
              "scopeRawValue" : "single:met",
              "familyToken" : "large",
              "nonce" : 1,
              "phase" : "success",
              "artwork" : {
                "museumID" : "met",
                "artworkKey" : "met|1",
                "museumName" : "大都会艺术博物馆",
                "title" : "Existing",
                "subtitle" : "2026",
                "imageFileName" : null,
                "appURL" : "dailymuseum://artwork/met/1",
                "updatedAt" : 20
              },
              "displayedArtworkKeys" : [
                "met|1"
              ],
              "failureMessage" : null,
              "lastUpdatedAt" : 20
            },
            {
              "instanceToken" : "new-idle-token",
              "scopeRawValue" : "single:met",
              "familyToken" : "large",
              "nonce" : 0,
              "phase" : "idle",
              "artwork" : null,
              "displayedArtworkKeys" : [],
              "failureMessage" : null,
              "lastUpdatedAt" : 30
            }
          ]
        }
        """
        try Data(persistedState.utf8).write(
            to: directoryURL.appendingPathComponent("instances.json"),
            options: [.atomic]
        )
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)

        let rendered = await store.renderState(
            for: sharedKey,
            scopeRawValue: scope,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 40)
        )
        let knownInstances = await store.knownInstances()

        XCTAssertEqual(rendered.instanceToken, sharedKey)
        XCTAssertEqual(rendered.familyToken, familyToken)
        XCTAssertEqual(rendered.phase, .success)
        XCTAssertEqual(rendered.artwork?.title, "Existing")
        XCTAssertEqual(knownInstances.count, 1)
    }

    func testScopeChangeResetsArtworkFailureAndDisplayedHistory() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        _ = await store.beginRefresh(
            instanceToken: "instance-scope",
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        )
        _ = await store.markSuccess(
            instanceToken: "instance-scope",
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "旧展品"
            ),
            imageData: Data("image".utf8)
        )

        let refreshed = await store.beginRefresh(
            instanceToken: "instance-scope",
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue
        )

        XCTAssertEqual(refreshed.scopeRawValue, WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue)
        XCTAssertEqual(refreshed.phase, .refreshing)
        XCTAssertNil(refreshed.artwork)
        XCTAssertNil(refreshed.failureMessage)
        XCTAssertEqual(refreshed.displayedArtworkKeys, [])
    }

    func testOverdueAutomaticRefreshIsNotReplayedAfterFailureAndStoreRestart() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let calendar = makeCalendar(timeZone: timeZone)
        let scope = "single:nmc"
        let schedule = try XCTUnwrap(WidgetAutoRefreshSchedule(
            interval: .twelveHours, startMinutes: 0, endMinutes: 23 * 60,
            calendar: calendar, timeZone: timeZone
        ))
        let initialDate = date(hour: 0, minute: 0, calendar: calendar)
        let overdueDate = date(hour: 12, minute: 0, calendar: calendar)
        _ = await store.resolveAutomaticRefresh(
            for: scope, scopeRawValue: scope, familyToken: "small", schedule: schedule, now: initialDate
        )
        let now = try XCTUnwrap(calendar.date(
            byAdding: .day, value: 5, to: date(hour: 12, minute: 21, calendar: calendar)
        ))
        let expectedNext = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: initialDate))
        let due = await store.resolveAutomaticRefresh(
            for: scope, scopeRawValue: scope, familyToken: "small", schedule: schedule, now: now
        )
        XCTAssertTrue(due.shouldRefresh)
        XCTAssertEqual(due.scheduledAt, overdueDate)
        XCTAssertEqual(due.nextAutomaticRefreshAt, expectedNext)

        // The future slot must already be on disk before the network refresh starts.
        let restarted = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let persisted = await restarted.state(for: scope)
        XCTAssertEqual(persisted?.nextAutomaticRefreshAt, expectedNext.timeIntervalSince1970)
        let refreshing = await restarted.beginRefresh(instanceToken: scope, scopeRawValue: scope, now: now)
        _ = await restarted.markFailure(
            instanceToken: scope, expectedNonce: refreshing.nonce, message: "网络不可用", now: now
        )
        let reloaded = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let repeated = await reloaded.resolveAutomaticRefresh(
            for: scope, scopeRawValue: scope, familyToken: "large", schedule: schedule,
            now: now.addingTimeInterval(60)
        )
        XCTAssertFalse(repeated.shouldRefresh)
        XCTAssertEqual(repeated.nextAutomaticRefreshAt, expectedNext)

        let nextDay = await reloaded.resolveAutomaticRefresh(
            for: scope, scopeRawValue: scope, schedule: schedule, now: expectedNext
        )
        XCTAssertTrue(nextDay.shouldRefresh)
        XCTAssertEqual(nextDay.scheduledAt, expectedNext)
    }

    func testResolveAutomaticRefreshPersistsNextScheduledRefresh() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(MuseumIdentifier("met")), family: nil)
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

        let initialResolution = await store.resolveAutomaticRefresh(
            for: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            familyToken: WidgetFamily.systemSmall.debugToken,
            schedule: schedule,
            now: date(hour: 11, minute: 0, calendar: calendar)
        )
        let dueResolution = await store.resolveAutomaticRefresh(
            for: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            familyToken: WidgetFamily.systemSmall.debugToken,
            schedule: schedule,
            now: scheduledAt
        )
        let state = await store.state(for: refreshKey)

        XCTAssertEqual(initialResolution.nextAutomaticRefreshAt, scheduledAt)
        XCTAssertTrue(dueResolution.shouldRefresh)
        XCTAssertEqual(dueResolution.scheduledAt, scheduledAt)
        XCTAssertEqual(
            state?.nextAutomaticRefreshAt,
            date(hour: 15, minute: 0, calendar: calendar).timeIntervalSince1970
        )
        XCTAssertEqual(state?.automaticRefreshScheduleSignature, schedule.signature)
    }

    func testManualRefreshStateChangesDoNotOverwriteAutomaticRefreshSchedule() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(MuseumIdentifier("met")), family: nil)
        let schedule = try XCTUnwrap(
            WidgetAutoRefreshSchedule(
                interval: .threeHours,
                startMinutes: 9 * 60,
                endMinutes: 18 * 60,
                calendar: calendar,
                timeZone: timeZone
            )
        )
        let nextAutomaticRefreshAt = date(hour: 15, minute: 0, calendar: calendar)

        _ = await store.resolveAutomaticRefresh(
            for: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            schedule: schedule,
            now: date(hour: 12, minute: 0, calendar: calendar)
        )
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue,
            now: date(hour: 12, minute: 30, calendar: calendar)
        )
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "手动刷新结果"
            ),
            imageData: nil,
            now: date(hour: 12, minute: 31, calendar: calendar)
        )
        let state = await store.state(for: refreshKey)

        XCTAssertEqual(state?.automaticRefreshScheduleSignature, schedule.signature)
        XCTAssertEqual(
            state?.nextAutomaticRefreshAt,
            nextAutomaticRefreshAt.timeIntervalSince1970
        )
    }

    func testPersistedStateWithoutDisplayedHistoryStillLoads() async throws {
        let directoryURL = baseURL.appendingPathComponent("WidgetInstances", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let persistedState = """
        {
          "instances" : [
            {
              "instanceToken" : "legacy",
              "scopeRawValue" : "single:met",
              "nonce" : 2,
              "phase" : "success",
              "artwork" : {
                "museumID" : "met",
                "museumName" : "大都会艺术博物馆",
                "title" : "旧展品",
                "subtitle" : "2026",
                "imageFileName" : null,
                "appURL" : "dailymuseum://artwork/met/1",
                "updatedAt" : 1
              },
              "failureMessage" : null,
              "lastUpdatedAt" : 2
            }
          ]
        }
        """
        try Data(persistedState.utf8).write(
            to: directoryURL.appendingPathComponent("instances.json"),
            options: [.atomic]
        )

        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue, familyToken: "")
        let state = await store.state(for: refreshKey)

        XCTAssertEqual(state?.instanceToken, refreshKey)
        XCTAssertEqual(state?.displayedArtworkKeys, [])
        XCTAssertEqual(state?.artwork?.title, "旧展品")
    }

    func testDisplayedHistoryPersistsAfterWidgetInstanceStateIsRemoved() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(MuseumIdentifier("met")), family: nil)
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("met")).rawValue
        )
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("met"),
                museumName: "大都会艺术博物馆",
                title: "旧实例展品"
            ),
            imageData: nil
        )

        await store.removeInstances(excludingRefreshKeys: [])

        let removedState = await store.state(for: refreshKey)
        let displayedHistory = await store.displayedArtworkKeys(for: MuseumIdentifier("met"))

        XCTAssertNil(removedState)
        XCTAssertEqual(displayedHistory, [WidgetDisplayedArtworkKey.make(museumID: MuseumIdentifier("met"), objectID: "1")])
    }

    func testMarkSuccessDownsamplesStoredImageBeforeWritingToAppGroup() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(MuseumIdentifier("nnm")), family: nil)
        let sourceData = makeJPEGData(size: CGSize(width: 2400, height: 1600))
        let sourceDimensions = try XCTUnwrap(WidgetArtworkSnapshotStore.imageDimensions(from: sourceData))

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(MuseumIdentifier("nnm")).rawValue
        )
        let successState = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("nnm"),
                museumName: "奈良国立博物馆",
                title: "大图展品"
            ),
            imageData: sourceData
        )

        let imageFileName = try XCTUnwrap(successState?.artwork?.imageFileName)
        let imageURL = baseURL
            .appendingPathComponent("WidgetInstances", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(imageFileName)
        let storedData = try Data(contentsOf: imageURL)
        let storedDimensions = try XCTUnwrap(WidgetArtworkSnapshotStore.imageDimensions(from: storedData))

        XCTAssertGreaterThan(max(sourceDimensions.width, sourceDimensions.height), 1024)
        XCTAssertLessThanOrEqual(max(storedDimensions.width, storedDimensions.height), 1024)
        XCTAssertLessThanOrEqual(storedDimensions.width * storedDimensions.height, 1_000_000)
        XCTAssertEqual(
            CGFloat(storedDimensions.width) / CGFloat(storedDimensions.height),
            CGFloat(sourceDimensions.width) / CGFloat(sourceDimensions.height),
            accuracy: 0.02
        )
    }

    func testPreparedImagesRespectWidgetArchiveLimitsForLandscapePortraitAndSquare() throws {
        let sourceSizes = [
            CGSize(width: 5000, height: 3757),
            CGSize(width: 3757, height: 5000),
            CGSize(width: 1100, height: 1100),
        ]

        for sourceSize in sourceSizes {
            let sourceData = makeJPEGData(size: sourceSize)
            let preparedData = WidgetArtworkSnapshotStore.preparedImageDataForStorage(sourceData)
            let preparedDimensions = try XCTUnwrap(
                WidgetArtworkSnapshotStore.imageDimensions(from: preparedData)
            )

            XCTAssertLessThanOrEqual(
                max(preparedDimensions.width, preparedDimensions.height),
                1024,
                "Unexpected maximum dimension for source size \(sourceSize)"
            )
            XCTAssertLessThanOrEqual(
                preparedDimensions.width * preparedDimensions.height,
                1_000_000,
                "Unexpected pixel area for source size \(sourceSize)"
            )
        }
    }

    func testRenderStateMigratesLegacyOversizedStoredImage() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .all, family: nil)

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.all.rawValue
        )
        let successState = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: MuseumIdentifier("nnm"),
                museumName: "奈良国立博物馆",
                title: "旧版本大图"
            ),
            imageData: makeJPEGData(size: CGSize(width: 800, height: 600))
        )
        let imageFileName = try XCTUnwrap(successState?.artwork?.imageFileName)
        let imageURL = baseURL
            .appendingPathComponent("WidgetInstances", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(imageFileName)
        let legacyData = makeJPEGData(size: CGSize(width: 1200, height: 901))
        try legacyData.write(to: imageURL, options: [.atomic])

        _ = await store.renderState(
            for: refreshKey,
            scopeRawValue: WidgetMuseumScope.all.rawValue,
            familyToken: WidgetFamily.systemSmall.debugToken
        )

        let migratedData = try Data(contentsOf: imageURL)
        let migratedDimensions = try XCTUnwrap(
            WidgetArtworkSnapshotStore.imageDimensions(from: migratedData)
        )
        XCTAssertLessThanOrEqual(max(migratedDimensions.width, migratedDimensions.height), 1024)
        XCTAssertLessThanOrEqual(migratedDimensions.width * migratedDimensions.height, 1_000_000)
    }

    private func makePayload(
        museumID: MuseumID,
        museumName: String,
        title: String
    ) -> WidgetArtworkSnapshotStore.ArtworkPayload {
        WidgetArtworkSnapshotStore.ArtworkPayload(
            museumID: museumID,
            artworkKey: WidgetDisplayedArtworkKey.make(museumID: museumID, objectID: "1"),
            museumName: museumName,
            title: title,
            subtitle: "2026",
            imageFileName: nil,
            appURL: URL(string: "dailymuseum://artwork/\(museumID.rawValue)/1"),
            updatedAt: 1
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
}
