import Foundation

enum AppGroupCompatibility {
    static let libraryName = "ReSignAppGroups.framework"
    static let mappingsKey = "ReSignAppGroupMappings"
    static let libraryPath = "@executable_path/Frameworks/" + libraryName + "/ReSignAppGroups"
    static let extensionLibraryPath = "@executable_path/../../Frameworks/" + libraryName + "/ReSignAppGroups"

    static func identifiers(for originals: [String], teamID: String, existing: [String]) -> [String: String] {
        var identifiers: [String: String] = [:]
        for original in Set(originals).sorted() {
            if let owned = existing.first(where: { $0.caseInsensitiveCompare(original) == .orderedSame }) {
                identifiers[original] = owned
                continue
            }
            let digest = AnisetteService.digest(Data(original.lowercased().utf8))
            let identifier = "group.io.resign.\(teamID.lowercased()).\(digest.prefix(32))"
            identifiers[original] = existing.first(where: {
                $0.caseInsensitiveCompare(identifier) == .orderedSame
            }) ?? identifier
        }
        return identifiers
    }

    static func prepare(_ info: IPAInfo, identifiers: [String: String], runtimeURL: URL? = nil) throws {
        guard let main = info.components.first, main.bundleID == info.bundleID else {
            throw ReSignError("无法确定共享组兼容组件的主应用。")
        }
        var plans: [(executable: URL, binary: Data, permissions: Int, bundle: URL, plist: Data)] = []
        for component in info.components {
            var mappings: [String: String] = [:]
            for original in component.appGroups {
                guard let identifier = identifiers[original] else {
                    throw ReSignError("缺少 App Group 映射：\(original)。")
                }
                if identifier != original { mappings[original] = identifier }
            }
            guard !mappings.isEmpty else { continue }
            var plist = try IPAService.readPlist(component.url)
            guard plist[mappingsKey] == nil else {
                throw ReSignError("应用已包含 ReSign 共享组兼容组件，请导入未经过此兼容处理的原始 IPA。")
            }
            guard let name = plist["CFBundleExecutable"] as? String else {
                throw ReSignError("无法找到需要适配 App Groups 的可执行文件。")
            }
            let executable = component.url.appendingPathComponent(name)
            guard let permissions = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int else {
                throw ReSignError("无法读取需要适配 App Groups 的可执行文件权限。")
            }
            let path = component.url == main.url ? libraryPath : extensionLibraryPath
            let binary = try MachOLibraryInjector.addingLibrary(path, to: Data(contentsOf: executable))
            plist[mappingsKey] = mappings
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            plans.append((executable, binary, permissions, component.url, data))
        }
        guard !plans.isEmpty else { return }
        guard let library = runtimeURL ?? Bundle.main.url(forResource: "ReSignAppGroups", withExtension: "framework") else {
            throw ReSignError("当前 ReSign 缺少共享组兼容组件，请使用完整构建的应用重试。")
        }
        let fm = FileManager.default
        let frameworks = main.url.appendingPathComponent("Frameworks", isDirectory: true)
        let destination = frameworks.appendingPathComponent(libraryName)
        guard !fm.fileExists(atPath: destination.path) else {
            throw ReSignError("应用已包含 ReSign 共享组兼容组件，请导入未经过此兼容处理的原始 IPA。")
        }
        _ = try Data(contentsOf: library.appendingPathComponent("ReSignAppGroups"))
        // iOS extensions load shared frameworks from the containing app, not from nested Frameworks directories.
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try fm.copyItem(at: library, to: destination)
        for plan in plans {
            try plan.binary.write(to: plan.executable, options: .atomic)
            try fm.setAttributes([.posixPermissions: plan.permissions], ofItemAtPath: plan.executable.path)
            try plan.plist.write(to: plan.bundle.appendingPathComponent("Info.plist"), options: .atomic)
        }
    }
}
