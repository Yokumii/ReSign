import Foundation
import Security

struct KeychainVault: Sendable {
    private let service: String

    init(service: String = "io.resign.mac") { self.service = service }

    func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try requireSuccess(status)
        guard let data = result as? Data else { throw ReSignError("钥匙串数据格式无效。") }
        return try JSONDecoder().decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try requireSuccess(SecItemAdd(item as CFDictionary, nil))
        } else {
            try requireSuccess(status)
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecItemNotFound { try requireSuccess(status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
            throw ReSignError("钥匙串操作失败：\(detail)")
        }
    }
}
