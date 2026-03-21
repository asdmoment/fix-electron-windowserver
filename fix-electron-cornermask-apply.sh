#!/bin/bash
# fix-electron-cornermask-apply.sh
#
# 扫描 /Applications 中未修复 _cornerMask bug 的 Electron 应用，
# 通过 LSEnvironment + DYLD_INSERT_LIBRARIES 注入 fix-electron-cornermask.dylib。
# 对需要重签名的应用自动添加 allow-dyld-environment-variables entitlement。
#
# 用法: fix-electron-cornermask-apply.sh [--dry-run] [--force] [--remove]
#   --dry-run  仅扫描，不修改
#   --force    即使已注入也重新应用
#   --remove   移除所有已注入的 LSEnvironment 配置并重签名

set -euo pipefail

# dylib 路径：与本脚本同目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$SCRIPT_DIR/fix-electron-cornermask.dylib"
APPS_DIR="/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

DRY_RUN=false
FORCE=false
REMOVE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        --remove)  REMOVE=true ;;
    esac
done

# Electron 修复版本阈值
is_patched() {
    local ver="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$ver"
    case "$major" in
        [0-9]|[12][0-9]|3[0-5]) return 1 ;;  # <36: 未修复
        36) [ "$minor" -gt 9 ] || { [ "$minor" -eq 9 ] && [ "$patch" -ge 2 ]; } ;;
        37) [ "$minor" -gt 6 ] || { [ "$minor" -eq 6 ] && [ "$patch" -ge 0 ]; } ;;
        38) [ "$minor" -gt 2 ] || { [ "$minor" -eq 2 ] && [ "$patch" -ge 0 ]; } ;;
        *) return 0 ;;  # >=39: 已修复
    esac
}

# 检测 Electron 版本
detect_electron_version() {
    local app_path="$1"
    local candidates=(
        "$app_path/Contents/Frameworks/Electron Framework.framework/Electron Framework"
        "$app_path/Contents/Frameworks/QQNT.framework/Versions/A/QQNT"
    )
    for bin in "${candidates[@]}"; do
        [ -f "$bin" ] || continue
        local ver
        ver=$(grep -aoE -m 1 'Electron/[0-9]+\.[0-9]+\.[0-9]+' "$bin" 2>/dev/null | head -1 | sed 's/Electron\///')
        if [ -n "$ver" ]; then
            echo "$ver"
            return 0
        fi
    done
    return 1
}

# 检查是否需要添加 allow-dyld entitlement
needs_dyld_entitlement() {
    local app_path="$1"
    local flags
    flags=$(codesign -dvv "$app_path" 2>&1 | grep "flags=" | head -1)
    echo "$flags" | grep -q "runtime" || return 1
    codesign -d --entitlements - "$app_path" 2>&1 | grep -q "allow-dyld-environment-variables" && return 1
    return 0
}

# 提取当前 entitlements 并添加 allow-dyld
create_entitlements_with_dyld() {
    local app_path="$1"
    local out_plist="$2"
    local ents
    ents=$(codesign -d --entitlements - "$app_path" 2>&1)

    local keys=()
    while IFS= read -r line; do
        if echo "$line" | grep -q '\[Key\]'; then
            keys+=("$(echo "$line" | sed 's/.*\[Key\] //')")
        fi
    done <<< "$ents"

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        for key in "${keys[@]}"; do
            echo "    <key>$key</key><true/>"
        done
        echo "    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>"
        echo '</dict>'
        echo '</plist>'
    } > "$out_plist"
}

# --remove 模式
if $REMOVE; then
    echo "fix-electron-cornermask: 移除注入..."
    removed=0
    for app_dir in "$APPS_DIR"/*.app; do
        app_name=$(basename "$app_dir" .app)
        existing=$(defaults read "$app_dir/Contents/Info" LSEnvironment 2>/dev/null | grep "fix-electron-cornermask" 2>/dev/null) || true
        [ -n "$existing" ] || continue

        echo "  移除: $app_name"
        defaults delete "$app_dir/Contents/Info" LSEnvironment 2>/dev/null || true
        codesign --force --deep --preserve-metadata=entitlements -s - "$app_dir" 2>/dev/null || true
        "$LSREGISTER" -f "$app_dir" 2>/dev/null
        removed=$((removed + 1))
    done
    echo "已移除 $removed 个应用的注入"
    exit 0
fi

echo "fix-electron-cornermask-apply"
echo "  dylib: $DYLIB"
echo ""

if [ ! -f "$DYLIB" ]; then
    echo "错误: dylib 不存在: $DYLIB"
    echo "请先运行 'make build' 编译"
    exit 1
fi

patched=0
skipped=0
failed=0

for app_dir in "$APPS_DIR"/*.app; do
    app_name=$(basename "$app_dir" .app)

    ver=$(detect_electron_version "$app_dir" 2>/dev/null) || continue

    if is_patched "$ver"; then
        continue
    fi

    if ! $FORCE; then
        existing=$(defaults read "$app_dir/Contents/Info" LSEnvironment 2>/dev/null | grep "fix-electron-cornermask" 2>/dev/null) || true
        if [ -n "$existing" ]; then
            echo "SKIP: $app_name (Electron $ver) — 已注入"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    echo "FOUND: $app_name (Electron $ver)"

    if $DRY_RUN; then
        if needs_dyld_entitlement "$app_dir"; then
            echo "  → 需要重签名 (添加 allow-dyld entitlement)"
        else
            echo "  → 可直接注入"
        fi
        continue
    fi

    # 备份 Info.plist
    cp "$app_dir/Contents/Info.plist" "/tmp/${app_name}-Info.plist.backup" 2>/dev/null || true

    # 添加 LSEnvironment
    defaults write "$app_dir/Contents/Info" LSEnvironment -dict-add \
        DYLD_INSERT_LIBRARIES -string "$DYLIB" 2>/dev/null || \
    defaults write "$app_dir/Contents/Info" LSEnvironment -dict \
        DYLD_INSERT_LIBRARIES -string "$DYLIB"

    # 重签名
    if needs_dyld_entitlement "$app_dir"; then
        echo "  重签名 (添加 allow-dyld entitlement)..."
        ents_plist="/tmp/${app_name}-ents.plist"
        create_entitlements_with_dyld "$app_dir" "$ents_plist"
        if codesign --force --deep --entitlements "$ents_plist" -s - "$app_dir" 2>&1; then
            echo "  OK"
        else
            echo "  FAIL: 重签名失败"
            failed=$((failed + 1))
            continue
        fi
    else
        echo "  重签名 (保留 entitlements)..."
        if codesign --force --deep --preserve-metadata=entitlements -s - "$app_dir" 2>&1; then
            echo "  OK"
        else
            echo "  FAIL: 重签名失败"
            failed=$((failed + 1))
            continue
        fi
    fi

    "$LSREGISTER" -f "$app_dir" 2>/dev/null
    patched=$((patched + 1))
done

echo ""
echo "完成: $patched 个已修补, $skipped 个已跳过, $failed 个失败"
