#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>
#import "SimulatorFramebuffer.h"
#import <dlfcn.h>
#import <malloc/malloc.h>

@interface SimulatorFramebuffer (Testing)
- (void)startWithScreens:(NSArray *)screens
           frameHandler:(void (^)(CGImageRef, unsigned int))frameHandler
         failureHandler:(void (^)(NSError *))failureHandler;
- (void)setTestInputClient:(id)client messageBuilder:(void *)builder;
- (void)setTestWatchInputClient:(id)client simulatorKit:(void *)kit;
@end

// A CPU-backed surface implements IOSurface's public selectors without requiring a GUI session.
@interface TestSurface : NSObject
@property size_t width;
@property size_t height;
@property size_t bytesPerRow;
@property size_t allocationSize;
@property size_t planeCount;
@property OSType pixelFormat;
@property void *baseAddress;
@end

@implementation TestSurface
- (kern_return_t)lockWithOptions:(IOSurfaceLockOptions)options seed:(uint32_t *)seed { return KERN_SUCCESS; }
- (kern_return_t)unlockWithOptions:(IOSurfaceLockOptions)options seed:(uint32_t *)seed { return KERN_SUCCESS; }
- (void)dealloc { free(_baseAddress); }
@end

@interface TestBacklight : NSObject
@property int state;
@end

@implementation TestBacklight
@end

@interface TestScreen : NSObject
@property IOSurface *framebufferSurface;
@property unsigned int uiOrientation;
@property TestBacklight *backlight;
@property dispatch_queue_t callbackQueue;
@property (copy) void (^frameCallback)(void);
@property (copy) void (^propertiesCallback)(id);
@property dispatch_semaphore_t disconnected;
@end

@implementation TestScreen
- (id)screenProperties { return self; }
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                         callbackQueue:(dispatch_queue_t)queue
                         frameCallback:(void (^)(void))frame
               surfacesChangedCallback:(void (^)(IOSurface *, IOSurface *))surfaces
             propertiesChangedCallback:(void (^)(id))properties {
    @synchronized (self) {
        self.callbackQueue = queue;
        self.frameCallback = frame;
        self.propertiesCallback = properties;
    }
}
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid {
    @synchronized (self) {
        self.frameCallback = nil;
        self.propertiesCallback = nil;
    }
    dispatch_semaphore_signal(self.disconnected);
}
- (void)emit {
    @synchronized (self) {
        void (^frame)(void) = self.frameCallback;
        if (frame) { dispatch_async(self.callbackQueue, frame); }
    }
}
- (void)emitProperties {
    @synchronized (self) {
        void (^properties)(id) = self.propertiesCallback;
        if (properties) { dispatch_async(self.callbackQueue, ^{ properties(self); }); }
    }
}
@end

@interface TestInputClient : NSObject
- (instancetype)initWithDevice:(id)device error:(NSError **)error;
@property NSMutableArray<NSData *> *messages;
@end

@implementation TestInputClient
- (instancetype)initWithDevice:(id)device error:(NSError **)error { return [self init]; }
- (instancetype)init {
    if ((self = [super init])) { _messages = [NSMutableArray array]; }
    return self;
}
- (void)sendWithMessage:(void *)message
          freeWhenDone:(BOOL)freeWhenDone
       completionQueue:(dispatch_queue_t)queue
            completion:(void (^)(NSError *))completion {
    @synchronized (self) { [self.messages addObject:[NSData dataWithBytes:message length:malloc_size(message)]]; }
    if (freeWhenDone) { free(message); }
    dispatch_async(queue, ^{ completion(nil); });
}
@end

