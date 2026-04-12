import Foundation

struct WidgetSettingsReader {
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
    }

    var refreshInterval: WidgetRefreshInterval {
        let value = defaults.integer(forKey: SettingsKeys.widgetRefreshIntervalMinutes)
        return WidgetRefreshInterval(rawValue: value) ?? .oneHour
    }

    var museumScope: WidgetMuseumScope {
        let raw = defaults.string(forKey: SettingsKeys.widgetMuseumScope) ?? WidgetMuseumScope.all.rawValue
        return WidgetMuseumScope(rawValue: raw) ?? .all
    }

    var preferHasImages: Bool {
        if defaults.object(forKey: SettingsKeys.widgetPreferHasImages) == nil { return true }
        return defaults.bool(forKey: SettingsKeys.widgetPreferHasImages)
    }

    var manualRefreshNonce: TimeInterval {
        defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce)
    }

    var manualRefreshInProgress: Bool {
        defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress)
    }
}
