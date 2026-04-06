import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("展品列表") {
                Toggle("随机展示展品", isOn: $settings.feedRandomOrder)
            }
            Section("小组件") {
                Picker("刷新间隔", selection: $settings.widgetRefreshIntervalMinutes) {
                    ForEach(WidgetRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval.rawValue)
                    }
                }
                Picker("展示范围", selection: $settings.widgetMuseumScopeRawValue) {
                    Text("所有博物馆").tag(WidgetMuseumScope.all.rawValue)
                    ForEach(MuseumRepository.supportedMuseums) { museum in
                        Text(museum.displayName).tag(WidgetMuseumScope.single(museum.id).rawValue)
                    }
                }
                Toggle("优先只展示有图片的展品", isOn: $settings.widgetPreferHasImages)
            }
            Section {
                Text("提示：WidgetKit 不保证按设定精确刷新，系统会根据电量和使用情况进行调整。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .onChange(of: settings.widgetRefreshIntervalMinutes) { _, _ in
            settings.requestWidgetReload()
        }
        .onChange(of: settings.widgetMuseumScopeRawValue) { _, _ in
            settings.requestWidgetReload()
        }
        .onChange(of: settings.widgetPreferHasImages) { _, _ in
            settings.requestWidgetReload()
        }
    }
}
