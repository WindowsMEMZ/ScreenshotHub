#import "SimulatorFramebuffer.h"
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <dlfcn.h>
#import <math.h>

// These interfaces belong to the selected Xcode. Check every entry point before using it.
@protocol SHServiceContext <NSObject>
+ (id)sharedServiceContextForDeveloperDir:(NSString *)directory error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
@end

@protocol SHDeviceSet <NSObject>
- (NSArray *)availableDevices;
@end

@protocol SHDevice <NSObject>
- (NSUUID *)UDID;
- (id)io;
@end

@protocol SHDeviceIO <NSObject>
- (void)updateIOPorts;
- (NSArray *)deviceIOPorts;
@end

@protocol SHPort <NSObject>
- (NSString *)portIdentifier;
- (id)descriptor;
@end

@protocol SHScreenBacklight <NSObject>
- (int)state;
@end

@protocol SHScreenProperties <NSObject>
- (unsigned int)uiOrientation;
- (id<SHScreenBacklight>)backlight;
@end

@protocol SHScreen <NSObject>
- (IOSurface *)framebufferSurface;
- (id<SHScreenProperties>)screenProperties;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                         callbackQueue:(dispatch_queue_t)queue
                         frameCallback:(void (^)(void))frame
               surfacesChangedCallback:(void (^)(IOSurface *, IOSurface *))surfaces
             propertiesChangedCallback:(void (^)(id))properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end

typedef void *(*SHMouseMessageBuilder)(CGPoint *, CGPoint *, uint32_t, NSUInteger, CGSize, uint32_t);

typedef void *(*SHButtonMessageBuilder)(uint32_t, uint32_t, uint32_t);
typedef void *(*SHCrownMessageBuilder)(double);
@protocol SHLegacyHIDClient <NSObject>
- (instancetype)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message
          freeWhenDone:(BOOL)freeWhenDone
       completionQueue:(dispatch_queue_t)queue
            completion:(void (^)(NSError *))completion;
@end

@interface SimulatorFramebuffer () {
    dispatch_queue_t _queue;
    id _device;
    id _io;
    NSArray<id<SHScreen>> *_screens;
    NSUUID *_subscription;
    void (^_frameHandler)(CGImageRef, unsigned int);
    id<SHLegacyHIDClient> _hidClient;
    SHMouseMessageBuilder _mouseMessage;
    SHButtonMessageBuilder _buttonMessage;
    SHCrownMessageBuilder _crownMessage;
    BOOL _isWatch;
    BOOL _isCrownPressed;
    unsigned int _inputOrientation;
    CGPoint _lastTouch;
    BOOL _isTouching;
    void (^_failureHandler)(NSError *);
    BOOL _isStopped;
    BOOL _isPending;
    NSTimeInterval _lastFrameTime;
}
@end

@implementation SimulatorFramebuffer

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.memz233.ScreenshotHub.framebuffer", DISPATCH_QUEUE_SERIAL);
        _isStopped = YES;
    }
    return self;
}

