import Foundation
import FlutterMacOS

// Deliberately retain unregistered textures, as a renderer may do while
// finishing a frame. MPV destruction must not depend on their ARC lifetime.
final class RetainingRegistry: NSObject, FlutterTextureRegistry {
  var retained = [FlutterTexture]()
  private var nextID: Int64 = 0
  func register(_ texture: FlutterTexture) -> Int64 {
    retained.append(texture)
    nextID += 1
    return nextID
  }
  func unregisterTexture(_ textureId: Int64) {}
  func textureFrameAvailable(_ textureId: Int64) {}
}

@main
struct NativeVideoDisposalTests {
  static func waitUntil(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(predicate(), "Native render lifecycle acknowledgement timed out")
  }

  static func main() {
    let hardware = ProcessInfo.processInfo.environment["BOBTV_TEST_HARDWARE"] == "1"
    let registry = RetainingRegistry()
    let manager = VideoOutputManager(registry: registry)
    for _ in 0..<20 {
      guard let player = mpv_create() else { fatalError("mpv_create failed") }
      MPVHelpers.checkError(mpv_set_option_string(player, "vo", "libmpv"))
      MPVHelpers.checkError(mpv_initialize(player))
      let handle = Int64(Int(bitPattern: player))
      var ready = false
      manager.create(handle: handle,
        configuration: VideoOutputConfiguration(width: nil, height: nil,
          enableHardwareAcceleration: hardware),
        textureUpdateCallback: { _, _ in ready = true })
      waitUntil { ready }
      var released = false
      manager.destroy(handle: handle, completion: { released = true })
      waitUntil { released }
      // The unpatched plugin aborts here if a texture retains its context.
      mpv_terminate_destroy(player)
    }
    precondition(registry.retained.count == 20)
    registry.retained.removeAll()
    print("PASS: 20 native MPV destructions while Flutter textures remain retained")
  }
}
