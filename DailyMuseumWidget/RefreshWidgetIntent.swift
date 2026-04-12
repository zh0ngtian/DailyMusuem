import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        let startedAt = Date()
        let nextNonce = defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce) + 1
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(startedAt.timeIntervalSince1970, forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.set(nextNonce, forKey: SettingsKeys.widgetManualRefreshNonce)
        defaults.synchronize()
        await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "触发手动刷新，进入加载态，nonce=\(Int(nextNonce))")
        WidgetCenter.shared.reloadTimelines(ofKind: SettingsKeys.widgetKind)
        defer {
            defaults.set(false, forKey: SettingsKeys.widgetManualRefreshInProgress)
            defaults.removeObject(forKey: SettingsKeys.widgetManualRefreshStartedAt)
            defaults.synchronize()
            WidgetCenter.shared.reloadTimelines(ofKind: SettingsKeys.widgetKind)
        }

        do {
            let settings = WidgetSettingsReader()
            _ = try await WidgetArtworkService(settings: settings).fetchEntry(date: .now)
            await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "手动刷新拉取完成，准备退出加载态")
        } catch {
            await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "手动刷新拉取失败：\(error.localizedDescription)")
        }
        return .result()
    }
}
