import Foundation
import XCTest
import SideSign
@testable import ReSign

final class IPAExtensionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReSignExtensionTests-" + UUID().uuidString)
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
        try IPAService.rewriteBundleIDs(targets)
        let rewritten = try IPAService.inspect(app)
        XCTAssertEqual(rewritten.components.map(\.bundleID), targets.map(\.bundleID))
        let plist = try readPlist(app.appendingPathComponent("PlugIns/Share.appex"))
        let configuration = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(configuration["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        XCTAssertEqual(configuration["NSExtensionPrincipalClass"] as? String, "Share.ViewController")
    }

    func testMixedExtensionTypesPreserveConfigurationAndRewriteWidgetReference() throws {
        let app = try makeApp()
        let extensionPoints = [
            "com.apple.share-services", "com.apple.ui-services", "com.apple.widgetkit-extension",
            "com.apple.usernotifications.service", "com.apple.usernotifications.content-extension",
            "com.apple.keyboard-service", "com.apple.photo-editing", "com.apple.intents-service",
        ]
        var configurations: [URL: NSDictionary] = [:]
        for (index, point) in extensionPoints.enumerated() {
            let ext = try makeExtension(
                in: app, name: "Extension\(index)", identifier: "com.example.test.Extension\(index)",
                extensionPoint: point)
            let configuration: [String: Any] = [
                "NSExtensionPointIdentifier": point,
                "NSExtensionPrincipalClass": "Extension\(index).Handler",
                "NSExtensionAttributes": ["CustomAttribute": ["value"]],
            ]
            try writePlist(at: ext, changes: ["NSExtension": configuration])
            configurations[ext] = configuration as NSDictionary
        }
        try writePlist(at: app, changes: ["UIApplicationShortcutWidget": "com.example.test.Extension2"])
        let info = try IPAService.inspect(app)
        let mainID = SigningService.bundleID(original: info.bundleID, team: "TESTTEAM01")
        let targets = try info.signingTargets(mainBundleID: mainID)
        XCTAssertEqual(targets.count, extensionPoints.count + 1)
        try IPAService.rewriteBundleIDs(targets)
        XCTAssertEqual(try IPAService.inspect(app).components.map(\.bundleID), targets.map(\.bundleID))
        XCTAssertEqual(try readPlist(app)["UIApplicationShortcutWidget"] as? String, mainID + ".Extension2")
        for (ext, configuration) in configurations {
            XCTAssertEqual(try readPlist(ext)["NSExtension"] as? NSDictionary, configuration)
        }
    }

    func testRejectsInvalidExtensionConfigurations() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Extension", identifier: "com.example.test.Extension")
        let invalidConfigurations: [Any] = [
            "invalid", [String: String](),
            ["NSExtensionPointIdentifier": ""], ["NSExtensionPointIdentifier": 42],
            ["NSExtensionPointIdentifier": "com..example"],
            ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension "],
            ["NSExtensionPointIdentifier": "com.apple.watchkit"],
        ]
        for configuration in invalidConfigurations {
            try writePlist(at: ext, changes: ["NSExtension": configuration])
            XCTAssertThrowsError(try IPAService.inspect(app))
        }
        try writePlist(at: ext, changes: [
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
            "CFBundlePackageType": "APPL",
        ])
        XCTAssertThrowsError(try IPAService.inspect(app))
    }

    func testRejectsEncryptedExtensionExecutables() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
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

    func testMismatchedVersionsAreAcceptedAndNormalizedOnlyInSigningCopy() throws {
        let app = try makeApp()
        let build = try makeExtension(in: app, name: "Build", identifier: "com.example.test.Build")
        let release = try makeExtension(in: app, name: "Release", identifier: "com.example.test.Release")
        let missing = try makeExtension(in: app, name: "Missing", identifier: "com.example.test.Missing")
        try writePlist(at: build, changes: ["CFBundleVersion": "2"])
        try writePlist(at: release, changes: ["CFBundleShortVersionString": "2.0"])
        try writePlist(at: missing, changes: [:], removingKeys: ["CFBundleShortVersionString"])
        let sourceURLs = [app, build, release, missing].map { $0.appendingPathComponent("Info.plist") }
        let sourceData = try sourceURLs.map { try Data(contentsOf: $0) }
        let imported = try IPAService.inspect(app)
        XCTAssertEqual(imported.version, "1.0")
        XCTAssertEqual(imported.buildVersion, "1")
        XCTAssertEqual(try sourceURLs.map { try Data(contentsOf: $0) }, sourceData)

        let workingApp = root.appendingPathComponent("Signing.app")
        try FileManager.default.copyItem(at: app, to: workingApp)
        let info = try IPAService.inspect(workingApp)
        let mainID = SigningService.bundleID(original: info.bundleID, team: "TESTTEAM01")
        let targets = try info.signingTargets(mainBundleID: mainID)
        let mainData = try Data(contentsOf: workingApp.appendingPathComponent("Info.plist"))
        try IPAService.normalizeExtensionVersions(info)
        XCTAssertEqual(try Data(contentsOf: workingApp.appendingPathComponent("Info.plist")), mainData)
        try IPAService.rewriteBundleIDs(targets)
        for target in targets {
            let plist = try readPlist(target.component.url)
            XCTAssertEqual(plist["CFBundleVersion"] as? String, "1")
            XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.0")
            XCTAssertEqual(plist["CFBundleIdentifier"] as? String, target.bundleID)
            if target.component.bundleID != info.bundleID {
                let source = app.appendingPathComponent("PlugIns/" + target.component.url.lastPathComponent)
                XCTAssertEqual(plist["NSExtension"] as? NSDictionary, try readPlist(source)["NSExtension"] as? NSDictionary)
                XCTAssertEqual(
                    try Data(contentsOf: target.component.url.appendingPathComponent("Test")),
                    try Data(contentsOf: source.appendingPathComponent("Test")))
            }
        }
        XCTAssertEqual(try sourceURLs.map { try Data(contentsOf: $0) }, sourceData)
    }

    func testNormalizationRemovesExtensionShortVersionWhenMainHasNone() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        try writePlist(at: app, changes: [:], removingKeys: ["CFBundleShortVersionString"])
        let info = try IPAService.inspect(app)
        try IPAService.normalizeExtensionVersions(info)
        XCTAssertNil(try readPlist(ext)["CFBundleShortVersionString"])
        XCTAssertEqual(try readPlist(ext)["CFBundleVersion"] as? String, "1")
    }

    func testRejectsMissingOrInvalidExtensionBuildVersion() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        try writePlist(at: ext, changes: [:], removingKeys: ["CFBundleVersion"])
        XCTAssertThrowsError(try IPAService.inspect(app))
        let invalidBuildVersions: [Any] = ["", 42]
        for value in invalidBuildVersions {
            try writePlist(at: ext, changes: ["CFBundleVersion": value])
            XCTAssertThrowsError(try IPAService.inspect(app))
        }
    }

    func testRejectsNestedBundles() throws {
        let app = try makeApp()
        let ext = try makeExtension(in: app, name: "Share", identifier: "com.example.test.Share")
        for directory in ["Watch", "AppClips", "PlugIns"] {
            let nested = ext.appendingPathComponent(directory + "/Nested.app")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            XCTAssertThrowsError(try IPAService.inspect(app))
            try FileManager.default.removeItem(at: ext.appendingPathComponent(directory))
        }
    }

    func testReadsAppGroupsForEachComponentAndAcceptsUnsignedBuilds() throws {
        let app = try makeApp()
        let ext = try makeExtension(
            in: app, name: "Widget", identifier: "com.example.test.Widget",
            extensionPoint: "com.apple.widgetkit-extension")
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
    private func makeExtension(
        in app: URL, name: String, identifier: String,
        extensionPoint: String = "com.apple.share-services"
    ) throws -> URL {
        let ext = app.appendingPathComponent("PlugIns/\(name).appex")
        try makeBundle(at: ext, identifier: identifier, packageType: "XPC!")
        try writePlist(
            at: ext,
            changes: [
                "NSExtension": [
                    "NSExtensionPointIdentifier": extensionPoint,
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

    private func writePlist(at bundle: URL, changes: [String: Any], removingKeys: [String] = []) throws {
        var plist = try readPlist(bundle)
        plist.merge(changes) { _, new in new }
        for key in removingKeys { plist.removeValue(forKey: key) }
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
