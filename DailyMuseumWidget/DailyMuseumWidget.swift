import WidgetKit
import SwiftUI

struct WidgetArtworkEntry: TimelineEntry {
    let date: Date
    let renderID: String
    let familyKey: String
    let deliveryID: String
    let museumName: String
    let title: String
    let subtitle: String?
    let imageFileName: String?
    let appURL: URL?
    let isRefreshing: Bool

    init(
        date: Date,
        renderID: String,
        familyKey: String = "",
        deliveryID: String = "",
        museumName: String,
        title: String,
        subtitle: String?,
        imageFileName: String?,
        appURL: URL?,
        isRefreshing: Bool
    ) {
        self.date = date
        self.renderID = renderID
        self.familyKey = familyKey
        self.deliveryID = deliveryID
        self.museumName = museumName
        self.title = title
        self.subtitle = subtitle
        self.imageFileName = imageFileName
        self.appURL = appURL
        self.isRefreshing = isRefreshing
    }

    var familyScopedRenderID: String {
        [renderID, familyKey, deliveryID]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    func scoped(to family: WidgetFamily, deliveryID: String = "") -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: date,
            renderID: renderID,
            familyKey: family.logKey,
            deliveryID: deliveryID,
            museumName: museumName,
            title: title,
            subtitle: subtitle,
            imageFileName: imageFileName,
            appURL: appURL,
            isRefreshing: isRefreshing
        )
    }
}

