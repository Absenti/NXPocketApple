#!/bin/bash
# Runs the probe on the *simulator* with a generated certificate, to check the probe's own code: that it de-XORs
# the bundled frameworks, writes them into Documents, signs them through tools/zsign_shim.cpp, reads the signature
# identifier back, and dlopens them.
#
# What this does NOT prove, and must never be read as proving: that iOS accepts the result. The simulator does not
# enforce code signatures, so 5A passing here is not the answer to phase 0c. Only the iPhone is.
#
# Usage: tools/run_probe_simulator.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=${NXPOCKET_SIGNING_WORK:-$ROOT/.build/signing}/probe-sim
TEAM=ABCDE12345
IDENTIFIER=dev.nxpocket.probe
PASSPHRASE=probe-sim
DEVICE="iPhone 17"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

say "1. a certificate chain, and a provisioning profile naming team $TEAM"
rm -rf "$WORK" && mkdir -p "$WORK"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/ca-key.pem" -out "$WORK/ca.pem" -days 30 -nodes \
    -subj "/CN=NXPocketApple probe CA/O=NXPocketApple/C=FR" 2>/dev/null || die "CA"
openssl req -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/leaf.csr" -nodes \
    -subj "/CN=Apple Development: NXPocketApple probe ($TEAM)/OU=$TEAM/O=NXPocketApple/C=FR" 2>/dev/null || die "leaf key"
cat > "$WORK/leaf.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca-key.pem" -CAcreateserial \
    -extfile "$WORK/leaf.ext" -out "$WORK/cert.pem" -days 30 2>/dev/null || die "leaf cert"
# The p12 must carry its issuer: GenerateCMS prefers a CA chain inside the p12 and otherwise demands an Apple WWDR
# intermediate. A real SideStore export carries the intermediate for the same reason.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -certfile "$WORK/ca.pem" -out "$WORK/cert.p12" \
    -passout "pass:$PASSPHRASE" -name "NXPocketApple probe" 2>/dev/null || die "p12"
cat > "$WORK/profile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Name</key><string>NXPocketApple probe profile</string>
  <key>TeamIdentifier</key><array><string>$TEAM</string></array>
  <key>UUID</key><string>00000000-0000-0000-0000-0000000000FE</string>
  <key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date>
  <key>Entitlements</key><dict>
    <key>application-identifier</key><string>$TEAM.$IDENTIFIER</string>
    <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
    <key>get-task-allow</key><true/>
  </dict>
</dict></plist>
EOF
openssl smime -sign -in "$WORK/profile.plist" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" \
    -outform DER -nodetach -out "$WORK/profile.mobileprovision" 2>/dev/null || die "profile"
echo "  $WORK/cert.p12 and $WORK/profile.mobileprovision"

say "2. the probe, for the simulator"
SIM=1 "$ROOT/probe/build_probe.sh" >/dev/null || die "the probe did not build"
echo "  $(du -h "$ROOT/probe-out/NXProbe.ipa" | cut -f1) IPA"

say "3. install and run it"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" dev.nxpocket.probe 2>/dev/null || true
xcrun simctl install "$DEVICE" "$ROOT/probe-out/NXProbe.ipa" || die "install"
# The environment is only how the probe is fed a certificate without a file picker: nothing is written to disk.
SIMCTL_CHILD_NXPROBE_P12="$WORK/cert.p12" \
SIMCTL_CHILD_NXPROBE_PASSWORD="$PASSPHRASE" \
SIMCTL_CHILD_NXPROBE_PROVISION="$WORK/profile.mobileprovision" \
    xcrun simctl launch "$DEVICE" dev.nxpocket.probe >/dev/null || die "launch"
sleep 12

say "4. what the probe logged"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" dev.nxpocket.probe data) || die "container"
LOG=$(find "$CONTAINER" -name 'probe-log.txt' | head -1)
[ -n "$LOG" ] || die "the probe wrote no log"
grep -E '^\[(sig|2 |5A|5B)|^RESULT|^\[cert|^\[5 resign|^summary' "$LOG" | sed 's/^/  /'
