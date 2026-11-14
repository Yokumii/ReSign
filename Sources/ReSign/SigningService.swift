import Foundation
import SideSign

struct AuthenticationNeeded: LocalizedError {
    var errorDescription: String? { "账号会话已失效，请重新登录后继续续签。" }
}

struct SavedAccount: Codable {
    var authentication: AuthSession
    var team: Team
    var context: String
}

private struct SavedCertificate: Codable {
    let certificate: Data
    let privateKey: Data
    let identifier: String?
}

struct SignedArtifact: Sendable {
    let ipa: URL
    let workspace: URL
    let expiresAt: Date
}

actor SigningService {
    private let portal: DeveloperPortal
    private let anisette: AnisetteService
    private let vault: KeychainVault

    init(vault: KeychainVault = KeychainVault()) {
        self.vault = vault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        portal = DeveloperPortal(session: URLSession(configuration: configuration))
        anisette = AnisetteService(vault: vault)
    }

    func savedAccount() throws -> SavedAccount? {
        try vault.read(SavedAccount.self, key: "account")
    }

    func login(
        appleID: String, password: String, settings: AppSettings,
        verification: @escaping DeveloperPortal.VerificationHandler
    ) async throws -> (AuthSession, [Team]) {
        let data = try await anisette.fresh(settings: settings)
        let authentication = try await portal.authenticate(
            appleID: appleID, password: password, anisetteData: data,
            xcodeVersion: settings.xcodeVersion,
            accountRepairHandler: { url, message in
                // Do not open URLs from Apple responses without user interaction.
                throw ReSignError("Apple 要求先完成账号确认或条款确认。请访问 developer.apple.com/account 后重新登录。\n\(message)")
            },
            verificationHandler: verification
        )
        var session = authentication.session
        let freshData = try await anisette.fresh(settings: settings)
        session.anisetteData = try Self.refreshedAnisette(freshData, issued: session.anisetteData)
        let teams = try await portal.fetchTeams(for: authentication.account, session: session)
        guard !teams.isEmpty else { throw ReSignError("此账号没有可用的开发团队。请先在 Apple 开发者网站完成账号设置。") }
        return (AuthSession(account: authentication.account, session: session), teams)
    }

    func selectTeam(_ team: Team, authentication: AuthSession, settings: AppSettings) throws -> SavedAccount {
        guard team.type != .unknown else { throw ReSignError("无法确定此团队的开发者账号类型。") }
        let account = SavedAccount(
            authentication: authentication, team: team,
            context: settings.authenticationContext)
        try vault.write(account, key: "account")
        return account
    }

    func logout() throws { try vault.remove("account") }

    func sign(
        app: ManagedApp, device: ConnectedDevice, source: URL, workRoot: URL,
        settings: AppSettings,
        stage: @escaping @Sendable (JobStage) async -> Void
    ) async throws -> SignedArtifact {
        guard let account = try savedAccount(), account.authentication.session.isValid,
            account.context == settings.authenticationContext
        else { throw AuthenticationNeeded() }
        guard account.team.identifier == app.teamID else {
            throw ReSignError("此应用属于其他开发团队，请使用原团队账号续签。")
        }
        guard app.bundleID == Self.bundleID(original: app.originalBundleID, team: app.teamID) else {
            throw ReSignError("应用签名标识与托管记录不一致。")
        }
        let workspace = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        do {
            // Validate the cached source before modifying developer account resources.
            let appURL = try IPAService.extract(source, into: workspace)
            let info = try IPAService.inspect(appURL)
            guard info.bundleID == app.originalBundleID, info.buildVersion == app.buildVersion else {
                throw ReSignError("缓存的 IPA 与托管记录不一致，请重新导入。")
            }
            let targets = try info.signingTargets(mainBundleID: app.bundleID)
            await stage(.authentication)
            let certificate = try await signingCertificate(account: account, settings: settings)
            var session = try await session(account: account, settings: settings)
            let type: DeviceType = device.productType?.hasPrefix("iPad") == true ? .iPad : .iPhone
            let devices = try await portal.fetchDevices(for: account.team, types: type, session: session)
            if !devices.contains(where: { $0.identifier == device.udid }) {
                session = try await self.session(account: account, settings: settings)
                _ = try await portal.registerDevice(
                    name: device.displayName, identifier: device.udid,
                    type: type, team: account.team, session: session)
            }
            await stage(.provisioning)
            session = try await self.session(account: account, settings: settings)
            var appIDs = try await portal.fetchAppIDs(for: account.team, session: session)
            let groups = try await appGroups(for: targets, account: account, settings: settings)
            var profiles: [ProvisioningProfile] = []
            var expiry = certificate.expiryDate
            for target in targets {
                var appID: AppID
                if let existing = appIDs.first(where: { $0.bundleIdentifier == target.bundleID }) {
                    appID = existing
                } else {
                    session = try await self.session(account: account, settings: settings)
                    let shortName = "ReSign " + String(AnisetteService.digest(Data(target.component.bundleID.utf8)).prefix(16))
                    appID = try await portal.addAppID(
                        withName: shortName, bundleIdentifier: target.bundleID,
                        team: account.team, session: session)
                    appIDs.append(appID)
                }
                guard appID.bundleIdentifier == target.bundleID else {
                    throw ReSignError("Apple 返回的 App ID 与签名目标不匹配：\(target.component.bundleID)。")
                }
                if !target.component.appGroups.isEmpty {
                    if appID.features[.appGroups] != "true" {
                        appID.features[.appGroups] = "true"
                        session = try await self.session(account: account, settings: settings)
                        appID = try await portal.updateAppID(appID, team: account.team, session: session)
                    }
                    let assignedGroups = try target.component.appGroups.map { identifier in
                        guard let group = groups[identifier], !group.groupID.isEmpty else {
                            throw ReSignError("缺少 App Group：\(identifier)。")
                        }
                        return group
                    }
                    session = try await self.session(account: account, settings: settings)
                    appID = try await portal.assignAppGroups(assignedGroups, to: appID, team: account.team, session: session)
                }
                let profile = try await provisioningProfile(
                    for: target, appID: appID, app: app,
                    device: device, certificate: certificate,
                    account: account, settings: settings)
                profiles.append(profile)
                expiry = min(expiry, profile.expirationDate)
            }
            await stage(.signing)
            for target in targets {
                try IPAService.rewriteBundleID(at: target.component.url, to: target.bundleID)
            }
            let signer = AppBundleSigner(team: account.team, keyStore: certificate)
            try await signer.signApp(at: appURL, provisioningProfiles: profiles)
            let ipa = try FileManager.default.zipAppBundle(at: appURL, compressionLevel: .fastest)
            return SignedArtifact(ipa: ipa, workspace: workspace, expiresAt: expiry)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw Self.classify(error)
        }
    }

    private func appGroups(
        for targets: [IPASigningTarget], account: SavedAccount,
        settings: AppSettings
    ) async throws -> [String: AppGroup] {
        let identifiers = Set(targets.flatMap { $0.component.appGroups }).sorted()
        guard !identifiers.isEmpty else { return [:] }
        let session = try await session(account: account, settings: settings)
        let existing = try await portal.fetchAppGroups(for: account.team, session: session)
        var groups: [String: AppGroup] = [:]
        for identifier in identifiers {
            if let group = existing.first(where: { $0.identifier == identifier }) {
                groups[identifier] = group
                continue
            }
            // Preserve identifiers because apps may hard-code their shared container names.
            do {
                let session = try await self.session(account: account, settings: settings)
                let name = "ReSign " + String(AnisetteService.digest(Data(identifier.utf8)).prefix(16))
                let group = try await portal.addAppGroup(
                    name: name, groupIdentifier: identifier,
                    team: account.team, session: session)
                guard group.identifier == identifier, !group.groupID.isEmpty else {
                    throw ReSignError("Apple 返回的 App Group 与请求不匹配。")
                }
                groups[identifier] = group
            } catch {
                let classified = Self.classify(error)
                if classified is AuthenticationNeeded { throw classified }
                throw ReSignError("当前团队无法注册 App Group「\(identifier)」。需要可使用此组名的团队，或重新构建使用当前团队共享组的应用。\n\(classified.localizedDescription)")
            }
        }
        return groups
    }

    private func provisioningProfile(
        for target: IPASigningTarget, appID: AppID, app: ManagedApp,
        device: ConnectedDevice, certificate: KeyStore,
        account: SavedAccount, settings: AppSettings
    ) async throws -> ProvisioningProfile {
        guard appID.bundleIdentifier == target.bundleID else {
            throw ReSignError("App ID 与签名目标不匹配：\(target.component.bundleID)。")
        }
        var profile = try await downloadProfile(appID, account: account, settings: settings)
        func certificateMatches(_ profile: ProvisioningProfile) -> Bool {
            profile.certificates.contains {
                $0.serialNumber.caseInsensitiveCompare(certificate.serialNumber) == .orderedSame
            }
        }
        func groupsMatch(_ profile: ProvisioningProfile) -> Bool {
            let authorized = profile.entitlements["com.apple.security.application-groups"] as? [String] ?? []
            return Set(target.component.appGroups).isSubset(of: Set(authorized))
        }
        let needsNewProfile =
            profile.expirationDate <= Date().addingTimeInterval(48 * 3600)
            || (!app.pendingInstall && profile.expirationDate <= (app.expiresAt ?? .distantPast).addingTimeInterval(60))
            || !profile.deviceIDs.contains(device.udid) || !certificateMatches(profile) || !groupsMatch(profile)
        guard profile.teamIdentifier == app.teamID, profile.bundleIdentifier == target.bundleID else {
            throw ReSignError("Apple 返回的描述文件与签名目标不匹配：\(target.component.bundleID)。")
        }
        if needsNewProfile {
            var profileID = profile.identifier
            if profileID == nil {
                let session = try await session(account: account, settings: settings)
                let profiles = try await portal.listProvisioningProfiles(for: account.team, session: session)
                profileID =
                    profiles.first(where: {
                        $0.bundleIdentifier == target.bundleID && $0.uuid == profile.uuid
                    })?.identifier
            }
            guard let profileID else { throw ReSignError("无法定位需要更新的描述文件：\(target.component.bundleID)。") }
            let session = try await session(account: account, settings: settings)
            guard try await portal.deleteProvisioningProfile(profileID: profileID, team: account.team, session: session) else {
                throw ReSignError("无法移除旧描述文件：\(target.component.bundleID)。")
            }
            profile = try await downloadProfile(appID, account: account, settings: settings)
        }
        let expiry = min(profile.expirationDate, certificate.expiryDate)
        guard profile.bundleIdentifier == target.bundleID, profile.teamIdentifier == app.teamID,
            profile.deviceIDs.contains(device.udid), expiry > Date().addingTimeInterval(48 * 3600),
            (app.pendingInstall || expiry > (app.expiresAt ?? .distantPast).addingTimeInterval(60)),
            certificateMatches(profile)
        else {
            throw ReSignError("描述文件未延长有效期，或与设备／证书不匹配：\(target.component.bundleID)。")
        }
        guard groupsMatch(profile) else {
            throw ReSignError("描述文件未授权所需的 App Groups：\(target.component.bundleID)。")
        }
        return profile
    }

    private func session(account: SavedAccount, settings: AppSettings) async throws -> Session {
        guard account.authentication.session.isValid else { throw AuthenticationNeeded() }
        var session = account.authentication.session
        let freshData = try await anisette.fresh(settings: settings)
        session.anisetteData = try Self.refreshedAnisette(freshData, issued: session.anisetteData)
        return session
    }

    static func refreshedAnisette(_ fresh: AnisetteData, issued: AnisetteData) throws -> AnisetteData {
        guard fresh.deviceID == issued.deviceID, fresh.localUserID == issued.localUserID,
            fresh.machineID == issued.machineID, fresh.routingInfo == issued.routingInfo,
            fresh.clientInfo == issued.clientInfo, fresh.userAgent == issued.userAgent
        else {
            throw AuthenticationNeeded()
        }
        return fresh
    }

    private func downloadProfile(_ appID: AppID, account: SavedAccount, settings: AppSettings) async throws -> ProvisioningProfile {
        let session = try await session(account: account, settings: settings)
        return try await portal.downloadProvisioningProfile(
            for: appID, isTeamProfile: true,
            team: account.team, session: session)
    }

    private func signingCertificate(account: SavedAccount, settings: AppSettings) async throws -> KeyStore {
        let key = "certificate-" + account.team.identifier
        if let saved = try vault.read(SavedCertificate.self, key: key) {
            guard
                let certificate = X509Certificate(
                    data: saved.certificate,
                    metadata: saved.identifier.map { ["identifier": $0] } ?? [:])
            else {
                throw ReSignError("无法解析钥匙串中的签名证书。")
            }
            if certificate.expiryDate > Date().addingTimeInterval(8 * 24 * 3600) {
                let session = try await session(account: account, settings: settings)
                let active = try await portal.fetchCertificates(for: account.team, session: session)
                if active.contains(where: { $0.serialNumber.caseInsensitiveCompare(certificate.serialNumber) == .orderedSame }) {
                    return KeyStore(certificate: certificate, privateKey: saved.privateKey)
                }
            }
        }
        let session = try await session(account: account, settings: settings)
        let keyStore = try await portal.addCertificate(
            machineName: "ReSign " + (Host.current().localizedName ?? "Mac"),
            type: .development, to: account.team, session: session)
        guard let data = keyStore.certificate.data else { throw ReSignError("Apple 返回的证书缺少可保存的数据。") }
        try vault.write(
            SavedCertificate(
                certificate: data, privateKey: keyStore.privateKey,
                identifier: keyStore.identifier), key: key)
        return keyStore
    }

    static func bundleID(original: String, team: String) -> String {
        "io.resign." + team.lowercased() + ".a" + String(AnisetteService.digest(Data(original.utf8)).prefix(24))
    }

    private static func classify(_ error: Error) -> Error {
        if let error = error as? DeveloperPortalError {
            switch error {
            case .incorrectCredentials, .requiresTwoFactorAuthentication:
                return AuthenticationNeeded()
            default: break
            }
        }
        if let error = error as? ServerError, case .underlyingError(let code, _) = error,
            [1100, 1101, -20101, -22406].contains(code)
        {
            return AuthenticationNeeded()
        }
        return error
    }
}
