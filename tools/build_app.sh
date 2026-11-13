#!/bin/bash
# Builds the iPhone app.
#
#   tools/build_app.sh --sim                 an app for the iOS Simulator (no signature is enforced there)
#   tools/build_app.sh --device-unsigned     an unsigned IPA (CODE_SIGNING_ALLOWED=NO, then ad-hoc), for SideStore
#
# The engine is not linked into the app: each game's framework carries its own host (docs/ENGINE.md). The app only
# carries the shared-font stand-ins, made below from a free font.
#
# The app is an XcodeGen project over the SwiftPM package in app/. Regenerate with:
#   (cd app && xcodegen generate)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP=$ROOT/app
DD=${NXPOCKET_DERIVED:-$APP/.builddd}
SIM_NAME=${NXPOCKET_SIM:-iPhone 17}
OUT=${NXPOCKET_OUTPUT:-$HOME/Documents/NXPocket}
MODE=${1:---sim}

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# The stand-ins for the console's shared fonts: tools/make_fonts.sh, from a free font.
fonts() { "$ROOT/tools/make_fonts.sh" "$APP/Gen/dm/font"; }

say "the shared-font stand-ins"
if fonts; then
    echo "  $(ls "$APP/Gen/dm/font" | tr '\n' ' ')"
elif [ "$MODE" = --device-unsigned ]; then
    die "no shared fonts: run tools/setup_python.sh for fontTools, and check the network for Noto Sans JP"
else
    echo "  missing (a game that draws text would show none): fine for the simulator"
fi

command -v xcodegen >/dev/null || die "xcodegen is missing (brew install xcodegen)"
say "generating the project"
(cd "$APP" && xcodegen generate --spec project.yml >/dev/null)

case "$MODE" in
--sim)
    say "building for the simulator ($SIM_NAME)"
    xcodebuild -project "$APP/NXPocket.xcodeproj" -scheme NXPocket -configuration Debug \
        -destination "platform=iOS Simulator,name=$SIM_NAME" -derivedDataPath "$DD" build \
        | tail -3
    APP_PATH=$DD/Build/Products/Debug-iphonesimulator/NXPocket.app
    [ -d "$APP_PATH" ] || die "no app at $APP_PATH"
    say "app: $APP_PATH"
    echo "install it with: xcrun simctl boot '$SIM_NAME' ; xcrun simctl install booted '$APP_PATH' ; xcrun simctl launch booted dev.nxpocketapple.app"
    ;;
--device-unsigned)
    say "building an unsigned app for a device"
    xcodebuild -project "$APP/NXPocket.xcodeproj" -scheme NXPocket -configuration Release \
        -sdk iphoneos -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        ONLY_ACTIVE_ARCH=NO build | tail -3
    APP_PATH=$DD/Build/Products/Release-iphoneos/NXPocket.app
    [ -d "$APP_PATH" ] || die "no app at $APP_PATH"

    say "ad-hoc signing the placeholders (SideStore replaces every signature on install)"
    xattr -cr "$APP_PATH" 2>/dev/null || true
    ENTITLEMENTS=$APP/Gen/NXPocketApple.entitlements
    if [ -f "$ENTITLEMENTS" ]; then
        # The increased-memory entitlement has to be requested here, or the ad-hoc signature drops it and the
        # installer has nothing to carry into the profile it builds for the device.
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH" || die "codesign"
        codesign -d --entitlements - "$APP_PATH" 2>&1 | grep -q increased-memory-limit \
            || die "the increased-memory entitlement did not survive the signature"
    else
        codesign --force --sign - "$APP_PATH" || die "codesign"
    fi

    say "packing the IPA"
    rm -rf "$APP/.pkg" && mkdir -p "$APP/.pkg/Payload"
    cp -R "$APP_PATH" "$APP/.pkg/Payload/"
    mkdir -p "$OUT"
    rm -f "$OUT/NXPocketApple.ipa"
    (cd "$APP/.pkg" && zip -qry "$OUT/NXPocketApple.ipa" Payload)
    rm -rf "$APP/.pkg"
    say "IPA: $OUT/NXPocketApple.ipa ($(du -h "$OUT/NXPocketApple.ipa" | cut -f1 | tr -d ' '))"
    echo "Install it with SideStore or AltStore, then export the .p12 from SideStore and import it in the app."
    ;;
*)
    die "usage: tools/build_app.sh [--sim|--device-unsigned]"
    ;;
esac
