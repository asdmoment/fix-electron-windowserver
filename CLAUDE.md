# CLAUDE.md

## What This Is

A macOS 26 Tahoe workaround for the Electron `_cornerMask` bug ([electron/electron#48311](https://github.com/electron/electron/issues/48311)) that causes WindowServer GPU spikes. Injects a tiny dylib via `LSEnvironment` + `DYLD_INSERT_LIBRARIES` to swizzle away the `_cornerMask` override in `ElectronNSWindow`.

## Build & Run

```bash
make build   # clang → fix-electron-cornermask.dylib
make install # copy dylib + scripts to ~/.local/bin
make apply   # scan /Applications, inject + re-sign unpatched Electron apps
make status  # dry-run scan
make uninstall
```

## Architecture

Two files do all the work:

1. **`fix-electron-cornermask.m`** (~60 lines) — Objective-C dylib with a `__attribute__((constructor))` that:
   - Checks if `ElectronNSWindow` / `ElectronNSPanel` classes exist
   - If they directly override `_cornerMask`, replaces the IMP with the superclass default
   - No-op for non-Electron processes or patched Electron versions

2. **`fix-electron-cornermask-apply.sh`** (~180 lines) — Bash script that:
   - Scans `/Applications` for Electron apps with unpatched versions (< 36.9.2 / 37.6.0 / 38.2.0 / 39.0.0)
   - Adds `DYLD_INSERT_LIBRARIES` to each app's `Info.plist` via `LSEnvironment`
   - For hardened runtime apps without `allow-dyld-environment-variables`: extracts entitlements, adds the key, re-signs
   - Supports `--dry-run`, `--force`, `--remove`

## Key Design Decisions

- **Why LSEnvironment, not `launchctl setenv`**: SIP blocks `launchctl setenv DYLD_*` on macOS. Per-app `LSEnvironment` in `Info.plist` works because Launch Services sets the env before process start, and dyld respects it for non-hardened or properly entitled binaries.
- **Why swizzle `_cornerMask`, not disable shadows**: The bug is about AppKit's method identity check forcing dynamic corner mask re-rendering, not shadows. Disabling shadows via `CGSSetWindowShadowAndRimParameters` from an external process doesn't fix the root cause and doesn't persist.
- **Chrome is NOT affected**: Chrome uses `NativeWidgetMacNSWindow` directly without the Electron `_cornerMask` override layer.

## WindowServer Invalid Window 调查记录

### 问题

在调查 Electron GPU 占用问题的过程中，发现系统日志中有另一个独立的高频错误：

```
_CGXPackagesSetWindowConstraints: Invalid window
```

每 10 秒约 17-22 次，仅在 biliacat 用户账户出现，新建用户无此问题。

### 调查路径

#### 第一阶段：定位错误来源
- 通过 `log stream` 和进程关联分析，确认错误来自 WindowServer 内部的 Packages 约束系统
- 通过 SkyLight 反汇编定位到错误触发点：`_WindowSendRightsGrantOfferedNotification + 0xc4`（偏移 0x1EF09C）
- 调用链：Timer → `_CGXPackagesSetWindowConstraints` → 权限授予 → `_WindowSendRightsGrantOfferedNotification` → 窗口无效 → 报错

#### 第二阶段：排除嫌疑
- 逐个杀死进程测试（NotificationCenter、WindowManager、Dock）— 效果不稳定且不持久
- 排除 Finder Sync 扩展（BetterZip、Keka）
- 排除幽灵窗口（遍历所有窗口 ID，零幽灵）
- 排除特定进程（Surge 是最强触发器，但不是根因）

#### 第三阶段：发现根因
- `com.apple.spaces.plist` 中存在 4 个「Collapsed Space」幽灵条目，关联已断开的外接显示器
- `com.apple.windowserver.displays.plist` 中保留了 5 个历史显示器的 6+ 配置
- WindowServer 在登录时加载这些配置，为幽灵显示器的窗口创建约束记录
- 约束循环每 0.5-1 秒尝试管理已销毁的窗口 → 权限授予失败 → 报错

#### 第四阶段：尝试修复（全部失败）
1. **Plist 清理 + 注销/登录** — WindowServer 在注销时将内存中的脏状态写回 plist，覆盖了清理
2. **SkyLight SPI 操作** — `SLSSpaceDestroy`、`SLSRestorePackagesManagementPersistenceData`、显示重配置 — 均返回成功但无实际效果
3. **从其他用户清理 plist** — 创建临时管理员 tmpfix，从该账户清理 biliacat 的 plist → 重启后问题依旧，WindowServer 不知从何处重新生成了幽灵条目
4. **LaunchDaemon 开机清理** — 在用户登录前清理 plist → 同样无效

### 结论

这是 macOS 26 WindowServer 的内部 bug。幽灵显示器/Spaces 的状态不仅存储在用户可编辑的 plist 中，还缓存在 WindowServer 的内部数据库或 CoreGraphics 会话状态中，用户态无法触及。只有 Apple 在系统更新中修复才能彻底解决。

该错误仅为日志刷屏，不影响实际功能和系统稳定性。
