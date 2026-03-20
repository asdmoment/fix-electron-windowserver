# fix-electron-windowserver

修复 macOS 26 Tahoe 上 Electron 应用导致 WindowServer 持续高 CPU/GPU 占用的问题。

## 问题背景

macOS 26 Tahoe 改变了 WindowServer 对窗口 corner mask 的处理方式。AppKit 通过检查 `_cornerMask` 方法的实现者来决定是否使用共享缓存：

- 系统标准实现 → 使用共享缓存，mask 视为静态
- 子类覆写 → 标记为自定义，**每个窗口每帧重新渲染** → 持续高负载

Electron 的 `ElectronNSWindow` 恰好覆写了 `_cornerMask`（即使只是调用 super），导致 WindowServer 对每个 Electron 窗口做动态合成。

**典型症状：**
- WindowServer 进程 CPU 占用 30%–100%
- 系统全局卡顿掉帧，拖动窗口、滚动页面不流畅
- 最小化所有 Electron 应用后恢复正常
- 使用时间越长越卡

**上游修复：** [electron/electron#48376](https://github.com/electron/electron/pull/48376)，已合入 Electron 36.9.2 / 37.6.0 / 38.2.0 / 39.0.0+。但大量应用仍在使用旧版 Electron，短期内无法得到更新。

## 工作原理

1. 每 5 分钟扫描 `/Applications` 目录，从 Electron Framework 二进制中提取版本号
2. 识别出使用未修复版本（< 36.9.2 / 37.6.0 / 38.2.0 / 39.0.0）的应用
3. 检查这些应用的窗口，通过 CoreGraphics 私有 API 禁用窗口阴影
4. 监听应用启动事件（`NSWorkspace` 通知），检测到未修复应用启动后立即每秒轮询其窗口
5. **开机前 5 分钟每 1 秒轮询**，之后自动切换为每 10 秒
6. 启动时等待 WindowServer 就绪（最多 30 秒），确保在 GUI session 建立后才开始工作
7. 禁用 App Nap，防止 macOS 在开机期间节流定时器
8. 新安装的 Electron 应用会在下次扫描时自动识别

### LaunchAgent 配置

- `RunAtLoad: true` — 开机自动启动
- `KeepAlive: true` — 崩溃后自动重启
- `ProcessType: Adaptive` — 允许系统根据负载动态调度优先级，比 Background 更快获得 CPU 时间片，确保开机早期能及时修复窗口

## 系统要求

- macOS 26 Tahoe
- Apple Silicon 或 Intel Mac
- Xcode Command Line Tools（用于编译）

## 安装

```bash
git clone https://github.com/asdmoment/fix-electron-windowserver.git
cd fix-electron-windowserver
make install
```

默认安装到 `/usr/local/bin`，可通过 `PREFIX` 自定义：

```bash
make install PREFIX=$HOME/.local
```

安装后自动以 LaunchAgent 方式运行，开机自启动。

## 使用

```bash
# 查看运行状态
make status

# 查看实时日志
make log

# 停止
make stop

# 启动
make start

# 重启
make restart

# 卸载
make uninstall
```

日志输出示例：

```
fix-electron-windowserver
  问题: Electron _cornerMask 覆写导致 macOS 26 WindowServer 高负载
  方案: 自动检测未修复应用并禁用其窗口阴影
  轮询: 1s (开机 300s 内) → 10s | 应用扫描: 300s

[5:51:55 PM] 扫描完成: 发现 3 个未修复的 Electron 应用:
  - Motrix (Electron 22.3.7)
  - QQ (Electron 37.1.0)
  - Termius (Electron 21.4.4)
[5:51:57 PM] 已禁用阴影: QQ 窗口 6717
[5:51:57 PM] 已禁用阴影: Motrix 窗口 6236
[5:56:55 PM] 启动期结束，轮询间隔切换为 10s
```

## 副作用

- 受影响应用的窗口阴影会消失（纯视觉差异，不影响功能）
- 当应用更新到已修复的 Electron 版本后，工具会自动停止对其处理

## 何时可以卸载

当你常用的 Electron 应用全部更新到以下版本之后，可以安全卸载：

| Electron 分支 | 修复版本 |
|--------------|---------|
| 36.x | ≥ 36.9.2 |
| 37.x | ≥ 37.6.0 |
| 38.x | ≥ 38.2.0 |
| 39.x+ | 全部已修复 |

## 致谢

- [@avarayr](https://github.com/avarayr) 发现根因并提交 [PR #48376](https://github.com/electron/electron/pull/48376)
- [@fredizzimo](https://github.com/fredizzimo) 协助调试
- Electron 维护团队快速合并和 backport

## License

[MIT](LICENSE)
