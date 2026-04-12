import WidgetKit
import SwiftUI

struct WidgetArtworkEntry: TimelineEntry {
    let date: Date
    let museumName: String
    let title: String
    let subtitle: String?
    let imageData: Data?
    let appURL: URL?
    let isRefreshing: Bool
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
            museumName: "大都会艺术博物馆",
            title: "The Harvesters",
            subtitle: "1565",
            imageData: nil,
            appURL: nil,
            isRefreshing: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetArtworkEntry) -> Void) {
        Task {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: context.isPreview ? "请求快照预览" : "请求临时快照"
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

            if settings.manualRefreshInProgress {
                let retryDate = now.addingTimeInterval(Constants.loadingStateRetryInterval)
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到手动刷新进行中，先展示加载态，并在 \(Self.logTimestampFormatter.string(from: retryDate)) 重试"
                )
                let loadingEntry = await WidgetArtworkService(settings: settings).makeLoadingEntry(date: now)
                completion(Timeline(entries: [loadingEntry], policy: .after(retryDate)))
                return
            }

            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "开始刷新 timeline，范围=\(settings.museumScope.rawValue)，仅图片=\(settings.preferHasImages ? "是" : "否")"
            )

            let entry: WidgetArtworkEntry
            do {
                entry = try await WidgetArtworkService(settings: settings).fetchEntry(date: now)
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "timeline 刷新成功，下次系统刷新时间约为 \(Self.logTimestampFormatter.string(from: nextRefresh))"
                )
            } catch {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "timeline 刷新失败：\(error.localizedDescription)"
                )
                entry = WidgetArtworkEntry(
                    date: now,
                    museumName: "大都会艺术博物馆",
                    title: "加载失败",
                    subtitle: error.localizedDescription,
                    imageData: nil,
                    appURL: nil,
                    isRefreshing: false
                )
            }

            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
