#!/bin/bash
# Builds the macOS launcher and checks the SDK it recorded.
#
# Since Swift 6.4 (Xcode 27) `swift build` hands the SDK to clang as --sysroot on the link, but clang reads the SDK
# version from -isysroot or SDKROOT only. Without -isysroot the executable claims the SDK of its deployment target,
# and macOS then runs it as an app built with a much older SDK (no SwiftUI window after the last one closes).
# The check fails the build if that drifts back.
#
# Usage: tools/build_mac.sh                    build, then check
#        tools/build_mac.sh --app              the same, then mac/.build/NXPocket.app around it (ad hoc signed)
#        tools/build_mac.sh --check <binary>   only the check
#
# The .app: bundle ID dev.nxpocket.launcher, CFBundleShortVersionString from VERSION at the repository root (a
# release is tag v<VERSION>), CFBundleVersion from BUILD_NUMBER (default 1), LSMinimumSystemVersion the one the
# executable records. Its icon is mac/Resources/AppIcon.icns if there is one, else made from the iPhone app's.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SDK=$(xcrun --sdk macosx --show-sdk-path)
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)

check() {
    local binary=$1 minos sdk
    read -r minos sdk < <(otool -l "$binary" | awk '/cmd LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { m = $2 } f && $1 == "sdk" { print m, $2; exit }') || true
    [ -n "${sdk:-}" ] || { echo "FAIL $binary has no LC_BUILD_VERSION" >&2; return 1; }
    if [ "$sdk" != "$SDK_VERSION" ]; then
        echo "FAIL $binary records SDK $sdk (minimum macOS $minos), not $SDK_VERSION: build it with tools/build_mac.sh" >&2
        return 1
    fi
    echo "ok   $binary: SDK $sdk, minimum macOS $minos"
}

if [ "${1:-}" = "--check" ]; then
    check "${2:?usage: build_mac.sh --check <binary>}"
    exit
fi
MAKE_APP=0
case "${1:-}" in
    "") ;;
    --app) MAKE_APP=1 ;;
    *) echo "usage: build_mac.sh [--app | --check <binary>]" >&2; exit 2 ;;
esac

swift build -c release --package-path "$ROOT/mac" \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"
BINARY=$ROOT/mac/.build/release/NXPocket
check "$BINARY"
echo "launcher: $BINARY"
[ "$MAKE_APP" = 1 ] || exit 0

die() { echo "FAIL $*" >&2; exit 1; }
[ -f "$ROOT/VERSION" ] || die "no VERSION file at the repository root"
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "VERSION is \"$VERSION\", not a version like 0.2.0"
BUILD=${BUILD_NUMBER:-1}
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "BUILD_NUMBER is \"$BUILD\", not a number"
MINOS=$(otool -l "$BINARY" | awk '/cmd LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { print $2; exit }')
[ -n "$MINOS" ] || die "$BINARY records no minimum macOS"

APP=$ROOT/mac/.build/NXPocket.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/NXPocket"

ICON_KEY=""
ICNS=$ROOT/mac/Resources/AppIcon.icns
SOURCE_PNG=$ROOT/app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$SOURCE_PNG" ]; then
    ICONSET=$ROOT/mac/.build/AppIcon.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$SOURCE_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$SOURCE_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NXPocket</string>
    <key>CFBundleIdentifier</key><string>dev.nxpocket.launcher</string>
    <key>CFBundleName</key><string>NXPocket</string>
    <key>CFBundleDisplayName</key><string>NXPocket</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MINOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    $ICON_KEY
</dict>
</plist>
EOF
plutil -lint -s "$APP/Contents/Info.plist" || die "Info.plist is not valid"

# Ad hoc: no Developer ID. A copy downloaded by a browser is quarantined and Gatekeeper asks once; the launcher's own
# update downloads it without quarantine.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP" || die "the signature of $APP does not verify"
check "$APP/Contents/MacOS/NXPocket"
echo "app:      $APP ($VERSION, build $BUILD)"
