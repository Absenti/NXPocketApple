#!/bin/bash
# Signs a framework with zsign and a *self-signed* certificate, then lets Apple's own codesign judge the result.
#
# This is the half of the device signer that can be checked without an iPhone and without an Apple certificate:
# does zsign, called through tools/zsign_shim.cpp, write a CodeDirectory whose identifier is the one we asked for
# and whose team is the one the provisioning profile names? codesign reads both back independently.
#
# What it does NOT prove: that iOS accepts the result outside the app bundle. The simulator does not enforce code
# signatures and neither does macOS for this shape, so only a device can answer that (docs/SIGNING.md).
#
# Usage: tools/verify_signing.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=${NXPOCKET_SIGNING_WORK:-$ROOT/.build/signing}
OUT=$WORK/verify
OPENSSL=$(brew --prefix openssl@3 2>/dev/null || echo "")
TEAM=ABCDE12345
IDENTIFIER=dev.nxpocketapple.app
PASSPHRASE=nxpocket-test
EXE=Test

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$WORK/zsign/src/bundle.h" ] || die "zsign is not fetched: run tools/build_zsign.sh once"
[ -n "$OPENSSL" ] || die "no OpenSSL for the host: brew install openssl@3"

rm -rf "$OUT" && mkdir -p "$OUT"

say "1. a certificate chain and a provisioning profile naming team $TEAM"
# The certificate only has to be a certificate: zsign signs with whatever it is given. It must, however, arrive with
# its issuer, because GenerateCMS prefers a CA chain found inside the p12 and otherwise insists on an Apple WWDR
# intermediate whose name hash matches the leaf's issuer. A real developer export carries the WWDR intermediate for
# exactly this reason, so the test carries a CA of its own.
openssl req -x509 -newkey rsa:2048 -keyout "$OUT/ca-key.pem" -out "$OUT/ca.pem" -days 30 -nodes \
    -subj "/CN=NXPocketApple test CA/O=NXPocketApple test/C=FR" 2>/dev/null || die "openssl could not make the CA"
openssl req -newkey rsa:2048 -keyout "$OUT/key.pem" -out "$OUT/leaf.csr" -nodes \
    -subj "/CN=Apple Development: NXPocketApple test ($TEAM)/OU=$TEAM/O=NXPocketApple test/C=FR" 2>/dev/null \
    || die "openssl could not make the key"
# The code-signing extended key usage is what Apple's verifier checks before it will look at anything else. Without
# it codesign stops at "Invalid Key Usage for policy" and the real verdict stays hidden.
cat > "$OUT/leaf.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl x509 -req -in "$OUT/leaf.csr" -CA "$OUT/ca.pem" -CAkey "$OUT/ca-key.pem" -CAcreateserial \
    -extfile "$OUT/leaf.ext" -out "$OUT/cert.pem" -days 30 2>/dev/null || die "the CA could not issue the leaf"
openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -certfile "$OUT/ca.pem" -out "$OUT/cert.p12" \
    -passout "pass:$PASSPHRASE" -name "NXPocketApple test" 2>/dev/null || die "openssl could not make a p12"
echo "  issuer:  $(openssl x509 -in "$OUT/cert.pem" -noout -issuer | sed 's/issuer=//')"
echo "  subject: $(openssl x509 -in "$OUT/cert.pem" -noout -subject | sed 's/subject=//')"

cat > "$OUT/profile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Name</key><string>NXPocketApple test profile</string>
  <key>TeamIdentifier</key><array><string>$TEAM</string></array>
  <key>UUID</key><string>00000000-0000-0000-0000-0000000000FF</string>
  <key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date>
  <key>Entitlements</key><dict>
    <key>application-identifier</key><string>$TEAM.$IDENTIFIER</string>
    <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
    <key>get-task-allow</key><true/>
  </dict>
</dict></plist>
EOF
openssl smime -sign -in "$OUT/profile.plist" -signer "$OUT/cert.pem" -inkey "$OUT/key.pem" \
    -outform DER -nodetach -out "$OUT/profile.mobileprovision" 2>/dev/null \
    || die "the profile could not be CMS-wrapped"
echo "  cert.p12, profile.mobileprovision ($(du -h "$OUT/profile.mobileprovision" | cut -f1))"

say "2. a framework to sign: a real arm64 Mach-O with a first signature"
FW="$OUT/Test.framework"
mkdir -p "$FW"
printf 'int nxpocket_test_symbol(void) { return 42; }\n' > "$OUT/test.c"
xcrun --sdk macosx clang -arch arm64 -dynamiclib -install_name @rpath/Test.framework/Test \
    -o "$FW/Test" "$OUT/test.c" || die "the test dylib did not build"
