# fix-electron-windowserver

修复 macOS 26 Tahoe 上 Electron 应用导致 WindowServer 持续高 CPU/GPU 占用的问题。

## 问题背景

macOS 26 Tahoe 改变了 WindowServer 对窗口 corner mask 的处理方式。AppKit 通过 **方法身份检查(method identity check)** 决定是否缓存窗口圆角遮罩：

- 系统默认实现 → 使用共享缓存，mask 视为静态
- 子类覆写（即使只是调用 super）→ 标记为自定义，**每个窗口每帧重新渲染** → 持续高负载

Electron 的 `ElectronNSWindow` 覆写了私有 API `_cornerMask`（用于自定义 vibrant 窗口的圆角遮罩），触发了 WindowServer 的动态合成路径。

**典型症状：**
- WindowServer 进程 CPU 占用 30%–100%
- 系统全局卡顿掉帧
- 最小化所有 Electron 应用后恢复正常
- 使用时间越长越卡

**上游修复：** [electron/electron#48376](https://github.com/electron/electron/pull/48376)，已合入 Electron 36.9.2 / 37.6.0 / 38.2.0 / 39.0.0+。但大量应用仍在使用旧版 Electron。

**注意：Chrome 浏览器不受此 bug 影响。** Chrome 使用 Chromium 的 `NativeWidgetMacNSWindow`，没有 Electron 的 `ElectronNSWindow` 层，不覆写 `_cornerMask`。

## 工作原理

本工具通过 **DYLD_INSERT_LIBRARIES 注入** 在 Electron 应用启动时加载一个微型 dylib，从根源修复问题：

1. dylib 在加载时（`__attribute__((constructor))`）检查当前进程是否存在 `ElectronNSWindow` 类
2. 如果存在且直接覆写了 `_cornerMask`，将其实现替换为父类（NSWindow）的默认实现
3. 恢复 AppKit 的缓存优化，WindowServer 不再逐帧重新渲染 corner mask
4. 对非 Electron 进程、已修复版本、Chrome 浏览器完全无操作

注入方式是修改每个未修复 Electron 应用的 `Info.plist`，添加 `LSEnvironment.DYLD_INSERT_LIBRARIES`。对于启用了 hardened runtime 但缺少 `allow-dyld-environment-variables` entitlement 的应用，脚本会自动提取现有 entitlements、添加该权限并重签名。

## 另一个独立的 Tahoe 卡顿问题

macOS 26 Tahoe 还存在另一条与本项目 **无关** 的卡顿问题：`NSAutoFillHeuristicController` 在长时间运行后导致 Chrome、Zed、Ghostty、VS Code、iTerm2、Kitty、Alacritty 等文本密集应用逐渐变卡（CPU 单核 100%）。

**截至 macOS 26.4 (25E241)，Apple 仍未修复此 bug。** Ghostty、Zed、Kitty、iTerm2 等应用已各自在代码中加入 workaround。如果你使用的应用没有内置 workaround，需要手动设置全局开关。

**参考：**
- [ghostty-org/ghostty#8625](https://github.com/ghostty-org/ghostty/pull/8625) — Ghostty 的 workaround，被多个项目引用
- [zed-industries/zed#33182](https://github.com/zed-industries/zed/issues/33182)
- [alacritty/alacritty#8696](https://github.com/alacritty/alacritty/issues/8696)

**全局 workaround：**

```bash
defaults write -g NSAutoFillHeuristicControllerEnabled -bool false
```

写入一次即可持久生效。建议执行后注销或重启。副作用：可能影响短信验证码、密码等自动填充。

恢复默认：`defaults delete -g NSAutoFillHeuristicControllerEnabled`

## 系统要求

- macOS 26 Tahoe
- Apple Silicon 或 Intel Mac
- Xcode Command Line Tools（用于编译 dylib）

## 安装

```bash
git clone https://github.com/asdmoment/fix-electron-windowserver.git
cd fix-electron-windowserver
make install        # 编译 dylib 并安装到 ~/.local/bin/
make apply          # 扫描并修补所有未修复的 Electron 应用
```

自定义安装路径：

```bash
make install PREFIX=/usr/local
```

## 使用

安装后可直接用 `fix-electron` 命令：

```bash
fix-electron              # 扫描并修补所有未修复的 Electron 应用
fix-electron --dry-run    # 仅扫描，不修改
fix-electron --force      # 强制重新应用（app 更新后使用）
fix-electron --remove     # 完全移除所有注入
```

也可通过 Makefile：

```bash
make apply    # 等同于 fix-electron
make status   # 等同于 fix-electron --dry-run
make uninstall
```

输出示例：

```
fix-electron-cornermask-apply
  dylib: /Users/you/.local/bin/fix-electron-cornermask.dylib

FOUND: Motrix (Electron 22.3.7)
  重签名 (添加 allow-dyld entitlement)...
  OK
FOUND: QQ (Electron 37.1.0)
  重签名 (保留 entitlements)...
  OK
SKIP: Termius (Electron 21.4.4) — 已注入

完成: 2 个已修补, 1 个已跳过, 0 个失败
```

## 何时需要重新运行

本工具没有后台进程或开机自启动，修改一次 `Info.plist` 即可持久生效。以下情况需要重新运行 `fix-electron`：

- **Electron 应用更新后** — 更新会覆盖 `Info.plist`，注入配置丢失
- **安装了新的 Electron 应用后** — 脚本每次运行时扫描 `/Applications` 全量检测

```bash
fix-electron
# 或
fix-electron --force  # 强制重新应用所有（包括已注入的）
```

## 关于重签名

对于启用了 hardened runtime 但缺少 `allow-dyld-environment-variables` entitlement 的应用，脚本需要重签名（ad-hoc）。这意味着：

- 原始开发者签名和 Apple 公证会丢失
- Gatekeeper 可能在首次启动时弹出确认
- 应用功能不受影响
- 应用自动更新后需要重新运行脚本
- 开机自启动不受影响（macOS 通过 bundle ID 识别，不依赖签名身份）

## 何时可以卸载

当你常用的 Electron 应用全部更新到以下版本之后，可以安全卸载：

| Electron 分支 | 修复版本 |
|--------------|---------|
| 36.x | ≥ 36.9.2 |
| 37.x | ≥ 37.6.0 |
| 38.x | ≥ 38.2.0 |
| 39.x+ | 全部已修复 |

卸载前先移除注入：`fix-electron --remove`，然后 `make uninstall`。

## 附录：WindowServer `_CGXPackagesSetWindowConstraints: Invalid window` 调查

在调查 Electron GPU 占用问题的过程中，我们在同一台机器上发现了另一个独立的 WindowServer 问题：系统日志中高频刷屏 `_CGXPackagesSetWindowConstraints: Invalid window`，约每秒 2 次。这个问题与 Electron `_cornerMask` bug 无关，但因为都涉及 WindowServer 异常行为，在此一并记录调查过程。

### 现象

- 仅在特定用户账户出现，新建测试用户无此问题
- 安全模式下仍可复现
- 错误从登录开始持续存在，不随应用退出而消失
- Surge 是最强触发器，但非根因

### 根因分析

通过 SkyLight 框架反汇编，定位到错误触发点为 `_WindowSendRightsGrantOfferedNotification`。调用链：

```
Timer tick → _CGXPackagesSetWindowConstraints → 权限授予 → _WindowSendRightsGrantOfferedNotification → 窗口已销毁 → 报错
```

进一步调查发现，用户的 `com.apple.spaces.plist` 中存在 4 个「Collapsed Space」幽灵条目，对应已断开的外接显示器（历史上连接过 4 台不同的外接显示器）。WindowServer 在登录时加载这些配置，为幽灵显示器上下文创建窗口约束记录，然后持续尝试管理已销毁的窗口。

### 尝试过的修复方法（均失败）

| 方法 | 结果 |
|------|------|
| 清理 spaces.plist 后注销重登 | WindowServer 注销时将内存脏状态写回，覆盖清理 |
| SLSSpaceDestroy 销毁幽灵 Space | API 返回成功但无实际效果 |
| SLSRestorePackagesManagementPersistenceData | 只会追加不会替换 |
| CGDisplayConfig 显示重配置 | 无效果 |
| 从另一个管理员账户清理 plist + 重启 | 幽灵条目重新生成 |
| LaunchDaemon 开机前清理 | 同样无效 |
| 杀进程（NotificationCenter/WindowManager/Dock） | 效果不稳定且不持久 |

### 结论

这是 macOS 26 (Tahoe) WindowServer 的内部 bug。幽灵显示器状态不仅存储在用户可编辑的 plist 中，还缓存在 WindowServer 内部数据库或 CoreGraphics 会话状态中，用户态工具无法触及。该错误仅为日志刷屏，不影响实际功能。等待 Apple 在后续系统更新中修复。

已向 Apple 提交 bug report（见 [`apple-bug-report.txt`](apple-bug-report.txt)）。

### 调查中使用的诊断工具

调查过程中编写了多个 Objective-C 诊断工具（均在 `/tmp` 中临时使用）：

- `probe_ghost_wins.m` — 遍历所有窗口 ID 检测幽灵窗口
- `find_invalid_wins.m` — 交叉比对 Space 窗口与实际存活窗口
- `packages_diag2.m` — 导出 Packages 持久化字典
- `destroy_spaces.m` — 尝试 SLSSpaceDestroy 销毁幽灵 Space
- `find_skylight.m` — 定位 SkyLight 基址并符号化错误偏移
- `disasm_error.m` — 映射错误点附近的函数

## 致谢

- [@avarayr](https://github.com/avarayr) 发现根因并提交 [PR #48376](https://github.com/electron/electron/pull/48376)
- Electron 维护团队快速合并和 backport

## License

[MIT](LICENSE)
