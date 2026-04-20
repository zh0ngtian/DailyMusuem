import Foundation
import XCTest

final class RequestLoggerTests: XCTestCase {
    func testRequestLogEntryDecodesLegacyPayloadWithoutInstanceToken() throws {
        let data = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "timestamp": 0,
              "source": "Widget 完成渲染",
              "summary": "family=small scope=all phase=success",
              "method": null,
              "url": null,
              "statusCode": null,
              "durationMilliseconds": null
            }
            """.utf8
        )

        let entry = try JSONDecoder().decode(RequestLogEntry.self, from: data)

        XCTAssertNil(entry.instanceToken)
        XCTAssertEqual(entry.source, "Widget 完成渲染")
    }

    func testRequestLogEntryEncodesInstanceToken() throws {
        let entry = RequestLogEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            source: "Widget 刷新按钮",
            summary: "刷新成功：大都会艺术博物馆 / 展品",
            instanceToken: "widget-instance-1",
            method: nil,
            url: nil,
            statusCode: nil,
            durationMilliseconds: nil
        )

        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["instanceToken"] as? String, "widget-instance-1")
    }

    func testAppEntitlementsIncludeSharedAppGroup() throws {
        let appGroups = try entitlementApplicationGroups(
            atRelativePath: "DailyMuseum/DailyMuseum.entitlements"
        )

        XCTAssertEqual(appGroups, [SettingsKeys.appGroupID])
    }

    func testWidgetEntitlementsIncludeSharedAppGroup() throws {
        let appGroups = try entitlementApplicationGroups(
            atRelativePath: "DailyMuseumWidget/DailyMuseumWidgetAppGroup.entitlements"
        )

        XCTAssertEqual(appGroups, [SettingsKeys.appGroupID])
    }

    private func entitlementApplicationGroups(atRelativePath relativePath: String) throws -> [String] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: entitlementsURL)
        let plistObject = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        return plistObject["com.apple.security.application-groups"] as? [String] ?? []
    }
}