cat > "$FW/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Test</string>
  <key>CFBundleIdentifier</key><string>dev.nxpocket.test</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
</dict></plist>
EOF
# Real content, so the seal is not trivially empty: a game framework keeps its icon and its tables. The .lproj
# directory also exercises the rule that makes nested localisations optional, and the .DS_Store the one that omits it.
printf 'not a real icon, but a file the seal has to cover\n' > "$FW/Icon.png"
mkdir -p "$FW/tables" "$FW/en.lproj"
printf 'tables\n' > "$FW/tables/game.bin"
printf 'strings\n' > "$FW/en.lproj/Localizable.strings"
printf 'junk\n' > "$FW/.DS_Store"
echo "  framework content: $(cd "$FW" && find . -type f | wc -l | tr -d ' ') files"

say "3. zsign + our shim, built for this host"
mkdir -p "$OUT/obj" "$OUT/include"
# Two layouts exist in the wild: a normal OpenSSL has include/openssl/*.h, while
# krzyzanowskim/OpenSSL's framework keeps its headers flat. One symlink covers both.
if [ -d "$OPENSSL/include/openssl" ]; then
    OSSL_HEADERS="$OPENSSL/include/openssl"
elif [ -d "$OPENSSL/Headers" ]; then
    OSSL_HEADERS="$OPENSSL/Headers"
else
    die "no OpenSSL headers under $OPENSSL"
fi
ln -sfn "$OSSL_HEADERS" "$OUT/include/openssl"
echo "  headers: $OSSL_HEADERS"
CXXFLAGS=(-arch arm64 -std=c++11 -O1 -fPIC -I"$WORK/zsign/src" -I"$WORK/zsign/src/common"
          -I"$WORK/zsign/src/third-party/zlib" -I"$WORK/zsign/src/third-party/minizip" -I"$OUT/include")
for source in $(find "$WORK/zsign/src" -name '*.cpp' ! -name 'zsign.cpp'); do
    clang++ "${CXXFLAGS[@]}" -c "$source" -o "$OUT/obj/$(basename "${source%.cpp}").o" \
        || die "$(basename "$source") did not build"
done
clang++ "${CXXFLAGS[@]}" -DNXPOCKET_WITH_ZSIGN -I"$ROOT/tools" \
    -c "$ROOT/tools/zsign_shim.cpp" -o "$OUT/obj/nxpocket_zsign_shim.o" || die "the shim did not build"