- (void)startWithDeviceID:(NSString *)deviceID
      developerDirectory:(NSString *)developerDirectory
                 isWatch:(BOOL)isWatch
            frameHandler:(void (^)(CGImageRef, unsigned int))frameHandler
          failureHandler:(void (^)(NSError *))failureHandler {
    dispatch_async(_queue, ^{
        self->_isStopped = NO;
        self->_isWatch = isWatch;
        self->_frameHandler = [frameHandler copy];
        self->_failureHandler = [failureHandler copy];
        @try {
            NSString *kit = [[developerDirectory stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
            void *simulatorKit = dlopen(kit.fileSystemRepresentation, RTLD_NOW);
            if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)
                || !simulatorKit) {
                [self fail:@"Unable to load simulator streaming. Make sure the full version of Xcode is installed."];
                return;
            }
            [self loadInputSymbols:simulatorKit];
            Class contextClass = NSClassFromString(@"SimServiceContext");
            if (![contextClass respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)]) {
                [self fail:@"This version of Xcode does not support simulator framebuffer streaming."];
                return;
            }
            NSError *error;
            id<SHServiceContext> context = [(id<SHServiceContext>)contextClass
                sharedServiceContextForDeveloperDir:developerDirectory error:&error];
            if (![context respondsToSelector:@selector(defaultDeviceSetWithError:)]) {
                [self fail:error.localizedDescription ?: @"Unable to connect to CoreSimulator."];
                return;
            }
            id<SHDeviceSet> set = [context defaultDeviceSetWithError:&error];
            if (![set respondsToSelector:@selector(availableDevices)]) {
                [self fail:error.localizedDescription ?: @"Unable to read simulator devices."];
                return;
            }
            for (id<SHDevice> device in [set availableDevices]) {
                if ([device respondsToSelector:@selector(UDID)]
                    && [[[device UDID] UUIDString] caseInsensitiveCompare:deviceID] == NSOrderedSame) {
                    self->_device = device;
                    break;
                }
            }
            if (![self->_device respondsToSelector:@selector(io)]) {
                [self fail:@"The selected simulator is unavailable. Restart it and refresh the list."];
                return;
            }
            self->_io = [(id<SHDevice>)self->_device io];
            if (![self->_io respondsToSelector:@selector(updateIOPorts)]
                || ![self->_io respondsToSelector:@selector(deviceIOPorts)]) {
                [self fail:@"This version of Xcode does not provide an available display port."];
                return;
            }
            [(id<SHDeviceIO>)self->_io updateIOPorts];
            NSMutableArray *screens = [NSMutableArray array];
            for (id<SHPort> port in [(id<SHDeviceIO>)self->_io deviceIOPorts]) {
                if (![port respondsToSelector:@selector(portIdentifier)]
                    || ![port respondsToSelector:@selector(descriptor)]
                    || ![[port portIdentifier] isEqualToString:@"com.apple.framebuffer.display"]) { continue; }
                id descriptor = [port descriptor];
                if ([descriptor respondsToSelector:@selector(framebufferSurface)]
                    && [descriptor respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)]
                    && [descriptor respondsToSelector:@selector(unregisterScreenCallbacksWithUUID:)]) {
                    [screens addObject:descriptor];
                }
            }
            [self connectScreens:screens];
        } @catch (NSException *exception) {
            [self fail:@"Simulator streaming is incompatible with this version of Xcode."];
        }
    });
}

#if SCREENSHOT_HUB_TESTING
- (void)startWithScreens:(NSArray *)screens
           frameHandler:(void (^)(CGImageRef, unsigned int))frameHandler
         failureHandler:(void (^)(NSError *))failureHandler {
    dispatch_async(_queue, ^{
        self->_isStopped = NO;
        self->_frameHandler = [frameHandler copy];
        self->_failureHandler = [failureHandler copy];
        [self connectScreens:screens];
    });
}
- (void)setTestWatchInputClient:(id)client simulatorKit:(void *)kit {
    dispatch_async(_queue, ^{
        self->_hidClient = client;
        self->_isWatch = YES;
        [self loadInputSymbols:kit];
    });
}
- (void)setTestInputClient:(id)client messageBuilder:(void *)builder {
    dispatch_async(_queue, ^{
        self->_hidClient = client;
        self->_mouseMessage = (SHMouseMessageBuilder)builder;
    });
}
#endif

- (void)loadInputSymbols:(void *)kit {
    _mouseMessage = (SHMouseMessageBuilder)dlsym(kit, "IndigoHIDMessageForMouseNSEvent");
    _buttonMessage = (SHButtonMessageBuilder)dlsym(kit, "IndigoHIDMessageForButton");
    _crownMessage = (SHCrownMessageBuilder)dlsym(kit, "IndigoHIDMessageForDigitalCrownEvent");
}

