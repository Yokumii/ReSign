import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AppSettings
    @State private var launchAtLogin: Bool
    @State private var serviceMessage: String?

    init(model: AppModel) {
        self.model = model
        _settings = State(initialValue: model.library.settings)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置").font(.title2.weight(.semibold))
            Form {
                Section("自动续签") {
                    Stepper("提前 \(settings.refreshLeadHours) 小时续签", value: $settings.refreshLeadHours, in: 12...72, step: 12)
                    Toggle("登录 Mac 时启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                    Text("关闭主窗口后，菜单栏中的 ReSign 会继续运行。Mac 唤醒和设备重新连接时也会处理到期任务。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let serviceMessage { Text(serviceMessage).font(.caption).foregroundStyle(.orange) }
                }
                Section("Apple 认证") {
                    Picker("Anisette 来源", selection: $settings.anisetteSource) {
                        ForEach(AnisetteSource.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if settings.anisetteSource == .remoteV3 {
                        TextField("服务根地址", text: $settings.anisetteServer, prompt: Text("https://…"))
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
            }.formStyle(.grouped)
            HStack {
                Button("打开数据目录") { model.revealData() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { if model.saveSettings(settings) { dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 570, height: 570)
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
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
