import XCTest
import SideSign
@testable import ReSign

final class ReSignTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReSignTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRefreshSchedulingIncludesPendingUpdatesAndHonorsBackoff() {
        let now = Date()
        var app = sampleApp()
        app.expiresAt = now.addingTimeInterval(6 * 24 * 3600)
        XCTAssertTrue(app.isDue(at: now, leadHours: 48), "Pending imports must install even before renewal is due")
        app.pendingInstall = false
        XCTAssertFalse(app.isDue(at: now, leadHours: 48))
        app.expiresAt = now.addingTimeInterval(47 * 3600)
        XCTAssertTrue(app.isDue(at: now, leadHours: 48))
        app.nextAttemptAt = now.addingTimeInterval(60)
        XCTAssertFalse(app.isDue(at: now, leadHours: 48))
        XCTAssertTrue(app.isDue(at: now.addingTimeInterval(60), leadHours: 48))
        app.failedAttempts = 5
        XCTAssertFalse(app.isDue(at: now.addingTimeInterval(120), leadHours: 48))
        app.failedAttempts = 0
        app.autoRefresh = false
        XCTAssertFalse(app.isDue(at: now.addingTimeInterval(120), leadHours: 48))
    }

    func testCorruptLibraryIsPreservedAndNeverReset() throws {
        let store = try LibraryStore(root: root)
        let libraryURL = root.appendingPathComponent("library.json")
        let original = Data("{invalid".utf8)
        try original.write(to: libraryURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: libraryURL), original)
    }

    func testLibraryRoundTripAndRejectsEscapingCachePaths() throws {
        let store = try LibraryStore(root: root)
        var library = Library()
        library.apps = [sampleApp()]
        try store.save(library)
        let loaded = try store.load()
        XCTAssertEqual(loaded.apps.first?.id, library.apps.first?.id)
        XCTAssertTrue(loaded.apps[0].pendingInstall)
        var app = sampleApp()
        for path in ["../other.ipa", "/tmp/other.ipa", "nested/other.ipa"] {
            app.ipaFilename = path
            XCTAssertThrowsError(try store.sourceURL(for: app))
        }
    }

    func testAnisetteURLPolicy() throws {
        var settings = AppSettings()
        settings.anisetteSource = .remoteV3
        for value in ["https://anisette.example.com", "http://127.0.0.1:6969", "http://localhost:6969"] {
            settings.anisetteServer = value
            XCTAssertNoThrow(try settings.validatedServerURL())
        }
        for value in ["http://192.168.1.2:6969", "https://user:password@example.com", "https://example.com?key=secret", "ftp://example.com", ""] {
            settings.anisetteServer = value
            XCTAssertThrowsError(try settings.validatedServerURL())
        }
    }

    func testIPAExtractAndInspectAndRewrite() throws {
        let ipa = try makeIPA(entries: basicEntries())
        let app = try IPAService.extract(ipa, into: root.appendingPathComponent("extracted"))
        let info = try IPAService.inspect(app)
        XCTAssertEqual(info.bundleID, "com.example.test")
        XCTAssertEqual(info.buildVersion, "1")
        try IPAService.rewriteBundleID(at: app, to: "io.resign.test")
        XCTAssertEqual(try IPAService.inspect(app).bundleID, "io.resign.test")
    }

    func testIPARejectsTraversalBeforeWritingOutsideWorkspace() throws {
        let ipa = try makeIPA(entries: [("../escaped.txt", Data("bad".utf8))])
        XCTAssertThrowsError(try IPAService.extract(ipa, into: root.appendingPathComponent("extracted")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    func testIPARejectsEncryptedExecutableAndUnsupportedExtensions() throws {
        let encrypted = try makeIPA(entries: basicEntries(encrypted: true))
        let app = try IPAService.extract(encrypted, into: root.appendingPathComponent("encrypted"))
        XCTAssertThrowsError(try IPAService.inspect(app))
        let withExtension = try makeIPA(entries: basicEntries() + [("Payload/Test.app/PlugIns/Test.appex/Info.plist", Data())])
        let extendedApp = try IPAService.extract(withExtension, into: root.appendingPathComponent("extended"))
        XCTAssertThrowsError(try IPAService.inspect(extendedApp))
    }

    func testNativeDeviceEnumeration() async throws {
        guard ProcessInfo.processInfo.environment["RESIGN_DEVICE_TEST"] == "1" else {
            throw XCTSkip("Set RESIGN_DEVICE_TEST=1 to run the USB device enumeration test")
        }
        let devices = try await DeviceService.scan()
        XCTAssertEqual(Set(devices.map(\.udid)).count, devices.count)
        XCTAssertTrue(devices.allSatisfy { !$0.udid.isEmpty })
    }

    func testRemoteAnisetteProvisioningAndIdentityReuse() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["RESIGN_INTEGRATION_URL"] else {
            throw XCTSkip("Set RESIGN_INTEGRATION_URL to run the anonymous Anisette integration test")
        }
        let vault = KeychainVault(service: "io.resign.integration." + UUID().uuidString)
        var settings = AppSettings()
        settings.anisetteSource = .remoteV3
        settings.anisetteServer = endpoint
        let server = try settings.validatedServerURL()
        let (metadata, _) = try await URLSession.shared.data(from: server.appendingPathComponent("v3/client_info"))
        let advertised = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: String])
        let key = AnisetteService.identityKey(server: server, clientInfo: try XCTUnwrap(advertised["client_info"]),
                                              userAgent: try XCTUnwrap(advertised["user_agent"]))
        defer { try? vault.remove(key) }
        let firstService = AnisetteService(vault: vault)
        let first = try await firstService.fresh(settings: settings)
        XCTAssertFalse(first.oneTimePassword.isEmpty)
        XCTAssertFalse(first.machineID.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: first.oneTimePassword))
        XCTAssertEqual(first.clientInfo, advertised["client_info"])
        XCTAssertEqual(first.userAgent, advertised["user_agent"])
        // A new service instance represents the next app launch and must reuse the saved identity.
        let restartedService = AnisetteService(vault: vault)
        let second = try await restartedService.fresh(settings: settings)
        XCTAssertEqual(first.deviceID, second.deviceID)
        XCTAssertEqual(first.machineID, second.machineID)
        XCTAssertEqual(first.clientInfo, second.clientInfo)
        XCTAssertEqual(first.userAgent, second.userAgent)
        XCTAssertFalse(second.oneTimePassword.isEmpty)
    }

    func testGrandSlamRejectsSyntheticCredentialsAfterAcceptingAnisette() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["RESIGN_INTEGRATION_URL"],
              ProcessInfo.processInfo.environment["RESIGN_GSA_PROBE"] == "1" else {
            throw XCTSkip("Set RESIGN_GSA_PROBE=1 to run the synthetic-credentials authentication check")
        }
        let vault = KeychainVault(service: "io.resign.gsa-probe." + UUID().uuidString)
        var settings = AppSettings()
        settings.anisetteSource = .remoteV3
        settings.anisetteServer = endpoint
        let server = try settings.validatedServerURL()
        let (metadata, _) = try await URLSession.shared.data(from: server.appendingPathComponent("v3/client_info"))
        let advertised = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: String])
        let key = AnisetteService.identityKey(server: server, clientInfo: try XCTUnwrap(advertised["client_info"]),
                                              userAgent: try XCTUnwrap(advertised["user_agent"]))
        defer { try? vault.remove(key) }
        let service = SigningService(vault: vault)
        do {
            _ = try await service.login(appleID: "resign-probe-\(UUID().uuidString.lowercased())@example.invalid",
                                        password: UUID().uuidString, settings: settings,
                                        verification: { _ in .cancel })
            XCTFail("Synthetic credentials must not authenticate")
        } catch let error as DeveloperPortalError {
            switch error {
            case .incorrectCredentials, .appSpecificPasswordRequired:
                break
            default:
                throw error
            }
        }
    }

    private func sampleApp() -> ManagedApp {
        ManagedApp(deviceID: "test-device", teamID: "TESTTEAM01", name: "Test", version: "1.0", buildVersion: "1",
                   originalBundleID: "com.example.test", bundleID: "io.resign.test", ipaFilename: "test.ipa")
    }

    private func basicEntries(encrypted: Bool = false) throws -> [(String, Data)] {
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.test", "CFBundleVersion": "1",
                                   "CFBundleExecutable": "Test", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        var words: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, encrypted ? 1 : 0, encrypted ? 24 : 0, 0, 0]
        if encrypted { words += [0x2c, 24, 0, 0, 1, 0] }
        let executable = words.reduce(into: Data()) { data, word in
            var value = word.littleEndian
            data.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        return [("Payload/Test.app/Info.plist", plist), ("Payload/Test.app/Test", executable)]
    }

    private func makeIPA(entries: [(String, Data)]) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".ipa")
        let writer = try Archive.Writer.create(at: url)
        for (name, data) in entries { try writer.writeFile(path: name, data: data, permissions: 0o755) }
        try writer.close()
        return url
    }
}
