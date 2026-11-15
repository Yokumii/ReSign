import Foundation
import XCTest
@testable import ReSign

final class AppGroupCompatibilityTests: XCTestCase {
    private var root: URL!
    private let shared = "group.com.google.YouTube"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReSignGroupTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testMappingsAreStableTeamScopedAndReuseOwnedGroups() throws {
        let originals = [shared, "group.com.google.common", shared]
        let first = AppGroupCompatibility.identifiers(for: originals, teamID: "TEAM01", existing: [])
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first, AppGroupCompatibility.identifiers(for: Array(originals.reversed()), teamID: "TEAM01", existing: []))
        XCTAssertNotEqual(first, AppGroupCompatibility.identifiers(for: originals, teamID: "TEAM02", existing: []))
        let mapped = try XCTUnwrap(first[shared])
        XCTAssertTrue(mapped.hasPrefix("group.io.resign.team01."))
        XCTAssertEqual(first, AppGroupCompatibility.identifiers(for: originals, teamID: "TEAM01", existing: Array(first.values)))
        let owned = AppGroupCompatibility.identifiers(for: originals, teamID: "TEAM01", existing: [shared])
        XCTAssertEqual(owned[shared], shared)
        XCTAssertEqual(owned["group.com.google.common"], first["group.com.google.common"])
    }

    func testPreparationSharesMappingsAcrossComponentsAndPreservesSource() throws {
        let source = root.appendingPathComponent("Source.app")
        let sourceInfo = try fixture(at: source)
        let originalBinary = try Data(contentsOf: source.appendingPathComponent("Test"))
        let originalPlist = try Data(contentsOf: source.appendingPathComponent("Info.plist"))
        let working = root.appendingPathComponent("Work.app")
        try FileManager.default.copyItem(at: source, to: working)
        let info = relocating(sourceInfo, to: working)
        let identifiers = AppGroupCompatibility.identifiers(for: [shared], teamID: "TEAM01", existing: [])
        let runtime = root.appendingPathComponent("ReSignAppGroups.framework")
        let library = Data("fixture library bytes".utf8)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try library.write(to: runtime.appendingPathComponent("ReSignAppGroups"))
        try AppGroupCompatibility.prepare(info, identifiers: identifiers, runtimeURL: runtime)

        for component in info.components.prefix(2) {
            let plist = try IPAService.readPlist(component.url)
            XCTAssertEqual(plist[AppGroupCompatibility.mappingsKey] as? [String: String], identifiers)
            let executable = component.url.appendingPathComponent("Test")
            let binary = try Data(contentsOf: executable)
            XCTAssertEqual(binary.count, originalBinary.count)
            XCTAssertEqual(binary.suffix(16), originalBinary.suffix(16))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int, 0o751)
            let path = component.url == working ? AppGroupCompatibility.libraryPath : AppGroupCompatibility.extensionLibraryPath
            XCTAssertNotNil(binary.range(of: Data(path.utf8)))
        }
        XCTAssertEqual(try Data(contentsOf: working.appendingPathComponent("Frameworks/" + AppGroupCompatibility.libraryName + "/ReSignAppGroups")), library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.components[1].url.appendingPathComponent("Frameworks").path))
        let unrelated = try XCTUnwrap(info.components.last)
        XCTAssertNil(try IPAService.readPlist(unrelated.url)[AppGroupCompatibility.mappingsKey])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.url.appendingPathComponent("Frameworks").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Test")), originalBinary)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Info.plist")), originalPlist)
        XCTAssertEqual(try IPAService.readPlist(info.components[1].url)["NSExtension"] as? NSDictionary,
                       try IPAService.readPlist(sourceInfo.components[1].url)["NSExtension"] as? NSDictionary)
    }

    func testIdentityMappingDoesNotRequireRuntimeOrChangeFiles() throws {
        let info = try fixture(at: root.appendingPathComponent("Test.app"))
        let before = try snapshot(info)
        try AppGroupCompatibility.prepare(info, identifiers: [shared: shared])
        XCTAssertEqual(try snapshot(info), before)
    }

    func testMissingMappingRuntimeAndInsufficientPaddingLeaveFilesIntact() throws {
        let info = try fixture(at: root.appendingPathComponent("Test.app"))
        let before = try snapshot(info)
        XCTAssertThrowsError(try AppGroupCompatibility.prepare(info, identifiers: [:]))
        let identifiers = [shared: "group.io.resign.team01.shared"]
        XCTAssertThrowsError(try AppGroupCompatibility.prepare(
            info, identifiers: identifiers, runtimeURL: root.appendingPathComponent("Missing.framework")))
        XCTAssertEqual(try snapshot(info), before)

        let ext = info.components[1].url
        try executable(textOffset: 184).write(to: ext.appendingPathComponent("Test"))
        let noPadding = try snapshot(info)
        XCTAssertThrowsError(try AppGroupCompatibility.prepare(info, identifiers: identifiers))
        XCTAssertEqual(try snapshot(info), noPadding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.components[0].url.appendingPathComponent("Frameworks").path))
    }

    func testMachOInjectionIsIdempotentAndKeepsSectionBytesAndOffsets() throws {
        let original = executable()
        let patched = try MachOLibraryInjector.addingLibrary(AppGroupCompatibility.libraryPath, to: original)
        XCTAssertEqual(patched.count, original.count)
        XCTAssertEqual(patched[512..<528], original[512..<528])
        XCTAssertEqual(patched[152..<156], original[152..<156]) // section file offset
        XCTAssertEqual(patched[16], 2)
        XCTAssertEqual(patched[184], 0xc)
        XCTAssertEqual(String(decoding: patched[208..<(208 + AppGroupCompatibility.libraryPath.utf8.count)], as: UTF8.self), AppGroupCompatibility.libraryPath)
        XCTAssertEqual(try MachOLibraryInjector.addingLibrary(AppGroupCompatibility.libraryPath, to: patched), patched)
    }

    func testMachOInjectionHandlesEveryFATSlice() throws {
        for is64 in [false, true] {
            let original = fatExecutable(is64: is64)
            let patched = try MachOLibraryInjector.addingLibrary(AppGroupCompatibility.libraryPath, to: original)
            XCTAssertEqual(patched.count, original.count)
            for offset in [4096, 8192] {
                XCTAssertEqual(patched[offset + 16], 2)
                XCTAssertEqual(patched[(offset + 512)..<(offset + 528)], original[(offset + 512)..<(offset + 528)])
            }
        }
    }

    func testMachOInjectionRejectsMalformedOrUnsafeLayouts() throws {
        var dirtyPadding = executable()
        dirtyPadding[184] = 1
        var wrongCPU = executable()
        wrongCPU.replaceSubrange(4..<8, with: words([0x01000007]))
        var overlapping = fatExecutable(is64: false)
        overlapping.replaceSubrange(36..<40, with: words([4096], bigEndian: true))
        var invalidCommand = executable()
        invalidCommand.replaceSubrange(36..<40, with: words([0]))
        for data in [Data(), executable(textOffset: 184), dirtyPadding, wrongCPU, overlapping, invalidCommand] {
            XCTAssertThrowsError(try MachOLibraryInjector.addingLibrary(AppGroupCompatibility.libraryPath, to: data))
        }
    }

    private func fixture(at app: URL) throws -> IPAInfo {
        let bundles = [app, app.appendingPathComponent("PlugIns/Share.appex"), app.appendingPathComponent("PlugIns/Other.appex")]
        var components: [IPAComponent] = []
        for (index, url) in bundles.enumerated() {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let identifier = "com.example.test" + (index == 0 ? "" : ".Extension\(index)")
            var plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Test", "CFBundleVersion": "1"]
            if index > 0 { plist["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.share-services"] }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url.appendingPathComponent("Info.plist"))
            try executable().write(to: url.appendingPathComponent("Test"))
            try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: url.appendingPathComponent("Test").path)
            components.append(IPAComponent(url: url, bundleID: identifier, appGroups: index < 2 ? [shared] : []))
        }
        return IPAInfo(name: "Test", bundleID: "com.example.test", version: "1.0", buildVersion: "1", components: components)
    }

    private func relocating(_ info: IPAInfo, to app: URL) -> IPAInfo {
        let components = info.components.map { component in
            IPAComponent(url: component.url == info.components[0].url ? app : app.appendingPathComponent("PlugIns/" + component.url.lastPathComponent),
                         bundleID: component.bundleID, appGroups: component.appGroups)
        }
        return IPAInfo(name: info.name, bundleID: info.bundleID, version: info.version, buildVersion: info.buildVersion, components: components)
    }

    private func snapshot(_ info: IPAInfo) throws -> [Data] {
        try info.components.flatMap { component in
            try ["Test", "Info.plist"].map { try Data(contentsOf: component.url.appendingPathComponent($0)) }
        }
    }

    private func executable(textOffset: Int = 512) -> Data {
        var data = words([0xfeedfacf, 0x0100000c, 0, 2, 1, 152, 0, 0, 0x19, 152])
        data.append(fixedString("__TEXT"))
        data.append(words([0, 1, 4096, 0, 0, 0, UInt32(textOffset + 16), 0, 7, 5, 1, 0]))
        data.append(fixedString("__text"))
        data.append(fixedString("__TEXT"))
        data.append(words([UInt32(textOffset), 1, 16, 0, UInt32(textOffset), 2, 0, 0, 0x80000400, 0, 0, 0]))
        data.append(Data(repeating: 0, count: textOffset - data.count))
        data.append(Data(repeating: 0xab, count: 16))
        return data
    }

    private func fatExecutable(is64: Bool) -> Data {
        let slice = executable()
        var data = words([is64 ? 0xcafebabf : 0xcafebabe, 2], bigEndian: true)
        let offsets: [UInt32] = [4096, 8192]
        for offset in offsets {
            let entry: [UInt32] = is64
                ? [0x0100000c, 0, 0, offset, 0, UInt32(slice.count), 12, 0]
                : [0x0100000c, 0, offset, UInt32(slice.count), 12]
            data.append(words(entry, bigEndian: true))
        }
        data.append(Data(repeating: 0, count: 8192 + slice.count - data.count))
        data.replaceSubrange(4096..<(4096 + slice.count), with: slice)
        data.replaceSubrange(8192..<(8192 + slice.count), with: slice)
        return data
    }

    private func fixedString(_ string: String) -> Data {
        var data = Data(string.utf8)
        data.append(Data(repeating: 0, count: 16 - data.count))
        return data
    }

    private func words(_ words: [UInt32], bigEndian: Bool = false) -> Data {
        words.reduce(into: Data()) { data, word in
            var value = bigEndian ? word.bigEndian : word.littleEndian
            data.append(contentsOf: withUnsafeBytes(of: &value) { Array($0) })
        }
    }
}
