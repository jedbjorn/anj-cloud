// Automation and Accessibility consent of the calling process, without
// ever prompting (spec #31 M4, acceptance row 14). Runs ON mac-test:
//
//   swift tool/macos/automation_consent.swift <bundle id>...
//
// Prints one JSON object: "accessibility" (AXIsProcessTrusted, no prompt)
// and, per target, the Apple-event permission from
// AEDeterminePermissionToAutomateTarget with askUserIfNeeded false:
// "granted", "denied" (-1743), "wouldPrompt" (-1744, no decision yet),
// "notRunning" (-600: launch the target first) or "error <status>".
// The answer belongs to this process's responsible process (the SSH
// session, or the gui/<uid> job), so run it the way the editor harness runs.
import AppKit
import ApplicationServices
import CoreServices
import Foundation

var targets: [String: String] = [:]
for id in CommandLine.arguments.dropFirst() {
  let target = NSAppleEventDescriptor(bundleIdentifier: id)
  guard let desc = target.aeDesc else {
    targets[id] = "error no descriptor"
    continue
  }
  let status = AEDeterminePermissionToAutomateTarget(
    desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
  switch status {
  case noErr: targets[id] = "granted"
  case OSStatus(errAEEventNotPermitted): targets[id] = "denied"
  case OSStatus(errAEEventWouldRequireUserConsent): targets[id] = "wouldPrompt"
  case OSStatus(procNotFound): targets[id] = "notRunning"
  default: targets[id] = "error \(status)"
  }
}
let result: [String: Any] = [
  "accessibility": AXIsProcessTrusted(),
  "targets": targets,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
