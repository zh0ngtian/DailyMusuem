import AppIntents
import Foundation

struct WidgetConfiguredMuseumScope: AppEntity, Codable, Hashable, Identifiable, Sendable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "展示范围")
    static var defaultQuery = WidgetConfiguredMuseumScopeQuery()

    static let all = WidgetConfiguredMuseumScope(scope: .all)

    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: displayName))
    }

    var scope: WidgetMuseumScope {
        WidgetMuseumScope(rawValue: id) ?? .all
    }

    init(scope: WidgetMuseumScope) {
        id = scope.rawValue
        displayName = scope.displayName
    }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(museumID: MuseumID) {
        self.init(scope: .single(museumID))
    }
}

struct WidgetConfiguredMuseumScopeQuery: EntityQuery {
    func entities(for identifiers: [WidgetConfiguredMuseumScope.ID]) async throws -> [WidgetConfiguredMuseumScope] {
        let suggested = try await suggestedEntities()
        let suggestedByID = Dictionary(uniqueKeysWithValues: suggested.map { ($0.id, $0) })
        return identifiers.compactMap { identifier in
            if let known = suggestedByID[identifier] {
                return known
            }
            guard let scope = WidgetMuseumScope(rawValue: identifier) else {
                return nil
            }
            return WidgetConfiguredMuseumScope(scope: scope)
        }
    }

    func suggestedEntities() async throws -> [WidgetConfiguredMuseumScope] {
        let metadataMuseums = MuseumMetadataStore.cachedSnapshot()?.museums
            .filter { $0.capabilities.supportsWidgetContent }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }

        let metadataWidgetMuseums = metadataMuseums?.map { $0.toMuseum() } ?? []
        return [WidgetConfiguredMuseumScope.all] + metadataWidgetMuseums.map { museum in
            WidgetConfiguredMuseumScope(
                id: WidgetMuseumScope.single(museum.id).rawValue,
                displayName: museum.displayName
            )
        }
    }

    func defaultResult() async -> WidgetConfiguredMuseumScope? {
        .all
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
        instanceToken = ""
        museumScope = .all
    }

    static var parameterSummary: some ParameterSummary {
        Summary("展示 \(\.$museumScope)")
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
