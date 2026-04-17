import UIKit
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

    func testMostRecentDisplayableStatePrefersSuccessOverNewerRefreshingStateForScope() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let scope = WidgetMuseumScope.single(.met).rawValue

        _ = await store.registerInstance(instanceToken: "idle", scopeRawValue: scope)

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

        _ = await store.beginRefresh(
            instanceToken: "refreshing",
            scopeRawValue: scope,
            now: Date(timeIntervalSince1970: 300)
        )

        let adopted = await store.mostRecentDisplayableState(scopeRawValue: scope)

        XCTAssertEqual(adopted?.instanceToken, "success")
        XCTAssertEqual(adopted?.phase, .success)
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
