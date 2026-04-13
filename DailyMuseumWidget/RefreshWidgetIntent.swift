import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun: Bool = false

    private enum Constants {
        static let deliveryTimeout: TimeInterval = 8
        static let deliveryPollIntervalNanoseconds: UInt64 = 750_000_000
    }

    func perform() async throws -> some IntentResult {
        let widgetCenter = WidgetCenter.shared
        let defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        let startedAt = Date()
        let nextNonce = Int(defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce)) + 1

        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(startedAt.timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(Double(nextNonce), forKey: SettingsKeys.widgetManualRefreshNonce)
        defaults.synchronize()

        let widgetInfos = await currentWidgetConfigurations(widgetCenter: widgetCenter)
        let expectedCounts = expectedDeliveryCounts(from: widgetInfos)
        let trackerState = await WidgetRefreshDeliveryTracker.shared.begin(
            nonce: nextNonce,
            configurationCount: widgetInfos.count,
            expectedCounts: expectedCounts,
            startedAt: startedAt
        )

        await RequestLogger.shared.logEvent(
            source: "Widget 刷新按钮",
            summary: "触发手动刷新，进入加载态，nonce=\(nextNonce)，当前已安装组件=\(trackerState.configurationSummary)"
        )
        broadcastReloads(widgetCenter)

        let outcomeSummary: String
        do {
            let settings = WidgetSettingsReader()
            _ = try await WidgetArtworkService(settings: settings).fetchEntry(date: startedAt)

            guard let deliveringState = await WidgetRefreshDeliveryTracker.shared.transitionToDelivering(nonce: nextNonce) else {
                outcomeSummary = "nonce=\(nextNonce)，新快照已生成，但交付追踪状态丢失"
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新按钮",
                    summary: outcomeSummary
                )
                await finalizeManualRefresh(
                    defaults: defaults,
                    widgetCenter: widgetCenter,
                    nonce: nextNonce,
                    summary: outcomeSummary
                )
                return .result()
            }

            await RequestLogger.shared.logEvent(
                source: "Widget 刷新按钮",
                summary: "nonce=\(nextNonce)，新快照已生成，进入交付阶段，当前已安装组件=\(deliveringState.configurationSummary)，交付进度=\(deliveringState.progressSummary)"
            )

            let deliveryStatus = await waitForDelivery(
                nonce: nextNonce,
                widgetCenter: widgetCenter
            )
            switch deliveryStatus {
            case .completed(let state):
                outcomeSummary = "nonce=\(nextNonce)，手动刷新交付完成，当前已安装组件=\(state.configurationSummary)，交付进度=\(state.progressSummary)"
            case .pending(let state):
                outcomeSummary = "nonce=\(nextNonce)，手动刷新交付超时，当前已安装组件=\(state.configurationSummary)，交付进度=\(state.progressSummary)"
            case .missing:
                outcomeSummary = "nonce=\(nextNonce)，手动刷新交付状态丢失"
            }
        } catch {
            outcomeSummary = "nonce=\(nextNonce)，手动刷新拉取失败：\(error.localizedDescription)"
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新按钮",
                summary: outcomeSummary
            )
        }

        await finalizeManualRefresh(
            defaults: defaults,
            widgetCenter: widgetCenter,
            nonce: nextNonce,
            summary: outcomeSummary
        )
        return .result()
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

    private func waitForDelivery(
        nonce: Int,
        widgetCenter: WidgetCenter
    ) async -> WidgetRefreshDeliveryTracker.Status {
        let deadline = Date().addingTimeInterval(Constants.deliveryTimeout)

        while true {
            let status = await WidgetRefreshDeliveryTracker.shared.status(for: nonce)
            switch status {
            case .completed:
                return status
            case .missing:
                return .missing
            case .pending:
                if Date() >= deadline {
                    return status
                }
                broadcastReloads(widgetCenter)
                try? await Task.sleep(nanoseconds: Constants.deliveryPollIntervalNanoseconds)
            }
        }
    }

    private func finalizeManualRefresh(
        defaults: UserDefaults,
        widgetCenter: WidgetCenter,
        nonce: Int,
        summary: String
    ) async {
        defaults.set(false, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.removeObject(forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.synchronize()
        await WidgetRefreshDeliveryTracker.shared.clear(nonce: nonce)
        await RequestLogger.shared.logEvent(
            source: "Widget 刷新按钮",
            summary: "\(summary)，退出加载态后再次广播 kind 与全部 timeline 刷新"
        )
        broadcastReloads(widgetCenter)
    }

    private func broadcastReloads(_ widgetCenter: WidgetCenter) {
        widgetCenter.reloadTimelines(ofKind: SettingsKeys.widgetKind)
        widgetCenter.reloadAllTimelines()
    }
}
