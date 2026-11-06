import Foundation

struct ReSignError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ConnectedDevice: Decodable, Sendable, Identifiable {
    enum ConnectionType: String, Decodable, Sendable {
        case usb, network

        var title: String { self == .usb ? "USB 已连接" : "局域网已连接" }
    }

    let udid: String
    var name: String?
    let productType: String?
    let osVersion: String?
    let trusted: Bool
    let connectionType: ConnectionType
    let connectionError: String?
    var id: String { udid }
    var displayName: String { name ?? productType ?? "iOS 设备" }
    var connectionStatus: String {
        if trusted { return connectionType.title }
        return connectionType == .usb ? "USB 连接不可用" : "局域网连接不可用"
    }
}

struct RememberedDevice: Codable, Identifiable {
    var id: String
    var name: String
    var lastSeen: Date
}

struct ManagedApp: Codable, Identifiable {
    var id = UUID()
    var deviceID: String
    var teamID: String
    var name: String
    var version: String
    var buildVersion: String
    var originalBundleID: String
    var bundleID: String
    var ipaFilename: String
    var autoRefresh = true
    var pendingInstall = true
    var expiresAt: Date?
    var lastInstalledAt: Date?
    var lastError: String?
    var failedAttempts = 0
    var nextAttemptAt: Date?

    func isDue(at date: Date, leadHours: Int) -> Bool {
        guard autoRefresh, failedAttempts < 5 else { return false }
        if let nextAttemptAt, nextAttemptAt > date { return false }
        if pendingInstall { return true }
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(date) <= Double(leadHours) * 3600
    }
}

enum AnisetteSource: String, Codable, CaseIterable, Sendable, Hashable {
    case local, remoteV3
    var title: String { self == .local ? "本机认证" : "Anisette v3 服务" }
}

struct AppSettings: Codable, Equatable, Sendable {
    var anisetteSource: AnisetteSource = .local
    var anisetteServer = ""
    var refreshLeadHours = 48
    var xcodeVersion = "26.0"
}

struct Library: Codable {
    var schemaVersion = 1
    var devices: [RememberedDevice] = []
    var apps: [ManagedApp] = []
    var settings = AppSettings()
}

enum JobStage: String {
    case waiting = "等待设备"
    case authentication = "准备账号与证书"
    case provisioning = "更新描述文件"
    case signing = "正在签名"
    case installing = "传输并安装"
    case complete = "续签完成"
    case failed = "续签失败"
}

struct Activity: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}
