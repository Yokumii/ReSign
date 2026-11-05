import Foundation
import SideSign

struct IPAInfo: Sendable {
    let name: String
    let bundleID: String
    let version: String
    let buildVersion: String
}

enum IPAService {
    static func extract(_ ipa: URL, into directory: URL) throws -> URL {
        let reader = try Archive.Reader.open(at: ipa)
        let entries = try reader.entries()
        guard !entries.isEmpty else { throw ReSignError("IPA 为空。") }
        var seen: Set<String> = []
        let rootPath = directory.standardizedFileURL.path + "/"
        for entry in entries {
            let name = entry.filename
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            let target = directory.appendingPathComponent(name).standardizedFileURL.path
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !parts.contains(".."), !parts.contains("."), target.hasPrefix(rootPath),
                  seen.insert(target).inserted else { throw ReSignError("IPA 包含无效或重复的文件路径。") }
            let type = (entry.externalAttributes >> 16) & 0o170000
            guard type == 0 || type == 0o040000 || type == 0o100000 else {
                throw ReSignError("不支持包含符号链接或特殊文件的 IPA。")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try reader.goToFirstFile()
        repeat {
            let name = try reader.currentFilename()
            try reader.extractCurrentFile(to: directory.appendingPathComponent(name))
        } while reader.goToNextFile()

        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let apps = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw ReSignError("IPA 必须包含一个主应用。") }
        return app
    }

    static func inspect(_ app: URL) throws -> IPAInfo {
        let fm = FileManager.default
        for name in ["PlugIns", "Watch", "AppClips"] {
            let path = app.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path), !(try fm.contentsOfDirectory(atPath: path.path)).isEmpty {
                throw ReSignError("仅支持普通 IPA；不支持扩展、Watch 应用或 App Clip。")
            }
        }
        let plist = try readPlist(app)
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let build = plist["CFBundleVersion"] as? String, !build.isEmpty,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.contains("/"), executable != ".", executable != "..",
              let platforms = plist["CFBundleSupportedPlatforms"] as? [String], platforms.contains("iPhoneOS") else {
            throw ReSignError("应用配置不完整，或不是可在 iPhone／iPad 上运行的应用。")
        }
        try requireUnencrypted(app.appendingPathComponent(executable))
        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? bundleID
        return IPAInfo(name: name, bundleID: bundleID,
                       version: plist["CFBundleShortVersionString"] as? String ?? build, buildVersion: build)
    }

    static func rewriteBundleID(at app: URL, to identifier: String) throws {
        var plist = try readPlist(app)
        plist["CFBundleIdentifier"] = identifier
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private static func readPlist(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReSignError("无法读取应用 Info.plist。")
        }
        return plist
    }

    // Reject encrypted executables before creating App IDs or certificates.
    private static func requireUnencrypted(_ executable: URL) throws {
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        func u32(_ offset: Int, bigEndian: Bool) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - 4 else { throw ReSignError("Mach-O 文件不完整。") }
            let values = (0..<4).map { UInt32(bytes[offset + $0]) }
            if bigEndian { return values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3] }
            return values[3] << 24 | values[2] << 16 | values[1] << 8 | values[0]
        }
        func checkSlice(_ start: Int, length: Int) throws {
            guard length >= 28, start <= bytes.count - length else { throw ReSignError("Mach-O 切片无效。") }
            let magic = try u32(start, bigEndian: false)
            guard [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(magic) else {
                throw ReSignError("应用可执行文件不是受支持的 Mach-O。")
            }
            let big = magic == 0xcefaedfe || magic == 0xcffaedfe
            let is64 = magic == 0xfeedfacf || magic == 0xcffaedfe
            let count = try u32(start + 16, bigEndian: big)
            let commandBytes = Int(try u32(start + 20, bigEndian: big))
            var cursor = start + (is64 ? 32 : 28)
            let end = cursor + commandBytes
            guard count <= 65536, end <= start + length else { throw ReSignError("Mach-O 命令区无效。") }
            for _ in 0..<count {
                guard cursor + 8 <= end else { throw ReSignError("Mach-O 命令截断。") }
                let command = try u32(cursor, bigEndian: big)
                let size = Int(try u32(cursor + 4, bigEndian: big))
                guard size >= 8, cursor + size <= end else { throw ReSignError("Mach-O 命令长度无效。") }
                if command == 0x21 || command == 0x2c {
                    guard size >= 20 else { throw ReSignError("加密命令无效。") }
                    if try u32(cursor + 16, bigEndian: big) != 0 {
                        throw ReSignError("此 IPA 的可执行文件经过 FairPlay 加密，不能直接重签。请导入可重签的应用构建。")
                    }
                }
                cursor += size
            }
        }
        let magic = try u32(0, bigEndian: true)
        if magic == 0xcafebabe || magic == 0xbebafeca {
            let big = magic == 0xcafebabe
            let count = Int(try u32(4, bigEndian: big))
            guard (1...64).contains(count), bytes.count >= 8 + count * 20 else { throw ReSignError("FAT Mach-O 头无效。") }
            for index in 0..<count {
                let entry = 8 + index * 20
                try checkSlice(Int(try u32(entry + 8, bigEndian: big)), length: Int(try u32(entry + 12, bigEndian: big)))
            }
        } else {
            try checkSlice(0, length: bytes.count)
        }
    }
}
