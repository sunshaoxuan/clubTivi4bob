import Cocoa

// Isolated native regression window. No installed BobTV app or data is changed.
// --legacy reproduces the previous floating-level / native-Escape sequence.
final class FullscreenCycleTest: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let legacy = CommandLine.arguments.contains("--legacy")
  var window: NSWindow!
  var cycle = 0
  var phase = "starting"
  var timeout: Timer?
  var finished = false

  func report(_ event: String) {
    let payload: [String: Any] = [
      "event": event, "legacy": legacy, "cycle": cycle,
      "phase": phase, "fullscreen": window?.styleMask.contains(.fullScreen) ?? false,
      "level": window?.level.rawValue ?? -1,
      "collectionBehavior": window?.collectionBehavior.rawValue ?? 0
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 800, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "BobTV full-screen regression test"
    window.delegate = self
    window.isReleasedWhenClosed = false
    let label = NSTextField(labelWithString: "BobTV 原生全屏循环测试\n测试结束后此窗口会自动关闭")
    label.alignment = .center
    label.font = NSFont.systemFont(ofSize: 24)
    label.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
    ])
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.enter() }
  }

  func enter() {
    guard !finished else { return }
    phase = "entering"
    // Keep the same automatic fullscreen role as BobTV's MainMenu.xib. Only
    // change the window level so legacy/fixed runs isolate that difference.
    if !legacy { window.level = .normal }
    report("request_enter")
    armTimeout()
    window.toggleFullScreen(nil)
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    timeout?.invalidate()
    if legacy { window.level = .floating }
    phase = "fullscreen"
    report("did_enter")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      // This native exit has no player-route owner, matching Escape on the
      // channel page after transferring the fullscreen window to it.
      self.phase = "leaving"
      self.report("request_native_exit")
      self.armTimeout()
      self.window.toggleFullScreen(nil)
    }
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    timeout?.invalidate()
    phase = "ordinary"
    report("did_exit")
    cycle += 1
    if cycle >= 4 { finish(0, "passed"); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.enter() }
  }

  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    finish(1, "native_entry_failed")
  }

  func windowDidFailToExitFullScreen(_ window: NSWindow) {
    finish(1, "native_exit_failed")
  }

  func armTimeout() {
    timeout?.invalidate()
    timeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
      self.finish(1, "native_transition_timeout")
    }
  }

  func finish(_ code: Int32, _ event: String) {
    guard !finished else { return }
    finished = true
    timeout?.invalidate()
    report(event)
    window.level = .normal
    window.orderOut(nil)
    exit(code)
  }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let test = FullscreenCycleTest()
application.delegate = test
application.run()
