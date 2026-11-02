import Foundation
import Security
import Crypto
import NIOSSH
import NIO

struct Vault {
    private static let service = "dev.herdr.HerdrWatch"
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WatchError.message("Keychain is unavailable. Unlock this device and retry.") }
        return result as? Data
    }
    static func contains(_ account: String) throws -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw WatchError.message("Keychain is unavailable.") }
        return true
    }
    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw WatchError.message("Could not save to Keychain.") }
        } else if status != errSecSuccess { throw WatchError.message("Could not update Keychain.") }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WatchError.message("Could not remove Keychain item.") }
    }
}

final class PinValidator: NIOSSHClientServerAuthenticationDelegate {
    let expected: String?
    init(expected: String?) { self.expected = expected }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        guard let expected else { validationCompletePromise.fail(WatchError.trust(key)); return }
        guard expected == key else { validationCompletePromise.fail(WatchError.changed); return }
        validationCompletePromise.succeed(())
    }
    static func fingerprint(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count > 1, let bytes = Data(base64Encoded: String(parts[1])) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
