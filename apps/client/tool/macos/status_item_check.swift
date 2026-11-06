// Lists the menu-bar (status) windows of a process as JSON lines, with
// their on-screen bounds; exit 1 when there is none. Used by
// session_check.sh (spec #31 M3). Usage: status_item_check.swift <pid>
import AppKit
import CoreGraphics

let pid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? -1 : -1
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let status = Int(CGWindowLevelForKey(.statusWindow))
let matches = windows.filter {
  ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == status
}
for window in matches {
  let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let result: [String: Any] = ["id": window[kCGWindowNumber as String] ?? -1, "bounds": bounds]
  if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  {
    print(text)
  }
}
exit(matches.isEmpty ? 1 : 0)
