import Foundation
import Security
import LocalAuthentication

enum KeychainStore {
    static let service = "com.str8minds.ScrumTrace"

    /// The data-protection keychain needs an application-identifier or
    /// keychain-access-groups entitlement. Ad-hoc Debug builds have neither and
    /// get `errSecMissingEntitlement` (-34018), so those fall back to the login
    /// keychain instead of reporting every save as failed.
    private static func withKeychain(_ body: (_ dataProtection: Bool) -> OSStatus) -> OSStatus {
        let status = body(true)
        if status == errSecMissingEntitlement {
            AgentLog.event("keychain_legacy_fallback", [:])
            return body(false)
        }
        return status
    }

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func set(_ value: String, account: String) throws {
        let payload = Data(value.utf8)
        let status = withKeychain { dataProtection in
            let query = baseQuery(account: account, dataProtection: dataProtection)
            var attributes: [String: Any] = [kSecValueData as String: payload]
            if dataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                attributes[kSecUseDataProtectionKeychain as String] = true
            }
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updated != errSecItemNotFound {
                return updated
            }
            var add = query
            add[kSecValueData as String] = payload
            if dataProtection {
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func get(account: String) -> String? {
        var out: AnyObject?
        let status = withKeychain { dataProtection in
            var query = baseQuery(account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            out = nil
            return SecItemCopyMatching(query as CFDictionary, &out)
        }
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = out as? Data else {
            AgentLog.event("keychain_get_fail", ["status": String(status)])
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Attribute-only query: Settings never loads a saved secret into its text field.
    static func contains(account: String) -> Bool {
        let status = withKeychain { dataProtection in
            var query = baseQuery(account: account, dataProtection: dataProtection)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            return SecItemCopyMatching(query as CFDictionary, nil)
        }
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func remove(account: String) throws {
        let status = withKeychain { dataProtection in
            SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        // A key saved by a team-signed build must not linger in the other store.
        let legacy = SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
        guard legacy == errSecSuccess || legacy == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(legacy))
        }
    }
}
