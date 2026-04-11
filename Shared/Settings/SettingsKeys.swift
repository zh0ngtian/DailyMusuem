import Foundation

enum SettingsKeys {
    static let appGroupID = "group.tech.zh0ngtian.DailyMuseum"
    static let legacyAppGroupID = "group.com.example.DailyMuseum"
    static let feedRandomOrder = "feed.randomOrder"
    static let museumDisplayOrder = "museum.displayOrder"
    static let translationEngine = "translation.engine"
    static let widgetManualRefreshNonce = "widget.manualRefreshNonce"
    static let widgetRefreshIntervalMinutes = "widget.refreshIntervalMinutes"
    static let widgetMuseumScope = "widget.museumScope"
    static let widgetPreferHasImages = "widget.preferHasImages"

    static let defaultsBackedKeys: [String] = [
        feedRandomOrder,
        museumDisplayOrder,
        translationEngine,
        widgetManualRefreshNonce,
        widgetRefreshIntervalMinutes,
        widgetMuseumScope,
        widgetPreferHasImages
    ]
}
