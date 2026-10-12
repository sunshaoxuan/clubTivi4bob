import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
