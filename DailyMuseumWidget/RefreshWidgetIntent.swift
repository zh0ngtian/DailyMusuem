import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        let nextNonce = defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce) + 1
        defaults.set(nextNonce, forKey: SettingsKeys.widgetManualRefreshNonce)
        await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "触发手动刷新，nonce=\(Int(nextNonce))")
        WidgetCenter.shared.reloadTimelines(ofKind: DailyMuseumWidget.kind)
        return .result()
    }
}
