import Cocoa
import CryptoKit
import FlutterMacOS
import Security
import SystemConfiguration

/// The runner's side of the macOS desktop session (spec #31 M3), beside the
/// window channel in MainFlutterWindow.swift:
///
/// - `cloud.anj/tray`: the menu-bar item (`NSStatusItem`, a template image
///   of the cloud-seal mark) with the Linux tray's menu: status, Open,
///   Pause or Resume, Quit (lib/platform/desktop/channel_tray.dart);
/// - `cloud.anj/keychain`: generic-password items in the legacy login
///   keychain (lib/platform/macos/keychain_secrets.dart);
/// - `cloud.anj/system`: the Computer Name, the pairing label;
/// - App Nap: a user-initiated activity held for the app's lifetime that
///   still allows idle system sleep, so App Nap cannot stretch the pass
///   timer while the window is closed (#40). System sleep is never
///   prevented.
final class DesktopIntegration: NSObject {
  private let tray: FlutterMethodChannel
  private let keychain: FlutterMethodChannel
  private let system: FlutterMethodChannel
  private var statusItem: NSStatusItem?
  private var statusLine: NSMenuItem?
  private var pauseItem: NSMenuItem?
  private let activity: NSObjectProtocol
  // Keychain calls may wait on the access dialog; they never block the
  // main thread, and run one at a time.
  private let keychainQueue = DispatchQueue(label: "cloud.anj.keychain")

