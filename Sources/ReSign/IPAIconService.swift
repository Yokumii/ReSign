import Foundation
import ImageIO
import SideSign
import UniformTypeIdentifiers

enum IPAIconService {
    // Read only the main app's plist and icon files, including when backfilling an existing IPA.
    static func extract(from ipa: URL) throws -> Data? {
        let reader = try Archive.Reader.open(at: ipa)
        let entries = try reader.entries()
        let plists = entries.filter {
            let parts = $0.filename.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "Payload"
                && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard plists.count == 1, let plistEntry = plists.first else {
            throw ReSignError("IPA 必须包含一个主应用。")
        }
        try reader.goToFirstFile()
        while try reader.currentFilename() != plistEntry.filename {
            guard reader.goToNextFile() else { throw ReSignError("找不到应用 Info.plist。") }
        }
        guard plistEntry.uncompressedSize <= 4 * 1024 * 1024,
              plistEntry.compressedSize <= 4 * 1024 * 1024,
              let plist = try PropertyListSerialization.propertyList(from: reader.readCurrentFile(), format: nil)
                as? [String: Any] else {
            throw ReSignError("无法读取应用 Info.plist。")
        }

        let prefix = String(plistEntry.filename.dropLast("Info.plist".count))
        let files = entries.filter {
            $0.filename.hasPrefix(prefix) && !$0.isDirectory
                && !$0.filename.dropFirst(prefix.count).contains("/")
                && $0.filename.lowercased().hasSuffix(".png")
        }
        let names = iconNames(in: plist)
        var candidates = files.filter { entry in
            names.contains { matches(filename: String(entry.filename.dropFirst(prefix.count)), iconName: $0) }
        }
        if candidates.isEmpty {
            candidates = files.filter {
                let name = String($0.filename.dropFirst(prefix.count))
                return matches(filename: name, iconName: "AppIcon") || matches(filename: name, iconName: "Icon")
            }
        }
        let paths = Set(candidates.map(\.filename))
        guard !paths.isEmpty else { return nil }

        var best: (data: Data, pixels: Int)?
        try reader.goToFirstFile()
        repeat {
            let entry = try reader.currentEntry()
            guard paths.contains(entry.filename) else { continue }
            guard entry.uncompressedSize <= 16 * 1024 * 1024,
                  entry.compressedSize <= 16 * 1024 * 1024 else { continue }
            let data = try reader.readCurrentFile()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height) else { continue }
            let pixels = width * height
            guard pixels > (best?.pixels ?? 0) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw ReSignError("无法创建应用图标缓存。")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ReSignError("无法编码应用图标。") }
            best = (output as Data, pixels)
        } while reader.goToNextFile()
        guard let best else { throw ReSignError("应用图标文件无法解码。") }
        return best.data
    }

    private static func iconNames(in plist: [String: Any]) -> [String] {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = plist[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            names += primary["CFBundleIconFiles"] as? [String] ?? []
            if let name = primary["CFBundleIconName"] as? String { names.append(name) }
        }
        names += plist["CFBundleIconFiles"] as? [String] ?? []
        names += plist["CFBundleIconFiles~ipad"] as? [String] ?? []
        for key in ["CFBundleIconFile", "CFBundleIconFile~ipad"] {
            if let name = plist[key] as? String { names.append(name) }
        }
        return names.filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") }
    }

    private static func matches(filename: String, iconName: String) -> Bool {
        func stem(_ value: String) -> String {
            let lower = value.lowercased()
            let name = lower.hasSuffix(".png") ? String(lower.dropLast(4)) : lower
            return String(name.prefix { $0 != "@" && $0 != "~" })
        }
        let file = stem(filename)
        let icon = stem(iconName)
        if file == icon { return true }
        // Asset catalogs append dimensions to CFBundleIconName, e.g. AppIcon60x60@3x.png.
        guard file.hasPrefix(icon) else { return false }
        let dimensions = file.dropFirst(icon.count).split(separator: "x", omittingEmptySubsequences: false)
        return dimensions.count == 2 && dimensions.allSatisfy { (Double($0) ?? 0) > 0 }
    }
}
