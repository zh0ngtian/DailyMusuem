import Foundation
import WidgetKit

struct WidgetManualRefreshRunner {
    let widgetCenter: WidgetCenter
    let defaults: UserDefaults
    let logSource: String

    init(
        widgetCenter: WidgetCenter = .shared,
        defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard,
        logSource: String
    ) {
        self.widgetCenter = widgetCenter
        self.defaults = defaults
        self.logSource = logSource
    }

    func perform(familyKey: String = "") async {
        let startedAt = Date()
        let previousNonce = Int(defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce))
        let previousRefreshInProgress = defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress)
        let nextNonce = previousNonce + 1

        let refreshTask = Task {
            try await runManualRefresh(
                startedAt: startedAt,
                nextNonce: nextNonce,
                previousNonce: previousNonce,
                previousRefreshInProgress: previousRefreshInProgress,
                familyKey: familyKey
            )
        }
        await WidgetManualRefreshExecutionController.shared.activate(
            nonce: nextNonce,
            task: refreshTask
        )
        defer {
            Task {
                await WidgetManualRefreshExecutionController.shared.finish(nonce: nextNonce)
            }
        }

        do {
            try await refreshTask.value
        } catch let error as WidgetManualRefreshInterruptedError {
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "nonce=\(error.executionNonce) 已被 nonce=\(error.activeNonce) 抢占，中断旧刷新"
            )
            await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
        } catch is CancellationError {
            let activeNonce = Int(defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce))
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "nonce=\(nextNonce) 已被 nonce=\(activeNonce) 抢占，中断旧刷新"
            )
            await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
        } catch {
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "nonce=\(nextNonce) 发生未处理错误：\(error.localizedDescription)"
            )
        }
    }

    private func runManualRefresh(
        startedAt: Date,
        nextNonce: Int,
        previousNonce: Int,
        previousRefreshInProgress: Bool,
        familyKey: String
    ) async throws {
        let widgetInfos = await currentWidgetConfigurations()
        let requestedFamilyKey = resolvedRequestedFamilyKey(
            familyKey: familyKey,
            widgetInfos: widgetInfos
        )

        defaults.set(requestedFamilyKey, forKey: SettingsKeys.widgetManualRefreshRequestedFamilyKey)
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(startedAt.timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(Double(nextNonce), forKey: SettingsKeys.widgetManualRefreshNonce)
        defaults.synchronize()

        let expectedCounts = expectedDeliveryCounts(
            from: widgetInfos,
            requestedFamilyKey: requestedFamilyKey
        )
        let recentDisplayedSummary = await WidgetDisplayedArtworkRegistry.shared
            .displayedArtworkSummary(forFamilyKey: requestedFamilyKey)
        let trackerState = await WidgetRefreshDeliveryTracker.shared.begin(
            nonce: nextNonce,
            configurationCount: widgetInfos.filter { $0.family.logKey == requestedFamilyKey }.count,
            expectedCounts: expectedCounts,
            requestedFamilyKey: requestedFamilyKey,
            startedAt: startedAt
        )

        if previousRefreshInProgress, previousNonce > 0 {
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "检测到 nonce=\(previousNonce) 尚未结束，当前点击将直接抢占并中断旧刷新"
            )
        }

        await RequestLogger.shared.logEvent(
            source: logSource,
            summary: "触发手动刷新，nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，当前已安装组件=\(trackerState.configurationSummary)，该尺寸最近扩展渲染记录=\(recentDisplayedSummary)"
        )

        do {
            let settings = WidgetSettingsReader(defaults: defaults)
            let generatedEntry = try await WidgetArtworkService(
                settings: settings,
                manualRefreshExecutionNonce: nextNonce,
                familyKey: requestedFamilyKey
            ).fetchEntry(date: startedAt)

            guard let deliveringState = await WidgetRefreshDeliveryTracker.shared.completeGeneratedRefresh(
                nonce: nextNonce,
                targetRenderID: generatedEntry.renderID
            ) else {
                if settings.shouldInterruptManualRefreshExecution(nonce: nextNonce) {
                    throw WidgetManualRefreshInterruptedError(
                        executionNonce: nextNonce,
                        activeNonce: settings.manualRefreshNonceValue
                    )
                }
                await RequestLogger.shared.logEvent(
                    source: logSource,
                    summary: "nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，新快照已生成，但结果固定状态写入失败。该尺寸最近扩展渲染记录=\(recentDisplayedSummary)，桌面可能继续停留在上一张旧图"
                )
                settings.clearManualRefreshStateIfCurrentNonce(nextNonce)
                await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
                return
            }

            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，新快照已生成，renderID=\(generatedEntry.renderID)，等待目标尺寸实际渲染，当前已安装组件=\(deliveringState.configurationSummary)，交付进度=\(deliveringState.progressSummary)"
            )
            widgetCenter.reloadTimelines(ofKind: SettingsKeys.widgetKind)
        } catch let error as WidgetManualRefreshInterruptedError {
            await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
            throw error
        } catch is CancellationError {
            await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
            throw CancellationError()
        } catch {
            WidgetSettingsReader(defaults: defaults).clearManualRefreshStateIfCurrentNonce(nextNonce)
            await WidgetRefreshDeliveryTracker.shared.clear(nonce: nextNonce)
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "nonce=\(nextNonce)，目标尺寸=\(requestedFamilyKey)，手动刷新拉取失败：\(error.localizedDescription)。该尺寸最近扩展渲染记录=\(recentDisplayedSummary)，桌面可能继续停留在上一张旧图"
            )
        }
    }

    private func resolvedRequestedFamilyKey(
        familyKey: String,
        widgetInfos: [WidgetInfo]
    ) -> String {
        let trimmed = familyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return widgetInfos.first?.family.logKey ?? WidgetFamily.systemLarge.logKey
    }

    private func currentWidgetConfigurations() async -> [WidgetInfo] {
        await withCheckedContinuation { continuation in
            widgetCenter.getCurrentConfigurations { result in
                switch result {
                case .success(let widgetInfos):
                    continuation.resume(returning: widgetInfos.filter { $0.kind == SettingsKeys.widgetKind })
                case .failure(let error):
                    Task {
                        await RequestLogger.shared.logEvent(
                            source: logSource,
                            summary: "读取已安装组件配置失败：\(error.localizedDescription)"
                        )
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func expectedDeliveryCounts(
        from widgetInfos: [WidgetInfo],
        requestedFamilyKey: String
    ) -> [String: Int] {
        var counts: [String: Int] = [
            "systemLarge": 0,
            "systemMedium": 0,
            "systemSmall": 0,
        ]
        for info in widgetInfos {
            guard info.family.logKey == requestedFamilyKey else {
                continue
            }
            counts[requestedFamilyKey, default: 0] += 1
        }
        return counts
    }
}

actor WidgetManualRefreshExecutionController {
    static let shared = WidgetManualRefreshExecutionController()

    private var activeRefresh: (nonce: Int, task: Task<Void, Error>)?

    func activate(nonce: Int, task: Task<Void, Error>) {
        if let activeRefresh, activeRefresh.nonce != nonce {
            activeRefresh.task.cancel()
        }
        activeRefresh = (nonce, task)
    }

    func finish(nonce: Int) {
        guard activeRefresh?.nonce == nonce else {
            return
        }
        activeRefresh = nil
    }
}
