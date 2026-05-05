#!/bin/bash
# fix-electron-cornermask-apply.sh
#
# 扫描 /Applications 中未修复 _cornerMask bug 的 macOS 应用，并通过
# LSEnvironment + DYLD_INSERT_LIBRARIES 注入修复 dylib。
#
# 检测覆盖范围：
#   - Electron 应用：按版本判断（Electron < 36.9.2 / 37.6.0 / 38.2.0 / 39.0.0
#     未修复），用 fix-electron-cornermask.dylib。
#   - 任何原生应用：扫描 .app 内所有 Mach-O 二进制的 Objective-C metadata，
#     如果有类直接 override 私有 _cornerMask 选择子则视为受影响，使用
#     fix-easydict-cornermask.dylib（按 NSWindow 子类全量扫描的通用版）。
#
# 重签名时只保留可安全用于 ad-hoc 签名的 entitlements，并添加
# allow-dyld-environment-variables，避免保留开发者团队绑定的受限权限。
# 注意：原生应用（尤其 Parallels、CleanMyMac 等带 helper / 系统扩展的）
# ad-hoc 重签很可能剥离关键权限并破坏功能，默认仅扫描，不自动注入。
#
# 用法: fix-electron-cornermask-apply.sh [--dry-run] [--force] [--remove]
#                                        [--scan-only] [--apply-native]
#   --dry-run        仅扫描，不修改
#   --force          即使已注入也重新应用
#   --remove         移除所有已注入的 LSEnvironment 配置并重签名
#   --scan-only      只输出扫描报告（默认在没有任何动作参数时也是这个行为）
#   --apply-native   对带 _cornerMask override 的非 Electron 应用也注入
#                    （会重签名并可能剥离原 Team ID 绑定的 entitlements，
#                    系统扩展、helper、kernel ext 类应用慎用）

set -euo pipefail

# dylib 路径：与本脚本同目录
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
DYLIB_ELECTRON="$SCRIPT_DIR/fix-electron-cornermask.dylib"
DYLIB_GENERIC="$SCRIPT_DIR/fix-easydict-cornermask.dylib"
# 兼容旧变量名（仅 Electron 路径仍读这个值）
DYLIB="$DYLIB_ELECTRON"
APPS_DIR="/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

# 列出 .app 内值得扫描的 Mach-O 文件（主二进制、Frameworks、PlugIns、
# XPCServices、Helpers、Library 下的可执行文件）。
list_app_machos() {
    local app_path="$1"
    find "$app_path/Contents" -type f -perm -111 \
        \( -path '*/Contents/MacOS/*' \
        -o -path '*/Contents/Frameworks/*' \
        -o -path '*/Contents/PlugIns/*' \
        -o -path '*/Contents/XPCServices/*' \
        -o -path '*/Contents/Helpers/*' \
        -o -path '*/Contents/Library/*' \) \
        -print0 2>/dev/null
}

# 在某个 Mach-O 二进制里确认是否存在 _cornerMask 方法实现。
# 仅靠 strings 容易把调用点（selector ref）也算进去，所以再用 otool -ov
# 看 Objective-C 元数据，要求存在 imp + name _cornerMask 配对。
binary_has_cornermask_override() {
    local bin="$1"
    local ftype
    ftype=$(file -b "$bin" 2>/dev/null)
    case "$ftype" in
        Mach-O*) ;;
        *) return 1 ;;
    esac
    # 在子 shell 中关闭 pipefail：grep -q / awk exit 都会关闭上游管道，
    # 让 strings / otool 收到 SIGPIPE，pipefail 会把这判定为流水线失败。
    (
        set +o pipefail
        strings -a -- "$bin" 2>/dev/null | grep -Fxq '_cornerMask'
    ) || return 1
    (
        set +o pipefail
        otool -ov "$bin" 2>/dev/null | awk '
            /^[[:space:]]+imp[[:space:]]/ { imp=1; next }
            imp && /^[[:space:]]+name[[:space:]]+0x[0-9a-f]+[[:space:]]+\(0x[0-9a-f]+\)[[:space:]]+_cornerMask$/ {
                found=1; exit
            }
            { imp=0 }
            END { exit found?0:1 }
        '
    )
}

# 判断整个 .app 是否存在任意 _cornerMask override。打印第一个命中的二进制相对路径。
app_has_cornermask_override() {
    local app_path="$1"
    local bin
    while IFS= read -r -d '' bin; do
        if binary_has_cornermask_override "$bin"; then
            printf '%s' "${bin#$app_path/}"
            return 0
        fi
    done < <(list_app_machos "$app_path")
    return 1
}

