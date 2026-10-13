import Cocoa
import CoreGraphics

guard let raw = CommandLine.arguments.dropFirst().first,
      let targetPid = Int32(raw) else { fatalError("Pass verified BobTV PID") }
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let includeAllLevels = CommandLine.arguments.contains("--all-levels")
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == targetPid {
    guard let layer = window[kCGWindowLayer as String] as? Int,
          includeAllLevels || layer == 0 else { continue }
    let result: [String: Any] = [
        "pid": targetPid,
        "id": window[kCGWindowNumber as String] ?? 0,
        "level": layer,
        "bounds": window[kCGWindowBounds as String] ?? [:],
        "screenCaptureAllowed": CGPreflightScreenCaptureAccess()
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
