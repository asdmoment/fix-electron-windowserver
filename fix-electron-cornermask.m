// fix-electron-cornermask.dylib
//
// 修复 macOS 26 Tahoe 上 Electron 应用导致 WindowServer GPU 高负载的问题。
//
// 根因: Electron 的 ElectronNSWindow 覆写了私有 API _cornerMask，
// 导致 AppKit 无法缓存窗口圆角遮罩，WindowServer 每帧重新渲染。
//
// 修复: 在 dylib 加载时，将 ElectronNSWindow/ElectronNSPanel 的
// _cornerMask 实现替换为其父类（NSWindow/NSPanel）的默认实现，
// 恢复 AppKit 的缓存优化。
//
// 用法: DYLD_INSERT_LIBRARIES=/path/to/fix-electron-cornermask.dylib
// 对非 Electron 进程完全无操作（仅做一次 class lookup 后返回）。
//
// Bug: https://github.com/electron/electron/issues/48311
// Fix: https://github.com/electron/electron/pull/48376

#import <objc/runtime.h>
#import <stdio.h>

// 检查某个类是否直接定义了指定 selector（非继承）
static int classDirectlyImplementsSelector(Class cls, SEL sel) {
    unsigned int count;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return 0;
    int found = 0;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = 1;
            break;
        }
    }
    free(methods);
    return found;
}

// 将指定类的 _cornerMask 实现替换为其父类的默认实现
static void removeCornerMaskOverride(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) return;

    SEL sel = sel_registerName("_cornerMask");
    if (!classDirectlyImplementsSelector(cls, sel)) return;

    Class super = class_getSuperclass(cls);
    if (!super) return;

    Method superMethod = class_getInstanceMethod(super, sel);
    if (!superMethod) return;

    Method method = class_getInstanceMethod(cls, sel);
    method_setImplementation(method, method_getImplementation(superMethod));

    fprintf(stderr, "[fix-electron-cornermask] patched %s._cornerMask\n", className);
}

__attribute__((constructor))
static void fix_electron_cornermask(void) {
    removeCornerMaskOverride("ElectronNSWindow");
    removeCornerMaskOverride("ElectronNSPanel");
}
