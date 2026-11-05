import Foundation
import NativeBridge

enum DeviceService {
    static func scan() async throws -> [ConnectedDevice] {
        try await Task.detached(priority: .utility) {
            var error: UnsafeMutablePointer<CChar>?
            let json = rs_devices_json(&error)
            defer { rs_free(error); rs_free(json) }
            guard let json else { throw ReSignError(error.map { String(cString: $0) } ?? "设备枚举失败。") }
            return try JSONDecoder().decode([ConnectedDevice].self, from: Data(String(cString: json).utf8))
        }.value
    }

    static func install(ipa: URL, udid: String, bundleID: String, version: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            var error: UnsafeMutablePointer<CChar>?
            let result = rs_install(udid, ipa.path, bundleID, version, &error)
            defer { rs_free(error) }
            guard result == 0 else {
                throw ReSignError(error.map { String(cString: $0) } ?? "设备安装失败。")
            }
        }.value
    }
}