# 判断 entitlement 是否适合 ad-hoc 重签名。
#
# 不能保留 com.apple.application-identifier、keychain-access-groups、
# com.apple.developer.*、application-groups 等与原开发者 Team ID 绑定的受限
# 权限，否则 AMFI 会拒绝启动：adhoc signed but contains restricted entitlements。
is_adhoc_safe_entitlement() {
    local key="$1"
    case "$key" in
        com.apple.security.cs.*) return 0 ;;
        com.apple.security.device.camera) return 0 ;;
        com.apple.security.device.audio-input) return 0 ;;
        com.apple.security.device.microphone) return 0 ;;
        com.apple.security.automation.apple-events) return 0 ;;
        com.apple.security.network.client) return 0 ;;
        com.apple.security.network.server) return 0 ;;
        com.apple.security.files.user-selected.read-only) return 0 ;;
        com.apple.security.files.user-selected.read-write) return 0 ;;
        com.apple.security.files.downloads.read-only) return 0 ;;
        com.apple.security.files.downloads.read-write) return 0 ;;
        com.apple.security.print) return 0 ;;
        com.apple.security.personal-information.*) return 0 ;;
        *) return 1 ;;
    esac
}

add_unique_entitlement_key() {
    local key="$1"
    local existing
    for existing in "${keys[@]}"; do
        [ "$existing" = "$key" ] && return 0
    done
    keys+=("$key")
}

# 提取当前 entitlements，过滤掉 ad-hoc 不能满足的受限项，并添加 allow-dyld。
create_entitlements_with_dyld() {
    local app_path="$1"
    local out_plist="$2"
    local ents
    ents=$(codesign -d --entitlements - "$app_path" 2>&1 || true)

    local keys=()
    local key
    while IFS= read -r line; do
        if echo "$line" | grep -q '\[Key\]'; then
            key="$(echo "$line" | sed 's/.*\[Key\] //')"
            if is_adhoc_safe_entitlement "$key"; then
                add_unique_entitlement_key "$key"
            fi
        fi
    done <<< "$ents"
    add_unique_entitlement_key "com.apple.security.cs.allow-dyld-environment-variables"
    add_unique_entitlement_key "com.apple.security.cs.allow-jit"
    add_unique_entitlement_key "com.apple.security.cs.allow-unsigned-executable-memory"

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        for key in "${keys[@]}"; do
            echo "    <key>$key</key><true/>"
        done
        echo '</dict>'
        echo '</plist>'
    } > "$out_plist"
}

strip_macho_entitlements() {
    local app_path="$1"
    local empty_ents="$2"
    local file_path file_type

    while IFS= read -r -d '' file_path; do
        file_type="$(file -b "$file_path" 2>/dev/null || true)"
        case "$file_type" in
            Mach-O*)
                codesign --force --entitlements "$empty_ents" -s - "$file_path" >/dev/null 2>&1 || true
                ;;
        esac
    done < <(find "$app_path/Contents" -type f -perm -111 -print0 2>/dev/null)
}

resign_app_with_entitlements() {
    local app_path="$1"
    local ents_plist="$2"
    local empty_ents
    empty_ents="$(mktemp "/tmp/fix-electron-empty-ents.XXXXXX.plist")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict/></plist>'
    } > "$empty_ents"

    # First strip entitlements from executable Mach-O files. Some Electron
    # dylibs/node addons live outside nested bundles, so --deep alone will not
    # necessarily touch them.
    strip_macho_entitlements "$app_path" "$empty_ents"

    # Then sign nested code with an empty entitlements plist. Plain --deep
    # signing preserves existing entitlements on nested bundles; the empty plist
    # strips them so AMFI no longer reports non-main-binary entitlement
    # constraint violations.
    if ! codesign --force --deep --entitlements "$empty_ents" -s - "$app_path"; then
        rm -f "$empty_ents"
        return 1
    fi

    # Then seal the outer app and its main executable with the filtered
    # entitlements needed for DYLD_INSERT_LIBRARIES.
    if ! codesign --force --entitlements "$ents_plist" -s - "$app_path"; then
        rm -f "$empty_ents"
        return 1
    fi
    rm -f "$empty_ents"
}

already_injected() {
    local app_dir="$1"
    local marker
    marker=$(defaults read "$app_dir/Contents/Info" LSEnvironment 2>/dev/null \
        | grep -E 'fix-electron-cornermask|fix-easydict-cornermask' 2>/dev/null) || true
    [ -n "$marker" ]
}

inject_app() {
    local app_dir="$1"
    local dylib="$2"
    local app_name
    app_name=$(basename "$app_dir" .app)

    cp "$app_dir/Contents/Info.plist" "/tmp/${app_name}-Info.plist.backup" 2>/dev/null || true

    defaults write "$app_dir/Contents/Info" LSEnvironment -dict-add \
        DYLD_INSERT_LIBRARIES -string "$dylib" 2>/dev/null || \
    defaults write "$app_dir/Contents/Info" LSEnvironment -dict \
        DYLD_INSERT_LIBRARIES -string "$dylib"

    echo "  重签名 (过滤受限 entitlements + 添加 allow-dyld)..."
    local ents_plist="/tmp/${app_name}-ents.plist"
    create_entitlements_with_dyld "$app_dir" "$ents_plist"
    if resign_app_with_entitlements "$app_dir" "$ents_plist" 2>&1; then
        echo "  OK"
    else
        echo "  FAIL: 重签名失败"
        return 1
    fi
    "$LSREGISTER" -f "$app_dir" 2>/dev/null
    return 0
}

