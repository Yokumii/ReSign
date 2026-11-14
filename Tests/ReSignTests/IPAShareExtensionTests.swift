import Foundation
import XCTest
import SideSign
@testable import ReSign

final class IPAShareExtensionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReSignShareTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testShareExtensionsMapAndRewriteTogetherWithoutChangingExtensionConfiguration() throws {
        let app = try makeApp()
        try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        try makeExtension(in: app, name: "Other", identifier: "com.example.test.Other")
        let info = try IPAService.inspect(app)
        let mainID = SigningService.bundleID(original: info.bundleID, team: "TESTTEAM01")
        let targets = try info.signingTargets(mainBundleID: mainID)
        XCTAssertEqual(targets.map(\.bundleID), [mainID, mainID + ".Other", mainID + ".Share"])
        XCTAssertEqual(try info.signingTargets(mainBundleID: mainID).map(\.bundleID), targets.map(\.bundleID))
        for target in targets {
            try IPAService.rewriteBundleID(at: target.component.url, to: target.bundleID)
        }
        let rewritten = try IPAService.inspect(app)
        XCTAssertEqual(rewritten.components.map(\.bundleID), targets.map(\.bundleID))
        let plist = try readPlist(app.appendingPathComponent("PlugIns/Share.appex"))
        let configuration = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(configuration["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        XCTAssertEqual(configuration["NSExtensionPrincipalClass"] as? String, "Share.ViewController")
    }

    func testRejectsOtherExtensionTypesAndEncryptedShareExecutables() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        try writePlist(at: ext, changes: ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]])
        XCTAssertThrowsError(try IPAService.inspect(app))
        try writePlist(at: ext, changes: ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"]])
        try executable(encrypted: true).write(to: ext.appendingPathComponent("Test"))
        XCTAssertThrowsError(try IPAService.inspect(app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("FairPlay"))
        }
    }

    func testRejectsUnrelatedDuplicateAndOversizedExtensionIdentifiers() throws {
        let app = try makeApp()
        let first = try makeExtension(in: app, name: "First", identifier: "com.other.Share")
        XCTAssertThrowsError(try IPAService.inspect(app))
        try writePlist(at: first, changes: ["CFBundleIdentifier": "com.example.test.Share"])
        let second = try makeExtension(in: app, name: "Second", identifier: "com.example.test.Share")
        XCTAssertThrowsError(try IPAService.inspect(app))
        try writePlist(at: second, changes: ["CFBundleIdentifier": "com.example.test.share"])
        XCTAssertThrowsError(try IPAService.inspect(app))
        try writePlist(at: second, changes: ["CFBundleIdentifier": "com.example.test." + String(repeating: "x", count: 230)])
        let info = try IPAService.inspect(app)
        XCTAssertThrowsError(try info.signingTargets(mainBundleID: SigningService.bundleID(original: info.bundleID, team: "TESTTEAM01")))
    }

    func testRejectsMismatchedVersionsAndNestedBundles() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        try writePlist(at: ext, changes: ["CFBundleVersion": "2"])
        XCTAssertThrowsError(try IPAService.inspect(app))
        try writePlist(at: ext, changes: ["CFBundleVersion": "1", "CFBundleShortVersionString": "2.0"])
        XCTAssertThrowsError(try IPAService.inspect(app))
        try writePlist(at: ext, changes: ["CFBundleShortVersionString": "1.0"])
        for directory in ["Watch", "AppClips", "PlugIns"] {
            let nested = ext.appendingPathComponent(directory + "/Nested.app")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            XCTAssertThrowsError(try IPAService.inspect(app))
            try FileManager.default.removeItem(at: ext.appendingPathComponent(directory))
        }
    }

    func testReadsAppGroupsForEachComponentAndAcceptsUnsignedBuilds() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        XCTAssertTrue(try IPAService.inspect(app).components.allSatisfy { $0.appGroups.isEmpty })
        let entitlements = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.application-groups": ["group.com.example.shared"]],
            format: .xml, options: 0)
        for bundle in [app, ext] {
            try executable(entitlements: entitlements).write(to: bundle.appendingPathComponent("Test"))
        }
        XCTAssertEqual(
            try IPAService.inspect(app).components.map(\.appGroups),
            [["group.com.example.shared"], ["group.com.example.shared"]])
    }

    func testRejectsMalformedEntitlementsAndInvalidAppGroupValues() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        try executable(entitlements: Data("invalid plist".utf8)).write(to: ext.appendingPathComponent("Test"))
        XCTAssertThrowsError(try IPAService.inspect(app))
        let invalidGroups: [Any] = [
            "group.com.example.shared", ["invalid"], ["group..invalid"],
            ["group.com.example.shared", "group.com.example.shared"],
        ]
        for groups in invalidGroups {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["com.apple.security.application-groups": groups], format: .xml, options: 0)
            try executable(entitlements: data).write(to: ext.appendingPathComponent("Test"))
            XCTAssertThrowsError(try IPAService.inspect(app))
        }
    }

    private func makeApp() throws -> URL {
        let app = root.appendingPathComponent("Test.app")
        try makeBundle(at: app, identifier: "com.example.test", packageType: "APPL")
        return app
    }

    @discardableResult
    private func makeExtension(in app: URL, name: String, identifier: String) throws -> URL {
        let ext = app.appendingPathComponent("PlugIns/\(name).appex")
        try makeBundle(at: ext, identifier: identifier, packageType: "XPC!")
        try writePlist(
            at: ext,
            changes: [
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "Share.ViewController",
                ]
            ])
        return ext
    }

    private func makeBundle(at url: URL, identifier: String, packageType: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "CFBundleExecutable": "Test",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "CFBundlePackageType": packageType,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        try executable().write(to: url.appendingPathComponent("Test"))
    }

    private func readPlist(_ bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func writePlist(at bundle: URL, changes: [String: Any]) throws {
        var plist = try readPlist(bundle)
        plist.merge(changes) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
    }

    private func executable(encrypted: Bool = false, entitlements: Data? = nil) -> Data {
        var commands: [UInt32] = []
        if encrypted { commands += [0x2c, 24, 0, 0, 1, 0] }
        var signature = Data()
        if let entitlements {
            // A synthetic SuperBlob containing the XML entitlements slot.
            let length = UInt32(28 + entitlements.count)
            signature = words([0xfade0cc0, length, 1, 5, 20, 0xfade7172, UInt32(8 + entitlements.count)], bigEndian: true)
            signature.append(entitlements)
            commands += [0x1d, 16, UInt32(32 + commands.count * 4 + 16), length]
        }
        let count: UInt32 = (encrypted ? 1 : 0) + (entitlements == nil ? 0 : 1)
        var data = words([0xfeedfacf, 0x0100000c, 0, 2, count, UInt32(commands.count * 4), 0, 0] + commands)
        data.append(signature)
        return data
    }

    private func words(_ values: [UInt32], bigEndian: Bool = false) -> Data {
        values.reduce(into: Data()) { data, word in
            var value = bigEndian ? word.bigEndian : word.littleEndian
            data.append(withUnsafeBytes(of: &value) { Data($0) })
        }
    }
}
