// BobTV macOS-only compatibility repair for Flutter external RGBA textures.
// Flutter issue #157379: a CVMetalTexture must outlive GPU use of its texture.
// A distinct, zero-copy Metal view owns the CV backing through an association.
// No association is placed on the CV-owned original (which would form a cycle).
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstring>

static std::atomic<int> liveBackings{0};
static std::atomic<uint64_t> wrappedFrames{0};
@interface BobTVMetalBacking : NSObject {
  CVMetalTextureRef _cvTexture;
  CVPixelBufferRef _pixelBuffer;
}
- (instancetype)initWithTexture:(CVMetalTextureRef)texture buffer:(CVPixelBufferRef)buffer;
@end
@implementation BobTVMetalBacking
- (instancetype)initWithTexture:(CVMetalTextureRef)texture buffer:(CVPixelBufferRef)buffer {
  if ((self = [super init])) {
    _cvTexture = (CVMetalTextureRef)CFRetain(texture);
    _pixelBuffer = CVPixelBufferRetain(buffer);
    ++liveBackings;
  }
  return self;
}
- (void)dealloc {
  CFRelease(_cvTexture);
  CVPixelBufferRelease(_pixelBuffer);
  --liveBackings;
}
@end

static char backingKey;
extern "C" id<MTLTexture> BobTVCreateOwnedMetalView(CVMetalTextureCacheRef cache,
                                                   CVPixelBufferRef buffer) {
  CVMetalTextureRef cvTexture = nullptr;
  if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache,
      buffer, nullptr, MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(buffer),
      CVPixelBufferGetHeight(buffer), 0, &cvTexture) != kCVReturnSuccess) return nil;
  id<MTLTexture> original = CVMetalTextureGetTexture(cvTexture);
  id<MTLTexture> view = [original newTextureViewWithPixelFormat:original.pixelFormat];
  if (view && view != original) {
    BobTVMetalBacking *backing = [[BobTVMetalBacking alloc]
        initWithTexture:cvTexture buffer:buffer];
    objc_setAssociatedObject(view, &backingKey, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  } else {
    view = nil; // Never expose the prematurely released CV-owned texture.
  }
  CFRelease(cvTexture);
  return view;
}
extern "C" int BobTVLiveMetalBackings(void) { return liveBackings.load(); }

// Pinned Flutter embedder external-texture ABI. Refuse incompatible runtimes.
struct BobTVExternalTexture {
  size_t struct_size, width, height;
  int pixel_format;
  size_t num_textures;
  const void **textures;
  int yuv_color_space;
};
@interface BobTVMetalFrame : NSObject {
 @public
  const void *_handle;
}
@property(nonatomic, strong) id<MTLTexture> texture;
@end
@implementation BobTVMetalFrame
@end
@protocol BobTVMetalContext
@property(nonatomic, readonly) CVMetalTextureCacheRef textureCache;
@end

static char frameKey;
static Ivar contextIvar, sourceIvar;
static BOOL (*originalPopulate)(id, SEL, CVPixelBufferRef, BobTVExternalTexture *);
static BOOL populateOwned(id self, SEL selector, CVPixelBufferRef buffer,
                          BobTVExternalTexture *out) {
  id source = object_getIvar(self, sourceIvar);
  if (![NSStringFromClass([source class]) hasSuffix:@"SafeResizableTexture"]) {
    return originalPopulate(self, selector, buffer, out);
  }
  if (!out || out->struct_size < sizeof(BobTVExternalTexture) ||
      CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return NO;
  id<BobTVMetalContext> context = object_getIvar(self, contextIvar);
  id<MTLTexture> view = BobTVCreateOwnedMetalView(context.textureCache, buffer);
  if (!view) return NO;
  BobTVMetalFrame *frame = [BobTVMetalFrame new];
  frame.texture = view;
  frame->_handle = (__bridge const void *)view;
  // Keep the callback's handle array valid until the next raster callback.
  // Thereafter the engine/GPU retain the view and its backing independently.
  objc_setAssociatedObject(self, &frameKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  out->width = CVPixelBufferGetWidth(buffer);
  out->height = CVPixelBufferGetHeight(buffer);
  out->pixel_format = 1; // kRGBA
  out->num_textures = 1;
  // Ivar address is stable throughout the retained frame lifetime.
  out->textures = &frame->_handle;
  const uint64_t count = ++wrappedFrames;
  if (count == 1 || count % 3000 == 0) {
    NSLog(@"[BobTV] Owned Metal frames=%llu liveBackings=%d", count, liveBackings.load());
  }
  return YES;
}

@interface BobTVMetalLifetimeRepair : NSObject
@end
@implementation BobTVMetalLifetimeRepair
+ (void)load {
  @autoreleasepool {
    Class cls = NSClassFromString(@"FlutterExternalTexture");
    SEL sel = NSSelectorFromString(@"populateTextureFromRGBAPixelBuffer:textureOut:");
    Method method = class_getInstanceMethod(cls, sel);
    contextIvar = class_getInstanceVariable(cls, "_darwinMetalContext");
    sourceIvar = class_getInstanceVariable(cls, "_texture");
    if (!method || !contextIvar || !sourceIvar || method_getNumberOfArguments(method) != 4) {
      NSLog(@"[BobTV] Metal lifetime adapter unavailable for this Flutter runtime");
      return;
    }
    char result[8], argument[32];
    method_getReturnType(method, result, sizeof(result));
    method_getArgumentType(method, 2, argument, sizeof(argument));
    char outputArgument[128];
    method_getArgumentType(method, 3, outputArgument, sizeof(outputArgument));
    if ((strcmp(result, "c") && strcmp(result, "B")) || argument[0] != '^' ||
        outputArgument[0] != '^' || ivar_getTypeEncoding(contextIvar)[0] != '@' ||
        ivar_getTypeEncoding(sourceIvar)[0] != '@') {
      NSLog(@"[BobTV] Metal lifetime adapter refused incompatible method ABI");
      return;
    }
    originalPopulate = (decltype(originalPopulate))method_setImplementation(method, (IMP)populateOwned);
    NSLog(@"[BobTV] Owned Metal frame lifetime adapter installed");
  }
}
@end
