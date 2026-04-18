import AppIntents
import Foundation

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun = false

    @Parameter(title: "实例标识")
    var instanceToken: String

    @Parameter(title: "展示范围")
    var museumScope: WidgetConfiguredMuseumScope

    @Parameter(title: "尺寸标识")
    var widgetFamilyToken: String

    init() {
        instanceToken = ""
        museumScope = .all
        widgetFamilyToken = ""
    }

    init(instanceToken: String, museumScope: WidgetConfiguredMuseumScope, widgetFamilyToken: String) {
        self.instanceToken = instanceToken
        self.museumScope = museumScope
        self.widgetFamilyToken = widgetFamilyToken
    }

    func perform() async throws -> some IntentResult {
        await WidgetRefreshCoordinator.shared.refresh(
            instanceToken: instanceToken,
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
