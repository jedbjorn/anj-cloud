// Keychain reachability facts for one session (spec #31 M3): what a process
// in this session sees of the login keychain, without UI and without
// reading any secret. Run it from SSH and from the GUI session
// (tool/macos/gui_run.sh) and compare; tool/macos/keychain_probe.sh does
// both. Prints one JSON object.
//
//   keychain_probe.swift <service> <existing account> <missing account>
//
// The existing item is one tool/macos/keychain_items.sh created; only its
// attributes are requested, and data is requested with user interaction
// disallowed, so no dialog can appear and nothing is printed of its value.
import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
  FileHandle.standardError.write("usage: keychain_probe.swift <service> <existing> <missing>\n".data(using: .utf8)!)
  exit(64)
}
let service = arguments[1]
let existing = arguments[2]
let missing = arguments[3]
var facts: [String: Any] = [:]

func path(_ keychain: SecKeychain) -> String {
  var length = UInt32(PATH_MAX)
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
  return SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess ? String(cString: buffer) : "?"
}
func message(_ status: OSStatus) -> String {
  (SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)"
}

_ = SecKeychainSetUserInteractionAllowed(false)
var allowed: DarwinBoolean = true
_ = SecKeychainGetUserInteractionAllowed(&allowed)
facts["interactionAllowed"] = allowed.boolValue
facts["sessionId"] = ProcessInfo.processInfo.environment["SECURITYSESSIONID"] ?? ""

var list: CFArray?
let listStatus = SecKeychainCopyDomainSearchList(.user, &list)
facts["userSearchList"] = [
  "status": Int(listStatus),
  "paths": ((list as? [AnyObject]) ?? []).map { path($0 as! SecKeychain) },
] as [String: Any]
var defaultKeychain: SecKeychain?
let defaultStatus = SecKeychainCopyDefault(&defaultKeychain)
facts["defaultKeychain"] = [
  "status": Int(defaultStatus),
  "path": defaultKeychain.map(path) ?? "",
] as [String: Any]

let loginPath = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
var login: SecKeychain?
let openStatus = SecKeychainOpen(loginPath, &login)
var keychainStatus: SecKeychainStatus = 0
let getStatus = login.map { SecKeychainGetStatus($0, &keychainStatus) } ?? errSecNoSuchKeychain
facts["loginKeychain"] = [
  "open": Int(openStatus),
  "getStatus": Int(getStatus),
  "getStatusMessage": message(getStatus),
  "unlocked": keychainStatus & UInt32(kSecUnlockStateStatus) != 0,
  "readable": keychainStatus & UInt32(kSecReadPermStatus) != 0,
  "writable": keychainStatus & UInt32(kSecWritePermStatus) != 0,
] as [String: Any]

func query(_ account: String, data: Bool, restrict: Bool) -> [String: Any] {
  var query: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: account,
    kSecUseDataProtectionKeychain: false,
    kSecMatchLimit: kSecMatchLimitOne,
  ]
  if data { query[kSecReturnData] = true } else { query[kSecReturnAttributes] = true }
  if restrict, let login = login { query[kSecMatchSearchList] = [login] }
  var item: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &item)
  return ["status": Int(status), "message": message(status)]
}
facts["existing"] = [
  "attributes": query(existing, data: false, restrict: true),
  "attributesDefaultList": query(existing, data: false, restrict: false),
  "dataNoUI": query(existing, data: true, restrict: true),
] as [String: Any]
facts["missing"] = [
  "attributes": query(missing, data: false, restrict: true),
  "dataNoUI": query(missing, data: true, restrict: true),
] as [String: Any]

let json = try! JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