  init(messenger: FlutterBinaryMessenger) {
    tray = FlutterMethodChannel(name: "cloud.anj/tray", binaryMessenger: messenger)
    keychain = FlutterMethodChannel(name: "cloud.anj/keychain", binaryMessenger: messenger)
    system = FlutterMethodChannel(name: "cloud.anj/system", binaryMessenger: messenger)
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "AnJ Cloud keeps your files in sync")
    super.init()
    tray.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.handleTray(call, result: result)
    }
    keychain.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.handleKeychain(call, result: result)
    }
    system.setMethodCallHandler { call, result in
      switch call.method {
      case "computerName":
        result(SCDynamicStoreCopyComputerName(nil, nil) as String?)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    ProcessInfo.processInfo.endActivity(activity)
  }

  // MARK: Menu-bar item

  private func handleTray(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let arguments = call.arguments as? [String: Any]
      let title = arguments?["tooltip"] as? String ?? "AnJ Cloud"
      if statusItem == nil { statusItem = makeStatusItem(title: title) }
      result(statusItem != nil)
    case "setState":
      let arguments = call.arguments as? [String: Any]
      if let status = arguments?["status"] as? String {
        statusLine?.title = status
        statusItem?.button?.toolTip = status
      }
      let paused = arguments?["paused"] as? Bool ?? false
      pauseItem?.title = paused ? "Resume sync" : "Pause sync"
      result(nil)
    case "close":
      if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
      statusItem = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func makeStatusItem(title: String) -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      if let image = NSImage(named: "StatusIcon") {
        image.isTemplate = true  // follows the menu bar's light or dark look
        button.image = image
      } else {
        button.title = "AnJ"
      }
      button.toolTip = title
      button.setAccessibilityLabel(title)
    }
    let menu = NSMenu()
    menu.autoenablesItems = false
    let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    status.isEnabled = false
    status.identifier = NSUserInterfaceItemIdentifier("status")
    menu.addItem(status)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(menuItem("Open AnJ Cloud", #selector(openSelected), "open"))
    let pause = menuItem("Pause sync", #selector(togglePauseSelected), "togglePause")
    menu.addItem(pause)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(menuItem("Quit AnJ Cloud", #selector(quitSelected), "quit"))
    item.menu = menu
    statusLine = status
    pauseItem = pause
    return item
  }

  private func menuItem(_ title: String, _ action: Selector, _ id: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = true
    item.identifier = NSUserInterfaceItemIdentifier(id)
    return item
  }

  @objc private func openSelected() { tray.invokeMethod("open", arguments: nil) }
  @objc private func togglePauseSelected() { tray.invokeMethod("togglePause", arguments: nil) }
  @objc private func quitSelected() { tray.invokeMethod("quit", arguments: nil) }

  // MARK: Keychain

  private func handleKeychain(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let service = arguments["service"] as? String,
      let account = arguments["account"] as? String
    else {
      result(FlutterError(code: "argument", message: "service and account are required", details: nil))
      return
    }
    let value = arguments["value"] as? String
    let interaction = arguments["interaction"] as? Bool ?? true
    let testKeychain = arguments["testKeychain"] as? String
    let method = call.method
    keychainQueue.async {
      let reply = LoginKeychain.perform(
        method, service: service, account: account, value: value, interaction: interaction,
        testKeychain: testKeychain)
      DispatchQueue.main.async { result(reply) }
    }
  }

  // MARK: Debug hooks (Debug builds only; tool/macos/session_check.sh)

  #if DEBUG
    /// Performs the runner's own controls, exactly as a click would, and
    /// reports the session state.
    func debugPerform(_ action: String?, window: NSWindow) -> Any? {
      switch action {
      case "state":
        let policy: String
        switch NSApp.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        default: policy = "prohibited"
        }
        // The item's button, in screen coordinates, then in screenshot
        // (top-left origin of the primary screen) points. The window's own
        // frame is not where the item is drawn (PR #72 review L2).
        var statusFrame: [Double] = []
        var statusOnScreen = false
        var statusInMenuBar = false
        if let button = statusItem?.button, let itemWindow = button.window {
          let rect = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
          let primary = NSScreen.screens.first?.frame ?? rect
          statusFrame = [rect.minX - primary.minX, primary.maxY - rect.maxY, rect.width, rect.height]
            .map { Double($0) }
          statusOnScreen = itemWindow.isVisible && itemWindow.occlusionState.contains(.visible)
          // Inside the menu-bar strip at the top of the screen it is on.
          let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
          if let screen, rect.width > 0, rect.height > 0 {
            let strip = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            statusInMenuBar = rect.maxY <= screen.frame.maxY + 1
              && rect.minY >= screen.frame.maxY - strip - 1
              && rect.minX >= screen.frame.minX && rect.maxX <= screen.frame.maxX
          }
        }
        return [
          "statusFrame": statusFrame,
          "statusOnScreen": statusOnScreen,
          "statusInMenuBar": statusInMenuBar,
          "windowVisible": window.isVisible,
          "activationPolicy": policy,
          "statusItem": statusItem?.isVisible ?? false,
          "statusImage": statusItem?.button?.image?.isTemplate ?? false,
          "menu": statusItem?.menu?.items.map { $0.title } ?? [],
        ] as [String: Any]
      case "statusMenu:open", "statusMenu:togglePause", "statusMenu:quit":
        let id = String(action!.dropFirst("statusMenu:".count))
        guard let menu = statusItem?.menu,
          let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == id })
        else { return false }
        menu.performActionForItem(at: index)
        return true
      case "window:close":
        window.performClose(nil)
        return true
      case "appMenu:quit":
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
          let index = appMenu.items.firstIndex(where: {
            $0.action == #selector(NSApplication.terminate(_:))
          })
        else { return false }
        appMenu.performActionForItem(at: index)
        return true
      // Spec #31 M5 (integration_test/macos_ui_test.dart).
      case "mainMenu":
        return (window as? MainFlutterWindow)?.debugMainMenu() ?? []
      case "window":
        return [
          "title": window.title,
          "titled": window.styleMask.contains(.titled),
          "fullSizeContent": window.styleMask.contains(.fullSizeContentView),
          "titlebarTransparent": window.titlebarAppearsTransparent,
          "titleVisible": window.titleVisibility == .visible,
          "closeButton": window.standardWindowButton(.closeButton) != nil,
          "miniaturizeButton": window.standardWindowButton(.miniaturizeButton) != nil,
          "zoomButton": window.standardWindowButton(.zoomButton) != nil,
          "contentSize": [Double(window.contentLayoutRect.width), Double(window.contentLayoutRect.height)],
        ] as [String: Any]
      case let action? where action.hasPrefix("menu:"):
        return (window as? MainFlutterWindow)?.debugPerformMenuItem(String(action.dropFirst("menu:".count))) ?? false
      case let action? where action.hasPrefix("cmdKey:"):
        return (window as? MainFlutterWindow)?.debugCommandKey(String(action.dropFirst("cmdKey:".count))) ?? [:]
      default:
        return false
      }
    }
  #endif
}

/// SecItem calls on the user's legacy login keychain only (decision #117
/// (3), spec #31 "Secrets and Identity"). Every query names the login
/// keychain explicitly, so an item never lands in, or is read from, another
/// keychain in the search list, and the data-protection keychain is never
/// used. Measured on mac-test (run 2, keychain_probe.sh): a process started
/// over SSH sees the login keychain in its search list but locked and not
/// writable; an existing item's attributes still match, its data is
/// refused (errSecAuthFailed), so it reads as unavailable, never as
/// missing; a missing item reads as missing, which is true (attributes are
/// searchable while locked); a write is refused (unavailable).
enum LoginKeychain {
  static func perform(
    _ method: String, service: String, account: String, value: String?, interaction: Bool,
    testKeychain: String? = nil
  ) -> Any? {
    let login: SecKeychain
    if let path = testKeychain {
      // Test builds only (ANJ_TEST_SEAMS, set for the Debug configuration in
      // Configs/AppInfo.xcconfig): a dedicated keychain file in place of the
      // login keychain, so a locked keychain can be checked without locking
      // the user's. The shipped app refuses the argument.
      #if ANJ_TEST_SEAMS
        var opened: SecKeychain?
        let status = SecKeychainOpen(path, &opened)
        guard status == errSecSuccess, let found = opened else {
          return unavailable(status, "The test keychain could not be opened.")
        }
        login = found
      #else
        return FlutterError(code: "argument", message: "No test keychain in this build", details: nil)
      #endif
    } else {
      guard let found = loginKeychain() else {
        return unavailable(errSecNoSuchKeychain, "The login keychain is not reachable from this session.")
      }
      login = found
    }
    var previous: DarwinBoolean = true
    _ = SecKeychainGetUserInteractionAllowed(&previous)
    if !interaction { _ = SecKeychainSetUserInteractionAllowed(false) }
    defer { if !interaction { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) } }

    let base: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecUseDataProtectionKeychain: false,
    ]
    var search = base
    search[kSecMatchSearchList] = [login]

    switch method {
    case "read":
      var query = search
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else { return unavailable(status) }
      guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
        return unavailable(errSecDecode, "The keychain item is not readable text.")
      }
      return text
    case "exists":
      // Attributes only: never decrypts, so never raises the access dialog.
      var query = search
      query[kSecReturnAttributes] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return false }
      return status == errSecSuccess ? true : unavailable(status)
    case "write", "add":
      guard let value = value, let data = value.data(using: .utf8) else {
        return FlutterError(code: "argument", message: "value is required", details: nil)
      }
      var add = base
      add[kSecUseKeychain] = login
      add[kSecValueData] = data
      add[kSecAttrLabel] = LoginKeychain.label(account)
      var status = SecItemAdd(add as CFDictionary, nil)
      if status == errSecDuplicateItem && method == "add" {
        // A new device key never replaces an item already there.
        return unavailable(status, "An item already exists for this account.")
      }
      if status == errSecDuplicateItem {
        let (reference, lookup) = itemReference(search)
        if let reference = reference {
          status = SecItemUpdate(
            [kSecClass: kSecClassGenericPassword, kSecMatchItemList: [reference]] as CFDictionary,
            [kSecValueData: data] as CFDictionary)
        } else {
          status = lookup
        }
      }
      return status == errSecSuccess ? nil : unavailable(status)
    case "delete":
      let (reference, lookup) = itemReference(search)
      guard let reference = reference else {
        return lookup == errSecItemNotFound ? nil : unavailable(lookup)
      }
      let status = SecItemDelete(
        [kSecClass: kSecClassGenericPassword, kSecMatchItemList: [reference]] as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound ? nil : unavailable(status)
    default:
      return FlutterMethodNotImplemented
    }
  }

  /// The item's reference, found by its attributes (no decryption), or the
  /// status of the failed lookup.
  private static func itemReference(_ search: [CFString: Any]) -> (CFTypeRef?, OSStatus) {
    var query = search
    query[kSecReturnRef] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let reference = item else {
      return (nil, status == errSecSuccess ? errSecItemNotFound : status)
    }
    return (reference, errSecSuccess)
  }

  /// The login keychain in this process's user search list, if any.
  /// What Keychain Access shows for an item (PR #72 review L4): the kind
  /// and the profile it belongs to, from the account
  /// `anj-cloud:<profileId>:<kind>`, so two profiles' device keys and an
  /// invitation are told apart, for example "AnJ Cloud — device key,
  /// profile 1a2b3c4d". Any other account keeps the plain name.
  static func label(_ account: String) -> String {
    let parts = account.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "anj-cloud", !parts[1].isEmpty else { return "AnJ Cloud" }
    let kind: String
    switch parts[2] {
    case "device-key": kind = "device key"
    case "invitation": kind = "pairing code"
    default: kind = parts[2]
    }
    return "AnJ Cloud — \(kind), profile \(parts[1].prefix(8))"
  }

  static func loginKeychain() -> SecKeychain? {
    var list: CFArray?
    guard SecKeychainCopyDomainSearchList(.user, &list) == errSecSuccess,
      let keychains = list as? [AnyObject]
    else { return nil }
    let expected = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Keychains/login.keychain-db")
      .resolvingSymlinksInPath().path
    for object in keychains {
      let keychain = object as! SecKeychain
      var length = UInt32(PATH_MAX)
      var path = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
      guard SecKeychainGetPath(keychain, &length, &path) == errSecSuccess else { continue }
      let found = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
      if found == expected { return keychain }
    }
    return nil
  }

  /// Every refusal is one error code with the OSStatus as details; Dart
  /// shows "Keychain unavailable" and never the message.
  private static func unavailable(_ status: OSStatus, _ message: String? = nil) -> FlutterError {
    let text = message ?? (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    return FlutterError(code: "unavailable", message: text, details: Int(status))
  }
}

