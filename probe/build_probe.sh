#!/bin/bash
# Build the iPorterNX probe IPA (README.md explains the tests) with plain clang, no Xcode project.
# Shape taken from nxnative's dm/ios/probe/build_probe.sh (MIT, seedds).
#   Payload/NXProbe.app/
#     NXProbe                                  the app: runs the tests at launch, log on screen and in Documents/probe-log.txt
#     Frameworks/Probe.framework/Probe         probe_answer() = 42, loaded from the bundle (baseline)
#     Frameworks/GameProbe.framework/GameProbe game_answer() = 43 + a 16K code page in __TEXT,__dmx0; the app copies it to Documents
#     Frameworks/OpenSSL.framework             zsign's crypto, a dynamic framework, so it travels inside the app
#     adhoc.xor                                AdhocProbe XOR 0x5A: ad-hoc signed, never re-signed (negative control)
#     resignA.xor, resignB.xor                 ResignA 48 / ResignB 49, also XOR'ed: the app signs these itself, in Documents
#   probe-out/PushProbe.framework              push_answer() = 46 + the same code page: sign it with your identity and push it (README)
# Usage: probe/build_probe.sh [out dir]   (default: <repo>/probe-out)
set -u
cd "$(dirname "$0")" || exit 1
P=$PWD; OUT=${1:-$(cd .. && pwd)/probe-out}
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
SDK=iphoneos; TARGET=arm64-apple-ios26.0
# SIM=1: a simulator build, to check the logic only (the simulator does not enforce signatures, its verdict means nothing)
[ "${SIM:-0}" = 1 ] && { SDK=iphonesimulator; TARGET=arm64-apple-ios26.0-simulator; }
B=$P/build; APP=$B/pkg/Payload/NXProbe.app
CC=(xcrun -sdk "$SDK" clang -arch arm64 -target "$TARGET" -Wall -Werror)

