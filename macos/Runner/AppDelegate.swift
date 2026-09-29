import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var updateMarker: URL?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    prepareUpdateStartupMonitor()
    super.applicationWillFinishLaunching(notification)
  }

  private func prepareUpdateStartupMonitor() {
    guard let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first, let identifier = Bundle.main.bundleIdentifier,
      let shortVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
    let root = support.appendingPathComponent(identifier, isDirectory: true)
      .appendingPathComponent("Update", isDirectory: true)
    let candidate = root.appendingPathComponent("candidate.txt")
    let worker = root.appendingPathComponent("mac_worker.sh")
    guard let contents = try? String(contentsOf: candidate, encoding: .utf8),
      FileManager.default.fileExists(atPath: worker.path) else { return }
    let lines = contents.components(separatedBy: .newlines)
    guard lines.count >= 4, lines[0] == "\(shortVersion)+\(build)",
      URL(fileURLWithPath: lines[3]).standardizedFileURL.path ==
        Bundle.main.bundleURL.standardizedFileURL.path else { return }

    let processId = ProcessInfo.processInfo.processIdentifier
    let marker = root.appendingPathComponent("startup.marker")
    do {
      try "\(processId)".write(to: marker, atomically: true, encoding: .utf8)
      let monitor = Process()
      monitor.executableURL = URL(fileURLWithPath: "/bin/bash")
      monitor.arguments = [worker.path, "monitor", root.path,
                           Bundle.main.bundleURL.path, "\(processId)"]
      try monitor.run()
      updateMarker = marker
    } catch {
      try? FileManager.default.removeItem(at: marker)
    }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if let marker = updateMarker {
      let healthy = marker.deletingLastPathComponent()
        .appendingPathComponent("startup.healthy")
      let processId = ProcessInfo.processInfo.processIdentifier
      try? "\(processId)".write(to: healthy, atomically: true,
                                encoding: .utf8)
      try? FileManager.default.removeItem(at: marker)
    }
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
