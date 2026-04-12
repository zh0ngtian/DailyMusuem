import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    private enum Constants {
        static let widgetKind = "DailyMuseumWidget"
    }

    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        let nextNonce = defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce) + 1
        defaults.set(true, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.set(nextNonce, forKey: SettingsKeys.widgetManualRefreshNonce)
        await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "触发手动刷新，进入加载态，nonce=\(Int(nextNonce))")
        WidgetCenter.shared.reloadTimelines(ofKind: Constants.widgetKind)

        do {
            let settings = WidgetSettingsReader()
            _ = try await WidgetArtworkService(settings: settings).fetchEntry(date: .now)
            await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "手动刷新拉取完成，准备退出加载态")
        } catch {
            await RequestLogger.shared.logEvent(source: "Widget 刷新按钮", summary: "手动刷新拉取失败：\(error.localizedDescription)")
        }

        defaults.set(false, forKey: SettingsKeys.widgetManualRefreshInProgress)
        WidgetCenter.shared.reloadTimelines(ofKind: Constants.widgetKind)
        return .result()
    }
}
