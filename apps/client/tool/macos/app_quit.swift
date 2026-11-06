// Asks a running app to quit the way the Dock's Quit and logout do (a quit
// Apple event through NSRunningApplication.terminate), never by a signal.
// Used by session_check.sh (spec #31 M3). Usage: app_quit.swift <pid>
// Exit 0 when the request was sent, 1 when macOS refused to send it.
import AppKit

let pid = CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) ?? -1 : -1
guard let app = NSRunningApplication(processIdentifier: pid) else {
  print("no running application with pid \(pid)")
  exit(1)
}
exit(app.terminate() ? 0 : 1)
