import AppIntents

struct WidgetRefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新展品"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "小组件组")
    var groupID: Int

    init() {}

    init(groupID: Int) {
        self.groupID = groupID
    }

    func perform() async throws -> some IntentResult {
        guard let group = WidgetGroup(id: groupID) else {
            return .result()
        }
        await WidgetManualRefreshRunner(logSource: "Widget 桌面刷新").perform(group: group)
        return .result()
    }
}
