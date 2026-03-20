# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS 26 Tahoe workaround for the Electron `_cornerMask` bug ([electron/electron#48311](https://github.com/electron/electron/issues/48311)) that causes WindowServer to spike to 30-100% CPU. Runs as a LaunchAgent, auto-detects unpatched Electron apps, and disables their window shadows via private CoreGraphics SPI.

## Build & Run

```bash
make build                            # swiftc -O Sources/main.swift → binary
make install                          # install to /usr/local/bin + LaunchAgent
make install PREFIX=$HOME/.local      # custom prefix
make start / stop / restart / status  # manage LaunchAgent
make log                              # tail ~/Library/Logs/fix-electron-windowserver.log
make uninstall                        # remove binary + LaunchAgent
```

Single source file: `Sources/main.swift`. No package manager, no tests — just `swiftc`.

## Architecture

All logic is in `Sources/main.swift` (~230 lines). Three-layer design:

1. **App Scanner** — scans `/Applications` every 5 min, greps Electron Framework binaries for version strings, checks against patched version table (36.9.2 / 37.6.0 / 38.2.0 / 39+). Handles QQ's `QQNT.framework` variant.

2. **Window Patcher** — uses `CGWindowListCopyWindowInfo` to find windows owned by unpatched apps, calls `CGSSetWindowShadowAndRimParameters(cid, wid, 0, 0, 0, 0, 0)` to disable shadows. Tracks patched window IDs to avoid redundant calls.

3. **Smart Polling** — 2s interval during first 2 min after boot (with App Nap disabled via `beginActivity`), then 10s. Also listens for `NSWorkspace.didLaunchApplicationNotification` to fast-patch newly launched apps at 1s intervals.

## Key Implementation Notes

- Private SPI: `CGSSetWindowShadowAndRimParameters` and `CGSMainConnectionID` via `@_silgen_name`
- `ElectronVersion` struct handles semver comparison and patch status
- `launchagent.plist.template` uses `__BINARY__`, `__LOG_PATH__`, `__LABEL__` placeholders substituted by Makefile
- Binary is gitignored; users build from source
