#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cstring>
extern "C" id<MTLTexture> BobTVCreateOwnedMetalView(CVMetalTextureCacheRef, CVPixelBufferRef);
extern "C" int BobTVLiveMetalBackings(void);
extern "C" void BobTVReleaseMetalFrameLease(void);
struct TestExternalTexture {
  size_t struct_size, width, height;
  int pixel_format;
  size_t num_textures;
  const void **textures;
  int yuv_color_space;
};
@interface TestSafeResizableTexture : NSObject
@end
@implementation TestSafeResizableTexture
@end
@interface TestMetalContext : NSObject
@property(nonatomic) CVMetalTextureCacheRef textureCache;
@end
@implementation TestMetalContext
@end
@protocol TestFlutterTexture
- (id)initWithFlutterTexture:(id)texture darwinMetalContext:(id)context;
- (BOOL)populateTextureFromRGBAPixelBuffer:(CVPixelBufferRef)buffer
                              textureOut:(TestExternalTexture *)out;
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    assert(device);
    CVMetalTextureCacheRef cache = nullptr;
    assert(CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache) == kCVReturnSuccess);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (argc > 1) {
      Class cls = NSClassFromString(@"FlutterExternalTexture");
      assert(cls);
      @autoreleasepool {
        TestMetalContext *context = [TestMetalContext new];
        context.textureCache = cache;
        id<TestFlutterTexture> external = nil;
        id<MTLTexture> heldFrame = nil;
        for (int i = 0; i < 500; ++i) {
          TestExternalTexture out = {};
          out.struct_size = sizeof(out);
          @autoreleasepool {
            external = [(id<TestFlutterTexture>)[cls alloc]
                initWithFlutterTexture:[TestSafeResizableTexture new]
                darwinMetalContext:context];
            CVPixelBufferRef buffer = nullptr;
            NSDictionary *attrs = @{(id)kCVPixelBufferMetalCompatibilityKey: @YES,
              (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
            assert(CVPixelBufferCreate(nullptr, 128, 72, kCVPixelFormatType_32BGRA,
              (__bridge CFDictionaryRef)attrs, &buffer) == kCVReturnSuccess);
            assert([external populateTextureFromRGBAPixelBuffer:buffer textureOut:&out]);
            assert(out.width == 128 && out.num_textures == 1 && out.pixel_format == 1);
            // Unregister may destroy FlutterExternalTexture between returning
            // from this callback and the engine retaining out.textures[0].
            external = nil;
            CVPixelBufferRelease(buffer);
          }
          assert(BobTVLiveMetalBackings() == (heldFrame ? 2 : 1));
          heldFrame = (__bridge id<MTLTexture>)out.textures[0];
          assert(heldFrame.width == 128);
          assert(BobTVLiveMetalBackings() == 1);
        }
        external = nil;
        assert(heldFrame.width == 128 && BobTVLiveMetalBackings() == 1);
        BobTVReleaseMetalFrameLease();
        heldFrame = nil;
      }
      assert(BobTVLiveMetalBackings() == 0);
      NSLog(@"PASS: installed Flutter runtime adapter, 500 callbacks, unregister before engine retention");
    }
    // Two active streams, resizing and immediately dropping producer buffers.
    for (int frame = 0; frame < 2000; ++frame) {
      @autoreleasepool {
        for (int stream = 0; stream < 2; ++stream) {
          size_t width = frame % 2 ? 128 : 256;
          CVPixelBufferRef buffer = nullptr;
          NSDictionary *attrs = @{(id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
          assert(CVPixelBufferCreate(nullptr, width, 72, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attrs, &buffer) == kCVReturnSuccess);
          CVPixelBufferLockBaseAddress(buffer, 0);
          memset(CVPixelBufferGetBaseAddress(buffer), frame % 255,
            CVPixelBufferGetBytesPerRow(buffer) * 72);
          CVPixelBufferUnlockBaseAddress(buffer, 0);
          id<MTLTexture> view = BobTVCreateOwnedMetalView(cache, buffer);
          assert(view && view.width == width && BobTVLiveMetalBackings() >= 1);
          CVPixelBufferRelease(buffer);
          // GPU work retains the view after the producer has been disposed.
          id<MTLCommandBuffer> command = [queue commandBuffer];
          id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
          MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:72 mipmapped:NO];
          id<MTLTexture> target = [device newTextureWithDescriptor:descriptor];
          [blit copyFromTexture:view sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, 72, 1)
            toTexture:target destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
          // Discrete Intel/AMD Macs need an explicit GPU-to-CPU transfer for
          // managed textures before getBytes can validate the rendered data.
          if (target.storageMode == MTLStorageModeManaged) {
            [blit synchronizeResource:target];
          }
          [blit endEncoding];
          view = nil;
          assert(BobTVLiveMetalBackings() >= 1);
          CVMetalTextureCacheFlush(cache, 0);
          [command commit];
          [command waitUntilCompleted];
          assert(command.status == MTLCommandBufferStatusCompleted);
          unsigned char pixel[4];
          [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
          if (pixel[0] != frame % 255) {
            NSLog(@"Readback mismatch frame=%d actual=%u expected=%d device=%@ storage=%lu",
              frame, pixel[0], frame % 255, device.name, (unsigned long)target.storageMode);
            abort();
          }
        }
      }
      // A completed Metal queue can retire its last resources asynchronously.
      // An ownership cycle would accumulate across these 2,000 rounds.
      assert(BobTVLiveMetalBackings() <= 4);
    }
    queue = nil;
    CVMetalTextureCacheFlush(cache, 0);
    CFRelease(cache);
    for (int attempt = 0; BobTVLiveMetalBackings() != 0 && attempt < 5000; ++attempt) {
      [NSThread sleepForTimeInterval:0.001];
    }
    if (BobTVLiveMetalBackings() != 0) {
      NSLog(@"FAIL: GPU queue cleanup retained %d backing objects", BobTVLiveMetalBackings());
    }
    assert(BobTVLiveMetalBackings() == 0);
    NSLog(@"PASS: 4000 owned frames, two streams, resize, GPU readback, no retained backings");
  }
}