- (void)connectScreens:(NSArray<id<SHScreen>> *)screens {
    if (screens.count == 0) {
        [self fail:@"The simulator display is not ready. Start the device and select it again."];
        return;
    }
    _screens = screens;
    _subscription = [NSUUID UUID];
    __weak SimulatorFramebuffer *weakSelf = self;
    for (id<SHScreen> screen in screens) {
        [screen registerScreenCallbacksWithUUID:_subscription callbackQueue:_queue frameCallback:^{
            [weakSelf requestFrame];
        } surfacesChangedCallback:^(IOSurface *surface, IOSurface *maskedSurface) {
            [weakSelf requestFrame];
        } propertiesChangedCallback:^(id properties) {
            [weakSelf requestFrame];
        }];
    }
    [self requestFrame];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), _queue, ^{
        if (!self->_isStopped && self->_lastFrameTime == 0) {
            [self fail:@"No screen frames received. Make sure the simulator is running and select it again."];
        }
    });
}

- (void)requestFrame {
    if (_isStopped || _isPending) { return; }
    _isPending = YES;
    NSTimeInterval delay = MAX(0, 1.0 / 120.0 - (NSProcessInfo.processInfo.systemUptime - _lastFrameTime));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        self->_isPending = NO;
        if (self->_isStopped) { return; }
        @autoreleasepool {
            @try { [self publishFrame]; }
            @catch (NSException *exception) {
                [self fail:@"Simulator streaming was interrupted. Select the device again."];
            }
        }
    });
}

- (void)publishFrame {
    IOSurface *surface;
    id<SHScreen> source;
    size_t largestArea = 0;
    // Auxiliary display planes can contain only the island or an overlay, not the full screen.
    for (id<SHScreen> screen in _screens) {
        if ([screen respondsToSelector:@selector(screenProperties)]) {
            id<SHScreenProperties> properties = [screen screenProperties];
            if ([properties respondsToSelector:@selector(backlight)]) {
                id<SHScreenBacklight> backlight = [properties backlight];
                // Folded-away Duo displays retain full-sized surfaces with a negative backlight state.
                if ([backlight respondsToSelector:@selector(state)] && [backlight state] < 0) { continue; }
            }
        }
        IOSurface *candidate = [screen framebufferSurface];
        size_t area = candidate.width * candidate.height;
        if (area > largestArea) {
            largestArea = area;
            surface = candidate;
            source = screen;
        }
    }
    if (!surface || !_frameHandler) { return; }
    size_t width = surface.width;
    size_t height = surface.height;
    size_t stride = surface.bytesPerRow;
    OSType format = surface.pixelFormat;
    if ((format != 'BGRA' && format != 'RGBA') || surface.planeCount != 0
        || stride < width * 4 || height > surface.allocationSize / MAX(stride, 1)) {
        [self fail:@"The simulator uses an unsupported screen pixel format."];
        return;
    }
    if ([surface lockWithOptions:kIOSurfaceLockReadOnly seed:NULL] != kIOReturnSuccess) { return; }
    // Own the pixels: the simulator reuses its surfaces while preview and export retain older frames.
    NSData *pixels = [NSData dataWithBytes:surface.baseAddress length:stride * height];
    [surface unlockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = format == 'BGRA'
        ? kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst
        : kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, colorSpace, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (!image) { return; }
    unsigned int orientation = 1;
    if ([source respondsToSelector:@selector(screenProperties)]) {
        id properties = [source screenProperties];
        if ([properties respondsToSelector:@selector(uiOrientation)]) {
            orientation = [(id<SHScreenProperties>)properties uiOrientation];
        }
    }
    CGImageRef oriented = [self copyImage:image orientation:orientation];
    _lastFrameTime = NSProcessInfo.processInfo.systemUptime;
    unsigned int inputOrientation = oriented ? orientation : 1;
    if (_isTouching && inputOrientation != _inputOrientation) {
        [self releaseTouch];
    }
    _inputOrientation = inputOrientation;
    _frameHandler(oriented ?: image, inputOrientation);
    if (oriented) { CGImageRelease(oriented); }
    CGImageRelease(image);
}

- (CGImageRef)copyImage:(CGImageRef)image orientation:(unsigned int)orientation CF_RETURNS_RETAINED {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    BOOL sideways = (orientation == 3 || orientation == 4) && width < height;
    if (!sideways && orientation != 2) { return NULL; }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, sideways ? height : width, sideways ? width : height,
        8, 0, colorSpace, kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(colorSpace);
    if (!context) { return NULL; }
    if (sideways) {
        if (orientation == 4) {
            CGContextTranslateCTM(context, height, 0);
            CGContextRotateCTM(context, M_PI_2);
        } else {
            CGContextTranslateCTM(context, 0, width);
            CGContextRotateCTM(context, -M_PI_2);
        }
    } else {
        CGContextTranslateCTM(context, width, height);
        CGContextRotateCTM(context, M_PI);
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

- (void)sendTouchAtPoint:(CGPoint)point
                   phase:(SimulatorTouchPhase)phase
        inputOrientation:(unsigned int)inputOrientation
              completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_isStopped) { return; }
        if (!isfinite(point.x) || !isfinite(point.y)) { return; }
        @try {
            if (phase == SimulatorTouchPhaseEnded) {
                if (self->_isTouching) {
                    if (inputOrientation == self->_inputOrientation) {
                        self->_lastTouch = [self nativePoint:point orientation:inputOrientation];
                    }
                    self->_isTouching = NO;
                    [self sendNativePoint:self->_lastTouch phase:SimulatorTouchPhaseEnded completion:completion];
                }
                return;
            }
            if (inputOrientation != self->_inputOrientation) {
                [self releaseTouch];
                completion([self inputError:@"The screen orientation changed. Try again on the updated preview."]);
                return;
            }
            if (phase == SimulatorTouchPhaseMoved && !self->_isTouching) { return; }
            if (phase == SimulatorTouchPhaseBegan) {
                [self releaseTouch];
                [self releaseCrown];
            }
            if (![self prepareInput]) {
                completion([self inputError:@"Unable to connect to simulator touch input. Retry streaming or check your Xcode version."]);
                return;
            }
            self->_lastTouch = [self nativePoint:point orientation:inputOrientation];
            self->_isTouching = YES;
            [self sendNativePoint:self->_lastTouch phase:phase completion:completion];
        } @catch (NSException *exception) {
            completion([self inputError:@"Simulator touch input is incompatible with this version of Xcode."]);
        }
    });
}

