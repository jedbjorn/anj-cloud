// Lists the on-screen windows of the AnJ Cloud process as JSON lines; exit 1
// when there is none. Used by launch_check.sh. Usage: window_check.swift <pid>
import AppKit
import CoreGraphics

let pid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? -1 : -1
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let matches = windows.filter {
  ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
}
for window in matches {
  let result: [String: Any] = [
    "id": window[kCGWindowNumber as String] ?? -1,
    "owner": window[kCGWindowOwnerName as String] ?? "",
    "bounds": window[kCGWindowBounds as String] ?? [:],
    "alpha": window[kCGWindowAlpha as String] ?? 0,
  ]
  if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  {
    print(text)
  }
}
exit(matches.isEmpty ? 1 : 0)
