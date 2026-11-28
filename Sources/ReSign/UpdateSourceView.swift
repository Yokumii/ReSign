import SwiftUI

struct UpdateSourceView: View {
    @ObservedObject var model: AppModel
    let app: ManagedApp
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var address: String
    @State private var pattern: String
    @State private var enabled: Bool
    @State private var errorMessage: String?

    private var palette: ThemePalette { ThemePalette(colorScheme: colorScheme) }

    init(model: AppModel, app: ManagedApp) {
        self.model = model
        self.app = app
        _address = State(initialValue: app.updateSource?.url ?? "")
        _pattern = State(initialValue: app.updateSource?.assetPattern ?? "")
        _enabled = State(initialValue: app.automaticUpdates != false)
    }

    var body: some View {
        Form {
            Section("来源地址") {
                if app.updateSource == nil {
                    Text("未能自动确定更新来源，请选择候选或手动填写。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let candidates = app.updateCandidates, !candidates.isEmpty {
                    Menu("从 IPA 中发现的候选选择…") {
                        ForEach(candidates, id: \.self) { candidate in
                            Button(candidate.title) { address = candidate.url; pattern = candidate.assetPattern ?? "" }
                        }
                    }
                }
                TextField("GitHub 仓库或 AltStore JSON 软件源", text: $address,
                          prompt: Text(verbatim: "https://github.com/owner/repo"))
                TextField("IPA 附件匹配规则（可选）", text: $pattern, prompt: Text(verbatim: "例如 *_ios_*.ipa"))
                Text("GitHub 包含多个 IPA 时填写通配符规则（* 匹配任意字符）；JSON 软件源按原始 Bundle ID 匹配。地址留空可清除绑定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自动更新") {
                Toggle("自动下载并更新 IPA", isOn: $enabled)
                Text("每小时检查更新，下载新版后在设备就绪时重签并覆盖安装。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaBar(edge: .top) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(.accentColor.opacity(palette.glassTintOpacity)), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("软件更新来源").font(.title3.weight(.semibold))
                    Text(app.name).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("取消") { dismiss() }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .keyboardShortcut(.cancelAction)
                            Button("保存") {
                                do {
                                    try model.saveUpdateSource(address, pattern: pattern, enabled: enabled, appID: app.id)
                                    dismiss()
                                } catch { errorMessage = error.localizedDescription }
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isCheckingUpdates || model.isLoggingIn)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 570, height: 470)
    }
}
