import Foundation
import Security
import LocalAuthentication
import PaperCore

enum ProviderSecret {
    static func load(account: String = "api-key") throws -> String {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.papershelf.provider", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LearningError.message("钥匙串暂时无法读取（\(status)）；请解锁登录钥匙串，或在设置中重新保存服务密钥。")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, account: String = "api-key") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.papershelf.provider", kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LearningError.message("无法清除钥匙串中的密钥：\(status)") }
            return
        }
        let attrs = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attrs) { _, new in new }; status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LearningError.message("无法保存密钥到钥匙串：\(status)") }
    }
}
