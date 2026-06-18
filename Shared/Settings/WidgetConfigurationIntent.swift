import AppIntents
import Foundation

enum WidgetConfiguredMuseumScope: String, AppEnum, CaseIterable {
    case all
    case nmc
    case shm
    case met
    case tnm
    case nnm
    case guimet

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "展示范围")

    static var caseDisplayRepresentations: [WidgetConfiguredMuseumScope: DisplayRepresentation] = [
        .all: DisplayRepresentation(title: "所有博物馆"),
        .nmc: DisplayRepresentation(title: "中国国家博物馆"),
        .shm: DisplayRepresentation(title: "上海博物馆"),
        .met: DisplayRepresentation(title: "大都会艺术博物馆"),
        .tnm: DisplayRepresentation(title: "东京国立博物馆"),
        .nnm: DisplayRepresentation(title: "奈良国立博物馆"),
    .guimet: DisplayRepresentation(title: "吉美国立亚洲艺术博物馆"),
    ]

    var scope: WidgetMuseumScope {
        switch self {
        case .all:
            return .all
        case .met:
            return .single(.met)
        case .tnm:
            return .single(.tnm)
        case .nnm:
            return .single(.nnm)
        case .nmc:
            return .single(.nmc)
        case .shm:
            return .single(.shm)
        case .guimet:
            return .single(.guimet)
        }
    }

    init?(museumID: MuseumID) {
        switch museumID {
        case .met:
            self = .met
        case .tnm:
            self = .tnm
        case .nnm:
            self = .nnm
        case .nmc:
            self = .nmc
        case .shm:
            self = .shm
        case .guimet:
            self = .guimet
        }
    }
}

struct DailyMuseumWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "配置小组件"
    static var description = IntentDescription("为当前小组件选择展品展示范围。")

    @Parameter(title: "展示范围", default: .all)
    var museumScope: WidgetConfiguredMuseumScope

    @Parameter(title: "实例标识")
    var instanceToken: String?

    init() {
        // Retain the legacy field so existing widget configurations continue to decode,
        // but content sharing now keys off scope instead of per-instance tokens.
        instanceToken = ""
    }

    static var parameterSummary: some ParameterSummary {
        Summary("展示 \(\.$museumScope)")
    }
}