// MARK: - In-app update verifier (spec #40 R2)

/// `AnJ Cloud --verify-update <archive> --manifest <file>`: the installed
/// release vouches for an update before its manager installs it. The
/// manager script (tool/macos/anj-cloud-macos-install.sh apply-update) runs
/// the INSTALLED bundle's executable, sealed by its code signature, because
/// base macOS has no Ed25519 tool. It runs before AppKit starts (no window,
/// no Dart, no profile), prints one JSON line and exits: 0 verified, 1
/// refused, 64 usage. The checks are linux_install.py verified_update and
/// _verify_download, byte for byte where it matters:
/// - the manifest has exactly the signed fields plus `signature` (and
///   optionally `min_client_version_code`), each within the gateway's rule;
/// - target `macos-arm64`; `key_id` is the key built into THIS bundle
///   (flutter_assets/assets/release/household-release-key.pub); the
///   Ed25519 signature verifies over services/access/release_manifest.py
///   signed_message (CryptoKit);
/// - `version_code` is above this bundle's own receipt
///   (Contents/Resources/bundle-receipt.json);
/// - the archive's size and SHA-256 are the signed ones.
enum ReleaseVerifier {
  static let target = "macos-arm64"
  static let header = "anj-cloud release v1"
  static let signedFields = ["target", "version", "version_code", "size", "sha256", "key_id"]
  static let maxPackage: Int64 = 512 * 1024 * 1024
  static let maxVersionCode: Int64 = 2_100_000_000

