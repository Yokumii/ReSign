import SwiftUI

struct UpdateSourceView: View {
    @ObservedObject var model: AppModel
    let app: ManagedApp
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var pattern: String
    @State private var enabled: Bool
    @State private var errorMessage: String?

    init(model: AppModel, app: ManagedApp) {
        self.model = model
        self.app = app
        _address = State(initialValue: app.updateSource?.url ?? "")
        _pattern = State(initialValue: app.updateSource?.assetPattern ?? "")
        _enabled = State(initialValue: app.automaticUpdates != false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("软件更新来源").font(.title2.weight(.semibold))
            Text(app.name).font(.headline)
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
                .textFieldStyle(.roundedBorder)
            TextField("IPA 附件匹配规则（可选）", text: $pattern, prompt: Text(verbatim: "例如 *_ios_*.ipa"))
                .textFieldStyle(.roundedBorder)
            Text("GitHub 包含多个 IPA 时填写通配符规则（* 匹配任意字符）；JSON 软件源按原始 Bundle ID 匹配。地址留空可清除绑定。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("自动下载并更新 IPA", isOn: $enabled)
            Text("每小时检查更新，下载新版后在设备就绪时重签并覆盖安装。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    do {
                        try model.saveUpdateSource(address, pattern: pattern, enabled: enabled, appID: app.id)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.isCheckingUpdates || model.isLoggingIn)
            }
        }.padding(24).frame(width: 570)
    }
}
