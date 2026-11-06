import Cocoa
import FlutterMacOS

/// The single application window and its `cloud.anj/window` channel
/// (lib/platform/macos/macos_window.dart), spec #31 M3:
///
/// - Dart -> runner: `show` (the window comes forward and the Dock icon
///   returns), `hide` (closed to the menu bar: the window is ordered out and
///   the app becomes an accessory, with no Dock icon), `exit` (sync has
///   stopped: AppKit may terminate);
/// - runner -> Dart: `close` (the close button; Dart decides between hiding
///   and quitting, as GTK's delete event does on Linux), `quit` (AppKit's
///   terminate request: Cmd-Q, the app and Dock menus, a quit Apple event,
///   logout), `activate` (a LaunchServices reopen: Dock, Finder, `open -a`).
///
/// A login start (`--background`, decision #134 (2)) shows neither the
/// window nor the Dock icon until Dart's lifecycle asks for them.
///
/// The main menu (MainMenu.xib, spec #31 M5) is the standard Mac one: the
/// app menu (About, Services, Hide, Hide Others, Show All, Quit), File with
/// Close Window (Cmd-W, the close button's path), Edit, View (full screen),
/// Window and Help. Edit's commands go to the focused Flutter text field
/// over `cloud.anj/edit` (lib/platform/macos/macos_edit_menu.dart) as the
/// same intents Cmd-X, Cmd-C, Cmd-V, Cmd-A, Cmd-Z and Shift-Cmd-Z raise,
/// so a menu click and its keys always do the same thing. They are enabled
/// only while a text field has focus.
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowChannel: FlutterMethodChannel?
  private var editChannel: FlutterMethodChannel?
  /// A Flutter text field has keyboard focus (Dart reports `focus`).
  private var textFocused = false
  private(set) var integration: DesktopIntegration?
  /// A terminate request is waiting for Dart (`NSTerminateLater`).
  private var terminationPending = false
  /// Dart has stopped sync: the next terminate request proceeds.
  private var quitApproved = false
  /// A login start's invisible first appearance is still to be undone.
  private var backgroundHidePending = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    let channel = FlutterMethodChannel(name: "cloud.anj/window", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(FlutterError(code: "gone", message: "No window", details: nil))
        return
      }
      window.handle(call, result: result)
    }
    windowChannel = channel
    let edit = FlutterMethodChannel(name: "cloud.anj/edit", binaryMessenger: messenger)
    edit.setMethodCallHandler { [weak self] call, result in
      guard let window = self else { result(nil); return }
      switch call.method {
      case "focus":
        window.textFocused = call.arguments as? Bool ?? false
        window.updateEditItems()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    editChannel = edit
    integration = DesktopIntegration(messenger: messenger)
    self.delegate = self
    // FlutterAppDelegate names the APP_NAME items in willFinishLaunching;
    // the menu is completed after that.
    NotificationCenter.default.addObserver(
      self, selector: #selector(completeMainMenu(_:)),
      name: NSApplication.didFinishLaunchingNotification, object: nil)

    super.awakeFromNib()
    // The Linux window's default size (1280x720, MainMenu.xib), centred so
    // it fits a 13-inch MacBook screen.
    center()

    // MainMenu.xib does not show the window at launch; this does, unless
    // this is a login start.
    if CommandLine.arguments.contains("--background") {
      NSApp.setActivationPolicy(.accessory)
      // Flutter launches its engine when the view first appears
      // (FlutterViewController.viewWillAppear), so the window is ordered in
      // once, fully transparent and not key, then out on the next turn of
      // the run loop. Nothing is seen; the engine keeps running, as it does
      // when the window is closed to the menu bar.
      alphaValue = 0
      ignoresMouseEvents = true
      backgroundHidePending = true
      orderFront(nil)
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.backgroundHidePending else { return }
        self.backgroundHidePending = false
        self.orderOut(nil)
        self.alphaValue = 1
        self.ignoresMouseEvents = false
      }
    } else {
      makeKeyAndOrderFront(nil)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "show":
      if backgroundHidePending {
        backgroundHidePending = false
        alphaValue = 1
        ignoresMouseEvents = false
      }
      NSApp.setActivationPolicy(.regular)
      NSApp.activate()
      makeKeyAndOrderFront(nil)
      result(nil)
    case "hide":
      orderOut(nil)
      NSApp.setActivationPolicy(.accessory)
      result(nil)
    case "exit":
      result(nil)
      if terminationPending {
        finishTermination()
      } else {
        quitApproved = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
      }
    case "debugPerform":
      #if DEBUG
        result(integration?.debugPerform(call.arguments as? String, window: self))
      #else
        result(FlutterMethodNotImplemented)
      #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// AppKit's terminate request (AppDelegate.applicationShouldTerminate).
  /// Sync stops first: Dart takes the Quit path and answers with `exit`.
  /// The wait is capped from the moment AppKit is told to wait, so a Dart
  /// side that never answers cannot hold a logout or Quit forever.
  func terminationRequested() -> NSApplication.TerminateReply {
    if quitApproved { return .terminateNow }
    // A second request while the first waits stays pending with it; the
    // one reply (from `exit`, the cap or a refusal) answers AppKit.
    if terminationPending { return .terminateLater }
    guard let channel = windowChannel else { return .terminateNow }
    terminationPending = true
    // Never longer than the worker's stop bound (20 s) plus closing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.finishTermination()
    }
    channel.invokeMethod("quit", arguments: nil) { [weak self] reply in
      // Dart took it (true): wait for `exit`. Nothing listens yet (early
      // start) or Dart declined: quit now.
      if (reply as? Bool) != true { self?.finishTermination() }
    }
    return .terminateLater
  }

  /// Answers the pending terminate request once.
  private func finishTermination() {
    guard terminationPending else { return }
    quitApproved = true
    terminationPending = false
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  /// A LaunchServices reopen of the running app.
  func reopenRequested() {
    windowChannel?.invokeMethod("activate", arguments: nil)
  }

  // MARK: Main menu (spec #31 M5)

  /// Edit's items, by the standard action MainMenu.xib gives them, and the
  /// command name Dart maps to a text-editing intent.
  static let editCommands: [(Selector, String)] = [
    (Selector(("undo:")), "undo"),
    (Selector(("redo:")), "redo"),
    (#selector(NSText.cut(_:)), "cut"),
    (#selector(NSText.copy(_:)), "copy"),
    (#selector(NSText.paste(_:)), "paste"),
    (#selector(NSText.selectAll(_:)), "selectAll"),
  ]

  private var editItems: [NSMenuItem] = []

  @objc private func completeMainMenu(_ notification: Notification) {
    guard let main = NSApp.mainMenu else { return }
    if let edit = main.item(withTitle: "Edit")?.submenu {
      // Enabled by Dart's focus report, not by the responder chain: the
      // field editor AppKit sees is not the text Flutter shows.
      edit.autoenablesItems = false
      for item in edit.items {
        guard let action = item.action,
          let name = Self.editCommands.first(where: { $0.0 == action })?.1
        else { continue }
        item.action = #selector(performEditCommand(_:))
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("edit:\(name)")
        editItems.append(item)
      }
      updateEditItems()
    }
    if main.item(withTitle: "File") == nil {
      let file = NSMenu(title: "File")
      let close = NSMenuItem(
        title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
      close.identifier = NSUserInterfaceItemIdentifier("file:close")
      file.addItem(close)
      let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
      item.submenu = file
      main.insertItem(item, at: min(1, main.numberOfItems))
    }
  }

  private func updateEditItems() {
    for item in editItems { item.isEnabled = textFocused }
  }

  @objc private func performEditCommand(_ sender: NSMenuItem) {
    guard let id = sender.identifier?.rawValue, id.hasPrefix("edit:") else { return }
    editChannel?.invokeMethod("perform", arguments: String(id.dropFirst("edit:".count)))
  }

  #if DEBUG
    /// The main menu as a user sees it, for the M5 checks
    /// (integration_test/macos_ui_test.dart).
    func debugMainMenu() -> [[String: Any]] {
      guard let main = NSApp.mainMenu else { return [] }
      return main.items.map { top in
        [
          "title": top.title,
          "items": (top.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map { item in
            [
              "title": item.title,
              "key": item.keyEquivalent,
              "command": item.keyEquivalentModifierMask.contains(.command),
              "enabled": item.isEnabled,
              "id": item.identifier?.rawValue ?? "",
            ] as [String: Any]
          },
        ] as [String: Any]
      }
    }

    /// Performs a main-menu item exactly as a click does.
    func debugPerformMenuItem(_ id: String) -> Bool {
      for top in NSApp.mainMenu?.items ?? [] {
        guard let menu = top.submenu,
          let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == id })
        else { continue }
        menu.performActionForItem(at: index)
        return true
      }
      return false
    }

    /// Sends Cmd+<key> through AppKit's own key handling (key equivalents,
    /// then the window), as the keyboard does. Reports whether the window
    /// was key, without which AppKit routes no key event to it.
    func debugCommandKey(_ key: String) -> [String: Any] {
      let codes: [String: UInt16] = ["a": 0, "c": 8, "f": 3, "v": 9, "w": 13, "x": 7, "z": 6]
      guard let code = codes[key] else { return ["sent": false] }
      NSApp.activate()
      makeKeyAndOrderFront(nil)
      let wasKey = isKeyWindow
      let time = ProcessInfo.processInfo.systemUptime
      let number = windowNumber
      func event(
        _ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ chars: String,
        _ keyCode: UInt16
      ) -> NSEvent? {
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: time,
          windowNumber: number, context: nil, characters: chars,
          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
      }
      let events = [
        event(.flagsChanged, [.command], "", 55),
        event(.keyDown, [.command], key, code),
        event(.keyUp, [.command], key, code),
        event(.flagsChanged, [], "", 55),
      ]
      for item in events.compactMap({ $0 }) { NSApp.sendEvent(item) }
      return ["sent": true, "keyWindow": wasKey]
    }
  #endif

  // The close button is a request Dart may turn into a hide, exactly like
  // the GTK runner's delete event on Linux. Without Dart, the app quits.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let channel = windowChannel else {
      NSApp.terminate(nil)
      return false
    }
    channel.invokeMethod("close", arguments: nil) { reply in
      if reply is FlutterError || (reply as? NSObject) === FlutterMethodNotImplemented {
        NSApp.terminate(nil)
      }
    }
    return false
  }
}
