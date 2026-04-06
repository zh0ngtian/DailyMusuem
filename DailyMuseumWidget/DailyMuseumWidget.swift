import WidgetKit
import SwiftUI

struct WidgetArtworkEntry: TimelineEntry {
    let date: Date
    let museumName: String
    let title: String
    let subtitle: String?
    let imageData: Data?
    let appURL: URL?
}

struct DailyMuseumWidget: Widget {
    let kind: String = "DailyMuseumWidget"

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
    func placeholder(in context: Context) -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: .now,
            museumName: "大都会艺术博物馆",
            title: "The Harvesters",
            subtitle: "1565",
            imageData: nil,
            appURL: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetArtworkEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetArtworkEntry>) -> Void) {
        Task {
            let settings = WidgetSettingsReader()
            let refresh = settings.refreshInterval
            let nextRefresh = Date().addingTimeInterval(refresh.seconds)

            let entry: WidgetArtworkEntry
            do {
                entry = try await WidgetArtworkService(settings: settings).fetchEntry(date: .now)
            } catch {
                entry = WidgetArtworkEntry(
                    date: .now,
                    museumName: "大都会艺术博物馆",
                    title: "加载失败",
                    subtitle: error.localizedDescription,
                    imageData: nil,
                    appURL: nil
                )
            }

            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}
