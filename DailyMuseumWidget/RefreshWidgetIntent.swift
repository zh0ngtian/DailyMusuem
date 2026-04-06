import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        defaults.set(Date().timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshNonce)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
