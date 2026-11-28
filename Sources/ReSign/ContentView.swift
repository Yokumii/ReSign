import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingImporter = false
    @State private var networkDevice: RememberedDevice?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 256, max: 300)
        } detail: {
            detail
        }
        .sheet(isPresented: $model.showLogin, onDismiss: { model.cancelLogin() }) { LoginView(model: model) }
        .sheet(item: $networkDevice) { device in NetworkConnectionView(model: model, device: device) }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: Binding(get: { model.updateSourceAppID != nil },
                                    set: { if !$0 { model.updateSourceAppID = nil } })) {
            if let app = model.library.apps.first(where: { $0.id == model.updateSourceAppID }) {
                UpdateSourceView(model: model, app: app)
            }
        }
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

    private var sidebar: some View {
        List(selection: $model.selectedDeviceID) {
            Section("设备") {
                if model.library.devices.isEmpty {
                    Label("连接设备后将显示在此处", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(model.library.devices) { device in
                        let current = model.connected.first { $0.udid == device.id }
                        DeviceSidebarRow(device: device, current: current)
                            .tag(device.id)
                            .contextMenu {
                                Button("通过 IP 连接…") { networkDevice = device }
                                    .disabled(model.isBusy || model.isScanning)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaBar(edge: .bottom) {
            sidebarAccountBar
        }
    }

    private var sidebarAccountBar: some View {
        Button {
            model.showLogin = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: accountSymbol)
                    .font(.title3)
                    .foregroundStyle(accountAccentColor)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.account?.team.name ?? "登录 Apple 账号")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(model.account != nil && !model.accountReady ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(model.isBusy || model.startupError != nil)
        .opacity(model.isBusy || model.startupError != nil ? 0.55 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var detail: some View {
        Group {
            if let error = model.startupError {
                ContentUnavailableView("无法加载资料", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        statusBanners
                        appList
                        activityList
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .navigationTitle(detailTitle)
        .navigationSubtitle(detailSubtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.scanDevices() } } label: {
                    Label("扫描设备", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || model.isScanning || model.startupError != nil)
                .help("扫描 USB 与局域网设备")

                Button {
                    networkDevice = model.library.devices.first { $0.id == model.selectedDeviceID }
                } label: {
                    Label("通过 IP 连接", systemImage: "network")
                }
                .disabled(model.selectedDeviceID == nil || model.isBusy || model.isScanning || model.startupError != nil)
                .help("配置当前设备的局域网 IP 直连")

                Button { model.showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .disabled(model.isBusy || model.isLoggingIn)
                .help("打开应用设置")
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Button { showingImporter = true } label: {
                    Label("导入 IPA", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy || model.isScanning || model.isLoggingIn || model.startupError != nil)
            }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if let error = model.discoveryError {
            StatusBanner(text: error, symbol: "cable.connector", tint: .orange)
        }
        if let device = model.selectedDevice, !device.trusted {
            StatusBanner(text: device.connectionError ?? "请解锁设备并信任这台 Mac。", symbol: "lock.iphone", tint: .orange)
        }
        if model.needsLogin {
            StatusBanner(
                text: "账号需要重新登录，完成后将继续等待中的续签任务。",
                symbol: "person.crop.circle.badge.exclamationmark",
                tint: .orange,
                actionTitle: "重新登录",
                actionDisabled: model.isBusy || model.startupError != nil
            ) {
                model.showLogin = true
            }
        }
    }

    @ViewBuilder
    private var appList: some View {
        if model.visibleApps.isEmpty {
            ContentUnavailableView {
                Label("还没有托管应用", systemImage: "square.stack.3d.up")
            } description: {
                Text("通过 USB 或局域网连接设备并登录账号，导入 IPA 后即可自动续签。局域网连接需先通过 USB 信任 Mac，并在 Finder 中开启“接入 Wi-Fi 时显示此设备”。")
            } actions: {
                Button { showingImporter = true } label: {
                    Label("导入 IPA", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(model.isBusy || model.isScanning || model.isLoggingIn || model.startupError != nil)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            VStack(spacing: 14) {
                ForEach(model.visibleApps) { app in
                    AppCard(app: app, stage: model.stages[app.id], model: model)
                }
            }
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("最近活动").font(.headline)
                if !model.activities.isEmpty {
                    Text("\(min(model.activities.count, 15))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if model.activities.isEmpty {
                    Text("设备接入、安装与续签结果会显示在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    let recent = Array(model.activities.prefix(15))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, activity in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(activity.date, style: .time)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 68, alignment: .leading)
                            Text(activity.message)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        if index < recent.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        }
        .padding(.top, 6)
    }

    private var detailTitle: String {
        if let selectedID = model.selectedDeviceID,
           let device = model.library.devices.first(where: { $0.id == selectedID }) {
            return device.name
        }
        return "应用续签"
    }

    private var detailSubtitle: String {
        if model.isBusy { return "正在处理应用任务…" }
        if model.isScanning { return "正在扫描设备…" }
        return "自动检查软件更新，并处理临近到期的应用。"
    }

    private var accountSymbol: String {
        guard model.account != nil else { return "person.crop.circle" }
        return model.accountReady ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
    }

    private var accountAccentColor: Color {
        guard model.account != nil else { return .accentColor }
        return model.accountReady ? .accentColor : .orange
    }

    private var accountSubtitle: String {
        guard model.account != nil else { return "登录后导入并自动续签" }
        return model.accountReady ? "账号已就绪" : "需要重新登录"
    }
}

private struct DeviceSidebarRow: View {
    let device: RememberedDevice
    let current: ConnectedDevice?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: deviceSymbol)
                .font(.title3)
                .foregroundStyle(current?.trusted == true ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .lineLimit(1)
                Text(current?.connectionStatus ?? "未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 4)
    }

    private var deviceSymbol: String {
        device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }

    private var statusColor: Color {
        guard let current else { return .secondary.opacity(0.3) }
        return current.trusted ? .green : .orange
    }
}

private struct StatusBanner: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String? = nil
    var actionDisabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(actionDisabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }
}

private struct AppCard: View {
    let app: ManagedApp
    let stage: JobStage?
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.headline)
                    Text("版本 \(app.version) · \(deviceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(app.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    stageBadge
                    if let expiry = app.expiresAt {
                        Text(expiry <= Date() ? "已到期" : "\(expiry.formatted(.relative(presentation: .numeric)))到期")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(expiry <= Date() ? .orange : .primary)
                        Text(expiry, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = app.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    if app.failedAttempts >= 5 {
                        Text("连续失败已暂停自动重试；处理原因后点击“立即续签”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let next = app.nextAttemptAt {
                        Text("下次重试：\(next.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let source = app.updateSource {
                        Label(app.automaticUpdates == false ? "自动更新已暂停" : "每小时检查更新", systemImage: "arrow.down.circle")
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(source.title)
                            .foregroundStyle(.primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Label("未绑定更新来源", systemImage: "link")
                    }
                }
                if let checked = app.lastUpdateCheck {
                    Text("上次检查：\(checked.formatted(date: .abbreviated, time: .shortened))")
                }
                if app.pendingInstall, app.previousIPAFilename != nil {
                    Text("新版 IPA 已就绪，等待覆盖安装。")
                        .foregroundStyle(Color.accentColor)
                }
                if let error = app.lastUpdateError {
                    Text("软件更新：\(error)")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Toggle("自动续签", isOn: Binding(get: { app.autoRefresh }, set: { model.setAutomatic($0, appID: app.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isBusy || model.isLoggingIn)
                Spacer(minLength: 8)
                GlassEffectContainer(spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Button(app.updateSource == nil ? "填写更新来源…" : "更新来源…") {
                            model.updateSourceAppID = app.id
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .disabled(model.isCheckingUpdates || model.isLoggingIn)

                        Button("立即续签") {
                            Task { await model.refresh(appID: app.id, force: true) }
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .disabled(model.isBusy || model.isScanning || model.isLoggingIn)

                        Menu {
                            Button("检查软件更新") {
                                Task { await model.checkForUpdates(appID: app.id, force: true) }
                            }
                            .disabled(app.updateSource == nil || app.previousIPAFilename != nil || model.isScanning)
                            if app.previousIPAFilename != nil {
                                Button("恢复上一份 IPA 并暂停更新") {
                                    Task { await model.restorePreviousIPA(appID: app.id) }
                                }
                                .disabled(model.isScanning)
                            }
                            Divider()
                            Button("停止托管", role: .destructive) {
                                model.forgetApp(app)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .glassEffect(.regular.interactive(), in: Circle())
                        .disabled(model.isBusy || model.isLoggingIn)
                        .opacity(model.isBusy || model.isLoggingIn ? 0.45 : 1)
                        .accessibilityLabel("更多操作")
                    }
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var stageBadge: some View {
        HStack(spacing: 5) {
            if isActiveStage {
                ProgressView().controlSize(.mini)
            }
            Text(stage?.rawValue ?? (app.lastInstalledAt == nil ? "等待首次安装" : "已托管"))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(stageColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(stageColor.opacity(0.12), in: Capsule())
    }

    private var isActiveStage: Bool {
        switch stage {
        case .authentication, .provisioning, .signing, .installing:
            return true
        default:
            return false
        }
    }

    private var stageColor: Color {
        switch stage {
        case .failed: return .orange
        case .complete: return .green
        case .authentication, .provisioning, .signing, .installing: return .accentColor
        case .waiting, .none: return .secondary
        }
    }

    private var appIcon: some View {
        Group {
            if let image = model.appIcons[app.id] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    Color.primary.opacity(0.05)
                    Image(systemName: "app.dashed")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var deviceName: String { model.library.devices.first { $0.id == app.deviceID }?.name ?? "设备" }
}
