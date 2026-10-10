import AppIntents
import SwiftUI
import WidgetKit

struct WidgetArtworkEntry: TimelineEntry {
    let date: Date
    let renderID: String
    let refreshKey: String
    let scopeRawValue: String
    let phase: WidgetRefreshPhase
    let museumName: String
    let title: String
    let subtitle: String?
    let imageFileName: String?
    let appURL: URL?
    let failureMessage: String?
    var compatibilityGroupID: Int? = nil
}

struct DailyMuseumWidget: Widget {
    static let kind = SettingsKeys.widgetKind
    let kind: String = DailyMuseumWidget.kind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: DailyMuseumWidgetConfigurationIntent.self,
            provider: DailyMuseumWidgetProvider()
        ) { entry in
            DailyMuseumWidgetView(entry: entry)
        }
        .configurationDisplayName("MuseumMuse")
        .description("自动或手动刷新展示一件展品")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct CompatibleMuseumWidget<Slot: CompatibleWidgetSlot>: Widget {
    private var group: WidgetCompatibilityGroup { WidgetCompatibilityGroup(id: Slot.id)! }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: group.kind, provider: CompatibleMuseumWidgetProvider(group: group)) {
            DailyMuseumWidgetView(entry: $0)
        }
        .configurationDisplayName(Text(verbatim: "博物女神 · \(group.name)"))
        .description("在 App 中为本组选馆，同组尺寸同步，点击刷新打开 App")
        .supportedFamilies(WidgetCompatibilityGroup.supportedFamilies)
        .contentMarginsDisabled()
    }
}

struct DailyMuseumWidgetProvider: AppIntentTimelineProvider {
    private let content = WidgetArtworkTimelineContent()
    func placeholder(in context: Context) -> WidgetArtworkEntry { content.placeholder() }
    func snapshot(for configuration: DailyMuseumWidgetConfigurationIntent, in context: Context) async -> WidgetArtworkEntry {
        await content.entry(scope: configuration.museumScope.scope, date: .now, family: context.family,
                            persistRenderState: false, logRender: false)
    }
    func timeline(for configuration: DailyMuseumWidgetConfigurationIntent, in context: Context) async -> Timeline<WidgetArtworkEntry> {
        await content.timeline(scope: configuration.museumScope.scope, family: context.family, isPreview: context.isPreview)
    }
}

struct CompatibleMuseumWidgetProvider: TimelineProvider {
    let group: WidgetCompatibilityGroup
    private let content = WidgetArtworkTimelineContent()
    func placeholder(in context: Context) -> WidgetArtworkEntry { content.placeholder(group: group) }
    func getSnapshot(in context: Context, completion: @escaping (WidgetArtworkEntry) -> Void) {
        Task {
            completion(await content.entry(scope: WidgetCompatibilityScope.read(group: group), date: .now, family: context.family, group: group,
                                           persistRenderState: false, logRender: false))
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetArtworkEntry>) -> Void) {
        Task {
            completion(await content.timeline(scope: WidgetCompatibilityScope.read(group: group), family: context.family, isPreview: context.isPreview, group: group))
        }
    }
}

