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
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(.met), family: nil)

        let registered = await store.registerInstance(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue
        )
        let refreshing = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue
        )
        let reloaded = await store.state(for: refreshKey)

        XCTAssertEqual(registered.phase, .idle)
        XCTAssertEqual(registered.displayedArtworkKeys, [])
        XCTAssertEqual(refreshing.phase, .refreshing)
        XCTAssertEqual(refreshing.nonce, 1)
        XCTAssertEqual(reloaded?.phase, .refreshing)
        XCTAssertEqual(reloaded?.scopeRawValue, WidgetMuseumScope.single(.met).rawValue)
    }

    func testMarkSuccessStoresImageAndFailureRemovesPreviousPayload() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(.tnm), family: nil)
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(.tnm).rawValue
        )

        let successState = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: .tnm,
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
        XCTAssertEqual(successState?.displayedArtworkKeys, [WidgetDisplayedArtworkKey.make(museumID: .tnm, objectID: "1")])

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(.tnm).rawValue
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
                museumID: .met,
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
        let scope = WidgetMuseumScope.single(.met).rawValue

        _ = await store.beginRefresh(instanceToken: "success", scopeRawValue: scope)
        _ = await store.markSuccess(
            instanceToken: "success",
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
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
        let scope = WidgetMuseumScope.single(.met).rawValue
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
        let migratedState = await store.state(for: sharedKey)
        let originalState = await store.state(for: "initial-token")
        XCTAssertEqual(migratedState?.phase, .success)
        XCTAssertNil(originalState)
    }

    func testRenderStateSharesAcrossDifferentFamilies() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(.met).rawValue
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
                museumID: .met,
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
        let scope = WidgetMuseumScope.single(.met).rawValue
        let refreshKey = WidgetRefreshGroupKey.make(scopeRawValue: scope, familyToken: "")

        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: scope
        )
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
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
        let scope = WidgetMuseumScope.single(.tnm).rawValue
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

    func testRenderStateKeepsLatestMeaningfulLegacyStateWhenIdleWidgetJoinsSameGroup() async throws {
        let scope = WidgetMuseumScope.single(.met).rawValue
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
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue
        )
        _ = await store.markSuccess(
            instanceToken: "instance-scope",
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
                museumName: "大都会艺术博物馆",
                title: "旧展品"
            ),
            imageData: Data("image".utf8)
        )

        let refreshed = await store.beginRefresh(
            instanceToken: "instance-scope",
            scopeRawValue: WidgetMuseumScope.single(.tnm).rawValue
        )

        XCTAssertEqual(refreshed.scopeRawValue, WidgetMuseumScope.single(.tnm).rawValue)
        XCTAssertEqual(refreshed.phase, .refreshing)
        XCTAssertNil(refreshed.artwork)
        XCTAssertNil(refreshed.failureMessage)
        XCTAssertEqual(refreshed.displayedArtworkKeys, [])
    }

    func testResolveAutomaticRefreshPersistsNextScheduledRefresh() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = makeCalendar(timeZone: timeZone)
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(.met), family: nil)
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
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue,
            familyToken: WidgetFamily.systemSmall.debugToken,
            schedule: schedule,
            now: date(hour: 11, minute: 0, calendar: calendar)
        )
        let dueResolution = await store.resolveAutomaticRefresh(
            for: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue,
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
        let refreshKey = WidgetRefreshGroupKey.make(scope: .single(.met), family: nil)
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
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue,
            schedule: schedule,
            now: date(hour: 12, minute: 0, calendar: calendar)
        )
        _ = await store.beginRefresh(
            instanceToken: refreshKey,
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue,
            now: date(hour: 12, minute: 30, calendar: calendar)
        )
        _ = await store.markSuccess(
            instanceToken: refreshKey,
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
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
        let refreshKey = WidgetRefreshGroupKey.make(scopeRawValue: WidgetMuseumScope.single(.met).rawValue, familyToken: "")
        let state = await store.state(for: refreshKey)

        XCTAssertEqual(state?.instanceToken, refreshKey)
        XCTAssertEqual(state?.displayedArtworkKeys, [])
        XCTAssertEqual(state?.artwork?.title, "旧展品")
    }

    func testWidgetImageUsesCroppedThumbnailWithinPixelBudget() throws {
        let sourceSize = CGSize(width: 6000, height: 600)
        let sourceData = makeJPEGData(size: sourceSize)

        let image = try XCTUnwrap(
            WidgetArtworkSnapshotStore.widgetImage(
                from: sourceData,
                targetPointSize: CGSize(width: 380, height: 376),
                scale: 3
            )
        )

        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let aspectRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        let expectedAspectRatio = 380.0 / 376.0

        XCTAssertLessThanOrEqual(max(pixelWidth, pixelHeight), 1200)
        XCTAssertEqual(aspectRatio, expectedAspectRatio, accuracy: 0.02)
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
