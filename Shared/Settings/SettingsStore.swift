import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults
    @Published private(set) var widgetRefreshInterval: WidgetRefreshInterval
    @Published private(set) var widgetAutoRefreshStartMinutes: Int
    @Published private(set) var widgetAutoRefreshEndMinutes: Int
    @Published private(set) var isMuseumLatencyTestEnabled: Bool
    @Published private(set) var naraMuseumDataSource: NaraMuseumDataSource

    init(defaults resolvedDefaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard) {
        defaults = resolvedDefaults
        widgetRefreshInterval = WidgetRefreshInterval.storedValue(in: resolvedDefaults)
        let autoRefreshWindow = WidgetAutoRefreshWindow.storedValue(in: resolvedDefaults)
        widgetAutoRefreshStartMinutes = autoRefreshWindow.startMinutes
        widgetAutoRefreshEndMinutes = autoRefreshWindow.endMinutes
        isMuseumLatencyTestEnabled = resolvedDefaults.bool(forKey: SettingsKeys.museumLatencyTestEnabled)
        naraMuseumDataSource = NaraMuseumDataSource.storedValue(in: resolvedDefaults)
    }

    func requestWidgetReload(invalidateContent: Bool = false) {
        defaults.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: SettingsKeys.widgetKind)
    }

    func saveWidgetRefreshInterval(_ interval: WidgetRefreshInterval) {
        widgetRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: SettingsKeys.widgetRefreshIntervalHours)
        requestWidgetReload()
    }

    func saveWidgetAutoRefreshStartMinutes(_ minutes: Int) {
        saveWidgetAutoRefreshWindow(
            startMinutes: minutes,
            endMinutes: widgetAutoRefreshEndMinutes
        )
    }

    func saveWidgetAutoRefreshEndMinutes(_ minutes: Int) {
        saveWidgetAutoRefreshWindow(
            startMinutes: widgetAutoRefreshStartMinutes,
            endMinutes: minutes
        )
    }

    func saveMuseumLatencyTestEnabled(_ isEnabled: Bool) {
        isMuseumLatencyTestEnabled = isEnabled
        defaults.set(isEnabled, forKey: SettingsKeys.museumLatencyTestEnabled)
        defaults.synchronize()
    }

    func saveNaraMuseumDataSource(_ dataSource: NaraMuseumDataSource) {
        naraMuseumDataSource = dataSource
        defaults.set(dataSource.rawValue, forKey: SettingsKeys.naraMuseumDataSource)
        defaults.synchronize()
        requestWidgetReload()
    }

    private func saveWidgetAutoRefreshWindow(startMinutes: Int, endMinutes: Int) {
        let normalizedWindow = WidgetAutoRefreshWindow(
            startMinutes: startMinutes,
            endMinutes: endMinutes
        )
        widgetAutoRefreshStartMinutes = normalizedWindow.startMinutes
        widgetAutoRefreshEndMinutes = normalizedWindow.endMinutes
        defaults.set(normalizedWindow.startMinutes, forKey: SettingsKeys.widgetAutoRefreshStartMinutes)
        defaults.set(normalizedWindow.endMinutes, forKey: SettingsKeys.widgetAutoRefreshEndMinutes)
        requestWidgetReload()
    }

    func feedCategories(for museumID: MuseumID) -> [MuseumCategory] {
        feedCategories(
            for: museumID,
            naraDataSource: museumID == .nnm ? naraMuseumDataSource : nil
        )
    }

    func feedCategories(for museumID: MuseumID, naraDataSource: NaraMuseumDataSource?) -> [MuseumCategory] {
        let key = SettingsKeys.feedCategoryKey(for: museumID, naraDataSource: naraDataSource)
        let storedValue = defaults.string(forKey: key)
        if museumID == .nnm, let naraDataSource {
            return museumID.feedCategories(withStoredValue: storedValue, naraDataSource: naraDataSource)
        }
        return museumID.feedCategories(withStoredValue: storedValue)
    }

    func saveFeedCategories(_ categories: [MuseumCategory], for museumID: MuseumID) {
        saveFeedCategories(
            categories,
            for: museumID,
            naraDataSource: museumID == .nnm ? naraMuseumDataSource : nil
        )
    }

    func saveFeedCategories(_ categories: [MuseumCategory], for museumID: MuseumID, naraDataSource: NaraMuseumDataSource?) {
        let normalized: [MuseumCategory]
        let storageValue: String
        if museumID == .nnm, let naraDataSource {
            normalized = museumID.normalizedFeedCategories(categories, naraDataSource: naraDataSource)
            storageValue = museumID.feedCategoryStorageValue(for: normalized, naraDataSource: naraDataSource)
        } else {
            normalized = museumID.normalizedFeedCategories(categories)
            storageValue = museumID.feedCategoryStorageValue(for: normalized)
        }
        defaults.set(storageValue, forKey: SettingsKeys.feedCategoryKey(for: museumID, naraDataSource: naraDataSource))
        defaults.synchronize()
        if museumID == .nnm {
            requestWidgetReload()
        }
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

    private func feedDisplayModeKey(for museumID: MuseumID) -> String {
        SettingsKeys.feedDisplayModePrefix + museumID.rawValue
    }
}
