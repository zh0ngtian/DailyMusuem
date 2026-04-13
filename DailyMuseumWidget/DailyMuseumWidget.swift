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
            let manualRefreshState = await settings.activeManualRefreshDeliveryState(now: now)
            let activeRefreshDate = manualRefreshState.map { Date(timeIntervalSince1970: $0.startedAt) } ?? now
            let manualRefreshSummary = manualRefreshState.map {
                "nonce=\($0.nonce)，phase=\($0.phase.rawValue)，交付进度=\($0.progressSummary)"
            } ?? "nonce=\(settings.manualRefreshNonceValue)"

            if settings.manualRefreshInProgress, manualRefreshState?.phase == .generating {
                let retryDate = now.addingTimeInterval(Constants.loadingStateRetryInterval)
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到手动刷新生成阶段，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，\(manualRefreshSummary)，先展示加载态，并在 \(Self.logTimestampFormatter.string(from: retryDate)) 重试"
                )
                let loadingEntry = await WidgetArtworkService(settings: settings)
                    .makeLoadingEntry(date: now)
                    .scoped(to: context.family, deliveryID: deliveryID)
                completion(Timeline(entries: [loadingEntry], policy: .after(retryDate)))
                return
            }

            if settings.manualRefreshInProgress, manualRefreshState == nil {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到手动刷新标记，但未找到交付追踪状态，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，直接返回最新内容"
                )
            }

            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "开始刷新 timeline，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)，范围=\(settings.museumScope.rawValue)，仅图片=\(settings.preferHasImages ? "是" : "否")，\(manualRefreshSummary)"
            )

            let entry: WidgetArtworkEntry
            do {
                entry = try await WidgetArtworkService(settings: settings)
                    .fetchEntry(date: activeRefreshDate)
                    .scoped(to: context.family, deliveryID: deliveryID)
                let deliveryProgress = await recordManualRefreshDeliveryIfNeeded(
                    state: manualRefreshState,
                    context: context,
                    deliveryID: deliveryID
                )
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "timeline 刷新成功，尺寸=\(context.family.logLabel)，displaySize=\(context.displaySize.widgetLogLabel)，deliveryID=\(deliveryID)\(deliveryProgress)，下次系统刷新时间约为 \(Self.logTimestampFormatter.string(from: nextRefresh))"
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
