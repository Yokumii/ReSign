import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingImporter = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                Label("ReSign", systemImage: "signature")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16).padding(.top, 20)
                List(selection: $model.selectedDeviceID) {
                    Section("设备") {
                        ForEach(model.library.devices) { device in
                            let current = model.connected.first { $0.udid == device.id }
                            HStack(spacing: 10) {
                                Image(systemName: "iphone").font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).lineLimit(1)
                                    Text(current?.connectionStatus ?? "未连接")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Circle().fill(current?.trusted == true ? Color.green : Color.secondary.opacity(0.3))
                                    .frame(width: 6, height: 6)
                            }.padding(.vertical, 7).tag(device.id)
                        }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    if let account = model.account {
                        Text(account.team.name).font(.headline)
                        Text(model.accountReady ? "账号已就绪" : "需要重新登录")
                            .font(.caption).foregroundStyle(model.accountReady ? Color.secondary : Color.orange)
                    } else {
                        Text("尚未登录").font(.headline)
                        Text("登录后导入 IPA，后续自动续签。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(model.account == nil ? "登录 Apple 账号" : "账号与团队") { model.showLogin = true }
                        .disabled(model.isBusy)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if let error = model.startupError {
                    ContentUnavailableView("无法加载资料", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if let error = model.discoveryError { message(error, symbol: "cable.connector") }
                            if let device = model.selectedDevice, !device.trusted {
                                message(device.connectionError ?? "请解锁设备并信任这台 Mac。", symbol: "lock.iphone")
                            }
                            if model.needsLogin {
                                message("账号需要重新登录，完成后将继续等待中的续签任务。", symbol: "person.crop.circle.badge.exclamationmark")
                            }
                            appList
                            activityList
                        }.padding(26)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItemGroup {
                    Button { Task { await model.scanDevices() } } label: { Label("扫描设备", systemImage: "arrow.clockwise") }
                    Button { model.showSettings = true } label: { Label("设置", systemImage: "gearshape") }
                        .disabled(model.isBusy || model.isLoggingIn)
                }
            }
        }
        .sheet(isPresented: $model.showLogin, onDismiss: { model.cancelLogin() }) { LoginView(model: model) }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .alert("ReSign", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
            switch result {
            case .success(let url): Task { await model.importIPA(url) }
            case .failure(let error): model.notice = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("应用续签").font(.system(size: 28, weight: .semibold))
                Text(model.isBusy ? "正在处理，完成后更新有效期。" : "启动时自动处理临近到期的应用。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingImporter = true } label: { Label("导入 IPA", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isBusy || model.isLoggingIn || model.startupError != nil)
        }.padding(26)
    }

    @ViewBuilder
    private var appList: some View {
        if model.visibleApps.isEmpty {
            ContentUnavailableView {
                Label("还没有托管应用", systemImage: "square.stack.3d.up")
            } description: {
                Text("通过 USB 或局域网连接设备并登录账号，导入 IPA 后即可自动续签。局域网连接需先通过 USB 信任 Mac，并在 Finder 中开启“连接到 Wi-Fi 时显示此设备”。")
            }.frame(maxWidth: .infinity, minHeight: 230)
        } else {
            VStack(spacing: 12) {
                ForEach(model.visibleApps) { app in
                    AppCard(app: app, stage: model.stages[app.id], model: model)
                }
            }
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近活动").font(.headline)
            if model.activities.isEmpty {
                Text("设备接入、安装与续签结果会显示在这里。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.activities.prefix(15)) { activity in
                HStack(alignment: .top, spacing: 14) {
                    Text(activity.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                    Text(activity.message).textSelection(.enabled)
                }.font(.caption)
            }
        }.padding(.top, 8)
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AppCard: View {
    let app: ManagedApp
    let stage: JobStage?
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.headline)
                    Text("版本 \(app.version) · \(deviceName)").font(.caption).foregroundStyle(.secondary)
                    Text(app.bundleID).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(stage?.rawValue ?? (app.lastInstalledAt == nil ? "等待首次安装" : "已托管"))
                        .font(.caption).foregroundStyle(stage == .failed ? Color.orange : Color.secondary)
                    if let expiry = app.expiresAt {
                        Text(expiry <= Date() ? "已到期" : "\(expiry.formatted(.relative(presentation: .numeric)))到期")
                            .font(.callout.weight(.medium))
                        Text(expiry, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = app.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                if app.failedAttempts >= 5 {
                    Text("连续失败已暂停自动重试；处理原因后点击“立即续签”。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let next = app.nextAttemptAt {
                    Text("下次重试：\(next.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("自动续签", isOn: Binding(get: { app.autoRefresh }, set: { model.setAutomatic($0, appID: app.id) }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("立即续签") { Task { await model.refresh(appID: app.id, force: true) } }
                Menu {
                    Button("停止托管", role: .destructive) { model.forgetApp(app) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }.disabled(model.isBusy || model.isLoggingIn)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06)))
    }

    private var appIcon: some View {
        Group {
            if let image = model.appIcons[app.id] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.fill").font(.system(size: 39)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var deviceName: String { model.library.devices.first { $0.id == app.deviceID }?.name ?? "设备" }
}