main() {
    local DRY_RUN=false
    local FORCE=false
    local REMOVE=false
    local SCAN_ONLY=false
    local APPLY_NATIVE=false
    local has_action=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run)      DRY_RUN=true; has_action=true ;;
            --force)        FORCE=true; has_action=true ;;
            --remove)       REMOVE=true; has_action=true ;;
            --scan-only)    SCAN_ONLY=true; has_action=true ;;
            --apply-native) APPLY_NATIVE=true; has_action=true ;;
            --apply)        has_action=true ;; # 显式 apply（默认 Electron）
        esac
    done
    # 默认无任何动作参数 → scan-only，避免在通用化后误伤原生应用
    if ! $has_action; then
        SCAN_ONLY=true
    fi

    # --remove 模式
    if $REMOVE; then
        echo "fix-cornermask: 移除注入..."
        local removed=0
        local app_dir app_name ents_plist
        for app_dir in "$APPS_DIR"/*.app; do
            app_name=$(basename "$app_dir" .app)
            already_injected "$app_dir" || continue

            echo "  移除: $app_name"
            defaults delete "$app_dir/Contents/Info" LSEnvironment 2>/dev/null || true
            ents_plist="/tmp/${app_name}-ents.plist"
            create_entitlements_with_dyld "$app_dir" "$ents_plist"
            resign_app_with_entitlements "$app_dir" "$ents_plist" 2>/dev/null || true
            "$LSREGISTER" -f "$app_dir" 2>/dev/null
            removed=$((removed + 1))
        done
        echo "已移除 $removed 个应用的注入"
        return 0
    fi

    echo "fix-cornermask-apply"
    echo "  electron dylib: $DYLIB_ELECTRON"
    echo "  generic  dylib: $DYLIB_GENERIC"
    if $SCAN_ONLY; then
        echo "  模式: 仅扫描"
    elif $APPLY_NATIVE; then
        echo "  模式: 注入 Electron + 原生 (高风险)"
    else
        echo "  模式: 仅注入 Electron"
    fi
    echo ""

    if [ ! -f "$DYLIB_ELECTRON" ]; then
        echo "错误: dylib 不存在: $DYLIB_ELECTRON"
        echo "请先运行 'make build' 编译"
        return 1
    fi
    if [ ! -f "$DYLIB_GENERIC" ] && ! $SCAN_ONLY; then
        echo "警告: 通用 dylib 不存在: $DYLIB_GENERIC (--apply-native 将不可用)"
    fi

    local electron_patched=0 electron_skipped=0
    local native_found=0 native_patched=0 native_skipped=0
    local failed=0
    local app_dir app_name ver hit kind dylib

    for app_dir in "$APPS_DIR"/*.app; do
        [ -d "$app_dir" ] || continue
        app_name=$(basename "$app_dir" .app)
        kind=""
        ver=""
        dylib=""

        # 1) 优先按 Electron 版本判断
        if ver=$(detect_electron_version "$app_dir" 2>/dev/null); then
            if is_patched "$ver"; then
                continue
            fi
            kind="electron"
            dylib="$DYLIB_ELECTRON"
        else
            # 2) 非 Electron：扫描 Mach-O 看是否有真正的 _cornerMask override
            if hit=$(app_has_cornermask_override "$app_dir"); then
                kind="native"
                dylib="$DYLIB_GENERIC"
            else
                continue
            fi
        fi

        if already_injected "$app_dir" && ! $FORCE; then
            if [ "$kind" = "electron" ]; then
                echo "SKIP: $app_name (Electron $ver) — 已注入"
                electron_skipped=$((electron_skipped + 1))
            else
                echo "SKIP: $app_name (native) — 已注入"
                native_skipped=$((native_skipped + 1))
            fi
            continue
        fi

        if [ "$kind" = "electron" ]; then
            echo "FOUND: $app_name (Electron $ver)"
        else
            echo "FOUND: $app_name (native, override at: $hit)"
            native_found=$((native_found + 1))
        fi

        if $SCAN_ONLY || $DRY_RUN; then
            echo "  → 将使用 $(basename "$dylib") 注入并 ad-hoc 重签名"
            continue
        fi

        if [ "$kind" = "native" ] && ! $APPLY_NATIVE; then
            echo "  → 跳过：原生应用需 --apply-native 显式启用 (重签会剥离 Team ID 绑定权限，可能破坏 helper / 系统扩展)"
            continue
        fi

        if [ ! -f "$dylib" ]; then
            echo "  FAIL: dylib 缺失: $dylib"
            failed=$((failed + 1))
            continue
        fi

        if inject_app "$app_dir" "$dylib"; then
            if [ "$kind" = "electron" ]; then
                electron_patched=$((electron_patched + 1))
            else
                native_patched=$((native_patched + 1))
            fi
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "完成: Electron 注入 ${electron_patched} / 跳过 ${electron_skipped}；原生 检出 ${native_found} / 注入 ${native_patched} / 跳过 ${native_skipped}；失败 ${failed}"
}

if [ "${FIX_ELECTRON_TESTING:-0}" != "1" ]; then
    main "$@"
fi
