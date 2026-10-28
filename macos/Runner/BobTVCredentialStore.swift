import Foundation
import Security

/// Only BobTV's two credentials are addressable. Never enumerate a keychain.
/// Keep legacy item service/accounts so upgrades do not lose existing backups.
enum BobTVCredentialStore {
  static let lock = NSLock()
  static func perform(_ operation: String, key: String, value: String?,
                      interactive: Bool, keychain: SecKeychain? = nil) -> (OSStatus, String?) {
    guard key == "bobtv_ai_api_key_v1" ||
      key.range(of: "^bobtv_private_favorites_v1_[a-f0-9]{64}$",
                options: .regularExpression) != nil,
      ["read", "write", "delete"].contains(operation) else {
      return (errSecParam, nil)
    }
    lock.lock()
    defer { lock.unlock() }
    var previous = DarwinBoolean(false)
    let getStatus = SecKeychainGetUserInteractionAllowed(&previous)
    guard getStatus == errSecSuccess else { return (getStatus, nil) }
    let setStatus = SecKeychainSetUserInteractionAllowed(interactive)
    guard setStatus == errSecSuccess else { return (setStatus, nil) }
    defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "flutter_secure_storage_service",
      kSecAttrAccount as String: key,
      kSecAttrSynchronizable as String: false
    ]
    // A dedicated keychain is used only by the native regression fixture.
    if let keychain = keychain {
      query[kSecUseKeychain as String] = keychain
      query[kSecMatchSearchList as String] = [keychain]
    }
    switch operation {
    case "read":
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return (errSecSuccess, nil) }
      guard status == errSecSuccess, let data = result as? Data,
        let text = String(data: data, encoding: .utf8) else {
        return (status == errSecSuccess ? errSecDecode : status, nil)
      }
      return (status, text)
    case "write":
      guard let value = value else { return (errSecParam, nil) }
      let data = Data(value.utf8)
      var status = SecItemUpdate(query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary)
      // Authorization failure must never become deletion or credential rotation.
      if status == errSecItemNotFound {
        query[kSecValueData as String] = data
        status = SecItemAdd(query as CFDictionary, nil)
      }
      return (status, nil)
    default:
      let status = SecItemDelete(query as CFDictionary)
      return (status == errSecItemNotFound ? errSecSuccess : status, nil)
    }
  }
}