  struct Refusal: Error { let message: String }

  /// The exit status when `--verify-update` was asked for, else nil.
  static func runIfRequested(_ arguments: [String]) -> Int32? {
    guard arguments.count > 1, arguments[1] == "--verify-update" else { return nil }
    var archive: String?
    var manifest: String?
    var keyFile: String?
    var installedCode: Int64?
    var i = 2
    while i < arguments.count {
      let flag = arguments[i]
      let value = i + 1 < arguments.count ? arguments[i + 1] : nil
      switch flag {
      case "--manifest" where value != nil: manifest = value; i += 2
      #if ANJ_TEST_SEAMS
      // Debug builds only: a throwaway key and version for the tamper tests.
      case "--release-key" where value != nil: keyFile = value; i += 2
      case "--installed-version-code" where value != nil: installedCode = Int64(value!); i += 2
      #endif
      default:
        if archive == nil && !flag.hasPrefix("--") { archive = flag; i += 1 } else { return usage() }
      }
    }
    guard let archive, let manifest else { return usage() }
    do {
      let verified = try verify(
        archive: URL(fileURLWithPath: archive), manifest: URL(fileURLWithPath: manifest),
        keyFile: keyFile.map(URL.init(fileURLWithPath:)), installedCode: installedCode)
      emit(["ok": true, "version": verified.version, "version_code": verified.versionCode,
            "size": verified.size, "sha256": verified.sha256])
      return 0
    } catch let refusal as Refusal {
      emit(["ok": false, "message": refusal.message])
      return 1
    } catch {
      emit(["ok": false, "message": "The update could not be verified (\(error))."])
      return 1
    }
  }

  static func usage() -> Int32 {
    emit(["ok": false, "message": "usage: --verify-update <archive> --manifest <file>"])
    return 64
  }

