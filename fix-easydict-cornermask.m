// fix-easydict-cornermask.dylib
//
// Runtime workaround for Easydict on macOS 26 Tahoe.
// It mirrors the Easydict source patch by replacing direct _cornerMask
// overrides on NSWindow subclasses with the inherited implementation, so
// WindowServer can use AppKit's shared corner-mask cache.

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdbool.h>
#import <stdio.h>

static bool EDIsTahoeOrLater(void) {
    if (@available(macOS 26.0, *)) {
        return true;
    }
    return false;
}

static bool EDIsSubclassOf(Class cls, Class target) {
    for (Class ancestor = class_getSuperclass(cls); ancestor; ancestor = class_getSuperclass(ancestor)) {
        if (ancestor == target) {
            return true;
        }
    }
    return false;
}

static Method EDDirectMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) {
        return NULL;
    }

    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static void EDPatchLoadedCornerMasks(void) {
    if (!EDIsTahoeOrLater()) {
        return;
    }

    SEL sel = sel_registerName("_cornerMask");
    Class nsWindowClass = [NSWindow class];

    unsigned int totalClasses = 0;
    Class *classList = objc_copyClassList(&totalClasses);
    if (!classList) {
        return;
    }

    for (unsigned int i = 0; i < totalClasses; i++) {
        Class cls = classList[i];
        if (cls == nsWindowClass || !EDIsSubclassOf(cls, nsWindowClass)) {
            continue;
        }

        Method method = EDDirectMethod(cls, sel);
        if (!method) {
            continue;
        }

        Class superCls = class_getSuperclass(cls);
        Method superMethod = class_getInstanceMethod(superCls, sel);
        if (!superMethod) {
            continue;
        }

        IMP inherited = method_getImplementation(superMethod);
        if (method_getImplementation(method) == inherited) {
            continue;
        }

        method_setImplementation(method, inherited);
        os_log_info(OS_LOG_DEFAULT, "[WindowServer patch] Patched %{public}s._cornerMask", class_getName(cls));
        fprintf(stderr, "[fix-easydict-cornermask] patched %s._cornerMask\n", class_getName(cls));
    }

    free(classList);
}

static id (*EDOrigInitWithContentRect)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL);
static id EDInitWithContentRect(id self, SEL cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer) {
    EDPatchLoadedCornerMasks();
    id window = EDOrigInitWithContentRect(self, cmd, rect, style, backing, defer);
    EDPatchLoadedCornerMasks();
    return window;
}

static id (*EDOrigInitWithContentRectScreen)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL, NSScreen *);
static id EDInitWithContentRectScreen(id self, SEL cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer, NSScreen *screen) {
    EDPatchLoadedCornerMasks();
    id window = EDOrigInitWithContentRectScreen(self, cmd, rect, style, backing, defer, screen);
    EDPatchLoadedCornerMasks();
    return window;
}

static id (*EDOrigInitWithCoder)(id, SEL, NSCoder *);
static id EDInitWithCoder(id self, SEL cmd, NSCoder *coder) {
    EDPatchLoadedCornerMasks();
    id window = EDOrigInitWithCoder(self, cmd, coder);
    EDPatchLoadedCornerMasks();
    return window;
}

static void EDReplaceNSWindowMethod(SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod([NSWindow class], sel);
    if (!method || *original) {
        return;
    }
    *original = method_setImplementation(method, replacement);
}

static void EDInstallWindowInitHooks(void) {
    EDReplaceNSWindowMethod(@selector(initWithContentRect:styleMask:backing:defer:),
                            (IMP)EDInitWithContentRect,
                            (IMP *)&EDOrigInitWithContentRect);
    EDReplaceNSWindowMethod(@selector(initWithContentRect:styleMask:backing:defer:screen:),
                            (IMP)EDInitWithContentRectScreen,
                            (IMP *)&EDOrigInitWithContentRectScreen);
    EDReplaceNSWindowMethod(@selector(initWithCoder:),
                            (IMP)EDInitWithCoder,
                            (IMP *)&EDOrigInitWithCoder);
}

static void EDSchedulePatchAfter(double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * (double)NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        EDPatchLoadedCornerMasks();
    });
}

__attribute__((constructor))
static void EDEasydictCornerMaskPatchInstall(void) {
    @autoreleasepool {
        if (!EDIsTahoeOrLater()) {
            return;
        }

        os_log_info(OS_LOG_DEFAULT, "[WindowServer patch] Easydict corner-mask dylib loaded");
        EDInstallWindowInitHooks();
        EDPatchLoadedCornerMasks();

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:NSApplicationWillFinishLaunchingNotification
                            object:nil
                             queue:nil
                        usingBlock:^(__unused NSNotification *note) {
            EDPatchLoadedCornerMasks();
        }];
        [center addObserverForName:NSApplicationDidFinishLaunchingNotification
                            object:nil
                             queue:nil
                        usingBlock:^(__unused NSNotification *note) {
            EDPatchLoadedCornerMasks();
            EDSchedulePatchAfter(0.1);
            EDSchedulePatchAfter(1.0);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            EDPatchLoadedCornerMasks();
        });
        EDSchedulePatchAfter(0.5);
        EDSchedulePatchAfter(2.0);
    }
}
