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

struct DailyMuseumWidgetProvider: AppIntentTimelineProvider {
    private let settingsReader = WidgetSettingsReader()

    func placeholder(in context: Context) -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: .now,
            renderID: "placeholder",
            refreshKey: "placeholder",
            scopeRawValue: WidgetMuseumScope.all.rawValue,
            phase: .idle,
            museumName: "MuseumMuse",
            title: "点击刷新获取展品",
            subtitle: "长按小组件，选择「编辑小组件」以改变展品展示范围",
            imageFileName: nil,
            appURL: nil,
            failureMessage: nil
        )
    }

    func snapshot(
        for configuration: DailyMuseumWidgetConfigurationIntent,
        in context: Context
    ) async -> WidgetArtworkEntry {
        await entry(
            for: configuration,
            date: .now,
            family: context.family,
            persistRenderState: false,
            logRender: false
        )
    }

    func timeline(
        for configuration: DailyMuseumWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<WidgetArtworkEntry> {
        let scope = scope(for: configuration)
        let refreshKey = WidgetRefreshGroupKey.make(scope: scope, family: context.family)
        let store = WidgetArtworkSnapshotStore.shared
        let now = Date()
        let canPersistTimeline = await shouldPersistTimeline(
            scope: scope,
            family: context.family,
            isPreview: context.isPreview
        )

        guard canPersistTimeline else {
            let entry = await entry(
                for: configuration,
                date: now,
                family: context.family,
                persistRenderState: false,
                logRender: false
            )
            return Timeline(entries: [entry], policy: .never)
        }

        let schedule = settingsReader.widgetAutoRefreshSchedule()
        let automaticRefreshResolution = await store.resolveAutomaticRefresh(
            for: refreshKey,
            scopeRawValue: scope.rawValue,
            familyToken: context.family.debugToken,
            schedule: schedule,
            now: now
        )

        if automaticRefreshResolution.shouldRefresh,
           let scheduledAt = automaticRefreshResolution.scheduledAt {
            await WidgetRefreshCoordinator.shared.refresh(
                refreshKey: refreshKey,
                scope: scope,
                familyToken: context.family.debugToken,
                trigger: .automatic(scheduledAt: scheduledAt),
                logSource: "Widget 自动刷新",
                reloadTimelines: false
            )
        }

        let entryDate = Date()
        let entry = await entry(
            for: configuration,
            date: entryDate,
            family: context.family,
            persistRenderState: true,
            logRender: true
        )
        if let nextRefreshDate = automaticRefreshResolution.nextAutomaticRefreshAt {
            return Timeline(entries: [entry], policy: .after(nextRefreshDate))
        }
        return Timeline(entries: [entry], policy: .never)
    }

    private func entry(
        for configuration: DailyMuseumWidgetConfigurationIntent,
        date: Date,
        family: WidgetFamily?,
        persistRenderState: Bool,
        logRender: Bool
    ) async -> WidgetArtworkEntry {
        let scope = scope(for: configuration)
        let refreshKey = WidgetRefreshGroupKey.make(scope: scope, family: family)
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
                    failureMessage: nil
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
                failureMessage: state?.failureMessage
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
            subtitle: "长按小组件，选择「编辑小组件」以改变展品展示范围",
            imageFileName: nil,
            appURL: nil,
            failureMessage: nil
        )
    }

    private func scope(for configuration: DailyMuseumWidgetConfigurationIntent) -> WidgetMuseumScope {
        configuration.museumScope.scope
    }

    private func shouldPersistTimeline(
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
                target.scope == scope && target.familyToken == family.debugToken
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
