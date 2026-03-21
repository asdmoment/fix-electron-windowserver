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
