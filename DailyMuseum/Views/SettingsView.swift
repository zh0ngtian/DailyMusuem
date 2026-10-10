import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var presentedTimeField: SettingsTimeField?
    @State private var configurationDocument = AppConfigurationFileDocument()
    @State private var isShowingConfigurationExporter = false
    @State private var isShowingConfigurationImporter = false
    @State private var isHandlingConfigurationFile = false
    @State private var configurationAlertState: SettingsConfigurationAlertState?
    @State private var appVersionTapCount = 0

    var body: some View {
        Form {
            Section {
                if SettingsKeys.widgetCompatibilityMode {
                    NavigationLink("分组与展示博物馆") {
                        CompatibleWidgetGroupsSettingsView(settings: settings)
                    }
                }
                Picker("自动刷新", selection: widgetRefreshIntervalBinding) {
                    ForEach(WidgetRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                TimeSelectionRow(
                    "开始时间",
                    value: WidgetAutoRefreshWindow.displayText(for: settings.widgetAutoRefreshStartMinutes)
                ) {
                    presentedTimeField = .start
                }

                TimeSelectionRow(
                    "结束时间",
                    value: WidgetAutoRefreshWindow.displayText(for: settings.widgetAutoRefreshEndMinutes)
                ) {
                    presentedTimeField = .end
                }

                VStack(alignment: .leading, spacing: 6) {
                    if settings.widgetRefreshInterval.isEnabled {
                        Text("今日自动刷新时间")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if todayAutomaticRefreshTimes.isEmpty {
                            Text("今日无自动刷新时间")
                                .font(.subheadline)
                        } else {
                            LazyVGrid(columns: refreshTimeGridColumns, alignment: .leading, spacing: 10) {
                                ForEach(todayAutomaticRefreshTimes, id: \.self) { refreshTime in
                                    Text(refreshTime)
                                        .font(scheduleTimeFont)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }
                        }
                    } else {
                        Text("当前已关闭自动刷新")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("小组件")
            }

            Section {
                Button {
                    exportConfiguration()
                } label: {
                    Label("导出配置到文件", systemImage: "square.and.arrow.up")
                }
                .disabled(isHandlingConfigurationFile)

                Button {
                    isShowingConfigurationImporter = true
                } label: {
                    Label("从文件导入配置", systemImage: "square.and.arrow.down")
                }
                .disabled(isHandlingConfigurationFile)
            } header: {
                Text("配置")
            }

            Section {
                LabeledContent("App 版本", value: appVersionInfo.version)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        registerAppVersionTap()
                    }
                LabeledContent("Build 号", value: appVersionInfo.build)
            } header: {
                Text("关于")
            }

            if settings.isRequestLogAccessUnlocked {
                Section {
                    Button {
                        hideRequestLogAccess()
                    } label: {
                        Label("隐藏日志显示", systemImage: "eye.slash")
                    }
                } header: {
                    Text("日志")
                }
            }
        }
        .navigationTitle("设置")
        .sheet(item: $presentedTimeField) { field in
            TimeSelectionSheet(
                title: field.title,
                selection: timeBinding(for: field)
            )
        }
        .fileExporter(
            isPresented: $isShowingConfigurationExporter,
            document: configurationDocument,
            contentType: .json,
            defaultFilename: "MuseumMuse-Configuration"
        ) { result in
            switch result {
            case .success:
                configurationAlertState = SettingsConfigurationAlertState(
                    title: "导出完成",
                    message: "配置文件已保存。"
                )
            case .failure(let error):
                configurationAlertState = SettingsConfigurationAlertState(
                    title: "导出失败",
                    message: error.localizedDescription
                )
            }
        }
        .fileImporter(
            isPresented: $isShowingConfigurationImporter,
            allowedContentTypes: [.json]
        ) { result in
            importConfiguration(from: result)
        }
        .alert(item: $configurationAlertState) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var widgetRefreshIntervalBinding: Binding<WidgetRefreshInterval> {
        Binding {
            settings.widgetRefreshInterval
        } set: { interval in
            settings.saveWidgetRefreshInterval(interval)
        }
    }

    private var widgetAutoRefreshStartMinutesBinding: Binding<Int> {
        Binding {
            settings.widgetAutoRefreshStartMinutes
        } set: { minutes in
            settings.saveWidgetAutoRefreshStartMinutes(minutes)
        }
    }

    private var widgetAutoRefreshEndMinutesBinding: Binding<Int> {
        Binding {
            settings.widgetAutoRefreshEndMinutes
        } set: { minutes in
            settings.saveWidgetAutoRefreshEndMinutes(minutes)
        }
    }

    private func timeBinding(for field: SettingsTimeField) -> Binding<Int> {
        switch field {
        case .start:
            return widgetAutoRefreshStartMinutesBinding
        case .end:
            return widgetAutoRefreshEndMinutesBinding
        }
    }

    private var todayAutomaticRefreshTimes: [String] {
        guard let schedule = WidgetAutoRefreshSchedule(
            interval: settings.widgetRefreshInterval,
            startMinutes: settings.widgetAutoRefreshStartMinutes,
            endMinutes: settings.widgetAutoRefreshEndMinutes
        ) else {
            return []
        }

        return schedule.refreshDates(forDayContaining: .now).map(displayTime)
    }

    private var refreshTimeGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: 4)
    }

    private var scheduleTimeFont: Font {
        .system(size: 15, weight: .regular, design: .monospaced)
    }

    private var appVersionInfo: AppVersionInfo {
        AppVersionInfo.current
    }

    private func exportConfiguration() {
        guard !isHandlingConfigurationFile else {
            return
        }

        isHandlingConfigurationFile = true
        Task {
            do {
                let configuration = await settings.makeConfigurationExport()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(configuration)
                await MainActor.run {
                    configurationDocument = AppConfigurationFileDocument(data: data)
                    isHandlingConfigurationFile = false
                    isShowingConfigurationExporter = true
                }
            } catch {
                await MainActor.run {
                    isHandlingConfigurationFile = false
                    configurationAlertState = SettingsConfigurationAlertState(
                        title: "导出失败",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func registerAppVersionTap() {
        guard !settings.isRequestLogAccessUnlocked else {
            return
        }

        appVersionTapCount += 1
        if appVersionTapCount >= 5 {
            settings.saveRequestLogAccessUnlocked(true)
            appVersionTapCount = 0
        }
    }

    private func hideRequestLogAccess() {
        appVersionTapCount = 0
        settings.saveRequestLogAccessUnlocked(false)
    }

    private func importConfiguration(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard !isHandlingConfigurationFile else {
                return
            }

            isHandlingConfigurationFile = true
            Task {
                do {
                    let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if shouldStopAccessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let data = try Data(contentsOf: url)
                    let configuration = try JSONDecoder().decode(AppConfigurationExport.self, from: data)
                    await settings.importConfiguration(configuration)
                    await MainActor.run {
                        isHandlingConfigurationFile = false
                        configurationAlertState = SettingsConfigurationAlertState(
                            title: "导入完成",
                            message: "配置已导入。"
                        )
                    }
                } catch {
                    await MainActor.run {
                        isHandlingConfigurationFile = false
                        configurationAlertState = SettingsConfigurationAlertState(
                            title: "导入失败",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        case .failure(let error):
            configurationAlertState = SettingsConfigurationAlertState(
                title: "导入失败",
                message: error.localizedDescription
            )
        }
    }
}

private struct AppConfigurationFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SettingsConfigurationAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct AppVersionInfo {
    let version: String
    let build: String

    static var current: AppVersionInfo {
        AppVersionInfo(
            version: bundleValue(for: "CFBundleShortVersionString"),
            build: bundleValue(for: "CFBundleVersion")
        )
    }

    private static func bundleValue(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return "未知"
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? "未知" : trimmedValue
    }
}

private enum SettingsTimeField: String, Identifiable {
    case start
    case end

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start:
            return "开始时间"
        case .end:
            return "结束时间"
        }
    }
}

private struct TimeSelectionRow: View {
    let title: String
    let value: String
    let action: () -> Void

    init(_ title: String, value: String, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(value)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TimeSelectionSheet: View {
    let title: String
    @Binding var selection: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(
                    title,
                    selection: $selection
                ) {
                    ForEach(WidgetAutoRefreshWindow.selectableMinutes, id: \.self) { minutes in
                        Text(WidgetAutoRefreshWindow.displayText(for: minutes))
                            .tag(minutes)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 216)
                .padding(.top, 8)
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}

private func displayTime(_ date: Date) -> String {
    let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
}

private struct CompatibleWidgetGroupsSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(WidgetCompatibilityGroup.all) { group in
                    Picker(group.name, selection: scopeBinding(for: group)) {
                        Text("所有博物馆").tag(WidgetMuseumScope.all)
                        ForEach(MuseumRepository.widgetSupportedMuseums) { museum in
                            Text(museum.displayName).tag(WidgetMuseumScope.single(museum.id))
                        }
                    }
                }
            } header: {
                Text("10 组小组件")
            } footer: {
                Text("添加桌面小组件时选择对应组。同组的不同尺寸显示同一件展品，各组独立选馆与刷新。仅刷新已添加到桌面的组。")
            }
        }
        .navigationTitle("分组与展示博物馆")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scopeBinding(for group: WidgetCompatibilityGroup) -> Binding<WidgetMuseumScope> {
        Binding {
            settings.widgetScope(for: group)
        } set: { scope in
            guard scope != settings.widgetScope(for: group) else { return }
            settings.saveWidgetCompatibilityScope(scope, group: group)
            Task {
                await WidgetManualRefreshRunner(logSource: "Widget \(group.name)选馆")
                    .perform(compatibilityGroup: group)
            }
        }
    }
}
