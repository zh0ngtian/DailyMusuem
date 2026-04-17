import AppIntents
import Foundation

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun = false

    @Parameter(title: "实例标识")
    var instanceToken: String

    @Parameter(title: "展示范围")
    var museumScope: WidgetConfiguredMuseumScope

    init() {
        instanceToken = ""
        museumScope = .all
    }

    init(instanceToken: String, museumScope: WidgetConfiguredMuseumScope) {
        self.instanceToken = instanceToken
        self.museumScope = museumScope
    }

    func perform() async throws -> some IntentResult {
        await WidgetRefreshCoordinator.shared.refresh(
            instanceToken: instanceToken,
            scope: museumScope.scope,
            logSource: "Widget 刷新按钮"
        )
        return .result()
    }
}
