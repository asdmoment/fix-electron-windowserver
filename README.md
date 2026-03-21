# fix-electron-windowserver

修复 macOS 26 Tahoe 上 Electron 应用导致 WindowServer 持续高 CPU/GPU 占用的问题。

## 问题背景

macOS 26 Tahoe 改变了 WindowServer 对窗口 corner mask 的处理方式。AppKit 通过**方法身份检查（method identity check）**决定是否缓存窗口圆角遮罩：

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

与之前基于 `CGSSetWindowShadowAndRimParameters` 的外部阴影禁用方案不同，本方案：
- **从根源修复**：移除 `_cornerMask` override，而不是试图关闭阴影
- **窗口阴影保留**：不影响视觉效果
- **无需常驻守护进程**：修改一次 Info.plist 即可持久生效，无需轮询
- **精确控制**：仅影响未修复的 Electron 应用

## 另一个独立的 Tahoe 卡顿问题

macOS 26 Tahoe 还存在另一条与本项目 **无关** 的卡顿问题：`NSAutoFillHeuristicController` 可能在长时间运行后导致 Chrome、Zed、Ghostty、VS Code 等文本密集应用逐渐变卡。

**参考：**
- [zed-industries/zed#33182 comment 3289846957](https://github.com/zed-industries/zed/issues/33182#issuecomment-3289846957)
- [ghostty-org/ghostty#8625](https://github.com/ghostty-org/ghostty/pull/8625)

**全局 workaround：**

```bash
defaults write -g NSAutoFillHeuristicControllerEnabled -bool false
```

写入一次即可持久生效。建议执行后注销或重启，让新会话生效。可能影响自动填充体验。

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

```bash
# 扫描未修复的 Electron 应用（不修改）
make status

# 应用补丁（扫描 + 注入 + 重签名）
make apply

# 强制重新应用（app 更新后使用）
fix-electron-cornermask-apply.sh --force

# 完全移除所有注入
fix-electron-cornermask-apply.sh --remove

# 卸载工具
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

## App 更新后怎么办

应用更新会覆盖 `Info.plist`，移除注入配置。只需重新运行：

```bash
fix-electron-cornermask-apply.sh
# 或
fix-electron-cornermask-apply.sh --force  # 强制重新应用所有
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

卸载前先移除注入：`fix-electron-cornermask-apply.sh --remove`，然后 `make uninstall`。

## 致谢

- [@avarayr](https://github.com/avarayr) 发现根因并提交 [PR #48376](https://github.com/electron/electron/pull/48376)
- Electron 维护团队快速合并和 backport

## License

[MIT](LICENSE)
