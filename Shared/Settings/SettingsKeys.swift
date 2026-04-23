import Foundation

enum SettingsKeys {
    static let appGroupID = "group.tech.zh0ngtian.DailyMuseum"
    static let widgetKind = "DailyMuseumWidget"
    static let feedCategoryPrefix = "feed.category."
    static let feedDisplayModePrefix = "feed.displayMode."
    static let widgetRefreshIntervalHours = "widget.refreshIntervalHours"
    static let museumDisplayOrder = "museum.displayOrder"
    static let favoritesArtworks = "favorites.artworks"
}

enum WidgetRefreshInterval: Int, CaseIterable, Identifiable, Equatable, Hashable {
    case off = 0
    case oneHour = 1
    case threeHours = 3
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24

    static let defaultValue: WidgetRefreshInterval = .off

    var id: Int { rawValue }

    var isEnabled: Bool {
        self != .off
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue) * 60 * 60
    }

    var displayName: String {
        if self == .off {
            return "关闭"
        }
        return "\(rawValue)小时"
    }

    static func storedValue(in defaults: UserDefaults) -> WidgetRefreshInterval {
        WidgetRefreshInterval(rawValue: defaults.integer(forKey: SettingsKeys.widgetRefreshIntervalHours)) ?? defaultValue
    }
}
