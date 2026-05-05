#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

codesign() {
    case "$*" in
        *"--entitlements -"*)
            cat <<'EOF'
Executable=/Applications/Termius.app/Contents/MacOS/Termius
[Dict]
	[Key] com.apple.application-identifier
	[Value]
		[String] 6KN952WR85.com.termius-dmg.mac
	[Key] com.apple.developer.team-identifier
	[Value]
		[String] 6KN952WR85
	[Key] com.apple.security.application-groups
	[Value]
		[Array]
			[String] 6KN952WR85.com.termius-dmg.mac
	[Key] com.apple.security.cs.allow-jit
	[Value]
		[Bool] true
	[Key] com.apple.security.cs.allow-unsigned-executable-memory
	[Value]
		[Bool] true
	[Key] com.apple.security.device.usb
	[Value]
		[Bool] true
	[Key] keychain-access-groups
	[Value]
		[Array]
			[String] 6KN952WR85.com.termius-dmg.mac
EOF
            ;;
        *)
            echo "unexpected codesign invocation: $*" >&2
            return 1
            ;;
    esac
}

FIX_ELECTRON_TESTING=1 source "$REPO_DIR/fix-electron-cornermask-apply.sh"

out="$TMP_DIR/ents.plist"
create_entitlements_with_dyld "/Applications/Termius.app" "$out"

plutil -lint "$out" >/dev/null

for forbidden in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    com.apple.security.application-groups \
    com.apple.security.device.usb \
    keychain-access-groups; do
    if grep -q "$forbidden" "$out"; then
        echo "forbidden entitlement leaked into ad-hoc signature: $forbidden" >&2
        exit 1
    fi
done

for required in \
    com.apple.security.cs.allow-dyld-environment-variables \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory; do
    if ! grep -q "$required" "$out"; then
        echo "required entitlement missing: $required" >&2
        exit 1
    fi
done

count=$(grep -c 'com.apple.security.cs.allow-dyld-environment-variables' "$out")
if [ "$count" -ne 1 ]; then
    echo "allow-dyld entitlement should appear once, found $count" >&2
    exit 1
fi
