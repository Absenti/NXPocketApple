#!/bin/bash
# Builds the signing engine the iPhone app uses.
#
#   1. libnxzsign.xcframework — the device-side signer. zsign (https://github.com/zhlynn/zsign, MIT) re-signs a
#      framework on the phone with the user's own certificate. This script fetches it at a pinned revision, refuses
#      it if it is not MIT, builds it for the device and for the simulator, and compiles tools/zsign_shim.cpp against
#      it, so `#if canImport(NXZSign)` turns on DeviceSigner.
#
#      Both platforms, not just the device: app/project.yml links this framework unconditionally, so a device-only
#      build would link for the simulator too and the test suite would stop running.
#
#      zsign needs OpenSSL. On iOS that means an OpenSSL built for arm64-apple-ios, and the same for the simulator;
#      the script fetches OpenSSL.xcframework with a partial clone (11 MB rather than the repository's 1.3 GB) and
#      checks the layout it actually finds.
#
#      LiveContainer keeps its own copy of zsign under ZSign/ and implements the same API. It is NOT used here: that
#      repository is AGPL-3.0 and this project is MIT (AGPL code is excluded outright). See NOTICE.
#
# It is not vendored: it is fetched from its own repository at a pinned revision. The engine's host is not built here
# or anywhere in this project: each game's framework carries its own (docs/ARCHITECTURE.md).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=${NXPOCKET_SIGNING_WORK:-$ROOT/.build/signing}
SIGNING=$ROOT/app/Signing
ZSIGN_REPO=${ZSIGN_REPO:-https://github.com/zhlynn/zsign.git}
# master as of 2026-10-20, "fix: fail instead of sealing an unreadable file as empty (#413)".
ZSIGN_REV=${ZSIGN_REV:-9299685bab7ef99827e06e5dfda93af747386590}
OPENSSL_REPO=${OPENSSL_REPO:-https://github.com/krzyzanowskim/OpenSSL.git}
# The crypto that signs every game is pinned like zsign: tag 3.6.5000 (OpenSSL 3.6.0), 2026-10-02. The tag is what is
# fetched, the revision is what is trusted: a tag that moves stops the build.
OPENSSL_TAG=${OPENSSL_TAG:-3.6.5000}
OPENSSL_REV=${OPENSSL_REV:-0a6149bff4fb00921ce0ec1811f726b166638095}
OPENSSL_IOS=${OPENSSL_IOS:-}

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$WORK" "$SIGNING"

say "zsign at $ZSIGN_REV"
if [ ! -d "$WORK/zsign/.git" ]; then
    git clone --quiet "$ZSIGN_REPO" "$WORK/zsign" || die "zsign could not be cloned from $ZSIGN_REPO"
fi
git -C "$WORK/zsign" fetch --quiet origin "$ZSIGN_REV" 2>/dev/null || true
# --force: the checkout is ours and carries last run's patches; they are dropped here and applied again below.
git -C "$WORK/zsign" checkout --quiet --force "$ZSIGN_REV" || die "zsign has no revision $ZSIGN_REV"
REV=$(git -C "$WORK/zsign" rev-parse HEAD)
echo "  revision $REV"

say "patching zsign"
# patches/zsign/*.patch, in name order, each with a Reason: header. A patch that does not apply stops the build:
# signing without it would quietly produce the signature the patch exists to change.
for patch in "$ROOT"/patches/zsign/*.patch; do
    [ -f "$patch" ] || continue
    git -C "$WORK/zsign" apply "$patch" || die "$(basename "$patch") does not apply to zsign $REV"
    echo "  applied $(basename "$patch")"
done

say "checking the licence"
# The first rule of this project: no AGPL code. zsign is MIT; verify rather than assume, because a wrong
# repository silently changes the licence of everything linked into the app.
if ! grep -qiE 'MIT License|Permission is hereby granted, free of charge' "$WORK/zsign/LICENSE" 2>/dev/null; then
    die "$ZSIGN_REPO at $REV is not MIT. Stop: its licence decides what this project may do. See NOTICE."
fi
echo "  MIT, as expected"

say "OpenSSL for iOS"
if [ -z "$OPENSSL_IOS" ]; then
    for candidate in "$WORK/OpenSSL/Frameworks/OpenSSL.xcframework" "$ROOT/third_party/OpenSSL/Frameworks/OpenSSL.xcframework"; do
        [ -d "$candidate" ] && OPENSSL_IOS=$candidate && break
    done
fi
if [ -n "$OPENSSL_IOS" ] && [ "$OPENSSL_IOS" = "$WORK/OpenSSL/Frameworks/OpenSSL.xcframework" ] \
    && [ "$(git -C "$WORK/OpenSSL" rev-parse HEAD 2>/dev/null)" != "$OPENSSL_REV" ]; then
    say "  the OpenSSL checkout is not at $OPENSSL_REV: fetching it again"
    OPENSSL_IOS=
fi
if [ -z "$OPENSSL_IOS" ] || [ ! -d "$OPENSSL_IOS" ]; then
    # The repository carries prebuilt binaries for every Apple platform, 1.3 GB of it. Only the iOS slices are
    # needed, so it is cloned blobless and sparse-checked out, which brings down about 30 MB.
    say "  fetching only the iOS slices of $OPENSSL_TAG"
    rm -rf "$WORK/OpenSSL"
    git clone --quiet --depth 1 --branch "$OPENSSL_TAG" --filter=blob:none --sparse "$OPENSSL_REPO" "$WORK/OpenSSL" \
        || die "OpenSSL $OPENSSL_TAG could not be cloned from $OPENSSL_REPO"
    GOT=$(git -C "$WORK/OpenSSL" rev-parse HEAD)
    [ "$GOT" = "$OPENSSL_REV" ] || die "OpenSSL $OPENSSL_TAG is $GOT, not the pinned $OPENSSL_REV: the tag moved. Check it before trusting it."
    git -C "$WORK/OpenSSL" sparse-checkout set \
        Frameworks/OpenSSL.xcframework/ios-arm64 \
        Frameworks/OpenSSL.xcframework/ios-arm64_x86_64-simulator >/dev/null \
        || die "the iOS slices could not be checked out"
    OPENSSL_IOS="$WORK/OpenSSL/Frameworks/OpenSSL.xcframework"
fi

if [ -f "$WORK/OpenSSL/LICENSE.txt" ] && [ "$OPENSSL_IOS" = "$WORK/OpenSSL/Frameworks/OpenSSL.xcframework" ]; then
    # OpenSSL 3 is Apache 2.0, which the app may link. Checked for the same reason as zsign's.
    grep -q "Apache License" "$WORK/OpenSSL/LICENSE.txt" \
        || die "OpenSSL at $OPENSSL_REV is not under the Apache License. Stop: see NOTICE."
    echo "  revision $OPENSSL_REV, Apache 2.0"
fi

DEVICE_FRAMEWORK="$OPENSSL_IOS/ios-arm64/OpenSSL.framework"
SIM_FRAMEWORK="$OPENSSL_IOS/ios-arm64_x86_64-simulator/OpenSSL.framework"
for framework in "$DEVICE_FRAMEWORK" "$SIM_FRAMEWORK"; do
    [ -d "$framework/Headers" ] || die "no headers in $framework: the OpenSSL layout changed"
    [ -f "$framework/OpenSSL" ] || die "no library at $framework/OpenSSL"
done
echo "  device:    $DEVICE_FRAMEWORK"
echo "  simulator: $SIM_FRAMEWORK"

# OpenSSL.xcframework keeps its headers flat, but zsign includes <openssl/sha.h>. A one-entry include directory per
# slice with an openssl symlink is what makes that resolve; nothing is copied.
make_include() {
    local framework=$1 dest=$2
    rm -rf "$dest" && mkdir -p "$dest"
    ln -s "$framework/Headers" "$dest/openssl"
}

# The CLI (src/zsign.cpp) has its own main and is left out; everything else in src/ and src/common/ is the library.
SOURCES=$(find "$WORK/zsign/src" -name '*.cpp' ! -name 'zsign.cpp' | sort)
[ -n "$SOURCES" ] || die "no zsign sources under $WORK/zsign/src: the repository layout changed"

# compile <label> <sdk> <target> <include-dir> -> $WORK/obj-<label>/*.o and $WORK/libnxzsign-<label>.a
compile() {
    local label=$1 sdk=$2 target=$3 include=$4
    local objects="$WORK/obj-$label"
    mkdir -p "$objects" && rm -f "$objects"/*.o
    local sdkpath flags
    sdkpath=$(xcrun --sdk "$sdk" --show-sdk-path)
    flags=(-target "$target" -isysroot "$sdkpath" -std=c++11 -Oz -fPIC
           -I"$WORK/zsign/src" -I"$WORK/zsign/src/common" -I"$WORK/zsign/src/third-party/zlib"
           -I"$WORK/zsign/src/third-party/minizip" -I"$include")
    local failed=0 source object
    for source in $SOURCES; do
        object="$objects/$(basename "${source%.cpp}").o"
        xcrun --sdk "$sdk" clang++ "${flags[@]}" -c "$source" -o "$object" \
            || { echo "  FAILED ($label): $(basename "$source")"; failed=1; }
    done
    [ "$failed" = 0 ] || die "zsign did not compile for $label"
    xcrun --sdk "$sdk" clang++ "${flags[@]}" -DNXPOCKET_WITH_ZSIGN -I"$ROOT/tools" \
        -c "$ROOT/tools/zsign_shim.cpp" -o "$objects/nxpocket_zsign_shim.o" \
        || die "tools/zsign_shim.cpp no longer matches zsign's API ($label)"
    xcrun --sdk "$sdk" libtool -static -o "$objects/libnxzsign.a" "$objects"/*.o || die "libtool ($label)"
}

say "building zsign"
make_include "$DEVICE_FRAMEWORK" "$WORK/include-device"
compile device iphoneos arm64-apple-ios26.0 "$WORK/include-device"
echo "  device: arm64-apple-ios26.0"
make_include "$SIM_FRAMEWORK" "$WORK/include-simulator"
compile simulator-arm64 iphonesimulator arm64-apple-ios26.0-simulator "$WORK/include-simulator"
compile simulator-x86_64 iphonesimulator x86_64-apple-ios26.0-simulator "$WORK/include-simulator"
lipo -create "$WORK/obj-simulator-arm64/libnxzsign.a" "$WORK/obj-simulator-x86_64/libnxzsign.a" \
    -output "$WORK/obj-simulator-arm64/libnxzsign-simulator.a" || die "lipo"
echo "  simulator: arm64 and x86_64"

say "packaging app/Signing"
HEADERS="$WORK/headers"
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp "$ROOT/tools/zsign_shim.h" "$HEADERS/zsign_shim.h"
# The module map is what makes `import NXZSign` resolve from Swift; without it the call site silently falls into
# the #else branch and the app refuses to sign on the device.
cat > "$HEADERS/module.modulemap" <<'EOF'
module NXZSign {
    header "zsign_shim.h"
    export *
}
EOF

rm -rf "$SIGNING/libnxzsign.xcframework"
xcodebuild -create-xcframework \
    -library "$WORK/obj-device/libnxzsign.a" -headers "$HEADERS" \
    -library "$WORK/obj-simulator-arm64/libnxzsign-simulator.a" -headers "$HEADERS" \
    -output "$SIGNING/libnxzsign.xcframework" >/dev/null || die "the xcframework could not be created"

rm -rf "$SIGNING/OpenSSL.xcframework"
# Built from the two slices rather than copied wholesale: the repository's own xcframework lists tvOS, watchOS,
# xros and Catalyst slices as well, whose directories the sparse checkout never fetched, and Xcode reads that list.
xcodebuild -create-xcframework \
    -framework "$DEVICE_FRAMEWORK" \
    -framework "$SIM_FRAMEWORK" \
    -output "$SIGNING/OpenSSL.xcframework" >/dev/null || die "the OpenSSL xcframework could not be created"

cat > "$SIGNING/README.md" <<EOF
# Signing engine (built, not committed)

libnxzsign.xcframework and OpenSSL.xcframework are built by tools/build_zsign.sh from:

- zsign, https://github.com/zhlynn/zsign, MIT, revision $REV
- OpenSSL for iOS, https://github.com/krzyzanowskim/OpenSSL (Apache-2.0), the iOS slices
- tools/zsign_shim.cpp in this repository

Both carry a device and a simulator slice, because app/project.yml links them for every platform. OpenSSL is
dynamic, so it is embedded in the app; libnxzsign is static and is not. Nothing here is committed.
EOF

# The app only compiles its call into the shim when the engine is linked, so nothing in the normal build notices a
# mismatch between the two. Check it here, while the header is fresh: a silent one would surface as a runtime
# failure on the device, where it is far more expensive to find.
say "checking the app's call against the generated header"
CHECK=$(mktemp -d)
cat > "$CHECK/CallSite.swift" <<'SWIFT'
import Foundation
import NXZSign
func check(scratch: String, passphrase: String, provision: String, entitlements: String,
           framework: String, executable: String, identifier: String) -> Int32 {
    var error = [CChar](repeating: 0, count: 512)
    return nxpocket_zsign_sign(scratch, passphrase, provision, entitlements,
                               framework, executable, identifier, &error, 512)
}
SWIFT
swiftc -typecheck -I "$HEADERS" "$CHECK/CallSite.swift" || die "the app calls the signing engine with the wrong arguments"
rm -rf "$CHECK"
echo "  the arguments match"

say "done"
echo "  libnxzsign.xcframework  $(du -sh "$SIGNING/libnxzsign.xcframework" | cut -f1)"
echo "  OpenSSL.xcframework     $(du -sh "$SIGNING/OpenSSL.xcframework" | cut -f1) (dynamic, embedded in the app)"
