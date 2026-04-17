import AppIntents
import SwiftUI
import WidgetKit

struct WidgetArtworkEntry: TimelineEntry {
    let date: Date
    let renderID: String
    let instanceToken: String
    let scopeRawValue: String
    let phase: WidgetRefreshPhase
    let museumName: String
    let title: String
    let subtitle: String?
    let imageFileName: String?
    let appURL: URL?
    let failureMessage: String?

    var isRefreshing: Bool {
        phase == .refreshing
    }
}

enum WidgetConfiguredMuseumScope: String, AppEnum, CaseIterable {
    case all
    case met
    case tnm
    case nmc
    case shm

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "展示范围")

    static var caseDisplayRepresentations: [WidgetConfiguredMuseumScope: DisplayRepresentation] = [
        .all: DisplayRepresentation(title: "所有博物馆"),
        .met: DisplayRepresentation(title: "大都会艺术博物馆"),
        .tnm: DisplayRepresentation(title: "东京国立博物馆"),
        .nmc: DisplayRepresentation(title: "中国国家博物馆"),
        .shm: DisplayRepresentation(title: "上海博物馆"),
    ]

    var scope: WidgetMuseumScope {
        switch self {
        case .all:
            return .all
        case .met:
            return .single(.met)
        case .tnm:
            return .single(.tnm)
        case .nmc:
            return .single(.nmc)
        case .shm:
            return .single(.shm)
        }
    }
}

struct DailyMuseumWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "配置小组件"
    static var description = IntentDescription("为当前小组件实例单独选择展示范围。")

    @Parameter(title: "展示范围")
    var museumScope: WidgetConfiguredMuseumScope?

    @Parameter(title: "实例标识")
    var instanceToken: String?

    init() {
        museumScope = .all
        instanceToken = nil
    }

    static var parameterSummary: some ParameterSummary {
        Summary("展示 \(\.$museumScope)")
    }
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
        .configurationDisplayName("DailyMuseum")
        .description("手动刷新展示一件展品")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct DailyMuseumWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: .now,
            renderID: "placeholder",
            instanceToken: "placeholder",
            scopeRawValue: WidgetMuseumScope.all.rawValue,
            phase: .idle,
            museumName: "DailyMuseum",
            title: "点击刷新获取展品",
            subtitle: "每个小组件实例独立刷新",
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
            family: context.family
        )
    }

    func timeline(
        for configuration: DailyMuseumWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<WidgetArtworkEntry> {
        let entry = await entry(
            for: configuration,
            date: .now,
            family: context.family
        )
        return Timeline(entries: [entry], policy: .never)
    }

    private func entry(
        for configuration: DailyMuseumWidgetConfigurationIntent,
        date: Date,
        family: WidgetFamily?
    ) async -> WidgetArtworkEntry {
        let scope = configuration.museumScope?.scope ?? .all
        let resolvedInstanceToken = WidgetInstanceTokenResolver.resolve(
            from: configuration.instanceToken ?? "",
            scope: scope,
            family: family
        )
        let store = WidgetArtworkSnapshotStore.shared
        let exactState = await store.state(for: resolvedInstanceToken)
        let adoptedState: WidgetArtworkSnapshotStore.InstanceState?
        if exactState == nil {
            adoptedState = await store.mostRecentDisplayableState(scopeRawValue: scope.rawValue)
        } else {
            adoptedState = nil
        }
        let state: WidgetArtworkSnapshotStore.InstanceState
        if let exactState {
            state = exactState
        } else if let adoptedState {
            state = adoptedState
        } else {
            state = await store.registerInstance(
                instanceToken: resolvedInstanceToken,
                scopeRawValue: scope.rawValue,
                now: date
            )
        }
        let effectiveInstanceToken = adoptedState?.instanceToken ?? resolvedInstanceToken
        let renderID = "\(effectiveInstanceToken)|\(state.nonce)|\(state.phase.rawValue)"
        let stateSource: String
        if exactState != nil {
            stateSource = "exact"
        } else if adoptedState != nil {
            stateSource = "adopted"
        } else {
            stateSource = "registered"
        }
        await RequestLogger.shared.logEvent(
            source: "Widget Provider",
            summary: "family=\(family?.debugToken ?? "unknown") scope=\(scope.rawValue) resolved=\(resolvedInstanceToken) effective=\(effectiveInstanceToken) source=\(stateSource) phase=\(state.phase.rawValue)"
        )

        switch state.phase {
        case .success:
            if let artwork = state.artwork {
                return WidgetArtworkEntry(
                    date: date,
                    renderID: renderID,
                    instanceToken: effectiveInstanceToken,
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
        case .refreshing:
            if let artwork = state.artwork {
                return WidgetArtworkEntry(
                    date: date,
                    renderID: renderID,
                    instanceToken: effectiveInstanceToken,
                    scopeRawValue: scope.rawValue,
                    phase: .refreshing,
                    museumName: artwork.museumName,
                    title: artwork.title,
                    subtitle: artwork.subtitle,
                    imageFileName: artwork.imageFileName,
                    appURL: artwork.appURL,
                    failureMessage: nil
                )
            }

            return WidgetArtworkEntry(
                date: date,
                renderID: renderID,
                instanceToken: effectiveInstanceToken,
                scopeRawValue: scope.rawValue,
                phase: .refreshing,
                museumName: scope.displayName,
                title: "刷新中",
                subtitle: "正在拉取新展品",
                imageFileName: nil,
                appURL: nil,
                failureMessage: nil
            )
        case .failure:
            return WidgetArtworkEntry(
                date: date,
                renderID: renderID,
                instanceToken: effectiveInstanceToken,
                scopeRawValue: scope.rawValue,
                phase: .failure,
                museumName: scope.displayName,
                title: "刷新失败",
                subtitle: state.failureMessage,
                imageFileName: nil,
                appURL: nil,
                failureMessage: state.failureMessage
            )
        case .idle:
            break
        }

        return WidgetArtworkEntry(
            date: date,
            renderID: renderID,
            instanceToken: effectiveInstanceToken,
            scopeRawValue: scope.rawValue,
            phase: .idle,
            museumName: scope.displayName,
            title: "点击刷新获取展品",
            subtitle: "当前实例独立刷新",
            imageFileName: nil,
            appURL: nil,
            failureMessage: nil
        )
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
