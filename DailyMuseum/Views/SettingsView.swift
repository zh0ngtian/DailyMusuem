import SwiftUI

enum TranslationConfigurationPrompt {
    static let missingConfigurationMessage = "翻译引擎没有配置，请到主页设置页配置"
}

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("翻译引擎", selection: $settings.translationEngineRawValue) {
                    ForEach(TranslationEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }

                NavigationLink {
                    TranslationCredentialSettingsView(engine: selectedEngine)
                } label: {
                    HStack {
                        Text(selectedEngine.credentialsEntryTitle)
                        Spacer()
                        Text(selectedEngine.configurationStatusDescription(using: settings))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("翻译")
            } footer: {
                Text("先选择当前要使用的翻译引擎，再进入对应页面填写或测试凭证。")
            }
        }
        .navigationTitle("设置")
    }

    private var selectedEngine: TranslationEngine {
        settings.translationEngine()
    }
}

private struct TranslationCredentialSettingsView: View {
    let engine: TranslationEngine

    var body: some View {
        switch engine {
        case .tencent:
            TencentTranslationSettingsView()
        case .miniMax:
            MiniMaxTranslationSettingsView()
        }
    }
}

private struct TencentTranslationSettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var secretID = ""
    @State private var secretKey = ""
    @State private var isTestingCredentials = false
    @State private var settingsMessage: String?
    @State private var settingsAlert: String?

    private let translationClient = TencentTranslationClient()

    var body: some View {
        Form {
            Section {
                TextField("SecretId", text: $secretID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("SecretKey", text: $secretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("保存翻译凭证") {
                    saveCredentials()
                }

                Button(isTestingCredentials ? "测试中..." : "测试翻译凭证") {
                    Task {
                        await testCredentials()
                    }
                }
                .disabled(isTestingCredentials)

                if settings.tencentTranslationConfigured {
                    Text("当前设备已保存腾讯云翻译凭证。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let settingsMessage {
                    Text(settingsMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("清空翻译凭证", role: .destructive) {
                    clearCredentials()
                }
            } footer: {
                Text("凭证仅保存在当前设备的 Keychain 中，不会写入源码或小组件配置。机器翻译默认使用腾讯云项目 ID 0。")
            }
        }
        .navigationTitle("腾讯云翻译")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadCredentials()
        }
        .alert("设置提示", isPresented: Binding(
            get: { settingsAlert != nil },
            set: { if !$0 { settingsAlert = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(settingsAlert ?? "")
        }
    }

    private func loadCredentials() {
        secretID = settings.storedTencentTranslationSecretID()
        secretKey = settings.storedTencentTranslationSecretKey()
        settingsMessage = settings.tencentTranslationConfigured ? "已读取本机保存的腾讯云翻译凭证。" : nil
    }

    private func saveCredentials() {
        do {
            try settings.saveTencentTranslationCredentials(
                secretID: secretID,
                secretKey: secretKey
            )
            settingsMessage = "腾讯云翻译凭证已保存。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    private func clearCredentials() {
        do {
            try settings.clearTencentTranslationCredentials()
            secretID = ""
            secretKey = ""
            settingsMessage = "腾讯云翻译凭证已清空。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    @MainActor
    private func testCredentials() async {
        do {
            try settings.saveTencentTranslationCredentials(
                secretID: secretID,
                secretKey: secretKey
            )
        } catch {
            settingsAlert = error.localizedDescription
            return
        }

        guard let credentials = settings.tencentTranslationCredentials() else {
            settingsAlert = TranslationConfigurationPrompt.missingConfigurationMessage
            return
        }

        isTestingCredentials = true
        defer { isTestingCredentials = false }

        do {
            let result = try await translationClient.testCredentials(credentials)
            settingsMessage = "测试成功，返回结果：\(result)"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }
}

private struct MiniMaxTranslationSettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var apiKey = ""
    @State private var isTestingCredentials = false
    @State private var settingsMessage: String?
    @State private var settingsAlert: String?

    private let translationClient = MiniMaxTranslationClient()

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("保存 API Key") {
                    saveAPIKey()
                }

                Button(isTestingCredentials ? "测试中..." : "测试 API Key") {
                    Task {
                        await testCredentials()
                    }
                }
                .disabled(isTestingCredentials)

                if settings.miniMaxTranslationConfigured {
                    Text("当前设备已保存 MiniMax API Key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let settingsMessage {
                    Text(settingsMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("清空 API Key", role: .destructive) {
                    clearAPIKey()
                }
            } footer: {
                Text("API Key 仅保存在当前设备的 Keychain 中，不会写入源码。当前默认使用 MiniMax 文本对话接口和 MiniMax-M2.7 进行翻译。")
            }
        }
        .navigationTitle("MiniMax 翻译")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadCredentials()
        }
        .alert("设置提示", isPresented: Binding(
            get: { settingsAlert != nil },
            set: { if !$0 { settingsAlert = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(settingsAlert ?? "")
        }
    }

    private func loadCredentials() {
        apiKey = settings.storedMiniMaxTranslationAPIKey()
        settingsMessage = settings.miniMaxTranslationConfigured ? "已读取本机保存的 MiniMax API Key。" : nil
    }

    private func saveAPIKey() {
        do {
            try settings.saveMiniMaxTranslationAPIKey(apiKey)
            settingsMessage = "MiniMax API Key 已保存。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    private func clearAPIKey() {
        do {
            try settings.clearMiniMaxTranslationAPIKey()
            apiKey = ""
            settingsMessage = "MiniMax API Key 已清空。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    @MainActor
    private func testCredentials() async {
        do {
            try settings.saveMiniMaxTranslationAPIKey(apiKey)
        } catch {
            settingsAlert = error.localizedDescription
            return
        }

        guard let credentials = settings.miniMaxTranslationCredentials() else {
            settingsAlert = TranslationConfigurationPrompt.missingConfigurationMessage
            return
        }

        isTestingCredentials = true
        defer { isTestingCredentials = false }

        do {
            let result = try await translationClient.testCredentials(credentials)
            settingsMessage = "测试成功，返回结果：\(result)"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }
}

private extension TranslationEngine {
    var credentialsEntryTitle: String {
        switch self {
        case .tencent:
            return "腾讯云翻译凭证"
        case .miniMax:
            return "MiniMax API Key"
        }
    }

    @MainActor
    func configurationStatusDescription(using settings: SettingsStore) -> String {
        switch self {
        case .tencent:
            return settings.tencentTranslationConfigured ? "已配置" : "未配置"
        case .miniMax:
            return settings.miniMaxTranslationConfigured ? "已配置" : "未配置"
        }
    }
}
