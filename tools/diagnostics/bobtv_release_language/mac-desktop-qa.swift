import Foundation
import ApplicationServices
import Vision
import AppKit

let args = CommandLine.arguments
switch args[1] {
case "permissions":
    print("event=\(CGPreflightPostEventAccess()) capture=\(CGPreflightScreenCaptureAccess())")
case "window":
    let pid = Int32(args[2])!
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for row in list where row[kCGWindowOwnerPID as String] as? Int32 == pid {
        if let id = row[kCGWindowNumber as String], let bounds = row[kCGWindowBounds as String] as? [String: Any], let width = bounds["Width"] as? Double, width > 300, row[kCGWindowLayer as String] as? Int == 0 {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "bounds": bounds])
            print(String(data: data, encoding: .utf8)!)
            exit(0)
        }
    }
    exit(1)
case "click":
    let x = Double(args[2])!
    let y = Double(args[3])!
    let pid = Int32(args[4])!
    guard let app = NSRunningApplication(processIdentifier: pid) else { exit(4) }
    app.activate(options: [.activateIgnoringOtherApps])
    usleep(160000)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { exit(5) }
    let point = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
case "ocr":
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    if args.count > 3 { request.recognitionLanguages = Array(args.dropFirst(3)) }
    try VNImageRequestHandler(url: URL(fileURLWithPath: args[2])).perform([request])
    let result = (request.results ?? []).compactMap { row -> [String: Any]? in
        guard let text = row.topCandidates(1).first?.string else { return nil }
        return ["text": text, "x": row.boundingBox.midX, "y": 1-row.boundingBox.midY]
    }
    print(String(data: try JSONSerialization.data(withJSONObject: result),encoding: .utf8)!)
default: exit(2)
}
