import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// `--verify-update` (spec #40 R2) runs before AppKit: no window, no
  /// engine; everything else starts the app as before.
  static func main() {
    if let status = ReleaseVerifier.runIfRequested(CommandLine.arguments) {
      exit(status)
    }
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  private var window: MainFlutterWindow? { mainFlutterWindow as? MainFlutterWindow }

  // The window's close button asks Dart (MainFlutterWindow), and Dart's
  // DesktopLifecycle decides; closing the last window never quits.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Every terminate request (Cmd-Q and the app menu's Quit, the Dock's
  // Quit, a quit Apple event, logout) is the explicit Quit: sync stops
  // before AppKit terminates (spec #31 M3). This replaces Flutter's own
  // exit-request handling, which on macOS would turn Quit into Close.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return window?.terminationRequested() ?? .terminateNow
  }

  // LaunchServices reopen (Dock, Finder, `open -a`) shows the running
  // instance's window, also while it is closed to the menu bar.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    window?.reopenRequested()
    return false
  }
}
