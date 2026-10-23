// Prints the capture-sharing state of every window owned by a process and
// exits 1 if any of them can be captured. sharingState 0 means
// NSWindow.sharingType == .none (excluded from screenshots / screen sharing).
// Reading the sharing state needs no Screen Recording permission; window names
// do, so they may print empty.
//
//   swift scripts/window-sharing.swift <pid>
import CoreGraphics
import Foundation

guard let arg = CommandLine.arguments.dropFirst().first, let pid = Int(arg) else {
    FileHandle.standardError.write(Data("usage: window-sharing.swift <pid>\n".utf8))
    exit(2)
}
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0, capturable = 0
for w in info where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    count += 1
    let share = w[kCGWindowSharingState as String] as? Int ?? -1
    if share != 0 { capturable += 1 }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window id=\(w[kCGWindowNumber as String] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?") "
        + "onscreen=\(w[kCGWindowIsOnscreen as String] as? Bool ?? false) sharingState=\(share) "
        + "size=\(b["Width"] ?? 0)x\(b["Height"] ?? 0) name='\(w[kCGWindowName as String] as? String ?? "")'")
}
print("windows=\(count) capturable=\(capturable)")
exit(count > 0 && capturable == 0 ? 0 : 1)