- (BOOL)prepareInput {
    if (_hidClient) { return YES; }
    if (!_device) { return NO; }
    Class clientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    if (!clientClass) { clientClass = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient"); }
    if (![clientClass instancesRespondToSelector:@selector(initWithDevice:error:)]
        || ![clientClass instancesRespondToSelector:@selector(sendWithMessage:freeWhenDone:completionQueue:completion:)]) {
        return NO;
    }
    NSError *error;
    _hidClient = [(id<SHLegacyHIDClient>)[clientClass alloc] initWithDevice:_device error:&error];
    return _hidClient != nil;
}

- (CGPoint)nativePoint:(CGPoint)point orientation:(unsigned int)orientation {
    CGFloat x = MIN(1, MAX(0, point.x));
    CGFloat y = MIN(1, MAX(0, point.y));
    // Undo the rotation applied by copyImage:orientation:; digitizer coordinates are portrait-native.
    switch (orientation) {
        case 2: return CGPointMake(1 - x, 1 - y);
        case 3: return CGPointMake(y, 1 - x);
        case 4: return CGPointMake(1 - y, x);
        default: return CGPointMake(x, y);
    }
}

- (void)sendNativePoint:(CGPoint)point phase:(SimulatorTouchPhase)phase completion:(void (^)(NSError *))completion {
    if (!_hidClient) { return; }
    NSUInteger eventType = phase == SimulatorTouchPhaseEnded ? 2 : phase == SimulatorTouchPhaseMoved ? 6 : 1;
    // Watch touch input needs the built-in digitizer service's sender identity.
    void *message = _mouseMessage
        ? _mouseMessage(&point, NULL, 0x32, eventType, CGSizeMake(1, 1), 0) : NULL;
    // SimulatorKit intentionally coalesces closely spaced drag events.
    if (!message && _mouseMessage && phase == SimulatorTouchPhaseMoved) {
        completion(nil);
        return;
    }
    if (!message) {
        completion([self inputError:@"Unable to create a simulator touch event."]);
        return;
    }
    id<SHLegacyHIDClient> client = _hidClient;
    [client sendWithMessage:message freeWhenDone:YES completionQueue:_queue completion:^(NSError *error) {
        (void)client;
        completion(error);
    }];
}

- (void)sendCrownPressed:(BOOL)isPressed completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_isStopped || !self->_isWatch) { return; }
        @try {
            if (!isPressed && !self->_isCrownPressed) { return; }
            if (isPressed) { [self releaseTouch]; }
            if (![self prepareInput] || !self->_buttonMessage) {
                completion([self inputError:@"Unable to connect to simulator Digital Crown input."]);
                return;
            }
            self->_isCrownPressed = isPressed;
            [self sendNativeCrownPressed:isPressed completion:completion];
        } @catch (NSException *exception) {
            completion([self inputError:@"Digital Crown input is incompatible with this version of Xcode."]);
        }
    });
}

