import Foundation
import SideSign

struct RemoteAnisetteClient {
    let server: URL
    let identifier: UUID
    let clientInfo: String
    let userAgent: String
    private let session: URLSession

    init(server: URL, identifier: UUID, clientInfo: String, userAgent: String) {
        self.server = server
        self.identifier = identifier
        self.clientInfo = clientInfo
        self.userAgent = userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    private var identifierData: Data {
        var uuid = identifier.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    func provision() async throws -> (blob: Data, routing: String) {
        let lookup = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
        let bag = try await appleRequest(url: lookup)
        guard let urls = bag.values["urls"] as? [String: String] else {
            throw ReSignError("Apple 未返回认证注册地址。")
        }
        let startURL = try Self.appleURL(urls["midStartProvisioning"])
        let finishURL = try Self.appleURL(urls["midFinishProvisioning"])
        let start = try await appleRequest(url: startURL, body: [:])
        let spim = try Self.base64Field("spim", in: start.values)

        var components = URLComponents(url: server.appendingPathComponent("v3/provisioning_session"), resolvingAgainstBaseURL: false)!
        components.scheme = server.scheme == "https" ? "wss" : "ws"
        guard let socketURL = components.url else { throw ReSignError("Anisette 注册地址无效。") }
        let socket = session.webSocketTask(with: socketURL)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        var routing: String?
        for _ in 0..<5 {
            let reply = try await receive(socket)
            switch reply["result"] as? String {
            case "GiveIdentifier":
                try await send(["identifier": identifierData.base64EncodedString()], to: socket)
            case "GiveStartProvisioningData":
                try await send(["spim": spim], to: socket)
            case "GiveEndProvisioningData":
                let cpim = try Self.base64Field("cpim", in: reply)
                let finish = try await appleRequest(url: finishURL, body: ["cpim": cpim], routing: start.routing)
                guard let appleRouting = finish.routing else {
                    throw ReSignError("Apple 未返回注册路由。")
                }
                routing = appleRouting
                // ADI provisioning requires Apple's routing value; ptm/tk alone is insufficient.
                try await send(["ptm": try Self.base64Field("ptm", in: finish.values),
                                "tk": try Self.base64Field("tk", in: finish.values),
                                "X-Apple-I-MD-RINFO": appleRouting], to: socket)
            case "ProvisioningSuccess":
                guard let routing else { throw ReSignError("认证服务跳过了 Apple 注册步骤。") }
                let encoded = try Self.base64Field("adi_pb", in: reply)
                return (Data(base64Encoded: encoded)!, routing)
            default:
                throw ReSignError("Anisette 注册失败：\(reply["result"] as? String ?? "未知步骤")。")
            }
        }
        throw ReSignError("Anisette 注册流程未在预期步骤内完成。")
    }

    func headers(blob: Data, routing: String) async throws -> AnisetteData {
        var request = URLRequest(url: server.appendingPathComponent("v3/get_headers"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifierData.base64EncodedString(), "adi_pb": blob.base64EncodedString()
        ])
        let data = try await requestData(request)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String],
              values["result"] == "Headers" || values["result"] == nil else {
            throw ReSignError("Anisette 未生成认证数据。")
        }
        let otp = try Self.base64Field("X-Apple-I-MD", in: values)
        let mid = try Self.base64Field("X-Apple-I-MD-M", in: values)
        let actualRouting = try Self.validRouting(values["X-Apple-I-MD-RINFO"] ?? routing)
        guard actualRouting == routing else { throw ReSignError("认证服务的路由与 Apple 注册记录不一致。") }
        return AnisetteData(machineID: mid, oneTimePassword: otp,
                            localUserID: AnisetteService.digest(identifierData), routingInfo: actualRouting,
                            deviceID: identifier.uuidString.uppercased(), serialNumber: "0",
                            clientInfo: clientInfo, userAgent: userAgent,
                            clientTime: ISO8601DateFormatter().string(from: Date()),
                            locale: Locale.current.identifier, timeZone: TimeZone.current.identifier)
    }

    private func appleRequest(url: URL, body: [String: String]? = nil,
                              routing: String? = nil) async throws -> (values: [String: Any], routing: String?) {
        var request = URLRequest(url: url)
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(identifier.uuidString.uppercased(), forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(AnisetteService.digest(identifierData), forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue("0", forHTTPHeaderField: "X-Apple-I-SRL-NO")
        if let routing { request.setValue(routing, forHTTPHeaderField: "X-Apple-I-MD-RINFO") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: ["Header": [:], "Request": body], format: .xml, options: 0)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReSignError("Apple 认证注册请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）。")
        }
        let values = plist["Response"] as? [String: Any] ?? plist
        let rawRouting = http.value(forHTTPHeaderField: "X-Apple-I-MD-RINFO")
            ?? (values["X-Apple-I-MD-RINFO"] as? CustomStringConvertible)?.description
            ?? (values["routing-info"] as? CustomStringConvertible)?.description
        return (values, try rawRouting.map(Self.validRouting))
    }

    private func requestData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 4_200_000 else {
            throw ReSignError("Anisette 请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）。")
        }
        return data
    }

    private func send(_ value: [String: String], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let data: Data
        switch try await socket.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw ReSignError("认证服务返回了未知消息。")
        }
        guard data.count <= 4_200_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReSignError("认证服务返回了无效消息。")
        }
        return value
    }

    private static func appleURL(_ string: String?) throws -> URL {
        guard let string, let url = URL(string: string), url.scheme == "https",
              ["gsa.apple.com", "gsd.apple.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.hasPrefix("/grandslam/") else {
            throw ReSignError("Apple 返回了无效的认证注册地址。")
        }
        return url
    }

    private static func validRouting(_ string: String) throws -> String {
        guard !string.isEmpty, string.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(string), value > 0 else { throw ReSignError("Apple 认证路由无效。") }
        return String(value)
    }

    private static func base64Field(_ name: String, in values: [String: Any]) throws -> String {
        guard let value = values[name] as? String, let data = Data(base64Encoded: value), !data.isEmpty else {
            throw ReSignError("认证响应缺少有效的 \(name) 字段。")
        }
        return value
    }
}
