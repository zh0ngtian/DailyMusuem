import Foundation

enum SettingsKeys {
    static let appGroupID = "group.tech.zh0ngtian.DailyMuseum"
    static let legacyAppGroupID = "group.com.example.DailyMuseum"
    static let widgetKind = "DailyMuseumWidget"
    static let feedRandomOrder = "feed.randomOrder"
    static let feedCategoryPrefix = "feed.category."
    static let feedDisplayModePrefix = "feed.displayMode."
    static let museumDisplayOrder = "museum.displayOrder"
    static let translationEngine = "translation.engine"
    static let widgetManualRefreshNonce = "widget.manualRefreshNonce"
    static let widgetManualRefreshInProgress = "widget.manualRefreshInProgress"
    static let widgetRefreshIntervalMinutes = "widget.refreshIntervalMinutes"
    static let widgetMuseumScope = "widget.museumScope"
    static let widgetCategoryPrefix = "widget.category."
    static let widgetPreferHasImages = "widget.preferHasImages"

    static let defaultsBackedKeys: [String] = [
        feedRandomOrder,
        museumDisplayOrder,
        translationEngine,
        widgetManualRefreshNonce,
        widgetManualRefreshInProgress,
        widgetRefreshIntervalMinutes,
        widgetMuseumScope,
        widgetPreferHasImages
    ]
}
