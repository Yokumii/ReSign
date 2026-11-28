import SwiftUI
import SideSign

struct LoginView: View {
    @ObservedObject var model: AppModel
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var settings: AppSettings
    @State private var localError: String?

    init(model: AppModel) {
        self.model = model
        _settings = State(initialValue: model.library.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple 账号").font(.title2.weight(.semibold))
                    Text("用于申请开发证书与描述文件。密码只用于此次登录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let request = model.verificationRequest {
                verification(request)
            } else if !model.availableTeams.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择本次使用的开发团队").font(.headline)
                    ForEach(model.availableTeams) { team in
                        Button {
                            Task { await model.selectTeam(team) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(team.name).font(.body.weight(.medium))
                                    Text("\(team.identifier) · \(team.isPaid ? "开发者账号" : "免费账号")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            } else {
                credentials
            }

            if let error = localError ?? model.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack {
                if model.account != nil && !model.isLoggingIn && model.availableTeams.isEmpty {
                    Button("退出账号", role: .destructive) {
                        Task {
                            localError = nil
                            if await model.logout() { model.showLogin = false }
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(model.isBusy)
                }
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(model.isLoggingIn || !model.availableTeams.isEmpty ? "取消登录" : "关闭") {
                            model.cancelLogin()
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut(.cancelAction)

                        if model.verificationRequest == nil && model.availableTeams.isEmpty && !model.isLoggingIn {
                            let trimmedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
                            Button("登录") {
                                do {
                                    localError = nil
                                    try model.saveSettings(settings)
                                    model.beginLogin(appleID: trimmedAppleID, password: password)
                                    password = ""
                                } catch { localError = error.localizedDescription }
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .disabled(trimmedAppleID.isEmpty || password.isEmpty || model.isBusy)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 520)
        .interactiveDismissDisabled(model.isLoggingIn || !model.availableTeams.isEmpty)
        .onChange(of: model.verificationRequest) { _, _ in code = ""; localError = nil }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let account = model.account {
                Label("当前团队：\(account.team.name)", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            TextField("Apple 账号邮箱", text: $appleID)
                .textContentType(.username)
                .textFieldStyle(.roundedBorder)
            SecureField("Apple 账号密码", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            DisclosureGroup("认证方式") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("认证来源", selection: $settings.anisetteSource) {
                        ForEach(AnisetteSource.allCases, id: \.self) { source in Text(source.title).tag(source) }
                    }
                    if settings.anisetteSource == .remoteV3 {
                        TextField("Anisette v3 服务地址", text: $settings.anisetteServer,
                                  prompt: Text(verbatim: "https://你的 Anisette v3 服务"))
                            .textFieldStyle(.roundedBorder)
                        Text("服务仅参与 Anisette 数据生成；Apple 账号密码由客户端发给 Apple。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                        Text("当前 macOS 27 需要配置 Anisette v3 服务。请选择上方的服务模式。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 10)
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if model.isLoggingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在与 Apple 建立登录会话…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .disabled(model.isLoggingIn)
    }

    @ViewBuilder
    private func verification(_ request: TwoFactorRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("双重认证").font(.headline)
            if let error = request.error { Text(error).font(.caption).foregroundStyle(.orange) }
            switch request {
            case .selectDeliveryMethod(_, let phones):
                Text("选择接收验证码的方式。").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Button("在受信任的 Apple 设备上接收") { model.answerVerification(.requestTrustedDevice) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                    ForEach(phones) { phone in
                        Button("发送短信至 \(phone.number)") { model.answerVerification(.requestSMS(phoneID: phone.id)) }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                    }
                }
            case .trustedDevice:
                Text("请在受信任的 Apple 设备上允许登录，并输入六位验证码。").foregroundStyle(.secondary)
                codeEntry
            case .sms(let phones, let activeID, _):
                Text("请输入发送到 \(phones.first { $0.id == activeID }?.number ?? "受信任号码") 的六位验证码。")
                    .foregroundStyle(.secondary)
                codeEntry
                Button("重新发送短信") { model.answerVerification(.requestSMS(phoneID: activeID)) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            case .voice(_, _, _):
                Text("请输入语音提供的六位验证码。").foregroundStyle(.secondary)
                codeEntry
            }
        }
    }

    private var codeEntry: some View {
        let digits = code.filter { !$0.isWhitespace }
        return HStack(spacing: 10) {
            TextField("六位验证码", text: $code)
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
            Button("继续") { model.answerVerification(.verificationCode(digits)) }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(digits.count != 6 || !digits.allSatisfy { "0123456789".contains($0) })
                .keyboardShortcut(.defaultAction)
        }
    }
}
