import AppKit
import Combine
import Foundation
import ImageIO
import SideSign

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var connected: [ConnectedDevice] = []
    @Published private(set) var account: SavedAccount?
    @Published private(set) var stages: [UUID: JobStage] = [:]
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var appIcons: [UUID: NSImage] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var needsLogin = false
    @Published private(set) var startupError: String?
    @Published private(set) var discoveryError: String?
    @Published var notice: String?
    @Published var showLogin = false
    @Published var showSettings = false
    @Published var selectedDeviceID: String?
    @Published private(set) var verificationRequest: TwoFactorRequest?
    @Published private(set) var availableTeams: [Team] = []

    private var store: LibraryStore?
    private var signing: SigningService?
    private var scanTask: Task<Void, Never>?
    private var iconTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    @Published private(set) var isScanning = false
    private var pendingAuthentication: AuthSession?
    private var verificationContinuation: CheckedContinuation<TwoFactorResponse, Never>?

    var selectedDevice: ConnectedDevice? { connected.first { $0.udid == selectedDeviceID } }
    var accountReady: Bool {
        guard let account else { return false }
        return !needsLogin && account.authentication.session.isValid
            && account.context == library.settings.authenticationContext
    }
    var visibleApps: [ManagedApp] {
        guard let selectedDeviceID else { return library.apps }
        return library.apps.filter { $0.deviceID == selectedDeviceID }
    }

    init() {
        do {
            let storage = try LibraryStore()
            library = try storage.load()
            store = storage
            signing = SigningService()
        } catch {
            startupError = "无法加载本地资料：\(error.localizedDescription)"
        }
    }

    func start() {
        guard scanTask == nil, startupError == nil else { return }
        iconTask = Task {
            for app in library.apps { await loadAppIcon(for: app) }
        }
        scanTask = Task {
            do {
                account = try await signing?.savedAccount()
                needsLogin = account != nil && !accountReady
            } catch { notice = userMessage(error) }
            await scanDevices()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await scanDevices()
            }
        }
    }

    func scanDevices() async {
        guard !isScanning, !isBusy, startupError == nil else { return }
        if await discoverDevices() { await refresh() }
    }

    private func discoverDevices() async -> Bool {
        isScanning = true
        defer { isScanning = false }
        do {
            let previouslyOnline = Set(connected.filter(\.trusted).map(\.udid))
            let devices = try await DeviceService.scan(remembered: library.devices)
            connected = devices
            discoveryError = nil
            if selectedDeviceID == nil { selectedDeviceID = devices.first?.udid ?? library.devices.first?.id }
            let now = Date()
            var updated = library
            var changed = false
            let reconnected = Set(devices.filter(\.trusted).map(\.udid)).subtracting(previouslyOnline)
            for index in updated.apps.indices where reconnected.contains(updated.apps[index].deviceID)
                && updated.apps[index].failedAttempts < 5 && updated.apps[index].nextAttemptAt != nil {
                updated.apps[index].nextAttemptAt = nil
                changed = true
            }
            for device in devices {
                if let index = updated.devices.firstIndex(where: { $0.id == device.udid }) {
                    if now.timeIntervalSince(updated.devices[index].lastSeen) >= 60
                        || (device.name != nil && device.displayName != updated.devices[index].name) {
                        if device.name != nil { updated.devices[index].name = device.displayName }
                        updated.devices[index].lastSeen = now
                        changed = true
                    }
                } else {
                    updated.devices.append(RememberedDevice(id: device.udid, name: device.displayName, lastSeen: now))
                    changed = true
                    record("发现设备：\(device.displayName)")
                }
            }
            if changed { try commit(updated) }
        } catch {
            connected = []
            discoveryError = userMessage(error)
            return false
        }
        return true
    }

    func setNetworkAddress(_ input: String, for deviceID: String) throws {
        guard !isBusy, !isScanning, startupError == nil else {
            throw ReSignError("请等待当前扫描或安装完成后再修改 IP 地址。")
        }
        guard let index = library.devices.firstIndex(where: { $0.id == deviceID }) else {
            throw ReSignError("请先通过 USB 配对并发现设备。")
        }
        let address = try DeviceService.validatedNetworkAddress(input)
        var updated = library
        updated.devices[index].networkAddress = address
        try commit(updated)
        connected.removeAll { $0.udid == deviceID && $0.networkAddress != nil }
        record(address == nil ? "已清除设备的手动 IP 地址。" : "已保存设备 IP 地址，正在重新连接。")
        Task { await self.scanDevices() }
    }

    func beginLogin(appleID: String, password: String) {
        guard !isBusy, !isLoggingIn, let signing, startupError == nil else { return }
        isLoggingIn = true
        availableTeams = []
        pendingAuthentication = nil
        let settings = library.settings
        loginTask = Task {
            defer { isLoggingIn = false; loginTask = nil }
            do {
                let result = try await signing.login(appleID: appleID, password: password, settings: settings) { request in
                    await self.requestVerification(request)
                }
                try Task.checkCancellation()
                pendingAuthentication = result.0
                availableTeams = result.1
                if result.1.count == 1, let team = result.1.first { await selectTeam(team) }
            } catch is CancellationError {
                record("已取消登录。")
            } catch {
                let message = userMessage(error)
                notice = message
                record("登录失败：\(message)")
            }
        }
    }

    func selectTeam(_ team: Team) async {
        guard let authentication = pendingAuthentication, let signing else { return }
        do {
            account = try await signing.selectTeam(team, authentication: authentication, settings: library.settings)
            needsLogin = false
            availableTeams = []
            pendingAuthentication = nil
            showLogin = false
            record("已登录开发团队：\(team.name)")
            // A successful login clears transient backoff for jobs in the selected team.
            var updated = library
            for index in updated.apps.indices where updated.apps[index].teamID == team.identifier {
                updated.apps[index].nextAttemptAt = nil
                updated.apps[index].failedAttempts = 0
            }
            try commit(updated)
            Task { await refresh() }
        } catch { notice = userMessage(error) }
    }

    func cancelLogin() {
        loginTask?.cancel()
        answerVerification(.cancel)
        pendingAuthentication = nil
        availableTeams = []
        showLogin = false
    }

    private func requestVerification(_ request: TwoFactorRequest) async -> TwoFactorResponse {
        guard !Task.isCancelled else { return .cancel }
        verificationRequest = request
        return await withCheckedContinuation { continuation in
            verificationContinuation = continuation
        }
    }

    func answerVerification(_ response: TwoFactorResponse) {
        let continuation = verificationContinuation
        verificationContinuation = nil
        verificationRequest = nil
        continuation?.resume(returning: response)
    }

    func logout() async {
        guard !isBusy, !isLoggingIn else { return }
        do {
            try await signing?.logout()
            account = nil
            needsLogin = false
            record("已退出账号；保留应用与签名证书记录。")
        } catch { notice = userMessage(error) }
    }

    @discardableResult
    func saveSettings(_ settings: AppSettings) -> Bool {
        guard !isBusy, !isLoggingIn else { return false }
        do {
            guard (12...72).contains(settings.refreshLeadHours), !settings.xcodeVersion.isEmpty else {
                throw ReSignError("续签提前量需为 12～72 小时，Xcode 客户端版本不能为空。")
            }
            if settings.anisetteSource == .remoteV3 { _ = try settings.validatedServerURL() }
            var updated = library
            updated.settings = settings
            try commit(updated)
            if let account, account.context != settings.authenticationContext { needsLogin = true }
            showSettings = false
            record("设置已保存。")
            return true
        } catch { notice = userMessage(error); return false }
    }

    func importIPA(_ url: URL) async {
        guard !isBusy, !isScanning, !isLoggingIn, let store, let account, accountReady,
              let device = selectedDevice, device.trusted else {
            notice = "请先登录账号，并选择已通过 USB 或局域网连接且受信任的 iPhone／iPad。"
            return
        }
        isBusy = true
        let filename = UUID().uuidString + ".ipa"
        let cached = store.ipaDirectory.appendingPathComponent(filename)
        let work = store.workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: work)
            isBusy = false
        }
        do {
            let info = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: url, to: cached)
                let appURL = try IPAService.extract(cached, into: work)
                return try IPAService.inspect(appURL)
            }.value
            var updated = library
            var obsolete: URL?
            var obsoleteIcon: URL?
            if let index = updated.apps.firstIndex(where: {
                $0.deviceID == device.udid && $0.originalBundleID == info.bundleID && $0.teamID == account.team.identifier
            }) {
                obsolete = try store.sourceURL(for: updated.apps[index])
                obsoleteIcon = try store.iconURL(for: updated.apps[index])
                updated.apps[index].ipaFilename = filename
                updated.apps[index].name = info.name
                updated.apps[index].version = info.version
                updated.apps[index].buildVersion = info.buildVersion
                updated.apps[index].pendingInstall = true
                updated.apps[index].lastError = nil
                updated.apps[index].failedAttempts = 0
                updated.apps[index].nextAttemptAt = nil
            } else {
                updated.apps.append(ManagedApp(deviceID: device.udid, teamID: account.team.identifier,
                                               name: info.name, version: info.version, buildVersion: info.buildVersion,
                                               originalBundleID: info.bundleID,
                                               bundleID: SigningService.bundleID(original: info.bundleID, team: account.team.identifier),
                                               ipaFilename: filename))
            }
            try commit(updated)
            if let obsolete { removeTemporary(obsolete) }
            if let obsoleteIcon { removeTemporary(obsoleteIcon) }
            record("已导入：\(info.name) \(info.version)")
            if let app = library.apps.first(where: { $0.ipaFilename == filename }) {
                appIcons[app.id] = nil
                await loadAppIcon(for: app)
                // Import clears isBusy before the initial install starts.
                Task { await self.refresh(appID: app.id, force: true) }
            }
        } catch {
            removeTemporary(cached)
            notice = userMessage(error)
        }
    }

    func refresh(appID: UUID? = nil, force: Bool = false) async {
        guard !isBusy, !isScanning, !isLoggingIn, startupError == nil, let store, let signing else { return }
        let now = Date()
        let candidates = library.apps.filter { app in
            if let appID, app.id != appID { return false }
            return force || app.isDue(at: now, leadHours: library.settings.refreshLeadHours)
        }
        guard !candidates.isEmpty else { return }
        guard accountReady else {
            if force { showLogin = true }
            return
        }
        isBusy = true
        defer { isBusy = false }
        for candidate in candidates {
            guard let app = library.apps.first(where: { $0.id == candidate.id }) else { continue }
            guard let device = connected.first(where: { $0.udid == app.deviceID && $0.trusted }) else {
                stages[app.id] = .waiting
                continue
            }
            // Signing and installation share one queue across all devices.
            var workspace: URL?
            defer { if let workspace { removeTemporary(workspace) } }
            do {
                let source = try store.sourceURL(for: app)
                record("开始续签：\(app.name) → \(device.displayName)")
                let artifact = try await signing.sign(app: app, device: device, source: source,
                                                      workRoot: store.workDirectory, settings: library.settings) { [weak self] stage in
                    await self?.setStage(stage, for: app.id)
                }
                workspace = artifact.workspace
                stages[app.id] = .installing
                try await DeviceService.install(ipa: artifact.ipa, device: device,
                                                 bundleID: app.bundleID, version: app.buildVersion)
                try updateApp(app.id) {
                    $0.expiresAt = artifact.expiresAt
                    $0.lastInstalledAt = Date()
                    $0.pendingInstall = false
                    $0.lastError = nil
                    $0.failedAttempts = 0
                    $0.nextAttemptAt = nil
                }
                stages[app.id] = .complete
                let action = app.pendingInstall ? "安装完成" : "续签完成"
                record("\(action)：\(app.name)，有效期至 \(artifact.expiresAt.formatted(date: .abbreviated, time: .shortened))")
            } catch {
                let message = userMessage(error)
                stages[app.id] = .failed
                record("\(app.name)：\(message)")
                let requiresLogin = error is AuthenticationNeeded
                do {
                    try updateApp(app.id) {
                        $0.lastError = message
                        if !requiresLogin {
                            $0.failedAttempts += 1
                            let delay = min(6 * 3600, 15 * 60 * pow(2, Double($0.failedAttempts - 1)))
                            $0.nextAttemptAt = Date().addingTimeInterval(delay)
                        }
                    }
                } catch {
                    startupError = "无法保存续签状态：\(error.localizedDescription)"
                    return
                }
                if requiresLogin { needsLogin = true; return }
            }
        }
    }

    func setAutomatic(_ enabled: Bool, appID: UUID) {
        guard !isBusy else { return }
        do { try updateApp(appID) { $0.autoRefresh = enabled } }
        catch { notice = userMessage(error) }
    }

    func forgetApp(_ app: ManagedApp) {
        guard !isBusy, let store else { return }
        do {
            let url = try store.sourceURL(for: app)
            let iconURL = try store.iconURL(for: app)
            var updated = library
            updated.apps.removeAll { $0.id == app.id }
            try commit(updated)
            stages[app.id] = nil
            appIcons[app.id] = nil
            removeTemporary(url)
            removeTemporary(iconURL)
            record("已停止托管：\(app.name)，设备上的应用仍保留。")
        } catch { notice = userMessage(error) }
    }

    func revealData() { if let store { NSWorkspace.shared.open(store.root) } }

    private func loadAppIcon(for app: ManagedApp) async {
        guard let store else { return }
        do {
            let source = try store.sourceURL(for: app)
            let cache = try store.iconURL(for: app)
            let data = try await Task.detached(priority: .utility) { () throws -> Data? in
                if let cached = try? Data(contentsOf: cache),
                   let source = CGImageSourceCreateWithData(cached as CFData, nil),
                   CGImageSourceGetCount(source) > 0 {
                    return cached
                }
                try? FileManager.default.removeItem(at: cache)
                return try IPAIconService.extract(from: source)
            }.value
            // Importing a replacement or forgetting an app can finish while extraction is running.
            guard library.apps.contains(where: { $0.id == app.id && $0.ipaFilename == app.ipaFilename }),
                  let data else { return }
            guard let image = NSImage(data: data) else { throw ReSignError("应用图标缓存无法解码。") }
            appIcons[app.id] = image
            if !FileManager.default.fileExists(atPath: cache.path) {
                try data.write(to: cache, options: .atomic)
            }
        } catch {
            record("\(app.name) 的图标读取失败：\(userMessage(error))")
        }
    }

    private func updateApp(_ id: UUID, _ body: (inout ManagedApp) -> Void) throws {
        var updated = library
        guard let index = updated.apps.firstIndex(where: { $0.id == id }) else { throw ReSignError("找不到托管应用记录。") }
        body(&updated.apps[index])
        try commit(updated)
    }

    private func commit(_ updated: Library) throws {
        guard let store, startupError == nil else { throw ReSignError("本地资料不可写。") }
        try store.save(updated)
        library = updated
    }

    private func setStage(_ stage: JobStage, for id: UUID) { stages[id] = stage }

    private func record(_ message: String) {
        FileHandle.standardError.write(Data("[ReSign] \(message)\n".utf8))
        activities.insert(Activity(message: message), at: 0)
        if activities.count > 100 { activities.removeLast(activities.count - 100) }
    }

    private func removeTemporary(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { record("清理本地文件失败：\(url.lastPathComponent)，\(error.localizedDescription)") }
    }

    private func userMessage(_ error: Error) -> String {
        if let server = error as? ServerError {
            switch server {
            case .badServerResponse(let reason, _): return "Apple 服务响应异常：\(reason)"
            case .invalidResponseFormat: return "Apple 服务返回了无法解析的数据。"
            case .missingKey(let key, _): return "Apple 服务响应缺少字段：\(key)"
            case .underlyingError(-80045, _):
                return "Apple 拒绝了登录请求（-80045）。请检查账号凭据和 Anisette 服务配置。"
            case .underlyingError(let code, let message): return "\(message)（\(code)）"
            }
        }
        return error.localizedDescription
    }
}
