import Cocoa
import ApplicationServices
import CoreGraphics

// A PID-scoped acceptance probe for the installed BobTV, never other apps.
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let pid = Int32(arguments[0]),
      let app = NSRunningApplication(processIdentifier: pid),
      app.bundleIdentifier == "com.briconbric.bobtv",
      app.bundleURL?.standardizedFileURL.path == "/Users/shou/Applications/BobTV.app" else {
  fail("Pass the verified installed BobTV PID and action")
}
guard AXIsProcessTrusted() else { fail("Accessibility permission is unavailable") }
let application = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value
}

func applicationWindows() -> [AXUIElement] {
  if let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty { return windows }
  return ((attribute(application, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter {
    (attribute($0, kAXRoleAttribute) as? String) == kAXWindowRole
  }
}

func bounds(_ element: AXUIElement) -> [String: Double]? {
  guard let position = attribute(element, kAXPositionAttribute),
        let size = attribute(element, kAXSizeAttribute),
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
  var point = CGPoint.zero
  var dimensions = CGSize.zero
  AXValueGetValue(position as! AXValue, .cgPoint, &point)
  AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
  return ["x": point.x, "y": point.y, "width": dimensions.width, "height": dimensions.height]
}

var nodes = 0
func tree(_ element: AXUIElement, _ depth: Int = 0) -> [String: Any] {
  nodes += 1
  var item: [String: Any] = [:]
  for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
    if let value = attribute(element, name) {
      if let string = value as? String, !string.isEmpty { item[name] = String(string.prefix(250)) }
      else if let number = value as? NSNumber { item[name] = number }
    }
  }
  if let rect = bounds(element) { item["bounds"] = rect }
  if let full = attribute(element, "AXFullScreen") as? NSNumber { item["fullscreen"] = full }
  if depth < 14 && nodes < 500, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
    item["children"] = children.prefix(80).map { tree($0, depth + 1) }
  }
  return item
}

func activate() {
  guard CGPreflightPostEventAccess() else { fail("Input-event permission is unavailable") }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = true
  configuration.createsNewApplicationInstance = false
  NSWorkspace.shared.openApplication(at: app.bundleURL!, configuration: configuration) { _, _ in }
  let deadline = Date().addingTimeInterval(4)
  var stable = 0
  repeat {
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    let windows = applicationWindows()
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let ready = foreground && windows.contains { bounds($0) != nil }
    stable = ready ? stable + 1 : 0
    if stable >= 4 { break }
  } while Date() < deadline
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    fail("BobTV is not foreground; input was not sent")
  }
}

let action = arguments[1]
if action == "snapshot" {
  var names: CFArray?
  if let window = applicationWindows().first {
    AXUIElementCopyAttributeNames(window, &names)
  }
  let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    .map { ["id": $0[kCGWindowNumber as String] ?? 0,
            "level": $0[kCGWindowLayer as String] ?? -1,
            "bounds": $0[kCGWindowBounds as String] ?? [:],
            "onscreen": $0[kCGWindowIsOnscreen as String] ?? false] }
  let payload: [String: Any] = ["pid": pid, "windowAttributes": names as? [String] ?? [],
                              "axFrontmost": (attribute(application, kAXFrontmostAttribute) as? NSNumber)?.boolValue ?? false,
                              "workspaceFrontmostPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                              "applicationActive": app.isActive,
                              "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                              "windows": owned, "ui": tree(application)]
  let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
  print(String(data: data, encoding: .utf8)!)
} else if action == "escape" {
  activate()
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: down) else { fail("Cannot create Escape event") }
    event.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
  }
} else if ["move", "click", "double-click"].contains(action), arguments.count == 4,
          let x = Double(arguments[2]), let y = Double(arguments[3]) {
  activate()
  let point = CGPoint(x: x, y: y)
  let windows = applicationWindows()
  guard windows.contains(where: { window in
    guard let rect = bounds(window) else { return false }
    return CGRect(x: rect["x"]!, y: rect["y"]!, width: rect["width"]!, height: rect["height"]!).contains(point)
  }) else { fail("Click point is outside BobTV; input was not sent") }
  guard let movement = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) else {
    fail("Cannot create pointer movement")
  }
  movement.post(tap: .cghidEventTap)
  RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  if action == "move" { exit(0) }
  for click in 1...(action == "double-click" ? 2 : 1) {
    for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
      guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { fail("Cannot create click event") }
      event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.06)
    }
  }
} else {
  fail("Supported actions: snapshot, escape, move x y, click x y, double-click x y")
}
