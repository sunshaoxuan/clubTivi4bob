import Foundation
import Security

@main struct CredentialFixture {
  static func main() {
    let path = CommandLine.arguments[2]
    var keychain: SecKeychain?
    let key = "bobtv_private_favorites_v1_" + String(repeating: "f", count: 64)
    if CommandLine.arguments[1] == "create" {
      let password = "disposable-fixture-only"
      let created = password.withCString {
        SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain)
      }
      precondition(created == errSecSuccess)
      var access: SecAccess?
      precondition(SecAccessCreate("BobTV regression fixture" as CFString,
        [] as CFArray, &access) == errSecSuccess)
      // An empty trusted-app list forces authorization even when unlocked.
      let attributes: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "flutter_secure_storage_service",
        kSecAttrAccount as String: key,
        kSecValueData as String: Data("fixture-value".utf8),
        kSecUseKeychain as String: keychain!,
        kSecAttrAccess as String: access!
      ]
      precondition(SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess)
      print("created disposable protected item")
    } else {
      precondition(SecKeychainOpen(path, &keychain) == errSecSuccess)
      var before = DarwinBoolean(false), after = DarwinBoolean(false)
      SecKeychainGetUserInteractionAllowed(&before)
      let began = Date()
      let (status, value) = BobTVCredentialStore.perform("read", key: key,
        value: nil, interactive: false, keychain: keychain)
      SecKeychainGetUserInteractionAllowed(&after)
      precondition(value == nil && status != errSecSuccess)
      precondition(before.boolValue == after.boolValue)
      precondition(Date().timeIntervalSince(began) < 5)
      let (invalid, _) = BobTVCredentialStore.perform("read", key: "unrelated-key",
        value: nil, interactive: false, keychain: keychain)
      precondition(invalid == errSecParam)
      print("blockedWithoutUI status=\(status) interactionRestored=true unrelatedKeyRejected=true")
    }
  }
}
