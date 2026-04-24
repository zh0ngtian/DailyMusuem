import AppIntents
import Foundation

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun = false

    @Parameter(title: "刷新键")
    var refreshKey: String

    @Parameter(title: "展示范围")
    var museumScope: WidgetConfiguredMuseumScope

    @Parameter(title: "尺寸标识")
    var widgetFamilyToken: String

    init() {
        refreshKey = ""
        museumScope = .all
        widgetFamilyToken = ""
    }

    init(refreshKey: String, museumScope: WidgetConfiguredMuseumScope, widgetFamilyToken: String) {
        self.refreshKey = refreshKey
        self.museumScope = museumScope
        self.widgetFamilyToken = widgetFamilyToken
    }

    func perform() async throws -> some IntentResult {
        await WidgetRefreshCoordinator.shared.refreshCurrentConfiguration(
            refreshKey: refreshKey,
            scope: museumScope.scope,
            familyToken: widgetFamilyToken.nilIfBlank,
            logSource: "Widget 刷新按钮"
        )
        return .result()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
