import Foundation
import Security

struct KeychainService {
    private let service = "com.chat.ChatMac.model-api-key"

    func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainServiceError.invalidValue
        }

        let lookupQuery = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            lookupQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(updateStatus)
        }

        var insertQuery = lookupQuery
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(insertStatus)
        }
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.invalidStoredValue
        }
        return value
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    func containsValue(account: String) throws -> Bool {
        try read(account: account) != nil
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainServiceError: LocalizedError {
    case invalidValue
    case invalidStoredValue
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "无法编码 API Key。"
        case .invalidStoredValue:
            "Keychain 中的 API Key 格式无效。"
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain 操作失败：\(message)"
            } else {
                "Keychain 操作失败，状态码 \(status)。"
            }
        }
    }
}
