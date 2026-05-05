#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LOG="$TMP_DIR/codesign.log"

codesign() {
    printf '%s\n' "$*" >> "$LOG"
}

FIX_ELECTRON_TESTING=1 source "$REPO_DIR/fix-electron-cornermask-apply.sh"

resign_app_with_entitlements "/Applications/Fake.app" "/tmp/fake-ents.plist"

line_count=$(wc -l < "$LOG" | tr -d ' ')
if [ "$line_count" -ne 2 ]; then
    echo "expected two codesign calls, got $line_count" >&2
    cat "$LOG" >&2
    exit 1
fi

first=$(sed -n '1p' "$LOG")
second=$(sed -n '2p' "$LOG")

case "$first" in
    *"--deep"*"/Applications/Fake.app"*) ;;
    *)
        echo "first codesign call should deep-sign nested code" >&2
        cat "$LOG" >&2
        exit 1
        ;;
esac

case "$first" in
    *"--entitlements /tmp/fake-ents.plist"*)
        echo "first codesign call must not apply the app entitlements to nested code" >&2
        cat "$LOG" >&2
        exit 1
        ;;
esac

case "$first" in
    *"--entitlements"*) ;;
    *)
        echo "first codesign call should use an empty entitlements plist to strip nested entitlements" >&2
        cat "$LOG" >&2
        exit 1
        ;;
esac

case "$second" in
    *"--entitlements /tmp/fake-ents.plist"*"/Applications/Fake.app"*) ;;
    *)
        echo "second codesign call should sign the outer app with entitlements" >&2
        cat "$LOG" >&2
        exit 1
        ;;
esac

case "$second" in
    *"--deep"*)
        echo "second codesign call must not use --deep with entitlements" >&2
        cat "$LOG" >&2
        exit 1
        ;;
esac
