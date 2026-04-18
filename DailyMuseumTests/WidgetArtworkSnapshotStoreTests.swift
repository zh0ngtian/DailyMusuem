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

        let registered = await store.registerInstance(
            instanceToken: "instance-a",
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue
        )
        let refreshing = await store.beginRefresh(
            instanceToken: "instance-a",
            scopeRawValue: WidgetMuseumScope.single(.met).rawValue
        )
        let reloaded = await store.state(for: "instance-a")

        XCTAssertEqual(registered.phase, .idle)
        XCTAssertEqual(registered.displayedArtworkKeys, [])
        XCTAssertEqual(refreshing.phase, .refreshing)
        XCTAssertEqual(refreshing.nonce, 1)
        XCTAssertEqual(reloaded?.phase, .refreshing)
        XCTAssertEqual(reloaded?.scopeRawValue, WidgetMuseumScope.single(.met).rawValue)
    }

    func testMarkSuccessStoresImageAndFailureRemovesPreviousPayload() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        _ = await store.beginRefresh(
            instanceToken: "instance-b",
            scopeRawValue: WidgetMuseumScope.single(.tnm).rawValue
        )

        let successState = await store.markSuccess(
            instanceToken: "instance-b",
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
            instanceToken: "instance-b",
            scopeRawValue: WidgetMuseumScope.single(.tnm).rawValue
        )
        let failureState = await store.markFailure(
            instanceToken: "instance-b",
            expectedNonce: 2,
            message: "未找到可展示的展品。"
        )

        XCTAssertEqual(failureState?.phase, .failure)
        XCTAssertNil(failureState?.artwork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testMarkSuccessIgnoresSupersededNonce() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        _ = await store.beginRefresh(
            instanceToken: "instance-c",
            scopeRawValue: WidgetMuseumScope.all.rawValue
        )
        _ = await store.beginRefresh(
            instanceToken: "instance-c",
            scopeRawValue: WidgetMuseumScope.all.rawValue
        )

        let outdatedWrite = await store.markSuccess(
            instanceToken: "instance-c",
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
                museumName: "大都会艺术博物馆",
                title: "旧结果"
            ),
            imageData: Data("old".utf8)
        )
        let currentState = await store.state(for: "instance-c")

        XCTAssertNil(outdatedWrite)
        XCTAssertEqual(currentState?.nonce, 2)
        XCTAssertEqual(currentState?.phase, .refreshing)
    }

    func testRegisterInstanceClearsLegacyDirectories() async throws {
        let legacyDirectories = ["WidgetCache", "WidgetRefresh", "WidgetRender"]
        for directoryName in legacyDirectories {
            let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data("legacy".utf8).write(to: directoryURL.appendingPathComponent("file.txt"))
        }

        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        _ = await store.registerInstance(
            instanceToken: "instance-d",
            scopeRawValue: WidgetMuseumScope.single(.shm).rawValue
        )

        for directoryName in legacyDirectories {
            let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
        }
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

    func testRenderStateRecoversRecentSameFamilyStateWhenTokenDrifts() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(.met).rawValue
        let familyToken = WidgetFamily.systemMedium.debugToken

        _ = await store.beginRefresh(
            instanceToken: "initial-token",
            scopeRawValue: scope,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 10)
        )
        _ = await store.markSuccess(
            instanceToken: "initial-token",
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
                museumName: "大都会艺术博物馆",
                title: "Recovered"
            ),
            imageData: nil,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 20)
        )

        let rendered = await store.renderState(
            for: "drifted-token",
            scopeRawValue: scope,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(rendered.instanceToken, "drifted-token")
        XCTAssertEqual(rendered.familyToken, familyToken)
        XCTAssertEqual(rendered.phase, .success)
        XCTAssertEqual(rendered.artwork?.title, "Recovered")
        let migratedState = await store.state(for: "drifted-token")
        let originalState = await store.state(for: "initial-token")
        XCTAssertEqual(migratedState?.phase, .success)
        XCTAssertNil(originalState)
    }

    func testRenderStateDoesNotRecoverRecentStateAcrossDifferentFamily() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(.met).rawValue

        _ = await store.beginRefresh(
            instanceToken: "large-token",
            scopeRawValue: scope,
            familyToken: WidgetFamily.systemLarge.debugToken,
            now: Date(timeIntervalSince1970: 10)
        )
        _ = await store.markSuccess(
            instanceToken: "large-token",
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
            for: "medium-token",
            scopeRawValue: scope,
            familyToken: WidgetFamily.systemMedium.debugToken,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(rendered.instanceToken, "medium-token")
        XCTAssertEqual(rendered.familyToken, WidgetFamily.systemMedium.debugToken)
        XCTAssertEqual(rendered.phase, .idle)
        XCTAssertNil(rendered.artwork)
    }

    func testRenderStateDoesNotRecoverStaleSameFamilyStateAfterRecoveryWindow() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(.met).rawValue
        let familyToken = WidgetFamily.systemLarge.debugToken

        _ = await store.beginRefresh(
            instanceToken: "stale-token",
            scopeRawValue: scope,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 10)
        )
        _ = await store.markSuccess(
            instanceToken: "stale-token",
            expectedNonce: 1,
            payload: makePayload(
                museumID: .met,
                museumName: "大都会艺术博物馆",
                title: "Stale"
            ),
            imageData: nil,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 20)
        )

        let rendered = await store.renderState(
            for: "fresh-large-token",
            scopeRawValue: scope,
            familyToken: familyToken,
            now: Date(timeIntervalSince1970: 250)
        )

        XCTAssertEqual(rendered.instanceToken, "fresh-large-token")
        XCTAssertEqual(rendered.familyToken, familyToken)
        XCTAssertEqual(rendered.phase, .idle)
        XCTAssertNil(rendered.artwork)
        let staleState = await store.state(for: "stale-token")
        XCTAssertNotNil(staleState)
    }

    func testRenderStateRecoversLegacyFamilylessStateForMatchingScope() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(.tnm).rawValue

        _ = await store.beginRefresh(
            instanceToken: "legacy-token",
            scopeRawValue: scope,
            now: Date(timeIntervalSince1970: 10)
        )
        _ = await store.markSuccess(
            instanceToken: "legacy-token",
            expectedNonce: 1,
            payload: makePayload(
                museumID: .tnm,
                museumName: "东京国立博物馆",
                title: "Legacy"
            ),
            imageData: nil,
            now: Date(timeIntervalSince1970: 20)
        )

        let rendered = await store.renderState(
            for: "migrated-medium-token",
            scopeRawValue: scope,
            familyToken: WidgetFamily.systemMedium.debugToken,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(rendered.instanceToken, "migrated-medium-token")
        XCTAssertEqual(rendered.familyToken, WidgetFamily.systemMedium.debugToken)
        XCTAssertEqual(rendered.phase, .success)
        XCTAssertEqual(rendered.artwork?.title, "Legacy")
        let originalLegacyState = await store.state(for: "legacy-token")
        XCTAssertNil(originalLegacyState)
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
        let state = await store.state(for: "legacy")

        XCTAssertEqual(state?.instanceToken, "legacy")
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
