import Foundation
import CryptoKit
import NativeBridge
import SideSign

actor AnisetteService {
    private struct RemoteIdentity: Codable {
        var identifier: UUID
        var adiBlob: Data?
        var routingInfo: String?
    }
    private struct ClientInfo: Decodable {
        let client_info: String
        let user_agent: String
    }
    private let vault: KeychainVault

    init(vault: KeychainVault = KeychainVault()) {
        self.vault = vault
    }

    func fresh(settings: AppSettings) async throws -> AnisetteData {
        if settings.anisetteSource == .local {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 else {
                throw ReSignError("当前系统不支持旧式本机认证，请配置 Anisette v3 服务。")
            }
            var error: UnsafeMutablePointer<CChar>?
            let json = rs_local_anisette_json(&error)
            defer { rs_free(error); rs_free(json) }
            guard let json else {
                throw ReSignError(error.map { String(cString: $0) } ?? "无法读取本机认证数据。")
            }
            return try JSONDecoder().decode(AnisetteData.self, from: Data(String(cString: json).utf8))
        }

        let server = try settings.validatedServerURL()
        // Keep the provider identity stable for provisioning and subsequent Apple requests.
        var request = URLRequest(url: server.appendingPathComponent("v3/client_info"))
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ReSignError("Anisette v3 服务未返回客户端信息。")
        }
        let info = try JSONDecoder().decode(ClientInfo.self, from: data)
        guard !info.client_info.isEmpty, !info.user_agent.isEmpty,
              !info.client_info.contains(where: { $0.isNewline }),
              !info.user_agent.contains(where: { $0.isNewline }) else {
            throw ReSignError("Anisette v3 服务的客户端身份无效。")
        }
        let key = Self.identityKey(server: server, clientInfo: info.client_info, userAgent: info.user_agent)
        var identity: RemoteIdentity
        if let saved = try vault.read(RemoteIdentity.self, key: key) {
            identity = saved
        } else {
            identity = RemoteIdentity(identifier: UUID(), adiBlob: nil, routingInfo: nil)
            try vault.write(identity, key: key)
        }
        let client = RemoteAnisetteClient(server: server, identifier: identity.identifier,
                                          clientInfo: info.client_info, userAgent: info.user_agent)
        if identity.adiBlob == nil {
            let provisioned = try await client.provision()
            identity.adiBlob = provisioned.blob
            identity.routingInfo = provisioned.routing
            try vault.write(identity, key: key)
        }
        guard let blob = identity.adiBlob, let routing = identity.routingInfo else {
            throw ReSignError("Anisette 注册信息不完整，请重新登录。")
        }
        return try await client.headers(blob: blob, routing: routing)
    }

    static func identityKey(server: URL, clientInfo: String, userAgent: String) -> String {
        "anisette-v3-routing-" + digest(Data("\(server.absoluteString)\n\(clientInfo)\n\(userAgent)".utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppSettings {
    var authenticationContext: String {
        "gsa-client-v5:\(anisetteSource.rawValue):\(anisetteServer.trimmingCharacters(in: .whitespacesAndNewlines)):\(xcodeVersion)"
    }

    func validatedServerURL() throws -> URL {
        guard let url = URL(string: anisetteServer.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw ReSignError("请输入 Anisette v3 服务根地址；HTTP 仅支持 localhost。")
        }
        return url
    }
}