- (void)sendCrownRotation:(double)delta completion:(void (^)(NSError *))completion {
    if (!isfinite(delta) || delta == 0) { return; }
    dispatch_async(_queue, ^{
        if (self->_isStopped || !self->_isWatch) { return; }
        @try {
            if (![self prepareInput] || !self->_crownMessage) {
                completion([self inputError:@"Unable to connect to simulator Digital Crown rotation input."]);
                return;
            }
            void *message = self->_crownMessage(delta);
            if (!message) {
                completion([self inputError:@"Unable to create a Digital Crown rotation event."]);
                return;
            }
            id<SHLegacyHIDClient> client = self->_hidClient;
            [client sendWithMessage:message freeWhenDone:YES completionQueue:self->_queue completion:^(NSError *error) {
                (void)client;
                completion(error);
            }];
        } @catch (NSException *exception) {
            completion([self inputError:@"Digital Crown rotation is incompatible with this version of Xcode."]);
        }
    });
}

- (void)sendNativeCrownPressed:(BOOL)isPressed completion:(void (^)(NSError *))completion {
    if (!_hidClient || !_buttonMessage) { return; }
    // Device Hub's Watch accepts Home through the default event-system route.
    void *message = _buttonMessage(0, isPressed ? 1 : 2, 1);
    if (!message) {
        completion([self inputError:@"Unable to create a Digital Crown event."]);
        return;
    }
    id<SHLegacyHIDClient> client = _hidClient;
    [client sendWithMessage:message freeWhenDone:YES completionQueue:_queue completion:^(NSError *error) {
        (void)client;
        completion(error);
    }];
}

- (void)releaseCrown {
    if (!_isCrownPressed) { return; }
    _isCrownPressed = NO;
    @try { [self sendNativeCrownPressed:NO completion:^(NSError *error) {}]; }
    @catch (NSException *exception) { }
}

- (void)releaseTouch {
    if (!_isTouching) { return; }
    _isTouching = NO;
    @try { [self sendNativePoint:_lastTouch phase:SimulatorTouchPhaseEnded completion:^(NSError *error) {}]; }
    @catch (NSException *exception) { }
}

- (NSError *)inputError:(NSString *)message {
    return [NSError errorWithDomain:@"ScreenshotHub.SimulatorInput" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)fail:(NSString *)message {
    void (^handler)(NSError *) = _failureHandler;
    [self disconnect];
    if (handler) {
        handler([NSError errorWithDomain:@"ScreenshotHub.Framebuffer" code:1
            userInfo:@{NSLocalizedDescriptionKey: message}]);
    }
}

- (void)disconnect {
    _isStopped = YES;
    [self releaseTouch];
    [self releaseCrown];
    _hidClient = nil;
    for (id<SHScreen> screen in _screens) {
        @try { [screen unregisterScreenCallbacksWithUUID:_subscription]; }
        @catch (NSException *exception) { }
    }
    _screens = nil;
    _subscription = nil;
    _io = nil;
    _device = nil;
    _frameHandler = nil;
    _failureHandler = nil;
}

- (void)stop {
    dispatch_async(_queue, ^{ [self disconnect]; });
}

@end
