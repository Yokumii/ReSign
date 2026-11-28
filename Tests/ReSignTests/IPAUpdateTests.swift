import CryptoKit
import Foundation
import SideSign
import XCTest
@testable import ReSign

final class IPAUpdateTests: XCTestCase {
    private var root: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReSignUpdates-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        session = URLSession(configuration: configuration)
        UpdateResponseProtocol.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: root)
    }

    func testSourceNormalizationAndHTTPSPolicy() throws {
        for url in ["https://github.com/example/app", "https://github.com/example/app.git",
                    "https://github.com/example/app/releases/latest", "https://api.github.com/repos/example/app/releases/latest"] {
            let source = try IPAUpdateService.source(from: url, assetPattern: "*_ios_*.ipa")
            XCTAssertEqual(source.url, "https://github.com/example/app")
            XCTAssertEqual(source.kind, .github)
            XCTAssertEqual(source.assetPattern, "*_ios_*.ipa")
        }
        XCTAssertEqual(try IPAUpdateService.source(from: "https://example.com/source.json").kind, .altStore)
        for value in ["", "http://example.com/source.json", "https://user:password@example.com/feed", "https://github.com/owner"] {
            XCTAssertThrowsError(try IPAUpdateService.source(from: value))
        }
    }

    func testFrameworkReleaseAPIIsDiscoveredWithoutBindingDependencyHomepages() throws {
        try write(Data("https://github.com/dependency/player\0".utf8), to: "Runner")
        try write(Data("https://api.github.com/repos/example/app/releases/latest\0https://github.com/example/app\0".utf8),
                  to: "Frameworks/App.framework/App")
        let discovery = try IPAUpdateService.discover(in: root)
        XCTAssertEqual(discovery.source?.url, "https://github.com/example/app")
        XCTAssertEqual(discovery.candidates.count, 2)
    }

    func testHomepagesAndAmbiguousReleaseAPIsRequireManualChoice() throws {
        try write(try PropertyListSerialization.data(fromPropertyList: ["sourceURL": "https://github.com/example/project"],
                                                     format: .binary, options: 0), to: "Info.plist")
        XCTAssertNil(try IPAUpdateService.discover(in: root).source)
        try write(Data("https://api.github.com/repos/one/app/releases/latest\0https://api.github.com/repos/two/app/releases/latest\0".utf8), to: "Runner")
        XCTAssertNil(try IPAUpdateService.discover(in: root).source)
    }

    func testDeclaredJSONSourceAndMissingSources() throws {
        XCTAssertTrue(try IPAUpdateService.discover(in: root).candidates.isEmpty)
        try write(Data(#"{"settings":{"altStoreSourceURL":"https://example.com/source.json"}}"#.utf8), to: "settings.json")
        XCTAssertEqual(try IPAUpdateService.discover(in: root).source?.url, "https://example.com/source.json")
    }

    func testGitHubRejectsAmbiguousAssetsAndHonorsLiteralWildcardPattern() async throws {
        UpdateResponseProtocol.respond(json: ["assets": [asset(id: 1, name: "App_ios_2.ipa"), asset(id: 2, name: "App_tv_2.ipa")]])
        var source = try IPAUpdateService.source(from: "https://github.com/example/app")
        do {
            _ = try await release(source)
            XCTFail("Multiple IPA assets must require a choice")
        } catch { XCTAssertTrue(error.localizedDescription.contains("多个 IPA")) }
        source.assetPattern = "App_ios_*.ipa"
        let selected = try await release(source)
        XCTAssertEqual(selected.downloadURL.lastPathComponent, "App_ios_2.ipa")
        XCTAssertEqual(selected.size, 3)
        XCTAssertEqual(selected.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(UpdateResponseProtocol.lastURL?.absoluteString, "https://api.github.com/repos/example/app/releases/latest")
        source.assetPattern = "App.[ios]*.ipa"
        do { _ = try await release(source); XCTFail("Regex punctuation must remain literal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有匹配")) }
    }

    func testReleaseRejectsHTTPFailuresMalformedResponsesAndInsecureDownloads() async throws {
        let source = try IPAUpdateService.source(from: "https://github.com/example/app")
        for status in [403, 404, 429, 503] {
            UpdateResponseProtocol.respond(json: ["assets": []], status: status)
            do { _ = try await release(source); XCTFail("HTTP failures must not succeed") }
            catch { XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)")) }
        }
        UpdateResponseProtocol.respond(json: ["unexpected": true])
        do { _ = try await release(source); XCTFail("Malformed metadata must fail") } catch { }
        var insecure = asset(id: 1, name: "App.ipa")
        insecure["browser_download_url"] = "http://example.com/App.ipa"
        UpdateResponseProtocol.respond(json: ["assets": [insecure]])
        do { _ = try await release(source); XCTFail("Insecure downloads must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
    }

    func testGitHubTokenIsUsedForAPIAndNotSentToAltStoreSource() async throws {
        UpdateResponseProtocol.respond(json: ["assets": [asset(id: 1, name: "App.ipa")]])
        let source = try IPAUpdateService.source(from: "https://github.com/example/app")
        _ = try await IPAUpdateService.release(for: source, bundleID: "com.example.test", osVersion: nil,
                                                githubToken: "test-token", session: session)
        XCTAssertEqual(UpdateResponseProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(UpdateResponseProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")

        let feed = try IPAUpdateService.source(from: "https://example.com/feed.json")
        UpdateResponseProtocol.respond(json: ["apps": [["bundleIdentifier": "com.example.test", "version": "2.0",
                                                        "downloadURL": "https://example.com/app.ipa"]]])
        _ = try await IPAUpdateService.release(for: feed, bundleID: "com.example.test", osVersion: nil,
                                                githubToken: "test-token", session: session)
        XCTAssertNil(UpdateResponseProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testGitHubAuthAndRateLimitErrors() async throws {
        let source = try IPAUpdateService.source(from: "https://github.com/example/app")
        UpdateResponseProtocol.respond(json: ["message": "Bad credentials"], status: 401)
        do {
            _ = try await IPAUpdateService.release(for: source, bundleID: "com.example.test", osVersion: nil,
                                                    githubToken: "test-token", session: session)
            XCTFail("An invalid token must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Token 无效"))
            XCTAssertFalse(error.localizedDescription.contains("test-token"))
        }
        XCTAssertEqual(UpdateResponseProtocol.urls.count, 1)

        UpdateResponseProtocol.reset()
        UpdateResponseProtocol.respond(json: ["message": "API rate limit exceeded"], status: 403,
                                       headers: ["X-RateLimit-Remaining": "0"])
        do { _ = try await release(source); XCTFail("Rate limiting must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("配置 GitHub Token")) }
        XCTAssertEqual(UpdateResponseProtocol.urls.count, 1)

        UpdateResponseProtocol.reset()
        UpdateResponseProtocol.respond(json: ["message": "Forbidden"], status: 403)
        do { _ = try await release(source); XCTFail("Forbidden must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 403")) }
        XCTAssertEqual(UpdateResponseProtocol.urls.count, 1)
    }

    func testAltStoreSelectsCompatibleVersionAndRejectsUnrelatedApps() async throws {
        let source = try IPAUpdateService.source(from: "https://example.com/feed.json")
        let versions: [[String: Any]] = [
            ["version": "3.0", "downloadURL": "https://example.com/3.ipa", "minOSVersion": "19.0"],
            ["version": "2.0", "buildVersion": "20", "downloadURL": "https://example.com/2.ipa", "minOSVersion": "17.0.0", "maxOSVersion": "18.0"],
        ]
        UpdateResponseProtocol.respond(json: ["apps": [["bundleIdentifier": "com.example.test", "versions": versions]]])
        let result = try await IPAUpdateService.release(for: source, bundleID: "com.example.test", osVersion: "17.0", session: session)
        XCTAssertEqual(result.version, "2.0")
        XCTAssertEqual(result.build, "20")
        do {
            _ = try await IPAUpdateService.release(for: source, bundleID: "other.app", osVersion: "17.0", session: session)
            XCTFail("Unrelated apps must not be selected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Bundle ID")) }
        do {
            _ = try await IPAUpdateService.release(for: source, bundleID: "com.example.test", osVersion: "16.0", session: session)
            XCTFail("Unsupported systems must not receive a release")
        } catch { XCTAssertTrue(error.localizedDescription.contains("系统")) }
    }

    func testLegacyAltStoreSourceAndDuplicateIdentity() async throws {
        let source = try IPAUpdateService.source(from: "https://example.com/feed.json")
        let entry: [String: Any] = ["bundleIdentifier": "com.example.test", "version": "2.0", "downloadURL": "https://example.com/app.ipa"]
        UpdateResponseProtocol.respond(json: ["apps": [entry]])
        let legacy = try await release(source)
        XCTAssertEqual(legacy.version, "2.0")
        UpdateResponseProtocol.respond(json: ["apps": [entry, entry]])
        do { _ = try await release(source); XCTFail("Duplicate identities must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("唯一匹配")) }
    }

    func testFileIntegrityRejectsCorruptionEmptyFilesAndWrongSize() throws {
        let file = root.appendingPathComponent("download.ipa")
        let bytes = Data("abc".utf8)
        try bytes.write(to: file)
        var release = descriptor()
        release.size = 3
        release.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try IPAUpdateService.validateFile(file, release: release))
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try IPAUpdateService.validateFile(file, release: release))
        release.sha256 = nil
        release.size = 4
        XCTAssertThrowsError(try IPAUpdateService.validateFile(file, release: release))
        release.size = nil
        try Data().write(to: file)
        XCTAssertThrowsError(try IPAUpdateService.validateFile(file, release: release))
    }

    func testIPAIdentityVersionBuildAndSystemAreCheckedBeforeReplacement() throws {
        let ipa = try makeIPA()
        let original = try Data(contentsOf: ipa)
        var release = descriptor()
        release.version = "2.0"
        release.build = "20"
        func inspect(_ release: IPARelease, app: ManagedApp = IPAUpdateTests.sampleApp(), os: String = "17.0") throws -> IPAInfo {
            try IPAUpdateService.inspectUpdate(ipa, into: root.appendingPathComponent(UUID().uuidString), release: release, app: app, osVersion: os)
        }
        XCTAssertEqual(try inspect(release).version, "2.0")
        var other = Self.sampleApp()
        other.originalBundleID = "com.unrelated.app"
        XCTAssertThrowsError(try inspect(release, app: other))
        XCTAssertThrowsError(try inspect(release, os: "16.0"))
        release.version = "3.0"
        XCTAssertThrowsError(try inspect(release))
        release.version = "2.0"
        release.build = "99"
        XCTAssertThrowsError(try inspect(release))
        XCTAssertEqual(try Data(contentsOf: ipa), original)
    }

    func testVersionOrderingPreventsDowngradesAndSupportsBuildOnlyUpdates() {
        var app = Self.sampleApp()
        app.version = "1.9"
        app.buildVersion = "9"
        XCTAssertTrue(IPAUpdateService.isNewer(version: "1.10", build: "1", than: app))
        XCTAssertFalse(IPAUpdateService.isNewer(version: "1.8", build: "99", than: app))
        XCTAssertFalse(IPAUpdateService.isNewer(version: "1.9.0", build: "9", than: app))
        XCTAssertTrue(IPAUpdateService.isNewer(version: "1.9", build: "10", than: app))
        XCTAssertFalse(IPAUpdateService.isNewer(version: "1.9-beta.1", build: "100", than: app))
        XCTAssertFalse(IPAUpdateService.isNewer(version: "1.9+metadata", build: "9", than: app))
    }

    func testLegacyLibraryAndUpdateRollbackStateRoundTrip() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.sampleApp())) as? [String: Any])
        for key in ["updateSource", "updateCandidates", "automaticUpdates", "lastUpdateCheck", "lastUpdateError", "lastResolvedRelease", "previousIPAFilename"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(ManagedApp.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.updateSource)
        var app = legacy
        app.updateSource = try IPAUpdateService.source(from: "https://github.com/example/app")
        app.previousIPAFilename = "previous.ipa"
        app.lastResolvedRelease = "release-2"
        app.lastUpdateCheck = Date(timeIntervalSince1970: 12345)
        app.automaticUpdates = false
        let store = try LibraryStore(root: root)
        var library = Library()
        library.apps = [app]
        try store.save(library)
        let restored = try store.load().apps[0]
        XCTAssertEqual(restored.updateSource, app.updateSource)
        XCTAssertEqual(restored.previousIPAFilename, "previous.ipa")
        XCTAssertEqual(restored.lastResolvedRelease, "release-2")
        XCTAssertEqual(restored.lastUpdateCheck, app.lastUpdateCheck)
        XCTAssertEqual(restored.automaticUpdates, false)
    }

    func testPendingSoftwareUpdateInstallsIndependentlyOfRenewalAndHonorsBackoff() {
        var app = Self.sampleApp()
        app.autoRefresh = false
        XCTAssertFalse(app.isDue(at: Date(), leadHours: 48))
        app.previousIPAFilename = "previous.ipa"
        XCTAssertTrue(app.isDue(at: Date(), leadHours: 48))
        app.nextAttemptAt = Date().addingTimeInterval(3600)
        XCTAssertFalse(app.isDue(at: Date(), leadHours: 48))
        app.nextAttemptAt = nil
        app.failedAttempts = 5
        XCTAssertFalse(app.isDue(at: Date(), leadHours: 48))
    }

    private func release(_ source: AppUpdateSource) async throws -> IPARelease {
        try await IPAUpdateService.release(for: source, bundleID: "com.example.test", osVersion: "17.0", session: session)
    }

    private func asset(id: Int, name: String) -> [String: Any] {
        ["id": id, "name": name, "size": 3, "updated_at": "2026-11-28T00:00:00Z",
         "browser_download_url": "https://example.com/\(name)", "digest": "sha256:" + String(repeating: "a", count: 64)]
    }

    private func descriptor() -> IPARelease {
        IPARelease(identifier: "test", downloadURL: URL(string: "https://example.com/app.ipa")!)
    }

    private static func sampleApp() -> ManagedApp {
        ManagedApp(deviceID: "device", teamID: "team", name: "Test", version: "1.0", buildVersion: "1",
                   originalBundleID: "com.example.test", bundleID: "io.resign.test", ipaFilename: "original.ipa")
    }

    private func write(_ data: Data, to path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func makeIPA() throws -> URL {
        let url = root.appendingPathComponent("source.ipa")
        let writer = try Archive.Writer.create(at: url)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.test", "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "20", "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "17.0"]
        let words: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0]
        let executable = words.reduce(into: Data()) { data, word in
            var value = word.littleEndian
            data.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        try writer.writeFile(path: "Payload/Test.app/Info.plist", data: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), permissions: 0o644)
        try writer.writeFile(path: "Payload/Test.app/Test", data: executable, permissions: 0o755)
        try writer.close()
        return url
    }
}

private final class UpdateResponseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var status = 200
    private static var headers: [String: String] = [:]
    private static var requests: [URLRequest] = []
    static var lastURL: URL? { lastRequest?.url }
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    static var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requests.compactMap(\.url) }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        body = Data(); status = 200; headers = [:]; requests = []
    }
    static func respond(json: [String: Any], status: Int = 200, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        body = try! JSONSerialization.data(withJSONObject: json)
        self.status = status
        self.headers = headers
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.body
        let status = Self.status
        let headers = Self.headers
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
