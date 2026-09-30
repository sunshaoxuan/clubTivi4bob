#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
  func resize(_ size: CGSize)
  func render(_ size: CGSize)
  func disposeRenderingResources()
}

// Other platforms retain upstream lifecycle behavior. macOS hardware and
// software textures explicitly override this release barrier.
extension ResizableTextureProtocol {
  public func disposeRenderingResources() {}
}
