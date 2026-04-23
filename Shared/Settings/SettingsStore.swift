import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults
    @Published private(set) var widgetRefreshInterval: WidgetRefreshInterval

    private init() {
        let resolvedDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        defaults = resolvedDefaults
        widgetRefreshInterval = WidgetRefreshInterval.storedValue(in: resolvedDefaults)
    }

    func requestWidgetReload(invalidateContent: Bool = false) {
        defaults.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: SettingsKeys.widgetKind)
    }

    func forceRefreshAllWidgets(logSource: String = "App 快捷操作") {
        Task {
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "触发刷新全部已登记的小组件实例"
            )
            await WidgetRefreshCoordinator.shared.refreshAllKnownInstances(logSource: logSource)
        }
    }

    func saveWidgetRefreshInterval(_ interval: WidgetRefreshInterval) {
        widgetRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: SettingsKeys.widgetRefreshIntervalHours)
        requestWidgetReload()
    }

    func feedCategories(for museumID: MuseumID) -> [MuseumCategory] {
        museumID.feedCategories(withStoredValue: defaults.string(forKey: feedCategoryKey(for: museumID)))
    }

    func saveFeedCategories(_ categories: [MuseumCategory], for museumID: MuseumID) {
        let normalized = museumID.normalizedFeedCategories(categories)
        defaults.set(museumID.feedCategoryStorageValue(for: normalized), forKey: feedCategoryKey(for: museumID))
        defaults.synchronize()
    }

    func feedCategory(for museumID: MuseumID) -> MuseumCategory {
        feedCategories(for: museumID).first ?? museumID.defaultFeedCategory
    }

    func saveFeedCategory(_ category: MuseumCategory, for museumID: MuseumID) {
        saveFeedCategories([category], for: museumID)
    }

    func feedDisplayModeRawValue(for museumID: MuseumID) -> String? {
        defaults.string(forKey: feedDisplayModeKey(for: museumID))
    }

    func saveFeedDisplayModeRawValue(_ rawValue: String, for museumID: MuseumID) {
        defaults.set(rawValue, forKey: feedDisplayModeKey(for: museumID))
        defaults.synchronize()
    }

    private func feedCategoryKey(for museumID: MuseumID) -> String {
        SettingsKeys.feedCategoryPrefix + museumID.rawValue
    }

    private func feedDisplayModeKey(for museumID: MuseumID) -> String {
        SettingsKeys.feedDisplayModePrefix + museumID.rawValue
    }
}