struct DailyMuseumWidget: Widget {
    static let kind: String = SettingsKeys.widgetKind
    let kind: String = DailyMuseumWidget.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyMuseumWidgetProvider()) { entry in
            DailyMuseumWidgetView(entry: entry)
        }
        .configurationDisplayName("DailyMuseum")
        .description("随机展示一件展品")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct DailyMuseumWidgetProvider: TimelineProvider {
    private enum Constants {
        static let loadingStateRetryInterval: TimeInterval = 5
    }

    func placeholder(in context: Context) -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: .now,
            renderID: "placeholder",
            museumName: "大都会艺术博物馆",
            title: "The Harvesters",
            subtitle: "1565",
            imageFileName: nil,
            appURL: nil,
            isRefreshing: false
        )
        .scoped(to: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetArtworkEntry) -> Void) {
        Task {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: context.isPreview
                    ? "请求快照预览，尺寸=\(context.family.logLabel)"
                    : "请求临时快照，尺寸=\(context.family.logLabel)"
            )
        }
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetArtworkEntry>) -> Void) {
        Task {
            let settings = WidgetSettingsReader()
            let refresh = settings.refreshInterval
            let now = Date()
            let nextRefresh = now.addingTimeInterval(refresh.seconds)
            let deliveryID = UUID().uuidString
            let manualRefreshState = await settings.activeManualRefreshDeliveryState(
                forFamilyKey: context.family.logKey,
                now: now
            )
            let manualRefreshSummary = manualRefreshState.map {
                "nonce=\($0.nonce)，phase=\($0.phase.rawValue)，交付进度=\($0.progressSummary)"
            } ?? "nonce=\(settings.manualRefreshNonceValue)"

            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "开始刷新 timeline，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，范围=\(settings.museumScope.rawValue)，仅图片=\(settings.preferHasImages ? "是" : "否")，\(manualRefreshSummary)"
            )

            if manualRefreshState == nil,
               settings.manualRefreshInProgress,
               settings.manualRefreshRequestedFamilyKey != context.family.logKey,
               let pinnedEntry = await WidgetDisplayedArtworkRegistry.shared.displayedEntry(
                forFamilyKey: context.family.logKey,
                date: now
               ) {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到手动刷新仅针对 \(settings.manualRefreshRequestedFamilyKey)，当前尺寸=\(context.family.logLabel) 保持原样，不参与这次刷新"
                )
                completion(Timeline(entries: [pinnedEntry], policy: .after(nextRefresh)))
                return
            }

            if let resolution = await resolveManualRefreshTimeline(
                settings: settings,
                state: manualRefreshState,
                context: context,
                now: now,
                deliveryID: deliveryID
            ) {
                switch resolution {
                case .loading(let entry, let retryDate):
                    completion(Timeline(entries: [entry], policy: .after(retryDate)))
                case .ready(let entries, let nextPolicyDate):
                    completion(Timeline(entries: entries, policy: .after(nextPolicyDate ?? nextRefresh)))
                }
                return
            }

            let entry: WidgetArtworkEntry
            do {
                entry = try await WidgetArtworkService(
                    settings: settings,
                    familyKey: context.family.logKey
                )
                    .fetchEntry(date: now)
                    .scoped(to: context.family, deliveryID: deliveryID)
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "timeline 刷新成功，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，图片尺寸=\(imageSummary(for: entry))，下次系统刷新时间约为 \(Self.logTimestampFormatter.string(from: nextRefresh))"
                )
            } catch {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "timeline 刷新失败，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，错误=\(error.localizedDescription)"
                )
                entry = WidgetArtworkEntry(
                    date: now,
                    renderID: "error-\(now.timeIntervalSince1970)",
                    deliveryID: deliveryID,
                    museumName: "大都会艺术博物馆",
                    title: "加载失败",
                    subtitle: error.localizedDescription,
                    imageFileName: nil,
                    appURL: nil,
                    isRefreshing: false
                )
                .scoped(to: context.family, deliveryID: deliveryID)
            }

            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func resolveManualRefreshTimeline(
        settings: WidgetSettingsReader,
        state: WidgetRefreshDeliveryTracker.State?,
        context: Context,
        now: Date,
        deliveryID: String
    ) async -> ManualRefreshTimelineResolution? {
        guard let state else {
            return nil
        }

        switch state.phase {
        case .generating:
            let retryDate = now.addingTimeInterval(Constants.loadingStateRetryInterval)
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "检测到手动刷新生成阶段，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，nonce=\(state.nonce)，\(state.progressSummary)，先展示加载态，并在 \(Self.logTimestampFormatter.string(from: retryDate)) 重试"
            )
            let loadingEntry = await WidgetArtworkService(
                settings: settings,
                familyKey: context.family.logKey
            )
                .makeLoadingEntry(date: now)
                .scoped(to: context.family, deliveryID: deliveryID)
            return .loading(entry: loadingEntry, retryDate: retryDate)
        case .delivering, .completed:
            let activeRefreshDate = Date(timeIntervalSince1970: state.startedAt)
            guard let targetRenderID = state.targetRenderID else {
                let retryDate = now.addingTimeInterval(Constants.loadingStateRetryInterval)
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到手动刷新状态缺少 renderID，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，nonce=\(state.nonce)，先展示加载态，并在 \(Self.logTimestampFormatter.string(from: retryDate)) 重试"
                )
                let loadingEntry = await WidgetArtworkService(
                    settings: settings,
                    familyKey: context.family.logKey
                )
                    .makeLoadingEntry(date: now)
                    .scoped(to: context.family, deliveryID: deliveryID)
                return .loading(entry: loadingEntry, retryDate: retryDate)
            }

            let service = WidgetArtworkService(
                settings: settings,
                familyKey: context.family.logKey
            )
            guard let manualRefreshEntry = await service.manualRefreshEntry(
                date: activeRefreshDate,
                targetRenderID: targetRenderID
            ) else {
                let retryDate = now.addingTimeInterval(Constants.loadingStateRetryInterval)
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "手动刷新结果尚未就绪，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，nonce=\(state.nonce)，renderID=\(targetRenderID)，先展示加载态，并在 \(Self.logTimestampFormatter.string(from: retryDate)) 重试"
                )
                let loadingEntry = await WidgetArtworkService(
                    settings: settings,
                    familyKey: context.family.logKey
                )
                    .makeLoadingEntry(date: now)
                    .scoped(to: context.family, deliveryID: deliveryID)
                return .loading(entry: loadingEntry, retryDate: retryDate)
            }
            let scheduledEntries = makeManualRefreshTimelineEntries(
                entry: manualRefreshEntry,
                state: state,
                family: context.family,
                now: now,
                deliveryID: deliveryID
            )

            let deliveryProgress = await recordManualRefreshDeliveryIfNeeded(
                state: state,
                context: context,
                deliveryID: deliveryID
            )
            let syncSummary = scheduledEntries.nextPolicyDate.map {
                "，桌面同步窗口中，将在 \(Self.logTimestampFormatter.string(from: $0)) 继续请求同一 renderID"
            } ?? ""
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "命中手动刷新结果，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，nonce=\(state.nonce)，phase=\(state.phase.rawValue)，renderID=\(targetRenderID)，图片尺寸=\(imageSummary(for: manualRefreshEntry))\(deliveryProgress)\(syncSummary)"
            )
            return .ready(entries: scheduledEntries.entries, nextPolicyDate: scheduledEntries.nextPolicyDate)
        }
    }

    private func makeManualRefreshTimelineEntries(
        entry: WidgetArtworkEntry,
        state: WidgetRefreshDeliveryTracker.State,
        family: WidgetFamily,
        now: Date,
        deliveryID: String
    ) -> ManualRefreshTimelineEntries {
        let currentEntry = entry.scoped(to: family, deliveryID: deliveryID).dated(now)
        guard state.phase == .completed,
              let syncStartedAt = WidgetDesktopSyncSchedule.syncStartedAt(for: state) else {
            return ManualRefreshTimelineEntries(entries: [currentEntry], nextPolicyDate: nil)
        }

        let futureEntries = WidgetDesktopSyncSchedule.remainingCheckpointDates(
            syncStartedAt: syncStartedAt,
            now: now
        ).map { checkpointDate in
            entry
                .scoped(
                    to: family,
                    deliveryID: "\(deliveryID)-sync-\(Int(checkpointDate.timeIntervalSince1970.rounded()))"
                )
                .dated(checkpointDate)
        }

        return ManualRefreshTimelineEntries(
            entries: [currentEntry] + futureEntries,
            nextPolicyDate: WidgetDesktopSyncSchedule.syncWindowEnd(for: state)
        )
    }

    private func recordManualRefreshDeliveryIfNeeded(
        state: WidgetRefreshDeliveryTracker.State?,
        context: Context,
        deliveryID: String
    ) async -> String {
        guard let state, state.phase == .delivering else {
            return ""
        }

        guard let updatedState = await WidgetRefreshDeliveryTracker.shared.recordDelivery(
            nonce: state.nonce,
            family: context.family,
            displaySize: context.displaySize,
            deliveryID: deliveryID
        ) else {
            return ""
        }

        return "，nonce=\(updatedState.nonce)，交付进度=\(updatedState.progressSummary)"
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private func imageSummary(for entry: WidgetArtworkEntry) -> String {
        guard let fileName = entry.imageFileName else {
            return "无图"
        }
        return WidgetArtworkSnapshotStore.imageDimensions(for: fileName)?.summary ?? "未知"
    }
}

private enum ManualRefreshTimelineResolution {
    case loading(entry: WidgetArtworkEntry, retryDate: Date)
    case ready(entries: [WidgetArtworkEntry], nextPolicyDate: Date?)
}

private struct ManualRefreshTimelineEntries {
    let entries: [WidgetArtworkEntry]
    let nextPolicyDate: Date?
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

    var logLabel: String {
        logKey
    }
}

private extension WidgetArtworkEntry {
    func dated(_ date: Date) -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: date,
            renderID: renderID,
            familyKey: familyKey,
            deliveryID: deliveryID,
            museumName: museumName,
            title: title,
            subtitle: subtitle,
            imageFileName: imageFileName,
            appURL: appURL,
            isRefreshing: isRefreshing
        )
    }
}
