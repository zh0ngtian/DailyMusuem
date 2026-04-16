import AppIntents
import Foundation
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新展品"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "组件尺寸")
    var familyKey: String

    init() {
        familyKey = ""
    }

    init(familyKey: String) {
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        await WidgetManualRefreshRunner(logSource: "Widget 刷新按钮")
            .perform(familyKey: familyKey)
        return .result()
    }
}
