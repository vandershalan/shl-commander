import Foundation
import Security

/// Passwords for saved servers, kept as internet passwords in the login Keychain.
///
/// The same class and attributes the system's own connect-to-server uses, so an entry saved
/// here is visible and revocable in Keychain Access rather than being buried in a private file.
enum ServerKeychain {
    /// Returns false when the Keychain refused, so the caller can say the password was not
    /// saved rather than pretending it was.
    @discardableResult
    static func save(password: String, host: String, account: String, scheme: String) -> Bool {
        guard !host.isEmpty, !account.isEmpty, !password.isEmpty else { return false }
        guard let data = password.data(using: .utf8) else { return false }

        var query = self.query(host: host, account: account, scheme: scheme)
        // An update rather than a second entry: the Keychain treats the attributes as the key,
        // so adding twice fails with errSecDuplicateItem.
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func password(host: String, account: String, scheme: String) -> String? {
        guard !host.isEmpty, !account.isEmpty else { return nil }
        var query = self.query(host: host, account: account, scheme: scheme)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(host: String, account: String) {
        guard !host.isEmpty, !account.isEmpty else { return }
        // No protocol here: removing should take the entry whatever scheme it was saved under.
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func query(host: String, account: String, scheme: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: protocolValue(for: scheme),
        ]
    }

    /// The Keychain names protocols by four-character code. An unknown scheme falls back to
    /// SMB, which is what this dialog is mostly used for.
    static func protocolValue(for scheme: String) -> CFString {
        switch scheme.lowercased() {
        case "smb": return kSecAttrProtocolSMB
        case "afp": return kSecAttrProtocolAFP
        case "ftp": return kSecAttrProtocolFTP
        case "ftps": return kSecAttrProtocolFTPS
        case "http": return kSecAttrProtocolHTTP
        case "https", "dav", "davs": return kSecAttrProtocolHTTPS
        default: return kSecAttrProtocolSMB
        }
    }
}