static TestScreen *makeScreen(size_t width, size_t height) {
    TestScreen *screen = [TestScreen new];
    screen.uiOrientation = 1;
    screen.disconnected = dispatch_semaphore_create(0);
    TestSurface *surface = [TestSurface new];
    surface.width = width;
    surface.height = height;
    surface.bytesPerRow = width * 4;
    surface.allocationSize = width * height * 4;
    surface.pixelFormat = 'BGRA';
    surface.baseAddress = calloc(1, surface.allocationSize);
    screen.framebufferSurface = (IOSurface *)surface;
    uint8_t *pixels = surface.baseAddress;
    size_t stride = surface.bytesPerRow;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t *pixel = pixels + y * stride + x * 4;
            pixel[0] = (uint8_t)x; pixel[1] = (uint8_t)y; pixel[2] = 200; pixel[3] = 255;
        }
    }
    return screen;
}

static void waitFor(dispatch_semaphore_t semaphore) {
    NSCAssert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
        @"Timed out waiting for frame or cleanup");
}

static NSData *imagePixels(CGImageRef image) {
    return CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
}

static void verifyMessageTarget(TestInputClient *client, NSUInteger index, CGPoint point, BOOL isDown, uint32_t expectedTarget) {
    NSData *message;
    @synchronized (client) { message = client.messages[index]; }
    NSCAssert(message.length >= 0x140, @"Unexpected Xcode touch message allocation");
    const uint8_t *bytes = message.bytes;
    double x, y;
    uint32_t target, touch;
    memcpy(&x, bytes + 0x3c, sizeof(x));
    memcpy(&y, bytes + 0x44, sizeof(y));
    memcpy(&target, bytes + 0x6c, sizeof(target));
    memcpy(&touch, bytes + 0x68, sizeof(touch));
    NSCAssert(fabs(x - point.x) < 1e-10 && fabs(y - point.y) < 1e-10, @"Normalized touch coordinates are incorrect");
    NSCAssert(target == expectedTarget && touch == (isDown ? 1 : 0), @"Touch routing or phase is incorrect at %lu: target=%u touch=%u", (unsigned long)index, target, touch);
    memcpy(&x, bytes + 0xdc, sizeof(x));
    memcpy(&y, bytes + 0xe4, sizeof(y));
    NSCAssert(fabs(x - point.x) < 1e-10 && fabs(y - point.y) < 1e-10, @"The repeated digitizer contact must carry the same coordinates");
}

static void verifyMessage(TestInputClient *client, NSUInteger index, CGPoint point, BOOL isDown) {
    verifyMessageTarget(client, index, point, isDown, 0x32);
}

static void *coalescedMovement(CGPoint *point, CGPoint *secondPoint, uint32_t target,
                               NSUInteger type, CGSize size, uint32_t edge) {
    return NULL;
}

static void touch(SimulatorFramebuffer *stream, CGPoint point, SimulatorTouchPhase phase, unsigned int orientation) {
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [stream sendTouchAtPoint:point phase:phase inputOrientation:orientation completion:^(NSError *error) {
        NSCAssert(!error, @"Unexpected input error: %@", error);
        dispatch_semaphore_signal(completed);
    }];
    waitFor(completed);
}

static void verifyWatchDigitizer(NSData *data, NSUInteger eventType, uint32_t expectedTarget) {
    NSCAssert(data.length >= 0x160, @"Watch input must include both native contact records");
    const uint8_t *bytes = data.bytes;
    for (NSUInteger offset = 0x20; offset <= 0xc0; offset += 0xa0) {
        uint32_t kind, mask, target, touch;
        memcpy(&kind, bytes + offset, sizeof(kind));
        memcpy(&mask, bytes + offset + 0x18, sizeof(mask));
        memcpy(&target, bytes + offset + 0x4c, sizeof(target));
        memcpy(&touch, bytes + offset + 0x48, sizeof(touch));
        NSCAssert(kind == 11 && target == expectedTarget,
            @"Every Watch contact must reach the display's digitizer target");
        NSCAssert(mask == (eventType == 6 ? 4 : 3) && touch == (eventType == 2 ? 0 : 1),
            @"Native touch phases must distinguish motion from range/touch transitions");
    }
}

