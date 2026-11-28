import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AppSettings
    @State private var launchAtLogin: Bool
    @State private var serviceMessage: String?
    @State private var githubToken = ""
    @State private var tokenMessage: String?
    @State private var tokenMessageIsError = false
    @State private var errorMessage: String?

    init(model: AppModel) {
        self.model = model
        _settings = State(initialValue: model.library.settings)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        Form {
            Section("自动续签") {
                Stepper("提前 \(settings.refreshLeadHours) 小时续签", value: $settings.refreshLeadHours, in: 12...72, step: 12)
                Toggle("登录 Mac 时启动", isOn: Binding(get: { launchAtLogin }, set: { updateLoginItem($0) }))
                Text("关闭主窗口后，菜单栏中的 ReSign 会继续运行。Mac 唤醒和设备重新连接时也会处理到期任务。")
                    .font(.caption).foregroundStyle(.secondary)
                if let serviceMessage { Text(serviceMessage).font(.caption).foregroundStyle(.orange) }
            }
            Section("Apple 认证") {
                Picker("Anisette 来源", selection: $settings.anisetteSource) {
                    ForEach(AnisetteSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.anisetteSource == .remoteV3 {
                    TextField("服务根地址", text: $settings.anisetteServer, prompt: Text(verbatim: "https://…"))
                    Text("仅使用你指定的 v3 服务。改变认证方式后需要重新登录。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("本机模式使用 macOS 的认证框架。macOS 27 请使用 Anisette v3 服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("客户端兼容设置") {
                    TextField("Xcode 客户端版本", text: $settings.xcodeVersion)
                }
            }
            Section("GitHub 软件更新") {
                SecureField("GitHub Token", text: $githubToken,
                            prompt: Text(model.hasGitHubToken ? "已保存，填写新 Token 可替换" : "填写 Personal Access Token"))
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("保存 Token") {
                            do {
                                try model.saveGitHubToken(githubToken)
                                githubToken = ""
                                tokenMessageIsError = false
                                tokenMessage = "Token 已保存。"
                            } catch {
                                tokenMessageIsError = true
                                tokenMessage = error.localizedDescription
                            }
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if model.hasGitHubToken {
                            Button("清除 Token", role: .destructive) {
                                do {
                                    try model.saveGitHubToken("")
                                    githubToken = ""
                                    tokenMessageIsError = false
                                    tokenMessage = "Token 已清除。"
                                } catch {
                                    tokenMessageIsError = true
                                    tokenMessage = error.localizedDescription
                                }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                    }
                }
                .disabled(model.isBusy || model.isLoggingIn)

                Text("Token 独立保存到 macOS 钥匙串，用于提高 GitHub API 请求配额。")
                    .font(.caption).foregroundStyle(.secondary)
                if let tokenMessage {
                    Text(tokenMessage).font(.caption)
                        .foregroundStyle(tokenMessageIsError ? Color.orange : Color.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaBar(edge: .top) {
            HStack {
                Text("设置")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("打开数据目录") { model.revealData() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                    Spacer()
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("取消") { dismiss() }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .keyboardShortcut(.cancelAction)
                            Button("保存") {
                                do {
                                    errorMessage = nil
                                    try model.saveSettings(settings)
                                    dismiss()
                                } catch { errorMessage = error.localizedDescription }
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isBusy || model.isLoggingIn)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 570, height: 680)
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                serviceMessage = "请在系统设置的“登录项与扩展”中允许 ReSign。"
                SMAppService.openSystemSettingsLoginItems()
            } else { serviceMessage = nil }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            serviceMessage = "无法更新登录启动设置：\(error.localizedDescription)"
        }
    }
}
