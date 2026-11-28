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
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var needsLogin = false
    @Published private(set) var startupError: String?
    @Published private(set) var discoveryError: String?
    @Published private(set) var loginError: String?
    @Published var notice: String?
    @Published var showLogin = false
    @Published var showSettings = false
    @Published var updateSourceAppID: UUID?
    @Published var selectedDeviceID: String?
    @Published private(set) var verificationRequest: TwoFactorRequest?
    @Published private(set) var availableTeams: [Team] = []
    @Published private(set) var hasGitHubToken = false

    private let vault = KeychainVault()
    private var store: LibraryStore?
    private var signing: SigningService?
    private var scanTask: Task<Void, Never>?
    private var iconTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
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
        do { hasGitHubToken = try vault.read(String.self, key: "github-update-token") != nil }
        catch { notice = "无法读取 GitHub Token：\(error.localizedDescription)" }
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
        updateTask = Task {
            while !Task.isCancelled {
                await checkForUpdates()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
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
                        || (device.name != nil && device.displayName != updated.devices[index].name)
                        || (device.osVersion != nil && device.osVersion != updated.devices[index].osVersion) {
                        if device.name != nil { updated.devices[index].name = device.displayName }
                        updated.devices[index].lastSeen = now
                        if let version = device.osVersion { updated.devices[index].osVersion = version }
                        changed = true
                    }
                } else {
                    updated.devices.append(RememberedDevice(id: device.udid, name: device.displayName, lastSeen: now,
                                                            osVersion: device.osVersion))
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
        let trimmedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoggingIn = true
        loginError = nil
        availableTeams = []
        pendingAuthentication = nil
        let settings = library.settings
        loginTask = Task {
            defer { isLoggingIn = false; loginTask = nil }
            do {
                let result = try await signing.login(appleID: trimmedAppleID, password: password, settings: settings) { request in
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
                loginError = message
                record("登录失败：\(message)")
            }
        }
    }

    func selectTeam(_ team: Team) async {
        guard let authentication = pendingAuthentication, let signing else { return }
        loginError = nil
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
        } catch { loginError = userMessage(error) }
    }

    func cancelLogin() {
        loginTask?.cancel()
        answerVerification(.cancel)
        loginError = nil
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

    @discardableResult
    func logout() async -> Bool {
        guard !isBusy, !isLoggingIn else {
            loginError = "请等待当前任务完成后再退出账号。"
            return false
        }
        loginError = nil
        do {
            try await signing?.logout()
            account = nil
            needsLogin = false
            record("已退出账号；保留应用与签名证书记录。")
            return true
        } catch {
            loginError = userMessage(error)
            return false
        }
    }

    func saveSettings(_ settings: AppSettings) throws {
        guard !isBusy, !isLoggingIn else { throw ReSignError("请等待当前任务完成后再保存设置。") }
        let xcodeVersion = settings.xcodeVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (12...72).contains(settings.refreshLeadHours), !xcodeVersion.isEmpty else {
            throw ReSignError("续签提前量需为 12～72 小时，Xcode 客户端版本不能为空。")
        }
        var normalized = settings
        normalized.xcodeVersion = xcodeVersion
        if normalized.anisetteSource == .remoteV3 { _ = try normalized.validatedServerURL() }
        var updated = library
        updated.settings = normalized
        try commit(updated)
        if let account, account.context != normalized.authenticationContext { needsLogin = true }
        record("设置已保存。")
    }

    func saveGitHubToken(_ input: String) throws {
        guard !isBusy, !isLoggingIn else { throw ReSignError("请等待当前任务完成。") }
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ReSignError("GitHub Token 不能包含空格、换行或非 ASCII 字符。")
        }
        if token.isEmpty { try vault.remove("github-update-token") }
        else { try vault.write(token, key: "github-update-token") }
        hasGitHubToken = !token.isEmpty
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
            let (info, discovery, discoveryError) = try await Task.detached(priority: .userInitiated) { () throws -> (IPAInfo, IPAUpdateDiscovery, String?) in
                try FileManager.default.copyItem(at: url, to: cached)
                let appURL = try IPAService.extract(cached, into: work)
                let info = try IPAService.inspect(appURL)
                do { return (info, try IPAUpdateService.discover(in: appURL), Optional<String>.none) }
                catch { return (info, IPAUpdateDiscovery(source: nil, candidates: []), error.localizedDescription) }
            }.value
            var updated = library
            var obsolete: URL?
            var obsoleteIcon: URL?
            var previous: String?
            if let index = updated.apps.firstIndex(where: {
                $0.deviceID == device.udid && $0.originalBundleID == info.bundleID && $0.teamID == account.team.identifier
            }) {
                obsolete = try store.sourceURL(for: updated.apps[index])
                obsoleteIcon = try store.iconURL(for: updated.apps[index])
                previous = updated.apps[index].previousIPAFilename
                updated.apps[index].previousIPAFilename = nil
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
            if let index = updated.apps.firstIndex(where: { $0.ipaFilename == filename }) {
                updated.apps[index].updateCandidates = discovery.candidates
                if updated.apps[index].updateSource == nil { updated.apps[index].updateSource = discovery.source }
                updated.apps[index].lastResolvedRelease = nil
                updated.apps[index].lastUpdateCheck = nil
                updated.apps[index].lastUpdateError = discoveryError
            }
            try commit(updated)
            if let obsolete { removeTemporary(obsolete) }
            if let obsoleteIcon { removeTemporary(obsoleteIcon) }
            if let previous { removeCachedIPA(previous, store: store) }
            record("已导入：\(info.name) \(info.version)")
            if let app = library.apps.first(where: { $0.ipaFilename == filename }) {
                appIcons[app.id] = nil
                await loadAppIcon(for: app)
                if let source = app.updateSource { record("已绑定更新来源：\(source.title)") }
                else { updateSourceAppID = app.id }
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
                    $0.previousIPAFilename = nil
                }
                if let previous = app.previousIPAFilename { removeCachedIPA(previous, store: store) }
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

    func saveUpdateSource(_ input: String, pattern: String, enabled: Bool, appID: UUID) throws {
        guard !isCheckingUpdates, !isLoggingIn, startupError == nil else {
            throw ReSignError("请等待当前更新检查完成后再保存。")
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: AppUpdateSource?
        if text.isEmpty { source = nil }
        else { source = try IPAUpdateService.source(from: text, assetPattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try updateApp(appID) {
            $0.updateSource = source
            $0.automaticUpdates = enabled
            $0.lastUpdateCheck = nil
            $0.lastUpdateError = nil
            $0.lastResolvedRelease = nil
        }
        if let source { record("已保存更新来源：\(source.title)") }
        else { record("已清除更新来源。") }
        Task { await checkForUpdates(appID: appID) }
    }

    func checkForUpdates(appID: UUID? = nil, force: Bool = false) async {
        guard !isBusy, !isScanning, !isLoggingIn, startupError == nil, let store else { return }
        let candidates = library.apps.filter {
            (appID == nil || $0.id == appID) && $0.updateSource != nil
                && $0.previousIPAFilename == nil
                && (force || $0.automaticUpdates != false)
                && (force || Date().timeIntervalSince($0.lastUpdateCheck ?? .distantPast) >= 3600)
        }
        guard !candidates.isEmpty else { return }
        do {
            isBusy = true
            isCheckingUpdates = true
            defer {
                isCheckingUpdates = false
                isBusy = false
            }
            for candidate in candidates {
                guard let app = library.apps.first(where: { $0.id == candidate.id }), let source = app.updateSource else { continue }
                // Keep one rollback copy until installation succeeds; do not stack pending updates.
                guard app.previousIPAFilename == nil else { continue }
                let cached = store.ipaDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
                let work = store.workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                var committed = false
                defer {
                    removeTemporary(work)
                    if !committed { removeTemporary(cached) }
                }
                do {
                    try updateApp(app.id) { $0.lastUpdateCheck = Date() }
                    let osVersion = connected.first { $0.udid == app.deviceID }?.osVersion
                        ?? library.devices.first { $0.id == app.deviceID }?.osVersion
                    let token: String?
                    if source.kind == .github { token = try vault.read(String.self, key: "github-update-token") }
                    else { token = nil }
                    let release = try await IPAUpdateService.release(for: source, bundleID: app.originalBundleID,
                                                                     osVersion: osVersion, githubToken: token)
                    if !force, release.identifier == app.lastResolvedRelease {
                        try updateApp(app.id) { $0.lastUpdateError = nil }
                        continue
                    }
                    record("检查更新：\(app.name)")
                    try await IPAUpdateService.download(release, to: cached)
                    let info = try await Task.detached(priority: .utility) {
                        try IPAUpdateService.inspectUpdate(cached, into: work, release: release, app: app, osVersion: osVersion)
                    }.value
                    guard IPAUpdateService.isNewer(version: info.version, build: info.buildVersion, than: app) else {
                        try updateApp(app.id) {
                            $0.lastResolvedRelease = release.identifier
                            $0.lastUpdateError = nil
                        }
                        if force { record("\(app.name) 没有更高版本的 IPA。") }
                        continue
                    }
                    try updateApp(app.id) {
                        $0.previousIPAFilename = app.ipaFilename
                        $0.ipaFilename = cached.lastPathComponent
                        $0.name = info.name
                        $0.version = info.version
                        $0.buildVersion = info.buildVersion
                        $0.pendingInstall = true
                        $0.lastError = nil
                        $0.failedAttempts = 0
                        $0.nextAttemptAt = nil
                        $0.lastResolvedRelease = release.identifier
                        $0.lastUpdateError = nil
                    }
                    committed = true
                    stages[app.id] = .waiting
                    appIcons[app.id] = nil
                    if let updated = library.apps.first(where: { $0.id == app.id }) { await loadAppIcon(for: updated) }
                    record("已下载更新：\(info.name) \(info.version)，等待设备连接并安装。")
                } catch {
                    let message = userMessage(error)
                    record("\(app.name) 更新检查失败：\(message)")
                    do { try updateApp(app.id) { $0.lastUpdateError = message } }
                    catch { startupError = "无法保存更新状态：\(userMessage(error))"; break }
                }
            }
        }
        // A failed update request must not prevent renewal with the existing source IPA.
        await refresh()
    }

    func restorePreviousIPA(appID: UUID) async {
        guard !isBusy, !isScanning, !isLoggingIn, let store,
              let app = library.apps.first(where: { $0.id == appID }), let previous = app.previousIPAFilename else { return }
        isBusy = true
        defer { isBusy = false }
        let work = store.workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { removeTemporary(work) }
        do {
            var old = app
            old.ipaFilename = previous
            let source = try store.sourceURL(for: old)
            let info = try await Task.detached(priority: .utility) {
                try IPAService.inspect(IPAService.extract(source, into: work))
            }.value
            guard info.bundleID == app.originalBundleID else { throw ReSignError("上一份 IPA 的应用身份不一致。") }
            try updateApp(app.id) {
                $0.ipaFilename = previous
                $0.previousIPAFilename = nil
                $0.name = info.name
                $0.version = info.version
                $0.buildVersion = info.buildVersion
                $0.pendingInstall = true
                $0.failedAttempts = 0
                $0.nextAttemptAt = nil
                $0.lastError = nil
                $0.automaticUpdates = false
            }
            removeCachedIPA(app.ipaFilename, store: store)
            stages[app.id] = .waiting
            appIcons[app.id] = nil
            await loadAppIcon(for: old)
            record("已恢复 \(info.name) 的上一份 IPA，并暂停自动更新；可点击立即续签安装。")
        } catch { notice = userMessage(error) }
    }

    private func removeCachedIPA(_ filename: String, store: LibraryStore) {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent, filename.hasSuffix(".ipa") else { return }
        removeTemporary(store.ipaDirectory.appendingPathComponent(filename))
        removeTemporary(store.root.appendingPathComponent("Icons").appendingPathComponent(String(filename.dropLast(4)) + ".png"))
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
            if let previous = app.previousIPAFilename { removeCachedIPA(previous, store: store) }
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
