import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("定时刷新", selection: widgetRefreshIntervalBinding) {
                    ForEach(WidgetRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            } header: {
                Text("小组件")
            }
        }
        .navigationTitle("设置")
    }

    private var widgetRefreshIntervalBinding: Binding<WidgetRefreshInterval> {
        Binding {
            settings.widgetRefreshInterval
        } set: { interval in
            settings.saveWidgetRefreshInterval(interval)
        }
    }
}
