import Darwin
import Foundation
import NativeBridge

enum DeviceService {
    static func scan(remembered: [RememberedDevice] = []) async throws -> [ConnectedDevice] {
        try await Task.detached(priority: .utility) {
            var error: UnsafeMutablePointer<CChar>?
            let json = rs_devices_json(&error)
            defer { rs_free(error); rs_free(json) }
            guard let json else { throw ReSignError(error.map { String(cString: $0) } ?? "设备枚举失败。") }
            var devices = try JSONDecoder().decode([ConnectedDevice].self, from: Data(String(cString: json).utf8))
            for saved in remembered {
                guard let address = saved.networkAddress else { continue }
                let index = devices.firstIndex { $0.udid == saved.id }
                if let index, devices[index].trusted { continue }
                var connectionError: UnsafeMutablePointer<CChar>?
                let result = rs_network_device_json(saved.id, address, &connectionError)
                defer { rs_free(connectionError); rs_free(result) }
                guard let result else {
                    throw ReSignError(connectionError.map { String(cString: $0) } ?? "IP 设备连接失败。")
                }
                var device = try JSONDecoder().decode(ConnectedDevice.self, from: Data(String(cString: result).utf8))
                if device.name == nil { device.name = saved.name }
                if let index { devices[index] = device } else { devices.append(device) }
            }
            return devices
        }.value
    }

    static func validatedNetworkAddress(_ input: String) throws -> String? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return nil }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let v4 = address.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1
        let v6 = address.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
        guard v4 || v6 else { throw ReSignError("请输入设备的 IPv4 或 IPv6 地址，不要填写协议、端口或网址。") }
        if v4 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            guard value >> 24 != 0, value >> 24 != 127, value >> 24 < 224 else {
                throw ReSignError("请输入设备的单播 IP 地址。")
            }
        } else {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            guard bytes[0] != 0xff, bytes.contains(where: { $0 != 0 }),
                  !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1),
                  !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80),
                  !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff) else {
                throw ReSignError("请输入设备可路由的单播地址；IPv6 链路本地地址暂不支持。")
            }
        }
        return address
    }

    static func install(ipa: URL, device: ConnectedDevice, bundleID: String, version: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            var error: UnsafeMutablePointer<CChar>?
            let result: Int32
            if let address = device.networkAddress {
                result = address.withCString { rs_install(device.udid, $0, ipa.path, bundleID, version, &error) }
            } else {
                result = rs_install(device.udid, nil, ipa.path, bundleID, version, &error)
            }
            defer { rs_free(error) }
            guard result == 0 else {
                throw ReSignError(error.map { String(cString: $0) } ?? "设备安装失败。")
            }
        }.value
    }
}
