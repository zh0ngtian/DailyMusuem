import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("翻译方式", value: "iOS 18 系统翻译")

                Text("展品详情页右上角的翻译按钮会使用 iOS 18 TranslationSession 批量翻译标题、介绍和字段，并直接在当前页替换原文；若系统语言包未准备好，只给提示，不弹出系统下载页。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("翻译")
            } footer: {
                Text("应用当前最低系统版本为 iOS 18。")
            }
        }
        .navigationTitle("设置")
    }
}