private struct WidgetArtworkTimelineContent {
    private let settingsReader = WidgetSettingsReader()
    func placeholder(group: WidgetCompatibilityGroup? = nil) -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: .now,
            renderID: "placeholder",
            refreshKey: "placeholder",
            scopeRawValue: WidgetMuseumScope.all.rawValue,
            phase: .idle,
            museumName: "MuseumMuse",
            title: "点击刷新获取展品",
            subtitle: SettingsKeys.widgetIdleSubtitle,
            imageFileName: nil,
            appURL: nil,
            failureMessage: nil,
            compatibilityGroupID: group?.id
        )
    }

    func timeline(scope: WidgetMuseumScope, family: WidgetFamily, isPreview: Bool, group: WidgetCompatibilityGroup? = nil) async -> Timeline<WidgetArtworkEntry> {
        let refreshKey = group?.refreshKey(scope: scope) ?? WidgetRefreshGroupKey.make(scope: scope, family: family)
        let store = WidgetArtworkSnapshotStore.shared
        let now = Date()
        let canPersistTimeline = await shouldPersistTimeline(
            refreshKey: refreshKey,
            scope: scope,
            family: family,
            isPreview: isPreview
        )

        guard canPersistTimeline else {
            let entry = await entry(
                scope: scope,
                date: now,
                family: family,
                group: group,
                persistRenderState: false,
                logRender: false
            )
            return Timeline(entries: [entry], policy: .never)
        }

        let schedule = settingsReader.widgetAutoRefreshSchedule()
        let automaticRefreshResolution = await store.resolveAutomaticRefresh(
            for: refreshKey,
            scopeRawValue: scope.rawValue,
            familyToken: family.debugToken,
            schedule: schedule,
            now: now
        )

        if automaticRefreshResolution.shouldRefresh,
           let scheduledAt = automaticRefreshResolution.scheduledAt {
            await WidgetRefreshCoordinator.shared.refresh(
                refreshKey: refreshKey,
                scope: scope,
                familyToken: family.debugToken,
                trigger: .automatic(scheduledAt: scheduledAt),
                logSource: "Widget 自动刷新",
                reloadTimelines: false
            )
        }

        let entryDate = Date()
        let entry = await entry(
            scope: scope,
            date: entryDate,
            family: family,
            group: group,
            persistRenderState: true,
            logRender: true
        )
        if let nextRefreshDate = automaticRefreshResolution.nextAutomaticRefreshAt {
            return Timeline(entries: [entry], policy: .after(nextRefreshDate))
        }
        return Timeline(entries: [entry], policy: .never)
    }

    func entry(
        scope: WidgetMuseumScope,
        date: Date,
        family: WidgetFamily?,
        group: WidgetCompatibilityGroup? = nil,
        persistRenderState: Bool,
        logRender: Bool
    ) async -> WidgetArtworkEntry {
        let refreshKey = group?.refreshKey(scope: scope) ?? WidgetRefreshGroupKey.make(scope: scope, family: family)
        let store = WidgetArtworkSnapshotStore.shared
        let state: WidgetArtworkSnapshotStore.InstanceState?
        if persistRenderState {
            state = await store.renderState(
                for: refreshKey,
                scopeRawValue: scope.rawValue,
                familyToken: family?.debugToken,
                now: date
            )
        } else {
            state = await store.presentationState(
                for: refreshKey,
                scopeRawValue: scope.rawValue
            )
        }
        let phase = state?.phase ?? .idle
        let renderID = "\(refreshKey)|\(scope.rawValue)|\(state?.nonce ?? 0)|\(phase.rawValue)"
        if logRender {
            await RequestLogger.shared.logEvent(
                source: "Widget 完成渲染",
                summary: "family=\(family?.debugToken ?? "unknown") scope=\(scope.rawValue) phase=\(phase.rawValue)",
                instanceToken: refreshKey
            )
        }

        switch phase {
        case .success:
            if let artwork = state?.artwork {
                return WidgetArtworkEntry(
                    date: date,
                    renderID: renderID,
                    refreshKey: refreshKey,
                    scopeRawValue: scope.rawValue,
                    phase: .success,
                    museumName: artwork.museumName,
                    title: artwork.title,
                    subtitle: artwork.subtitle,
                    imageFileName: artwork.imageFileName,
                    appURL: artwork.appURL,
                    failureMessage: nil,
                    compatibilityGroupID: group?.id
                )
            }
        case .failure:
            return WidgetArtworkEntry(
                date: date,
                renderID: renderID,
                refreshKey: refreshKey,
                scopeRawValue: scope.rawValue,
                phase: .failure,
                museumName: scope.displayName,
                title: "刷新失败",
                subtitle: state?.failureMessage,
                imageFileName: nil,
                appURL: nil,
                failureMessage: state?.failureMessage,
                compatibilityGroupID: group?.id
            )
        case .idle, .refreshing:
            break
        }

        return WidgetArtworkEntry(
            date: date,
            renderID: renderID,
            refreshKey: refreshKey,
            scopeRawValue: scope.rawValue,
            phase: .idle,
            museumName: scope.displayName,
            title: "点击刷新获取展品",
            subtitle: SettingsKeys.widgetIdleSubtitle,
            imageFileName: nil,
            appURL: nil,
            failureMessage: nil,
            compatibilityGroupID: group?.id
        )
    }

    private func shouldPersistTimeline(
        refreshKey: String,
        scope: WidgetMuseumScope,
        family: WidgetFamily,
        isPreview: Bool
    ) async -> Bool {
        guard !isPreview else {
            return false
        }

        do {
            let targets = try await WidgetCenterCurrentConfigurationResolver().refreshTargets()
            await WidgetArtworkSnapshotStore.shared.removeInstances(
                excludingRefreshKeys: Set(targets.map(\.refreshKey))
            )
            return targets.contains { target in
                target.refreshKey == refreshKey && target.scope == scope && target.familyToken == family.debugToken
            }
        } catch {
            return true
        }
    }

}

private extension WidgetMuseumScope {
    var displayName: String {
        switch self {
        case .all:
            return "所有博物馆"
        case .single(let museumID):
            return museumID.displayName
        }
    }
}

protocol CompatibleWidgetSlot { static var id: Int { get } }
enum CompatibleWidgetSlot1: CompatibleWidgetSlot { static let id = 1 }
enum CompatibleWidgetSlot2: CompatibleWidgetSlot { static let id = 2 }
enum CompatibleWidgetSlot3: CompatibleWidgetSlot { static let id = 3 }
enum CompatibleWidgetSlot4: CompatibleWidgetSlot { static let id = 4 }
enum CompatibleWidgetSlot5: CompatibleWidgetSlot { static let id = 5 }
enum CompatibleWidgetSlot6: CompatibleWidgetSlot { static let id = 6 }
enum CompatibleWidgetSlot7: CompatibleWidgetSlot { static let id = 7 }
enum CompatibleWidgetSlot8: CompatibleWidgetSlot { static let id = 8 }
enum CompatibleWidgetSlot9: CompatibleWidgetSlot { static let id = 9 }
enum CompatibleWidgetSlot10: CompatibleWidgetSlot { static let id = 10 }
