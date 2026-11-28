import CryptoKit
import Foundation

struct IPAUpdateDiscovery: Sendable {
    var source: AppUpdateSource?
    var candidates: [AppUpdateSource]
}

struct IPARelease: Sendable {
    var identifier: String
    var downloadURL: URL
    var version: String?
    var build: String?
    var sha256: String?
    var size: Int64?
    var minimumOS: String?
    var maximumOS: String?
}

enum IPAUpdateService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: UpdateSessionDelegate(), delegateQueue: nil)
    }()

    static func source(from input: String, assetPattern: String = "") throws -> AppUpdateSource {
        let url = try secureURL(input.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = url.pathComponents.filter { $0 != "/" }
        let host = url.host?.lowercased()
        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 2 else { throw ReSignError("请填写完整的 GitHub 仓库地址。") }
            let repository = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            return AppUpdateSource(kind: .github, url: "https://github.com/\(parts[0])/\(repository)",
                                   assetPattern: assetPattern.isEmpty ? nil : assetPattern)
        }
        if host == "api.github.com" {
            guard parts.count >= 3, parts[0] == "repos" else {
                throw ReSignError("请填写 GitHub 仓库或 Releases API 地址。")
            }
            return AppUpdateSource(kind: .github, url: "https://github.com/\(parts[1])/\(parts[2])",
                                   assetPattern: assetPattern.isEmpty ? nil : assetPattern)
        }
        return AppUpdateSource(kind: .altStore, url: url.absoluteString)
    }

    // A release API or an explicit source configuration carries more intent than a project link.
    static func discover(in app: URL) throws -> IPAUpdateDiscovery {
        var candidates = Set<AppUpdateSource>()
        var explicit = Set<AppUpdateSource>()
        let keys: Set<String> = ["sourceurl", "altsource", "altsourceurl", "altstoreurl", "altstoresource", "altstoresourceurl", "updateurl", "updatefeedurl"]
        func configuration(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, value) in dictionary {
                    if keys.contains(key.lowercased()), let text = value as? String,
                       let candidate = try? source(from: text) {
                        candidates.insert(candidate)
                        if key.lowercased() != "sourceurl" || candidate.kind == .altStore {
                            explicit.insert(candidate)
                        }
                    }
                    configuration(value)
                }
            } else if let array = value as? [Any] {
                for value in array { configuration(value) }
            }
        }
        guard let files = FileManager.default.enumerator(at: app,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            throw ReSignError("无法扫描 IPA 中的更新来源。")
        }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 512 * 1024 * 1024 else { continue }
            let ext = file.pathExtension.lowercased()
            let isConfiguration = ["plist", "json"].contains(ext) && size <= 1024 * 1024
            let isExecutable = ext.isEmpty || ext == "dylib"
            guard isConfiguration || isExecutable else { continue }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            if isConfiguration {
                if ext == "plist" {
                    configuration(try PropertyListSerialization.propertyList(from: data, format: nil))
                } else if let json = try? JSONSerialization.jsonObject(with: data) {
                    configuration(json)
                }
            }
            var cursor = data.startIndex
            let prefix = Data("https://".utf8)
            while cursor < data.endIndex, let match = data.range(of: prefix, in: cursor..<data.endIndex) {
                var end = match.upperBound
                while end < data.endIndex, end - match.lowerBound < 2048 {
                    let byte = data[end]
                    guard byte > 32, byte < 127, ![UInt8(34), 39, 60, 62, 92].contains(byte) else { break }
                    end += 1
                }
                let text = String(decoding: data[match.lowerBound..<end], as: UTF8.self)
                if let url = URL(string: text), let host = url.host?.lowercased(),
                   ["github.com", "www.github.com", "api.github.com"].contains(host),
                   let candidate = try? source(from: text) {
                    let parts = url.pathComponents
                    if host != "api.github.com" || parts.contains("releases") {
                        candidates.insert(candidate)
                        if parts.contains("releases") { explicit.insert(candidate) }
                    }
                }
                cursor = end
            }
        }
        let sorted = candidates.sorted { $0.url < $1.url }
        return IPAUpdateDiscovery(source: explicit.count == 1 ? explicit.first : nil, candidates: sorted)
    }

    static func release(for source: AppUpdateSource, bundleID: String, osVersion: String?,
                        githubToken: String? = nil, session: URLSession? = nil) async throws -> IPARelease {
        if source.kind == .github {
            let repo = try secureURL(source.url).path
            let data = try await json(at: secureURL("https://api.github.com/repos\(repo)/releases/latest"),
                                      githubToken: githubToken, session: session)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let assets = release.assets.filter {
                $0.name.lowercased().hasSuffix(".ipa") && matches($0.name, pattern: source.assetPattern)
            }
            guard assets.count == 1, let asset = assets.first else {
                throw ReSignError(assets.isEmpty ? "最新正式发布没有匹配的 IPA 附件，请检查附件规则。" : "发布中有多个 IPA，请在更新来源中填写附件匹配规则。")
            }
            return IPARelease(identifier: "github:\(asset.id):\(asset.updatedAt):\(asset.digest ?? "")",
                              downloadURL: try secureURL(asset.browserDownloadURL),
                              sha256: asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil },
                              size: asset.size)
        }
        let data = try await json(at: secureURL(source.url), session: session)
        let feed = try JSONDecoder().decode(AltStoreFeed.self, from: data)
        let apps = feed.apps.filter { $0.bundleIdentifier == bundleID }
        guard apps.count == 1, let app = apps.first else {
            throw ReSignError("软件源中没有唯一匹配原始 Bundle ID 的应用：\(bundleID)。")
        }
        let versions = app.versions ?? app.legacyVersion.map { [$0] } ?? []
        // AltStore sources order versions from newest to oldest; retain this ordering.
        guard let version = versions.first(where: { compatible(minimum: $0.minOSVersion, maximum: $0.maxOSVersion, os: osVersion) }) else {
            throw ReSignError("软件源没有适用于当前设备系统的版本。")
        }
        return IPARelease(identifier: "altstore:\(version.version):\(version.buildVersion ?? ""):\(version.downloadURL)",
                          downloadURL: try secureURL(version.downloadURL), version: version.version,
                          build: version.buildVersion, sha256: version.sha256, size: version.size,
                          minimumOS: version.minOSVersion, maximumOS: version.maxOSVersion)
    }

    static func download(_ release: IPARelease, to destination: URL) async throws {
        let (temporary, response) = try await session.download(for: request(release.downloadURL))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response)
        try validateFile(temporary, release: release)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func validateFile(_ url: URL, release: IPARelease) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size > 0, size <= 2 * 1024 * 1024 * 1024 else { throw ReSignError("下载的 IPA 为空或超过 2 GB。") }
        if let expected = release.size, expected != Int64(size) { throw ReSignError("下载文件大小与软件源声明不一致。") }
        if let expected = release.sha256 {
            guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { throw ReSignError("软件源的 SHA-256 摘要无效。") }
            try file.seek(toOffset: 0)
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw ReSignError("新版 IPA 的 SHA-256 校验失败。") }
        }
    }

    static func inspectUpdate(_ ipa: URL, into workspace: URL, release: IPARelease,
                              app: ManagedApp, osVersion: String?) throws -> IPAInfo {
        let extracted = try IPAService.extract(ipa, into: workspace)
        let info = try IPAService.inspect(extracted)
        guard info.bundleID == app.originalBundleID else { throw ReSignError("新版 IPA 的原始 Bundle ID 不匹配，请重新选择更新来源。") }
        if let version = release.version, version != info.version { throw ReSignError("下载 IPA 的版本与软件源声明不一致。") }
        if let build = release.build, build != info.buildVersion { throw ReSignError("下载 IPA 的构建号与软件源声明不一致。") }
        let plist = try IPAService.readPlist(extracted)
        guard compatible(minimum: plist["MinimumOSVersion"] as? String, maximum: nil, os: osVersion),
              compatible(minimum: release.minimumOS, maximum: release.maximumOS, os: osVersion) else {
            throw ReSignError("新版 IPA 不支持当前设备的系统版本。")
        }
        return info
    }

    static func compatible(minimum: String?, maximum: String?, os: String?) -> Bool {
        guard let os else { return true }
        if let minimum, compareVersions(os, minimum) == .orderedAscending { return false }
        if let maximum, compareVersions(os, maximum) == .orderedDescending { return false }
        return true
    }

    static func isNewer(version: String, build: String, than app: ManagedApp) -> Bool {
        let comparison = compareVersions(version, app.version)
        return comparison == .orderedDescending || (comparison == .orderedSame && compareVersions(build, app.buildVersion) == .orderedDescending)
    }

    private static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        func parts(_ text: String) -> (String, String?) {
            let value = text.split(separator: "+", maxSplits: 1).first.map(String.init) ?? text
            let pieces = value.split(separator: "-", maxSplits: 1).map(String.init)
            return (pieces.first ?? value, pieces.count == 2 ? pieces[1] : nil)
        }
        let (leftBase, leftPre) = parts(left)
        let (rightBase, rightPre) = parts(right)
        let lhs = leftBase.split(separator: ".").map(String.init)
        let rhs = rightBase.split(separator: ".").map(String.init)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : "0"
            let b = index < rhs.count ? rhs[index] : "0"
            let comparison = a.compare(b, options: .numeric)
            if comparison != .orderedSame { return comparison }
        }
        switch (leftPre, rightPre) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return a.compare(b, options: .numeric)
        }
    }

    private static func matches(_ name: String, pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return name.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func secureURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw ReSignError("更新来源及下载地址必须为不含账号密码的完整 HTTPS 地址。") }
        return url
    }

    private static func request(_ url: URL, githubToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("ReSign", forHTTPHeaderField: "User-Agent")
        if url.scheme == "https", url.host == "api.github.com", url.port == nil || url.port == 443 {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let githubToken, !githubToken.isEmpty {
                request.setValue("Bearer " + githubToken, forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private static func validate(_ response: URLResponse, body: Data? = nil) throws {
        if let http = response as? HTTPURLResponse, http.url?.host == "api.github.com",
           [403, 429].contains(http.statusCode) {
            let message = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["message"] as? String ?? ""
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || message.lowercased().contains("rate limit") {
                throw ReSignError("GitHub API 请求配额已耗尽，请在设置中配置 GitHub Token，或等待配额恢复后重试。")
            }
        }
        if let http = response as? HTTPURLResponse, http.url?.host == "api.github.com", http.statusCode == 401 {
            throw ReSignError("GitHub Token 无效或已过期，请在设置中替换或清除 Token。")
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else {
            let status = (response as? HTTPURLResponse)?.statusCode
            let host = response.url?.host ?? "未知服务器"
            throw ReSignError("\(host) 更新请求失败\(status.map { "（HTTP \($0)）" } ?? "")。请检查来源地址及服务器访问权限。")
        }
    }

    private static func json(at url: URL, githubToken: String? = nil, session: URLSession?) async throws -> Data {
        let (data, response) = try await (session ?? Self.session).data(for: request(url, githubToken: githubToken))
        try validate(response, body: data)
        guard data.count <= 5 * 1024 * 1024 else { throw ReSignError("更新源响应超过 5 MB。") }
        return data
    }
}

private final class UpdateSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.scheme != "https" || request.url?.host != "api.github.com"
            || (request.url?.port != nil && request.url?.port != 443) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}

private struct GitHubRelease: Decodable {
    var assets: [Asset]
    struct Asset: Decodable {
        var id: Int64
        var name: String
        var size: Int64
        var browserDownloadURL: String
        var updatedAt: String
        var digest: String?
        enum CodingKeys: String, CodingKey {
            case id, name, size, digest
            case browserDownloadURL = "browser_download_url", updatedAt = "updated_at"
        }
    }
}

private struct AltStoreFeed: Decodable {
    var apps: [App]
    struct App: Decodable {
        var bundleIdentifier: String
        var versions: [Version]?
        var version: String?
        var downloadURL: String?
        var size: Int64?
        var minOSVersion: String?
        var maxOSVersion: String?
        var legacyVersion: Version? {
            guard let version, let downloadURL else { return nil }
            return Version(version: version, downloadURL: downloadURL, size: size,
                           minOSVersion: minOSVersion, maxOSVersion: maxOSVersion)
        }
    }
    struct Version: Decodable {
        var version: String
        var buildVersion: String?
        var downloadURL: String
        var size: Int64?
        var sha256: String?
        var minOSVersion: String?
        var maxOSVersion: String?
    }
}
