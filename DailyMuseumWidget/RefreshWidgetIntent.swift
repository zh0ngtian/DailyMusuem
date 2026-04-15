import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "组件尺寸")
    var familyKey: String

    init() {
        familyKey = ""
    }

    init(familyKey: String) {
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        let widgetCenter = WidgetCenter.shared
        let defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        let startedAt = Date()
        let nextNonce = Int(defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce)) + 1

        defaults.set(false, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.removeObject(forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(Double(nextNonce), forKey: SettingsKeys.widgetManualRefreshNonce)
        defaults.synchronize()

        let widgetInfos = await currentWidgetConfigurations(widgetCenter: widgetCenter)
        let expectedCounts = expectedDeliveryCounts(from: widgetInfos)
        let requestedFamilyKey = resolvedRequestedFamilyKey(from: widgetInfos)
        let trackerState = await WidgetRefreshDeliveryTracker.shared.begin(
            nonce: nextNonce,
            configurationCount: widgetInfos.count,
            expectedCounts: expectedCounts,
            requestedFamilyKey: requestedFamilyKey,
            startedAt: startedAt
        )

        await RequestLogger.shared.logEvent(
            source: "Widget 刷新按钮",
            summary: "触发手动刷新，nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，当前已安装组件=\(trackerState.configurationSummary)"
        )

        let outcomeSummary: String
        do {
            let settings = WidgetSettingsReader()
            let generatedEntry = try await WidgetArtworkService(settings: settings).fetchEntry(date: startedAt)

            guard let completedState = await WidgetRefreshDeliveryTracker.shared.completeGeneratedRefresh(
                nonce: nextNonce,
                targetRenderID: generatedEntry.renderID
            ) else {
                outcomeSummary = "nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，新快照已生成，但结果固定状态写入失败"
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新按钮",
                    summary: outcomeSummary
                )
                await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
                return .result()
            }

            outcomeSummary = "nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，新快照已生成，renderID=\(generatedEntry.renderID)，本次仅广播一次 timeline 刷新，当前已安装组件=\(completedState.configurationSummary)，交付进度=\(completedState.progressSummary)"
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新按钮",
                summary: outcomeSummary
            )
            reloadWidgetKind(widgetCenter)
        } catch {
            outcomeSummary = "nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，手动刷新拉取失败：\(error.localizedDescription)"
            await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新按钮",
                summary: outcomeSummary
            )
        }
        return .result()
    }

    private func resolvedRequestedFamilyKey(from widgetInfos: [WidgetInfo]) -> String {
        let trimmed = familyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return widgetInfos.first?.family.logKey ?? WidgetFamily.systemLarge.logKey
    }

    private func currentWidgetConfigurations(widgetCenter: WidgetCenter) async -> [WidgetInfo] {
        await withCheckedContinuation { continuation in
            widgetCenter.getCurrentConfigurations { result in
                switch result {
                case .success(let widgetInfos):
                    continuation.resume(returning: widgetInfos.filter { $0.kind == SettingsKeys.widgetKind })
                case .failure(let error):
                    Task {
                        await RequestLogger.shared.logEvent(
                            source: "Widget 刷新按钮",
                            summary: "读取已安装组件配置失败：\(error.localizedDescription)"
                        )
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func expectedDeliveryCounts(from widgetInfos: [WidgetInfo]) -> [String: Int] {
        var counts: [String: Int] = [
            "systemLarge": 0,
            "systemMedium": 0,
            "systemSmall": 0,
        ]
        for info in widgetInfos {
            counts[info.family.logKey, default: 0] += 1
        }
        return counts
    }

    private func reloadWidgetKind(_ widgetCenter: WidgetCenter) {
        widgetCenter.reloadTimelines(ofKind: SettingsKeys.widgetKind)
    }
}
