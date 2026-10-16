import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func performClose(_ sender: Any?) {
    NativeWindowAudit.record("window_perform_close", window: self, sender: sender)
    super.performClose(sender)
  }

  override func close() {
    NativeWindowAudit.record("window_close_committed", window: self)
    super.close()
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    if let display = self.screen ?? NSScreen.main {
      let available = display.visibleFrame
      let scale = max(1, display.backingScaleFactor)
      windowFrame.size.width = min(windowFrame.width, min(1920 / scale, available.width))
      windowFrame.size.height = min(windowFrame.height, min(1280 / scale, available.height))
      windowFrame.origin.x = min(max(windowFrame.minX, available.minX), available.maxX - windowFrame.width)
      windowFrame.origin.y = min(max(windowFrame.minY, available.minY), available.maxY - windowFrame.height)
    }
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

// Record intent before Flutter teardown; Dart callbacks may no longer be alive
// when applicationWillTerminate is delivered. No channel URLs or user input
// text are recorded. CGEvent source PID distinguishes injected input where the
// OS exposes it; absence of a PID is not proof of a specific human action.
enum NativeWindowAudit {
  static func record(_ event: String, window: NSWindow? = nil, sender: Any? = nil) {
    var item: [String: Any] = [
      "time": ISO8601DateFormatter().string(from: Date()),
      "event": event,
      "pid": ProcessInfo.processInfo.processIdentifier,
      "applicationActive": NSApp.isActive
    ]
    if let window = window {
      item["windowNumber"] = window.windowNumber
      item["nativeFullscreen"] = window.styleMask.contains(.fullScreen)
    }
    if let sender = sender { item["senderType"] = String(describing: type(of: sender)) }
    if let current = NSApp.currentEvent {
      item["currentEventType"] = current.type.rawValue
      item["currentEventTimestamp"] = current.timestamp
      if let cg = current.cgEvent {
        item["eventSourcePid"] = cg.getIntegerValueField(.eventSourceUnixProcessID)
      }
    }
    item["callStack"] = Array(Thread.callStackSymbols.prefix(16))
    guard let data = try? JSONSerialization.data(withJSONObject: item),
      let support = FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask).first,
      let identifier = Bundle.main.bundleIdentifier else { return }
    let directory = support.appendingPathComponent(identifier)
      .appendingPathComponent("logs")
    do {
      try FileManager.default.createDirectory(at: directory,
        withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("native-window-events.jsonl")
      if !FileManager.default.fileExists(atPath: file.path) {
        FileManager.default.createFile(atPath: file.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: file)
      defer { handle.closeFile() }
      handle.seekToEndOfFile()
      handle.write(data)
      handle.write(Data([10]))
    } catch { NSLog("BobTV native window audit unavailable") }
  }
}
