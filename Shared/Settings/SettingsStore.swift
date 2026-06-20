import Foundation
import SwiftUI
import WidgetKit

struct AppConfigurationExport: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let userDefaults: [String: AppConfigurationValue]
    let widgetDisplayedArtworkHistory: [String: [String]]

    init(
        version: Int = Self.currentVersion,
        exportedAt: Date = .now,
        userDefaults: [String: AppConfigurationValue],
        widgetDisplayedArtworkHistory: [String: [String]]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.userDefaults = userDefaults
        self.widgetDisplayedArtworkHistory = widgetDisplayedArtworkHistory
    }
}

enum AppConfigurationValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringArray([String])
    case data(Data)

    init?(userDefaultsObject object: Any) {
        if let value = object as? Bool {
            self = .bool(value)
            return
        }

        if let value = object as? Int {
            self = .int(value)
            return
        }

        if let value = object as? Double {
            self = .double(value)
            return
        }

        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
                return
            }

            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue {
                self = .int(number.intValue)
            } else {
                self = .double(doubleValue)
            }
            return
        }

        if let value = object as? String {
            self = .string(value)
            return
        }

        if let value = object as? [String] {
            self = .stringArray(value)
            return
        }

        if let value = object as? Data {
            self = .data(value)
            return
        }

        return nil
    }

    func write(to defaults: UserDefaults, key: String) {
        switch self {
        case .bool(let value):
            defaults.set(value, forKey: key)
        case .int(let value):
            defaults.set(value, forKey: key)
        case .double(let value):
            defaults.set(value, forKey: key)
        case .string(let value):
            defaults.set(value, forKey: key)
        case .stringArray(let value):
            defaults.set(value, forKey: key)
        case .data(let value):
            defaults.set(value, forKey: key)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let widgetSnapshotStore: WidgetArtworkSnapshotStore
    @Published private(set) var widgetRefreshInterval: WidgetRefreshInterval
    @Published private(set) var widgetAutoRefreshStartMinutes: Int
    @Published private(set) var widgetAutoRefreshEndMinutes: Int
    @Published private(set) var metShowsOnlyOnViewArtworks: Bool
    @Published private(set) var artworkDetailFontScaleStep: Int
    @Published private(set) var isRequestLogAccessUnlocked: Bool
    @Published private(set) var naraMuseumDataSource: NaraMuseumDataSource

    init(
        defaults resolvedDefaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard,
        widgetSnapshotStore: WidgetArtworkSnapshotStore = .shared
    ) {
        defaults = resolvedDefaults
        self.widgetSnapshotStore = widgetSnapshotStore
        widgetRefreshInterval = WidgetRefreshInterval.storedValue(in: resolvedDefaults)
        let autoRefreshWindow = WidgetAutoRefreshWindow.storedValue(in: resolvedDefaults)
        widgetAutoRefreshStartMinutes = autoRefreshWindow.startMinutes
        widgetAutoRefreshEndMinutes = autoRefreshWindow.endMinutes
        metShowsOnlyOnViewArtworks = resolvedDefaults.bool(forKey: SettingsKeys.metShowsOnlyOnViewArtworks)
        artworkDetailFontScaleStep = ArtworkDetailFontScale.storedStep(in: resolvedDefaults)
        isRequestLogAccessUnlocked = resolvedDefaults.bool(forKey: SettingsKeys.requestLogAccessUnlocked)
        naraMuseumDataSource = NaraMuseumDataSource.storedValue(in: resolvedDefaults)
    }

    func requestWidgetReload(invalidateContent: Bool = false) {
        _ = invalidateContent
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

    func saveMetShowsOnlyOnViewArtworks(_ isEnabled: Bool) {
        metShowsOnlyOnViewArtworks = isEnabled
        defaults.set(isEnabled, forKey: SettingsKeys.metShowsOnlyOnViewArtworks)
        defaults.synchronize()
        requestWidgetReload()
    }

    func saveArtworkDetailFontScaleStep(_ step: Int) {
        let clampedStep = ArtworkDetailFontScale.clampedStep(step)
        artworkDetailFontScaleStep = clampedStep
        defaults.set(clampedStep, forKey: SettingsKeys.artworkDetailFontScaleStep)
        defaults.synchronize()
    }

    func saveRequestLogAccessUnlocked(_ isUnlocked: Bool) {
        isRequestLogAccessUnlocked = isUnlocked
        defaults.set(isUnlocked, forKey: SettingsKeys.requestLogAccessUnlocked)
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

    func makeConfigurationExport() async -> AppConfigurationExport {
        AppConfigurationExport(
            userDefaults: exportedUserDefaults(),
            widgetDisplayedArtworkHistory: await widgetSnapshotStore.exportDisplayedArtworkHistory()
        )
    }

    func importConfiguration(_ configuration: AppConfigurationExport) async {
        let removableKeys = configurationUserDefaultsKeys()
            .union(configuration.userDefaults.keys)
            .filter(Self.isExportableUserDefaultsKey)

        for key in removableKeys {
            defaults.removeObject(forKey: key)
        }

        for (key, value) in configuration.userDefaults where Self.isExportableUserDefaultsKey(key) {
            value.write(to: defaults, key: key)
        }

        defaults.synchronize()
        await widgetSnapshotStore.replaceDisplayedArtworkHistory(
            configuration.widgetDisplayedArtworkHistory
        )
        reloadPublishedValues()
        FavoritesStore.shared.reloadFromDefaults()
        requestWidgetReload(invalidateContent: true)
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

    private func reloadPublishedValues() {
        widgetRefreshInterval = WidgetRefreshInterval.storedValue(in: defaults)
        let autoRefreshWindow = WidgetAutoRefreshWindow.storedValue(in: defaults)
        widgetAutoRefreshStartMinutes = autoRefreshWindow.startMinutes
        widgetAutoRefreshEndMinutes = autoRefreshWindow.endMinutes
        metShowsOnlyOnViewArtworks = defaults.bool(forKey: SettingsKeys.metShowsOnlyOnViewArtworks)
        artworkDetailFontScaleStep = ArtworkDetailFontScale.storedStep(in: defaults)
        isRequestLogAccessUnlocked = defaults.bool(forKey: SettingsKeys.requestLogAccessUnlocked)
        naraMuseumDataSource = NaraMuseumDataSource.storedValue(in: defaults)
    }

    private func exportedUserDefaults() -> [String: AppConfigurationValue] {
        var exported: [String: AppConfigurationValue] = [:]

        for key in configurationUserDefaultsKeys() {
            guard let object = defaults.object(forKey: key),
                  let value = AppConfigurationValue(userDefaultsObject: object) else {
                continue
            }
            exported[key] = value
        }

        return exported
    }

    private func configurationUserDefaultsKeys() -> Set<String> {
        var keys = Self.baseExportedUserDefaultsKeys

        for museumID in MuseumID.allCases {
            keys.insert(SettingsKeys.feedCategoryKey(for: museumID))
            keys.insert(Self.feedDisplayModeKey(for: museumID))
        }

        keys.insert(SettingsKeys.feedCategoryKey(for: .nnm, naraDataSource: .official))
        keys.insert(SettingsKeys.feedCategoryKey(for: .nnm, naraDataSource: .colbase))

        for key in defaults.dictionaryRepresentation().keys where Self.isExportableUserDefaultsKey(key) {
            keys.insert(key)
        }

        return keys
    }

    private static var baseExportedUserDefaultsKeys: Set<String> {
        [
            SettingsKeys.naraMuseumDataSource,
            SettingsKeys.widgetRefreshIntervalHours,
            SettingsKeys.widgetAutoRefreshStartMinutes,
            SettingsKeys.widgetAutoRefreshEndMinutes,
            SettingsKeys.metShowsOnlyOnViewArtworks,
            SettingsKeys.artworkDetailFontScaleStep,
            SettingsKeys.requestLogAccessUnlocked,
            SettingsKeys.museumDisplayOrder,
            SettingsKeys.favoritesArtworks
        ]
    }

    private static func isExportableUserDefaultsKey(_ key: String) -> Bool {
        if baseExportedUserDefaultsKeys.contains(key) {
            return true
        }
        return key.hasPrefix(SettingsKeys.feedCategoryPrefix) ||
            key.hasPrefix(SettingsKeys.feedDisplayModePrefix)
    }

    private static func feedDisplayModeKey(for museumID: MuseumID) -> String {
        SettingsKeys.feedDisplayModePrefix + museumID.rawValue
    }
}
