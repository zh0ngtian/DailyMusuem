import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var tencentSecretID = ""
    @State private var tencentSecretKey = ""
    @State private var miniMaxAPIKey = ""
    @State private var isTestingTencentTranslationCredentials = false
    @State private var isTestingMiniMaxTranslationCredentials = false
    @State private var tencentTranslationSettingsMessage: String?
    @State private var miniMaxTranslationSettingsMessage: String?
    @State private var settingsAlert: String?

    private let tencentTranslationClient = TencentTranslationClient()
    private let miniMaxTranslationClient = MiniMaxTranslationClient()

    var body: some View {
        Form {
            Section("展品列表") {
                Toggle("随机展示展品", isOn: $settings.feedRandomOrder)
            }
            Section("翻译") {
                Picker("翻译引擎", selection: $settings.translationEngineRawValue) {
                    ForEach(TranslationEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }
            }
            Section {
                TextField("SecretId", text: $tencentSecretID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("SecretKey", text: $tencentSecretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("保存翻译凭证") {
                    saveTencentTranslationCredentials()
                }

                Button(isTestingTencentTranslationCredentials ? "测试中..." : "测试翻译凭证") {
                    Task {
                        await testTencentTranslationCredentials()
                    }
                }
                .disabled(isTestingTencentTranslationCredentials)

                if settings.tencentTranslationConfigured {
                    Text("当前设备已保存腾讯云翻译凭证。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let tencentTranslationSettingsMessage {
                    Text(tencentTranslationSettingsMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("清空翻译凭证", role: .destructive) {
                    clearTencentTranslationCredentials()
                }
            } header: {
                Text("腾讯云翻译")
            } footer: {
                Text("凭证仅保存在当前设备的 Keychain 中，不会写入源码或小组件配置。机器翻译默认使用腾讯云项目 ID 0。")
            }
            Section {
                SecureField("API Key", text: $miniMaxAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("保存 API Key") {
                    saveMiniMaxTranslationAPIKey()
                }

                Button(isTestingMiniMaxTranslationCredentials ? "测试中..." : "测试 API Key") {
                    Task {
                        await testMiniMaxTranslationCredentials()
                    }
                }
                .disabled(isTestingMiniMaxTranslationCredentials)

                if settings.miniMaxTranslationConfigured {
                    Text("当前设备已保存 MiniMax API Key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let miniMaxTranslationSettingsMessage {
                    Text(miniMaxTranslationSettingsMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("清空 API Key", role: .destructive) {
                    clearMiniMaxTranslationAPIKey()
                }
            } header: {
                Text("MiniMax 大模型翻译")
            } footer: {
                Text("API Key 仅保存在当前设备的 Keychain 中，不会写入源码。当前默认使用 MiniMax 文本对话接口和 MiniMax-M2.7 进行翻译。")
            }
        }
        .navigationTitle("设置")
        .task {
            loadTranslationCredentials()
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

    private func loadTranslationCredentials() {
        tencentSecretID = settings.storedTencentTranslationSecretID()
        tencentSecretKey = settings.storedTencentTranslationSecretKey()
        miniMaxAPIKey = settings.storedMiniMaxTranslationAPIKey()
        tencentTranslationSettingsMessage = settings.tencentTranslationConfigured ? "已读取本机保存的腾讯云翻译凭证。" : nil
        miniMaxTranslationSettingsMessage = settings.miniMaxTranslationConfigured ? "已读取本机保存的 MiniMax API Key。" : nil
    }

    private func saveTencentTranslationCredentials() {
        do {
            try settings.saveTencentTranslationCredentials(
                secretID: tencentSecretID,
                secretKey: tencentSecretKey
            )
            tencentTranslationSettingsMessage = "腾讯云翻译凭证已保存。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    private func clearTencentTranslationCredentials() {
        do {
            try settings.clearTencentTranslationCredentials()
            tencentSecretID = ""
            tencentSecretKey = ""
            tencentTranslationSettingsMessage = "腾讯云翻译凭证已清空。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    @MainActor
    private func testTencentTranslationCredentials() async {
        do {
            try settings.saveTencentTranslationCredentials(
                secretID: tencentSecretID,
                secretKey: tencentSecretKey
            )
        } catch {
            settingsAlert = error.localizedDescription
            return
        }

        guard let credentials = settings.tencentTranslationCredentials() else {
            settingsAlert = "请先填写完整的 SecretId 和 SecretKey。"
            return
        }

        isTestingTencentTranslationCredentials = true
        defer { isTestingTencentTranslationCredentials = false }

        do {
            let result = try await tencentTranslationClient.testCredentials(credentials)
            tencentTranslationSettingsMessage = "测试成功，返回结果：\(result)"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    private func saveMiniMaxTranslationAPIKey() {
        do {
            try settings.saveMiniMaxTranslationAPIKey(miniMaxAPIKey)
            miniMaxTranslationSettingsMessage = "MiniMax API Key 已保存。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    private func clearMiniMaxTranslationAPIKey() {
        do {
            try settings.clearMiniMaxTranslationAPIKey()
            miniMaxAPIKey = ""
            miniMaxTranslationSettingsMessage = "MiniMax API Key 已清空。"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }

    @MainActor
    private func testMiniMaxTranslationCredentials() async {
        do {
            try settings.saveMiniMaxTranslationAPIKey(miniMaxAPIKey)
        } catch {
            settingsAlert = error.localizedDescription
            return
        }

        guard let credentials = settings.miniMaxTranslationCredentials() else {
            settingsAlert = "请先填写 MiniMax API Key。"
            return
        }

        isTestingMiniMaxTranslationCredentials = true
        defer { isTestingMiniMaxTranslationCredentials = false }

        do {
            let result = try await miniMaxTranslationClient.testCredentials(credentials)
            miniMaxTranslationSettingsMessage = "测试成功，返回结果：\(result)"
        } catch {
            settingsAlert = error.localizedDescription
        }
    }
}