static void validateDuoScreens(void) {
    SimulatorFramebuffer *stream = [SimulatorFramebuffer new];
    TestScreen *outer = makeScreen(1398, 2034);
    TestScreen *inner = makeScreen(2007, 2853);
    TestScreen *island = makeScreen(20, 20);
    outer.backlight = [TestBacklight new];
    inner.backlight = [TestBacklight new];
    island.backlight = outer.backlight;
    outer.backlight.state = 2;
    inner.backlight.state = -101;
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block CGSize size;
    __block unsigned int inputOrientation;
    [stream startWithScreens:@[inner, island, outer] frameHandler:^(CGImageRef image, unsigned int orientation) {
        size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
        inputOrientation = orientation;
        dispatch_semaphore_signal(received);
    } failureHandler:^(NSError *error) { NSCAssert(NO, @"Duo streaming failed: %@", error); }];
    waitFor(received);
    NSCAssert(CGSizeEqualToSize(size, CGSizeMake(1398, 2034)),
        @"An inactive larger inner surface must never replace the active outer screen at startup");
    [inner emit];
    waitFor(received);
    NSCAssert(CGSizeEqualToSize(size, CGSizeMake(1398, 2034)),
        @"Updates from the inactive inner screen must not override the active outer screen");
    for (NSNumber *usesInner in @[@YES, @NO, @YES, @NO]) {
        BOOL isInner = usesInner.boolValue;
        inner.backlight.state = isInner ? 2 : -101;
        outer.backlight.state = isInner ? -101 : 2;
        TestScreen *active = isInner ? inner : outer;
        for (NSNumber *orientation in @[@1, @3, @4, @2]) {
            active.uiOrientation = orientation.unsignedIntValue;
            [active emitProperties];
            waitFor(received);
            BOOL sideways = active.uiOrientation == 3 || active.uiOrientation == 4;
            CGSize expected = isInner ? CGSizeMake(2007, 2853) : CGSizeMake(1398, 2034);
            if (sideways) { expected = CGSizeMake(expected.height, expected.width); }
            NSCAssert(CGSizeEqualToSize(size, expected) && inputOrientation == active.uiOrientation,
                @"Duo property changes must switch both the active display and its orientation");
        }
    }
    outer.backlight.state = -101;
    inner.backlight.state = -101;
    [outer emitProperties];
    NSCAssert(dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0,
        @"A transition with both displays inactive must not publish a stale inner screen");
    [stream stop];
    waitFor(outer.disconnected);
    waitFor(inner.disconnected);
    waitFor(island.disconnected);
    printf("Validated Duo active-display selection with both surfaces retained, inactive frame callbacks, fold transitions, property-only updates, all orientations, and inactive-display suppression.\n");
}