  static func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    {
      print(line)
    }
  }

  struct Verified { let version: String; let versionCode: Int64; let size: Int64; let sha256: String }

  static var bundle: URL { Bundle.main.bundleURL }
  static var builtInKey: URL {
    bundle.appendingPathComponent(
      "Contents/Frameworks/App.framework/Resources/flutter_assets/assets/release/household-release-key.pub")
  }
  static var receipt: URL { bundle.appendingPathComponent("Contents/Resources/bundle-receipt.json") }

  /// (raw 32-byte key, key id) from a key file: `#` comments and exactly one
  /// `ed25519 <base64>` line; the id is the first 16 hex digits of SHA-256.
  static func releaseKey(_ url: URL) throws -> (Curve25519.Signing.PublicKey, String) {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw Refusal(message: "This release has no built-in release key; install updates with the manager's update command.")
    }
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard lines.count == 1, lines[0].hasPrefix("ed25519 "),
      let raw = Data(base64Encoded: String(lines[0].dropFirst("ed25519 ".count)).trimmingCharacters(in: .whitespaces)),
      raw.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { throw Refusal(message: "The built-in release key file is malformed.") }
    return (key, String(hex(SHA256.hash(data: raw)).prefix(16)))
  }

  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  /// An integer JSON value (not a boolean, not a fraction), else nil.
  static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let whole = number.int64Value
    return number.doubleValue == Double(whole) && !number.stringValue.contains(".") ? whole : nil
  }

  static func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "^" + pattern + "$", options: .regularExpression) != nil
  }

  static func verify(archive: URL, manifest: URL, keyFile: URL?, installedCode: Int64?) throws -> Verified {
    let (key, keyId) = try releaseKey(keyFile ?? builtInKey)
    var installed = installedCode
    if installed == nil {
      guard let data = try? Data(contentsOf: receipt),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let code = integer(object["version_code"]), code >= 0
      else { throw Refusal(message: "This release has no release receipt; install updates with the manager's update command.") }
      installed = code
    }
    guard let data = try? Data(contentsOf: manifest), data.count < 64 * 1024,
      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Refusal(message: "The update record is not JSON.") }
    let allowed = Set(signedFields + ["signature", "min_client_version_code"])
    let required = Set(signedFields + ["signature"])
    guard required.isSubset(of: record.keys), Set(record.keys).isSubset(of: allowed) else {
      throw Refusal(message: "The update record is incomplete or has unexpected fields.")
    }
    guard let target = record["target"] as? String, target == self.target else {
      throw Refusal(message: "The update is for another platform.")
    }
    guard let version = record["version"] as? String, matches(version, "[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}") else {
      throw Refusal(message: "The update record has an invalid version.")
    }
    guard let code = integer(record["version_code"]), (1...maxVersionCode).contains(code) else {
      throw Refusal(message: "The update record has an invalid version_code.")
    }
    guard let size = integer(record["size"]), (1...maxPackage).contains(size) else {
      throw Refusal(message: "The update record has an invalid size.")
    }
    guard let sha256 = record["sha256"] as? String, matches(sha256, "[0-9a-f]{64}") else {
      throw Refusal(message: "The update record has an invalid SHA-256.")
    }
    if let minimum = record["min_client_version_code"], integer(minimum) == nil {
      throw Refusal(message: "The update record has an invalid min_client_version_code.")
    }
    guard let id = record["key_id"] as? String, id == keyId else {
      throw Refusal(message: "The update is signed with a different key than this app's.")
    }
    let values: [String: String] = ["target": target, "version": version, "version_code": String(code),
                                    "size": String(size), "sha256": sha256, "key_id": id]
    let message = ([header] + signedFields.map { "\($0) \(values[$0]!)" }).joined(separator: "\n") + "\n"
    guard let encoded = record["signature"] as? String, let signature = Data(base64Encoded: encoded),
      signature.count == 64, key.isValidSignature(signature, for: Data(message.utf8))
    else { throw Refusal(message: "The update's signature does not verify.") }
    guard code > installed! else {
      throw Refusal(message: "The update (\(code)) is not newer than the installed release (\(installed!)).")
    }
    guard let handle = try? FileHandle(forReadingFrom: archive) else {
      throw Refusal(message: "The update archive cannot be read.")
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    var read: Int64 = 0
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      read += Int64(chunk.count)
      if read > size { break }
      hasher.update(data: chunk)
    }
    guard read == size, hex(hasher.finalize()) == sha256 else {
      throw Refusal(message: "The downloaded update does not match its signed size and SHA-256.")
    }
    return Verified(version: version, versionCode: code, size: size, sha256: sha256)
  }
}
