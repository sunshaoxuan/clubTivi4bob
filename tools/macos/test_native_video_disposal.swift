import Foundation
import FlutterMacOS
import CoreVideo

// Deliberately retain unregistered textures, as a renderer may do while
// finishing a frame. MPV destruction must not depend on their ARC lifetime.
final class RetainingRegistry: NSObject, FlutterTextureRegistry {
  var retained = [FlutterTexture]()
  private var nextID: Int64 = 0
  var frames = 0
  func register(_ texture: FlutterTexture) -> Int64 {
    retained.append(texture)
    nextID += 1
    return nextID
  }
  func unregisterTexture(_ textureId: Int64) {}
  func textureFrameAvailable(_ textureId: Int64) {
    frames += 1
    // Consume ready buffers as Flutter's raster thread would. Otherwise a
    // three-buffer producer fills up and stops rendering new frames.
    _ = retained.last?.copyPixelBuffer()?.takeRetainedValue()
  }
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
    let liveFrames = ProcessInfo.processInfo.environment["BOBTV_TEST_LIVE_FRAMES"] == "1"
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bobtv-frames-\(UUID().uuidString).yuv")
    if liveFrames {
      var data = Data()
      for frame in 0..<40 {
        data.append(Data(repeating: UInt8(32 + frame * 4), count: 320 * 180))
        data.append(Data(repeating: 128, count: 320 * 180 / 2))
      }
      try! data.write(to: fixture)
    }
    defer { if liveFrames { try? FileManager.default.removeItem(at: fixture) } }
    let registry = RetainingRegistry()
    let manager = VideoOutputManager(registry: registry)
    for _ in 0..<20 {
      guard let player = mpv_create() else { fatalError("mpv_create failed") }
      MPVHelpers.checkError(mpv_set_option_string(player, "vo", "libmpv"))
      MPVHelpers.checkError(mpv_set_option_string(player, "ao", "null"))
      if liveFrames {
        MPVHelpers.checkError(mpv_set_option_string(player, "demuxer", "rawvideo"))
        MPVHelpers.checkError(mpv_set_option_string(player, "demuxer-rawvideo-w", "320"))
        MPVHelpers.checkError(mpv_set_option_string(player, "demuxer-rawvideo-h", "180"))
        MPVHelpers.checkError(mpv_set_option_string(player, "demuxer-rawvideo-mp-format", "yuv420p"))
        MPVHelpers.checkError(mpv_set_option_string(player, "demuxer-rawvideo-fps", "25"))
      }
      MPVHelpers.checkError(mpv_initialize(player))
      let handle = Int64(Int(bitPattern: player))
      var ready = false
      manager.create(handle: handle,
        configuration: VideoOutputConfiguration(width: liveFrames ? 320 : nil,
          height: liveFrames ? 180 : nil,
          enableHardwareAcceleration: hardware),
        textureUpdateCallback: { _, _ in ready = true })
      waitUntil { ready }
      if liveFrames {
        let framesBefore = registry.frames
        mpv_request_log_messages(player, "warn")
        MPVHelpers.checkError(mpv_command_string(player,
          "loadfile \(fixture.path)"))
        waitUntil {
          while let event = mpv_wait_event(player, 0), event.pointee.event_id != MPV_EVENT_NONE {
            if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
                let data = event.pointee.data {
              let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
              print(String(cString: message.text))
            }
          }
          return registry.frames >= framesBefore + 10
        }
        guard let frame = registry.retained.last?.copyPixelBuffer()?.takeRetainedValue()
          else { fatalError("Rendered video frame missing") }
        precondition(CVPixelBufferGetWidth(frame) == 320)
        precondition(CVPixelBufferGetHeight(frame) == 180)
      }
      var released = false
      manager.destroy(handle: handle, completion: { released = true })
      waitUntil { released }
      // The unpatched plugin aborts here if a texture retains its context.
      mpv_terminate_destroy(player)
    }
    precondition(registry.retained.count == 20)
    registry.retained.removeAll()
    print("PASS: 20 native MPV destructions while Flutter textures remain retained; liveFrames=\(liveFrames), frames=\(registry.frames)")
  }
}