# The signing engine, built by tools/build_zsign.sh. The probe signs with it for real, so it cannot be built without
# it: tests 5A and 5B are the whole point of phase 0c.
SIGNING=$(cd .. && pwd)/app/Signing
[ -f "$SIGNING/libnxzsign.xcframework/Info.plist" ] || die "the signing engine is not built: run tools/build_zsign.sh"
if [ "$SDK" = iphoneos ]; then SLICE=ios-arm64; else SLICE=ios-arm64_x86_64-simulator; fi
# The archive is not named the same in both slices: the simulator one is the lipo of two builds
# (libnxzsign-simulator.a), the device one is the build itself. Take whichever the slice carries.
SIGLIB=$(ls "$SIGNING/libnxzsign.xcframework/$SLICE"/*.a 2>/dev/null | head -1 || true)
SIGINC=$SIGNING/libnxzsign.xcframework/$SLICE/Headers
OPENSSL_FW=$SIGNING/OpenSSL.xcframework/$SLICE/OpenSSL.framework
[ -n "$SIGLIB" ] || die "no static library in the $SLICE slice"
[ -f "$SIGINC/zsign_shim.h" ] || die "no zsign_shim.h in the $SLICE slice"
[ -d "$OPENSSL_FW" ] || die "no OpenSSL.framework in the $SLICE slice"

rm -rf "$B" && mkdir -p "$APP/Frameworks" "$OUT" || die "mkdir"

fw_plist() {   # <framework dir> <name>
cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$2</string>
	<key>CFBundleIdentifier</key><string>dev.nxpocket.probe.$2</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>26.0</string>
</dict>
</plist>
EOF
}
dylib() {   # <out file> <install name> <function> <value> [extra sources...]
    local o=$1 id=$2 fn=$3 v=$4; shift 4
    "${CC[@]}" -Oz -dynamiclib -install_name "$id" -DANSWER_FN="$fn" -DANSWER="$v" src/answer.c "$@" -o "$o" || die "clang $o"
}

t "frameworks"
mkdir -p "$APP/Frameworks/Probe.framework" "$APP/Frameworks/GameProbe.framework" "$OUT/PushProbe.framework" \
         "$B/adhoc" "$B/resign"
dylib "$APP/Frameworks/Probe.framework/Probe" @rpath/Probe.framework/Probe probe_answer 42
dylib "$APP/Frameworks/GameProbe.framework/GameProbe" @rpath/GameProbe.framework/GameProbe game_answer 43 src/blob.S
rm -rf "$OUT/PushProbe.framework" && mkdir -p "$OUT/PushProbe.framework"
dylib "$OUT/PushProbe.framework/PushProbe" @rpath/PushProbe.framework/PushProbe push_answer 46 src/blob.S
dylib "$B/adhoc/AdhocProbe" @rpath/AdhocProbe adhoc_answer 45
# Tests 5A and 5B: the app signs these itself, in Documents. Different install names on purpose, so dyld cannot
# hand back an image it already loaded (try_load checks dladdr, but two names make it unambiguous).
dylib "$B/resign/ResignA" @rpath/FrameworkResignA resign_a 48 src/blob.S
dylib "$B/resign/ResignB" @rpath/FrameworkResignB resign_b 49 src/blob.S
fw_plist "$APP/Frameworks/Probe.framework" Probe
fw_plist "$APP/Frameworks/GameProbe.framework" GameProbe
fw_plist "$OUT/PushProbe.framework" PushProbe

t "OpenSSL: zsign's crypto, and a dynamic framework, so it has to sit inside the app"
rm -rf "$APP/Frameworks/OpenSSL.framework"
cp -R "$OPENSSL_FW" "$APP/Frameworks/OpenSSL.framework" || die "copy OpenSSL.framework"

t "app"
"${CC[@]}" -O2 -fobjc-arc -framework Foundation -framework UIKit -framework Security -framework UniformTypeIdentifiers \
    -I"$SIGINC" -F"$(dirname "$OPENSSL_FW")" \
    src/probe_main.m "$SIGLIB" -framework OpenSSL -lc++ -Wl,-rpath,@executable_path/Frameworks \
    -o "$APP/NXProbe" || die "clang NXProbe"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>NXProbe</string>
	<key>CFBundleExecutable</key><string>NXProbe</string>
	<key>CFBundleIdentifier</key><string>dev.nxpocket.probe</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>NXProbe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>LSSupportsOpeningDocumentsInPlace</key><true/>
	<key>MinimumOSVersion</key><string>26.0</string>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key><false/>
		<key>UISceneConfigurations</key>
		<dict>
			<key>UIWindowSceneSessionRoleApplication</key>
			<array><dict>
				<key>UISceneConfigurationName</key><string>Default</string>
				<key>UISceneDelegateClassName</key><string>AppDelegate</string>
			</dict></array>
		</dict>
	</dict>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UIFileSharingEnabled</key><true/>
	<key>UILaunchScreen</key><dict/>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
</dict>
</plist>
EOF

t "sign: ad-hoc placeholders (the sideloader re-signs the app and Frameworks/, never the .xor files)"
xattr -cr "$APP" "$OUT/PushProbe.framework" 2>/dev/null
codesign --force --sign - "$B/adhoc/AdhocProbe" || die "codesign AdhocProbe"
codex_xor() { python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); open(sys.argv[2],"wb").write(bytes(b^0x5A for b in d))' "$1" "$2"; }
codex_xor "$B/adhoc/AdhocProbe" "$APP/adhoc.xor" || die "xor"
# Signed after their de-XOR'ing, by us, on the iPhone: this is what makes them invisible to the sideloader.
codex_xor "$B/resign/ResignA" "$APP/resignA.xor" || die "xor ResignA"
codex_xor "$B/resign/ResignB" "$APP/resignB.xor" || die "xor ResignB"
codesign --force --sign - "$APP/Frameworks/OpenSSL.framework" || die "codesign OpenSSL"
codesign --force --sign - "$APP/Frameworks/Probe.framework" || die "codesign Probe"
codesign --force --sign - "$APP/Frameworks/GameProbe.framework" || die "codesign GameProbe"
codesign --force --sign - "$OUT/PushProbe.framework" || die "codesign PushProbe"
codesign --force --sign - "$APP" || die "codesign app"

t "self-check"
codesign --verify --strict "$APP" || die "verify app"
for f in Probe GameProbe OpenSSL; do codesign --verify --strict "$APP/Frameworks/$f.framework" || die "verify $f"; done
plutil -lint "$APP/Info.plist" "$APP"/Frameworks/*/Info.plist "$OUT/PushProbe.framework/Info.plist" >/dev/null || die "plutil"
for m in "$APP/NXProbe" "$APP/Frameworks/GameProbe.framework/GameProbe" "$OUT/PushProbe.framework/PushProbe"; do
    otool -l "$m" | grep -qE 'minos 26.0|version 26.0' || die "$m: deployment target is not 26.0"
done
for m in "$APP/Frameworks/GameProbe.framework/GameProbe" "$OUT/PushProbe.framework/PushProbe" \
         "$B/resign/ResignA" "$B/resign/ResignB"; do
    S=$(otool -l "$m" | awk '/sectname __dmx0/{f=1} f&&/addr/{print $2; exit}')
    [ -n "$S" ] && [ $(( S & 0x3FFF )) = 0 ] || die "$m: __TEXT,__dmx0 missing or not 16K aligned ($S)"
done
nm -gU "$APP/Frameworks/GameProbe.framework/GameProbe" | grep -q ' _game_answer$' || die "GameProbe exports no game_answer"
for s in resign_a resign_b; do
    nm -gU "$B/resign/$([ "$s" = resign_a ] && echo ResignA || echo ResignB)" | grep -q " _$s\$" || die "$s is not exported"
done
# The probe signs with zsign, so the engine and its crypto have to be inside the app and linked.
otool -L "$APP/NXProbe" | grep -q '@rpath/OpenSSL.framework/OpenSSL' || die "the probe does not link OpenSSL"
nm "$APP/NXProbe" | grep -q ' _nxpocket_zsign_sign$' || die "the probe does not carry the signing engine"
for x in adhoc.xor resignA.xor resignB.xor; do
    X=$(python3 -I -c 'import sys; print(open(sys.argv[1],"rb").read(4).hex())' "$APP/$x")
    [ "$X" != cffaedfe ] || die "$x is a plain Mach-O"
done

t "pack"
rm -f "$OUT/NXProbe.ipa"
(cd "$B/pkg" && zip -qry "$OUT/NXProbe.ipa" Payload) || die "zip"
rm -rf "$B/check" && mkdir -p "$B/check" && unzip -q "$OUT/NXProbe.ipa" -d "$B/check" || die "unzip"
codesign --verify --strict "$B/check/Payload/NXProbe.app" || die "verify the extracted app"
t "IPA: $OUT/NXProbe.ipa ($(du -h "$OUT/NXProbe.ipa" | cut -f1 | tr -d ' ')), push framework: $OUT/PushProbe.framework"