libtool -static -o "$OUT/libsigning.a" "$OUT"/obj/*.o || die "libtool"

say "4. calling the signer, exactly as DeviceSigner does"
# A framework carries no rights. zsign would otherwise copy the profile's Entitlements dict into the signature.
cat > "$OUT/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EOF
echo "  entitlements: $(wc -c < "$OUT/entitlements.plist" | tr -d ' ') bytes (empty dict); the seal is the shim's job"
cat > "$OUT/main.cpp" <<'EOF'
#include <stdio.h>
#include "zsign_shim.h"   // include it rather than redeclaring it: a bare declaration loses the C linkage
int main(int argc, char **argv) {
    if (argc < 7) {
        fprintf(stderr, "usage: sign <p12> <pass> <profile> <entitlements> <framework> <exe> <identifier>\n");
        return 2;
    }
    char error[1024] = {0};
    int status = nxpocket_zsign_sign(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7],
                                     error, sizeof error);
    printf("nxpocket_zsign_sign -> %d%s%s\n", status, error[0] ? ": " : "", error);
    return status;
}
EOF
clang++ -std=c++11 -arch arm64 -I"$ROOT/tools" -c "$OUT/main.cpp" -o "$OUT/obj_main.o"
clang++ "$OUT/obj_main.o" "$OUT/libsigning.a" -L"$OPENSSL/lib" -lssl -lcrypto \
    -o "$OUT/sign" || die "the caller did not link"

"$OUT/sign" "$OUT/cert.p12" "$PASSPHRASE" "$OUT/profile.mobileprovision" "$OUT/entitlements.plist" \
    "$FW" "$EXE" "$IDENTIFIER" \
    || die "zsign refused to sign (see the message above)"

say "5. what did zsign actually write? asked for identifier '$IDENTIFIER', team '$TEAM'"
codesign -d --verbose=4 "$FW" 2>&1 | sed -n '1,6p' | sed 's/^/  /'

echo
say "6. Apple's codesign on the result"
VERDICT=$(codesign --verify --verbose=4 "$FW" 2>&1 || true)
echo "$VERDICT" | sed 's/^/  /'
echo
case "$VERDICT" in
    *"valid on disk"*)      echo "  verdict: a valid signature, and the policy accepted it" ;;
    *"modified"*|*"invalid signature"*)
        # Integrity: the signature does not match the file. This is the failure the SHA-256 CodeDirectory fixes;
        # if it comes back, something in the shim's arguments changed.
        die "codesign says the signature does not match the code — the signer is producing invalid signatures" ;;
    *)  echo "  verdict: the signature is structurally intact; what is left is the certificate, not the code."
        echo "  (codesign complains about a bundle seal or a policy a real Apple certificate satisfies.)" ;;
esac

GOT_ID=$(codesign -d --verbose=4 "$FW" 2>&1 | awk -F= '/^Identifier=/{print $2}')
GOT_TEAM=$(codesign -d --verbose=4 "$FW" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
echo
echo "  identifier: asked '$IDENTIFIER', got '$GOT_ID'"
echo "  team:       asked '$TEAM', got '$GOT_TEAM'"
[ "$GOT_ID" = "$IDENTIFIER" ] || die "the identifier zsign wrote is not the one the app asked for"
[ "$GOT_TEAM" = "$TEAM" ] || die "the team in the CodeDirectory is not the profile's"

# The trap that cost the most to find: without SHA256-only, zsign puts the SHA-1 directory in slot 0 and codesign
# rejects the result with "code or signature have been modified". Pin it so a change to the flags cannot bring it
# back unnoticed. This refuses to pass quietly if the directory cannot be read: a verification that skips itself is
# worse than one that fails.
DIRECTORIES=$("$ROOT/tools/read_code_directory.py" "$FW/$EXE") \
    || die "the CodeDirectory could not be read back from the signed binary"
# One line per CodeDirectory. The bug this catches leaves SHA-1 in slot 0 and SHA-256 as the alternate in 0x001000,
# so only the slot 0 line may be tested: a match anywhere in the output passed that very case.
SLOT0=$(printf '%s\n' "$DIRECTORIES" | grep '^slot 0x000000 ' || true)
[ -n "$SLOT0" ] || die "the signed binary has no CodeDirectory in slot 0"
echo "  CodeDirectory slot 0: $SLOT0"
case "$SLOT0" in
    *SHA-256*) echo "  slot 0 is the SHA-256 directory, as an arm64 image needs" ;;
    *) die "slot 0 is not the SHA-256 CodeDirectory: codesign will reject this signature" ;;
esac

# The three things a game's signature can carry as entitlements (DeviceSigner.Entitlements), each read back by
# codesign rather than by our own reader:
#   .none        an empty dict           -> no entitlement at all
#   .appSigned   a file with the app's   -> exactly those, whatever the profile grants
#   .appProfile  no file                 -> the profile's own
# The middle one is how a store whose profile and signature disagree (a wildcard or shared App ID) is followed.
entitlement_keys() {
    codesign -d --entitlements - --xml "$FW/$EXE" 2>/dev/null | tr '<' '\n' | sed -n 's/^key>\(.*\)$/\1/p' | sort | tr '\n' ' '
}
say "7. the entitlements a game's signature carries, for each choice"
echo "  .none        -> [$(entitlement_keys)]"
[ -z "$(entitlement_keys | tr -d ' ')" ] || die "an empty entitlements file must leave the dylib with none"

cat > "$OUT/app-entitlements.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$IDENTIFIER</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>com.apple.developer.kernel.increased-memory-limit</key><true/>
  <key>get-task-allow</key><false/>
</dict></plist>
EOF2
"$OUT/sign" "$OUT/cert.p12" "$PASSPHRASE" "$OUT/profile.mobileprovision" "$OUT/app-entitlements.plist" \
    "$FW" "$EXE" "$IDENTIFIER" || die "signing with the app's entitlements failed"
GOT=$(entitlement_keys)
echo "  .appSigned   -> [$GOT]"
[ "$GOT" = "application-identifier com.apple.developer.kernel.increased-memory-limit com.apple.developer.team-identifier get-task-allow " ] \
    || die "a file of entitlements must reach the dylib as it is (the shim used to drop it)"
codesign -d --entitlements - --xml "$FW/$EXE" 2>/dev/null | grep -q '<false/>' || die "the app's get-task-allow=false was not kept"

"$OUT/sign" "$OUT/cert.p12" "$PASSPHRASE" "$OUT/profile.mobileprovision" "" "$FW" "$EXE" "$IDENTIFIER" \
    || die "signing with the profile's entitlements failed"
GOT=$(entitlement_keys)
echo "  .appProfile  -> [$GOT]"
echo "$GOT" | grep -q "application-identifier" || die "no entitlements file must leave the profile's in the dylib"

say "the signer writes the identifier and the team the device signer needs"
