import Foundation

// Compile the production manager without Flutter to test completion ownership.
public protocol FlutterTextureRegistry {}
public struct VideoOutputConfiguration {}
public class VideoOutput {
  public typealias TextureUpdateCallback = (Int64, Int64, Int64) -> Void
  static var instances = [Int64: VideoOutput]()
  var completions = [() -> Void]()
  init(handle: Int64, configuration: VideoOutputConfiguration,
       registry: FlutterTextureRegistry, textureUpdateCallback: @escaping TextureUpdateCallback) {
    Self.instances[handle] = self
  }
  func setSize(width: Int64?, height: Int64?) {}
  func dispose(completion: @escaping () -> Void) { completions.append(completion) }
  func finish() {
    let pending = completions
    completions.removeAll()
    pending.forEach { $0() }
  }
}
class Registry: FlutterTextureRegistry {}

@main
struct ManagerTests {
  static func main() {
    let manager = VideoOutputManager(registry: Registry())
    for handle in 0..<100 {
      let id = Int64(handle)
      manager.create(handle: id, configuration: VideoOutputConfiguration(), textureUpdateCallback: { _, _, _ in })
      var replies = 0
      manager.destroy(handle: id) { replies += 1 }
      manager.destroy(handle: id) { replies += 1 }
      precondition(replies == 0, "duplicate destruction replied before release completed")
      VideoOutput.instances[id]!.finish()
      precondition(replies == 2)
      manager.destroy(handle: id) { replies += 1 }
      precondition(replies == 3)
      VideoOutput.instances[id] = nil
    }
    print("PASS: 100 duplicate Mac disposal requests wait for actual resource release")
  }
}
