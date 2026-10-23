// Prints the capture-sharing state of every window owned by a process and
// exits 1 if any on-screen window can be captured. sharingState 0 means
// NSWindow.sharingType == .none (excluded from screenshots / screen sharing).
// Reading the sharing state needs no Screen Recording permission; window names
// do, so they may print empty.
// Off-screen capturable windows are reported but not failed: on CI these are
// AppKit's per-display menu-bar backing windows, which are not in NSApp.windows
// (so the app cannot set their sharingType) and hold no app content.
//
//   swift scripts/window-sharing.swift <pid>
import CoreGraphics
import Foundation

guard let arg = CommandLine.arguments.dropFirst().first, let pid = Int(arg) else {
    FileHandle.standardError.write(Data("usage: window-sharing.swift <pid>\n".utf8))
    exit(2)
}
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0, capturable = 0, onscreenCapturable = 0
for w in info where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    count += 1
    let share = w[kCGWindowSharingState as String] as? Int ?? -1
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    if share != 0 { capturable += 1; if onscreen { onscreenCapturable += 1 } }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window id=\(w[kCGWindowNumber as String] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?") "
        + "onscreen=\(onscreen) sharingState=\(share) "
        + "size=\(b["Width"] ?? 0)x\(b["Height"] ?? 0) name='\(w[kCGWindowName as String] as? String ?? "")'")
}
print("windows=\(count) capturable=\(capturable) onscreen_capturable=\(onscreenCapturable)")
exit(count > 0 && onscreenCapturable == 0 ? 0 : 1)