int main(void) {
    @autoreleasepool {
        validateDuoScreens();
        SimulatorFramebuffer *stream = [SimulatorFramebuffer new];
        TestScreen *main = makeScreen(8, 16);
        TestScreen *island = makeScreen(2, 2);
        dispatch_semaphore_t received = dispatch_semaphore_create(0);
        NSLock *lock = [NSLock new];
        __block CGImageRef latest = NULL;
        __block NSUInteger count = 0;
        [stream startWithScreens:@[island, main] frameHandler:^(CGImageRef image, unsigned int inputOrientation) {
            [lock lock];
            if (latest) { CGImageRelease(latest); }
            latest = CGImageRetain(image);
            count++;
            [lock unlock];
            dispatch_semaphore_signal(received);
        } failureHandler:^(NSError *error) {
            NSCAssert(NO, @"Unexpected error: %@", error);
        }];
        waitFor(received);
        [lock lock];
        NSCAssert(CGImageGetWidth(latest) == 8 && CGImageGetHeight(latest) == 16,
            @"The auxiliary island plane must not replace the screen");
        CGImageRef retained = CGImageRetain(latest);
        NSData *before = imagePixels(retained);
        [lock unlock];
        TestSurface *buffer = (TestSurface *)main.framebufferSurface;
        memset(buffer.baseAddress, 100, buffer.allocationSize);
        [main emit];
        waitFor(received);
        NSCAssert([before isEqual:imagePixels(retained)], @"Retained export frames must own immutable pixels");
        CGImageRelease(retained);
        for (size_t y = 0; y < buffer.height; y++) {
            for (size_t x = 0; x < buffer.width; x++) {
                uint8_t *pixel = (uint8_t *)buffer.baseAddress + y * buffer.bytesPerRow + x * 4;
                pixel[0] = (uint8_t)x; pixel[1] = (uint8_t)y; pixel[2] = 200; pixel[3] = 255;
            }
        }
        for (NSNumber *orientation in @[@3, @4, @2, @1]) {
            main.uiOrientation = orientation.unsignedIntValue;
            [main emit];
            waitFor(received);
            [lock lock];
            BOOL sideways = orientation.unsignedIntValue == 3 || orientation.unsignedIntValue == 4;
            NSCAssert(CGImageGetWidth(latest) == (sideways ? 16 : 8)
                && CGImageGetHeight(latest) == (sideways ? 8 : 16), @"Rotation dimensions are incorrect");
            NSData *pixels = imagePixels(latest);
            const uint8_t *bytes = pixels.bytes;
            size_t width = CGImageGetWidth(latest), height = CGImageGetHeight(latest), stride = CGImageGetBytesPerRow(latest);
            for (size_t y = 0; y < height; y += height - 1) {
                for (size_t x = 0; x < width; x += width - 1) {
                    size_t sourceX = x, sourceY = y;
                    switch (orientation.unsignedIntValue) {
                        case 2: sourceX = 7 - x; sourceY = 15 - y; break;
                        case 3: sourceX = y; sourceY = 15 - x; break;
                        case 4: sourceX = 7 - y; sourceY = x; break;
                    }
                    const uint8_t *pixel = bytes + y * stride + x * 4;
                    NSCAssert(pixel[0] == sourceX && pixel[1] == sourceY && pixel[2] == 200,
                        @"Every rotated frame must preserve the corner pixels in the correct orientation");
                }
            }
            [lock unlock];
        }
        void *kit = dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
        void *builder = dlsym(kit, "IndigoHIDMessageForMouseNSEvent");
        NSCAssert(builder, @"The selected Xcode must supply the touch message builder");
        Class hidClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
        NSCAssert([hidClass instancesRespondToSelector:@selector(initWithDevice:error:)]
                  && [hidClass instancesRespondToSelector:@selector(sendWithMessage:freeWhenDone:completionQueue:completion:)],
                  @"The installed Xcode must expose the expected input client selectors");
        TestInputClient *input = [TestInputClient new];
        [stream setTestInputClient:input messageBuilder:builder];
        touch(stream, CGPointMake(.2, .3), SimulatorTouchPhaseBegan, 1);
        [stream setTestInputClient:input messageBuilder:coalescedMovement];
        touch(stream, CGPointMake(.3, .4), SimulatorTouchPhaseMoved, 1);
        NSCAssert(input.messages.count == 1, @"Coalesced movement must succeed without sending a packet");
        [stream setTestInputClient:input messageBuilder:builder];
        [NSThread sleepForTimeInterval:0.02];
        touch(stream, CGPointMake(.4, .6), SimulatorTouchPhaseMoved, 1);
        touch(stream, CGPointMake(.4, .6), SimulatorTouchPhaseEnded, 1);
        verifyMessage(input, 0, CGPointMake(.2, .3), YES);
        verifyMessage(input, 1, CGPointMake(.4, .6), YES);
        verifyMessage(input, 2, CGPointMake(.4, .6), NO);
        NSUInteger nextMessage = 3;
        for (NSNumber *orientation in @[@3, @4, @2]) {
            main.uiOrientation = orientation.unsignedIntValue;
            [main emit]; waitFor(received);
            CGPoint native = orientation.unsignedIntValue == 3 ? CGPointMake(.3, .8)
                : orientation.unsignedIntValue == 4 ? CGPointMake(.7, .2) : CGPointMake(.8, .7);
            touch(stream, CGPointMake(.2, .3), SimulatorTouchPhaseBegan, orientation.unsignedIntValue);
            touch(stream, CGPointMake(.2, .3), SimulatorTouchPhaseEnded, orientation.unsignedIntValue);
            verifyMessage(input, nextMessage++, native, YES);
            verifyMessage(input, nextMessage++, native, NO);
        }
        dispatch_semaphore_t rejected = dispatch_semaphore_create(0);
        [stream sendTouchAtPoint:CGPointMake(.2, .3) phase:SimulatorTouchPhaseBegan inputOrientation:1 completion:^(NSError *error) {
            NSCAssert(error, @"A stale frame orientation must reject the touch");
            dispatch_semaphore_signal(rejected);
        }];
        waitFor(rejected);
        NSCAssert(input.messages.count == nextMessage, @"Stale input must not reach the device");
        main.uiOrientation = 1;
        [main emit]; waitFor(received);
        touch(stream, CGPointMake(.2, .3), SimulatorTouchPhaseBegan, 1);
        verifyMessage(input, nextMessage++, CGPointMake(.2, .3), YES);
        main.uiOrientation = 3;
        [main emit]; waitFor(received);
        verifyMessage(input, nextMessage++, CGPointMake(.2, .3), NO);
        touch(stream, CGPointMake(.2, .3), SimulatorTouchPhaseBegan, 3);
        verifyMessage(input, nextMessage++, CGPointMake(.3, .8), YES);
        
        [lock lock]; NSUInteger initialCount = count; [lock unlock];
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        while (NSProcessInfo.processInfo.systemUptime - started < 0.3) {
            [main emit]; [island emit];
            [NSThread sleepForTimeInterval:0.002];
        }
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - started;
        [lock lock];
        NSUInteger delivered = count - initialCount;
        NSCAssert(delivered >= 15 && delivered <= ceil(elapsed * 120) + 1,
            @"Continuous updates must support rates above 30 fps while staying capped at 120 fps");
        [lock unlock];
        [stream stop];
        waitFor(main.disconnected);
        waitFor(island.disconnected);
        verifyMessage(input, nextMessage++, CGPointMake(.3, .8), NO);
        NSCAssert(input.messages.count == nextMessage, @"Disconnect must release the active touch exactly once");
        [lock lock]; NSUInteger finalCount = count; [lock unlock];
        [main emit]; [island emit];
        [NSThread sleepForTimeInterval:0.1];
        [lock lock];
        NSCAssert(count == finalCount, @"Cancelled subscriptions must not publish frames");
        CGImageRelease(latest);
        [lock unlock];
        SimulatorFramebuffer *watchStream = [SimulatorFramebuffer new];
        TestScreen *watchScreen = makeScreen(8, 10);
        dispatch_semaphore_t watchReceived = dispatch_semaphore_create(0);
        [watchStream startWithScreens:@[watchScreen] frameHandler:^(CGImageRef image, unsigned int orientation) {
            dispatch_semaphore_signal(watchReceived);
        } failureHandler:^(NSError *error) { NSCAssert(NO, @"Watch streaming failed: %@", error); }];
        waitFor(watchReceived);
        TestInputClient *watchInput = [TestInputClient new];
        [watchStream setTestWatchInputClient:watchInput simulatorKit:kit];
        touch(watchStream, CGPointMake(.2, .3), SimulatorTouchPhaseBegan, 1);
        [NSThread sleepForTimeInterval:0.02];
        touch(watchStream, CGPointMake(.4, .6), SimulatorTouchPhaseMoved, 1);
        touch(watchStream, CGPointMake(.4, .6), SimulatorTouchPhaseEnded, 1);
        verifyMessage(watchInput, 0, CGPointMake(.2, .3), YES);
        verifyMessage(watchInput, 1, CGPointMake(.4, .6), YES);
        verifyMessage(watchInput, 2, CGPointMake(.4, .6), NO);
        verifyWatchDigitizer(watchInput.messages[0], 1, 0x32);
        verifyWatchDigitizer(watchInput.messages[1], 6, 0x32);
        verifyWatchDigitizer(watchInput.messages[2], 2, 0x32);
        touch(watchStream, CGPointMake(.5, .5), SimulatorTouchPhaseBegan, 1);
        verifyMessage(watchInput, 3, CGPointMake(.5, .5), YES);
        verifyWatchDigitizer(watchInput.messages[3], 1, 0x32);
        dispatch_semaphore_t crownSent = dispatch_semaphore_create(0);
        [watchStream sendCrownPressed:YES completion:^(NSError *error) {
            NSCAssert(!error, @"Crown press failed: %@", error);
            dispatch_semaphore_signal(crownSent);
        }];
        waitFor(crownSent);
        verifyMessage(watchInput, 4, CGPointMake(.5, .5), NO);
        verifyWatchDigitizer(watchInput.messages[4], 2, 0x32);
        NSData *crownDown = watchInput.messages[5];
        uint32_t key, operation, target;
        memcpy(&key, crownDown.bytes + 0x30, sizeof(key));
        memcpy(&operation, crownDown.bytes + 0x34, sizeof(operation));
        memcpy(&target, crownDown.bytes + 0x38, sizeof(target));
        NSCAssert(key == 0 && operation == 1 && target == 1, @"Crown must send Home through the Watch's default event-system route");
        for (NSNumber *delta in @[@0, @(NAN), @(INFINITY)]) {
            [watchStream sendCrownRotation:delta.doubleValue completion:^(NSError *error) {
                NSCAssert(NO, @"Invalid rotation must not be sent");
            }];
        }
        NSUInteger rotationIndex = 6;
        for (NSNumber *delta in @[@12.5, @-3]) {
            [watchStream sendCrownRotation:delta.doubleValue completion:^(NSError *error) {
                NSCAssert(!error, @"Crown rotation failed: %@", error);
                dispatch_semaphore_signal(crownSent);
            }];
            waitFor(crownSent);
            NSData *rotation = watchInput.messages[rotationIndex++];
            uint32_t type, flags;
            double sentDelta;
            memcpy(&type, rotation.bytes + 0x20, sizeof(type));
            memcpy(&flags, rotation.bytes + 0x2c, sizeof(flags));
            memcpy(&sentDelta, rotation.bytes + 0x3c, sizeof(sentDelta));
            memcpy(&target, rotation.bytes + 0x4c, sizeof(target));
            NSCAssert(type == 6 && flags == 0x10 && target == 0x34 && sentDelta == delta.doubleValue,
                @"Rotation must use SimulatorKit's native Digital Crown event and preserve its signed delta");
        }
        [watchStream stop];
        waitFor(watchScreen.disconnected);
        NSData *crownUp = watchInput.messages[8];
        memcpy(&key, crownUp.bytes + 0x30, sizeof(key));
        memcpy(&operation, crownUp.bytes + 0x34, sizeof(operation));
        memcpy(&target, crownUp.bytes + 0x38, sizeof(target));
        NSCAssert(key == 0 && operation == 2 && target == 1, @"Disconnect must release the Digital Crown through the same route");
        NSCAssert(watchInput.messages.count == 9, @"Rotation must not change held inputs or duplicate releases");
        printf("Validated Watch built-in digitizer routing, native touch phases, Digital Crown press/rotation events, signed rotation deltas, and held-input cleanup.\n");
        printf("Validated full-screen selection, immutable surface snapshots, orientation, 120 fps pacing, native touch routing, drag phases, rotated coordinates, stale input rejection, and touch/callback cleanup.\n");
    }
    return 0;
}
