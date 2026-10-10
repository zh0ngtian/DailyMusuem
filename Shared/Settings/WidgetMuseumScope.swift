import Foundation
import WidgetKit

enum WidgetMuseumScope: Hashable, Codable {
    case all
    case single(MuseumID)
}

extension WidgetMuseumScope {
    var rawValue: String {
        switch self {
        case .all:
            return "all"
        case .single(let id):
            return "single:\(id.rawValue)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "all" { self = .all; return }
        if rawValue.hasPrefix("single:") {
            let value = String(rawValue.dropFirst("single:".count))
            if let id = MuseumID(rawValue: value) {
                self = .single(id)
                return
            }
        }
        return nil
    }
}

struct WidgetRefreshGroupKey {
    static func make(scope: WidgetMuseumScope, family: WidgetFamily?) -> String {
        _ = family
        return scope.rawValue
    }

    static func make(scopeRawValue: String, familyToken: String) -> String {
        _ = familyToken
        return scopeRawValue
    }
}

extension WidgetFamily {
    var debugToken: String {
        if #available(iOS 27.0, *), self == .systemExtraLargePortrait { return "extraLargePortrait" }
        switch self {
        case .systemSmall:
            return "small"
        case .systemMedium:
            return "medium"
        case .systemLarge:
            return "large"
        default:
            return "other"
        }
    }
}

// Static widgets read this shared preference instead of an AppIntent parameter.
enum WidgetCompatibilityScope {
    static func read(group: WidgetCompatibilityGroup = .first, from defaults: UserDefaults = SettingsKeys.sharedDefaults) -> WidgetMuseumScope {
        defaults.synchronize()
        guard let raw = defaults.string(forKey: group.preferenceKey),
              let scope = WidgetMuseumScope(rawValue: raw) else { return .all }
        if case .single(let id) = scope,
           let snapshot = MuseumMetadataStore.cachedSnapshot(),
           !snapshot.museums.contains(where: { $0.id == id && $0.capabilities.supportsWidgetContent }) {
            return .all
        }
        return scope
    }
}

struct WidgetCompatibilityGroup: Hashable, Identifiable, Sendable {
    let id: Int
    static let first = WidgetCompatibilityGroup(id: 1)!
    static let all = (1...10).map { WidgetCompatibilityGroup(id: $0)! }

    init?(id: Int) {
        guard (1...10).contains(id) else { return nil }
        self.id = id
    }

    var name: String { "第 \(id) 组" }
    // Keep the installed widget and its existing preference as group 1.
    var kind: String { id == 1 ? SettingsKeys.widgetKind : "\(SettingsKeys.widgetKind).group\(id)" }
    var preferenceKey: String {
        id == 1 ? SettingsKeys.widgetCompatibilityScope : SettingsKeys.storageKey("widget.compatibilityScope.v1.group\(id)")
    }
    var refreshURL: URL {
        URL(string: "dailymuseum://widget/refresh?group=\(id)")!
    }
    func refreshKey(scope: WidgetMuseumScope) -> String { "compat:\(id)|\(scope.rawValue)" }

    static func from(kind: String) -> Self? { all.first { $0.kind == kind } }
    static func from(refreshKey: String) -> Self? {
        let parts = refreshKey.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("compat:"),
              let id = Int(parts[0].dropFirst(7)), let group = Self(id: id),
              let scope = WidgetMuseumScope(rawValue: parts[1]),
              group.refreshKey(scope: scope) == refreshKey else { return nil }
        return group
    }
    static func from(refreshURL url: URL) -> Self? {
        guard url.scheme == "dailymuseum", url.host == "widget", url.path == "/refresh" else { return nil }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "group" } ?? []
        if values.isEmpty { return .first } // Existing installed snapshots.
        guard values.count == 1, let value = values[0].value, let id = Int(value) else { return nil }
        return Self(id: id)
    }
    static var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        return families
    }
}
