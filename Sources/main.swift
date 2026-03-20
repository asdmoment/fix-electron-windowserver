// fix-electron-windowserver
// 自动检测所有未修复 _cornerMask bug 的 Electron 应用，禁用其窗口阴影，
// 防止 macOS 26 Tahoe 上 WindowServer 持续高 CPU/GPU 占用。
//
// Bug: https://github.com/electron/electron/issues/48311
// Fix: https://github.com/electron/electron/pull/48376
// 修复版本: Electron 36.9.2 / 37.6.0 / 38.2.0 / 39.0.0+

import Cocoa

// MARK: - Private CoreGraphics SPI

@_silgen_name("CGSSetWindowShadowAndRimParameters")
func CGSSetWindowShadowAndRimParameters(
    _ cid: Int32, _ wid: Int32,
    _ standardDeviation: CGFloat, _ density: CGFloat,
    _ offsetDx: Int32, _ offsetDy: Int32, _ rimDensity: CGFloat
) -> Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

// MARK: - Version

struct ElectronVersion: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int

    init?(_ str: String) {
        let parts = str.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        major = parts[0]; minor = parts[1]; patch = parts[2]
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ElectronVersion, rhs: ElectronVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// 判断该版本是否已包含 _cornerMask 修复
    var isPatched: Bool {
        switch major {
        case ..<36: return false
        case 36:    return self >= ElectronVersion("36.9.2")!
        case 37:    return self >= ElectronVersion("37.6.0")!
        case 38:    return self >= ElectronVersion("38.2.0")!
        default:    return true
        }
    }
}

// MARK: - App Scanner

/// 扫描 /Applications 下所有 Electron 应用，返回未修复的 [显示名: 版本号]
func scanForUnpatchedElectronApps() -> [String: String] {
    var results: [String: String] = [:]
    let fm = FileManager.default
    let appsDir = "/Applications"

    guard let apps = try? fm.contentsOfDirectory(atPath: appsDir) else {
        log("无法列出 /Applications 目录")
        return results
    }

    for appName in apps where appName.hasSuffix(".app") {
        let appPath = "\(appsDir)/\(appName)"

        // Electron Framework 的常见位置（含 QQ 的 QQNT.framework 变体）
        let candidates = [
            "\(appPath)/Contents/Frameworks/Electron Framework.framework/Electron Framework",
            "\(appPath)/Contents/Frameworks/QQNT.framework/Versions/A/QQNT",
        ]

        for binaryPath in candidates {
            guard fm.fileExists(atPath: binaryPath) else { continue }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            proc.arguments = ["-aoE", "-m", "1", "Electron/[0-9]+\\.[0-9]+\\.[0-9]+", binaryPath]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { continue }

            let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
            let versionStr = firstLine.replacingOccurrences(of: "Electron/", with: "")
            guard let version = ElectronVersion(versionStr), !version.isPatched else { continue }

            results[appName.replacingOccurrences(of: ".app", with: "")] = versionStr
            break
        }
    }

    return results
}

// MARK: - Window Patching

func getWindowsForApps(_ appNames: Set<String>) -> [(wid: Int32, owner: String)] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              appNames.contains(owner),
              let wid = info[kCGWindowNumber as String] as? Int32,
              (info[kCGWindowLayer as String] as? Int) == 0
        else { return nil }
        return (wid, owner)
    }
}

var patchedWindows = Set<Int32>()

func disableShadows(for windows: [(wid: Int32, owner: String)]) {
    let cid = CGSMainConnectionID()
    for (wid, owner) in windows where !patchedWindows.contains(wid) {
        if CGSSetWindowShadowAndRimParameters(cid, wid, 0, 0, 0, 0, 0) == 0 {
            patchedWindows.insert(wid)
            log("已禁用阴影: \(owner) 窗口 \(wid)")
        }
    }
}

// MARK: - Logging

func log(_ message: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(ts)] \(message)")
}

// MARK: - Main

setlinebuf(stdout)

let windowCheckInterval: TimeInterval = 10
let appScanInterval: TimeInterval = 300
var knownUnpatchedApps = Set<String>()
var lastAppScan: Date = .distantPast

func refreshAppListIfNeeded() {
    let now = Date()
    guard now.timeIntervalSince(lastAppScan) >= appScanInterval else { return }
    lastAppScan = now

    let unpatched = scanForUnpatchedElectronApps()
    knownUnpatchedApps = Set(unpatched.keys)

    if unpatched.isEmpty {
        log("扫描完成: 未发现需要修复的 Electron 应用")
    } else {
        log("扫描完成: 发现 \(unpatched.count) 个未修复的 Electron 应用:")
        for (name, ver) in unpatched.sorted(by: { $0.key < $1.key }) {
            print("  - \(name) (Electron \(ver))")
        }
    }
}

func tick() {
    refreshAppListIfNeeded()
    guard !knownUnpatchedApps.isEmpty else { return }

    let windows = getWindowsForApps(knownUnpatchedApps)
    if !windows.isEmpty {
        disableShadows(for: windows)
        patchedWindows = patchedWindows.intersection(Set(windows.map(\.wid)))
    }
}

print("fix-electron-windowserver")
print("  问题: Electron _cornerMask 覆写导致 macOS 26 WindowServer 高负载")
print("  方案: 自动检测未修复应用并禁用其窗口阴影")
print("  窗口检查间隔: \(Int(windowCheckInterval))s | 应用扫描间隔: \(Int(appScanInterval))s")
print("")

tick()

Timer.scheduledTimer(withTimeInterval: windowCheckInterval, repeats: true) { _ in tick() }
RunLoop.current.run()
