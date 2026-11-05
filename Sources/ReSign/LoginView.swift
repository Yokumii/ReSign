import SwiftUI
import SideSign

struct LoginView: View {
    @ObservedObject var model: AppModel
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        _settings = State(initialValue: model.library.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "person.crop.circle").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apple 账号").font(.title2.weight(.semibold))
                    Text("用于申请开发证书与描述文件。密码只用于此次登录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let request = model.verificationRequest {
                verification(request)
            } else if !model.availableTeams.isEmpty {
                Text("选择本次使用的开发团队").font(.headline)
                ForEach(model.availableTeams) { team in
                    Button {
                        Task { await model.selectTeam(team) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(team.name)
                                Text("\(team.identifier) · \(team.isPaid ? "开发者账号" : "免费账号")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(10)
                    }.buttonStyle(.bordered)
                }
            } else {
                credentials
            }
            Divider()
            HStack {
                if model.account != nil && !model.isLoggingIn {
                    Button("退出账号", role: .destructive) { Task { await model.logout(); model.showLogin = false } }
                }
                Spacer()
                Button(model.isLoggingIn ? "取消登录" : "关闭") { model.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28).frame(width: 520)
        .interactiveDismissDisabled(model.isLoggingIn)
        .onChange(of: model.verificationRequest) { _, _ in code = "" }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let account = model.account {
                Label("当前团队：\(account.team.name)", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Apple 账号邮箱", text: $appleID)
                .textContentType(.username).textFieldStyle(.roundedBorder)
            SecureField("Apple 账号密码", text: $password)
                .textContentType(.password).textFieldStyle(.roundedBorder)
            DisclosureGroup("认证方式") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("认证来源", selection: $settings.anisetteSource) {
                        ForEach(AnisetteSource.allCases, id: \.self) { source in Text(source.title).tag(source) }
                    }
                    if settings.anisetteSource == .remoteV3 {
                        TextField("https://你的 Anisette v3 服务", text: $settings.anisetteServer)
                            .textFieldStyle(.roundedBorder)
                        Text("服务仅参与 Anisette 数据生成；Apple 账号密码由客户端发给 Apple。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                        Text("当前 macOS 27 需要配置 Anisette v3 服务。请选择上方的服务模式。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.top, 10)
            }
            if model.isLoggingIn {
                HStack { ProgressView().controlSize(.small); Text("正在与 Apple 建立登录会话…").font(.callout) }
            } else {
                Button("登录") {
                    guard model.saveSettings(settings) else { return }
                    model.beginLogin(appleID: appleID, password: password)
                    password = ""
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }.disabled(model.isLoggingIn)
    }

    @ViewBuilder
    private func verification(_ request: TwoFactorRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("双重认证").font(.headline)
            if let error = request.error { Text(error).font(.caption).foregroundStyle(.orange) }
            switch request {
            case .selectDeliveryMethod(_, let phones):
                Text("选择接收验证码的方式。")
                Button("在受信任的 Apple 设备上接收") { model.answerVerification(.requestTrustedDevice) }
                ForEach(phones) { phone in
                    Button("发送短信至 \(phone.number)") { model.answerVerification(.requestSMS(phoneID: phone.id)) }
                }
            case .trustedDevice:
                Text("请在受信任的 Apple 设备上允许登录，并输入六位验证码。")
                codeEntry
            case .sms(let phones, let activeID, _):
                Text("请输入发送到 \(phones.first { $0.id == activeID }?.number ?? "受信任号码") 的六位验证码。")
                codeEntry
                Button("重新发送短信") { model.answerVerification(.requestSMS(phoneID: activeID)) }
            case .voice(_, _, _):
                Text("请输入语音提供的六位验证码。")
                codeEntry
            }
        }
    }

    private var codeEntry: some View {
        HStack {
            TextField("六位验证码", text: $code)
                .textFieldStyle(.roundedBorder).textContentType(.oneTimeCode)
            Button("继续") { model.answerVerification(.verificationCode(code)) }
                .buttonStyle(.borderedProminent)
                .disabled(code.count != 6 || !code.allSatisfy { "0123456789".contains($0) })
                .keyboardShortcut(.defaultAction)
        }
    }
}
