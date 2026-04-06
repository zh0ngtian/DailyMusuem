import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    @AppStorage(SettingsKeys.widgetRefreshIntervalMinutes, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var widgetRefreshIntervalMinutes: Int = WidgetRefreshInterval.oneHour.rawValue

    @AppStorage(SettingsKeys.widgetMuseumScope, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var widgetMuseumScopeRawValue: String = WidgetMuseumScope.all.rawValue

    @AppStorage(SettingsKeys.widgetPreferHasImages, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var widgetPreferHasImages: Bool = true

    @AppStorage(SettingsKeys.feedRandomOrder, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var feedRandomOrder: Bool = true

    private init() {
        defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
    }

    func widgetMuseumScope() -> WidgetMuseumScope {
        WidgetMuseumScope(rawValue: widgetMuseumScopeRawValue) ?? .all
    }

    func requestWidgetReload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
