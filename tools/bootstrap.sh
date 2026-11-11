#!/bin/bash
# Sets the checkout up: the NX2Apple engine the Mac app drives, an empty output folder, and the engine patches.
#
# The engine is a separate project (github.com/LNPANDY/NX2Apple, MIT, a fork of github.com/seedds/nxnative, MIT).
# This repository never vendors it: `tools/engine.py sync` fetches seedds/nxnative at the pinned revision and applies
# NX2Apple's patch queue. The result lands in third_party/NX2Apple/engine and is symlinked here as engine/.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NX2APPLE=${NX2APPLE_DIR:-$ROOT/third_party/NX2Apple}
ENGINE=$ROOT/engine
OUT=${NXPOCKET_OUTPUT:-$HOME/Documents/NXPocket}

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

say "checking the tools"
for tool in git python3 xcodegen xcrun xcodebuild; do
    command -v "$tool" >/dev/null || die "$tool is missing (brew install xcodegen, and install Xcode)"
done
python3 - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit(f'python3 is {sys.version.split()[0]}, the engine needs 3.10 or newer')
PY

say "the engine"
# NX2Apple is not a submodule: it is cloned beside this checkout by hand. An engine/ that already works is left as it
# is, whatever it points at, so running this again never swaps the tree a build uses.
if [ -f "$ENGINE/scripts/build_ipa_from_nsp.py" ]; then
    echo "  engine/ is set up ($(cd "$ENGINE" && pwd -P)), left as it is"
else
    if [ -e "$ENGINE" ] && [ ! -L "$ENGINE" ]; then
        die "engine/ exists and is not a link: move it away first, this script links engine/ to the NX2Apple checkout"
    fi
    [ -f "$NX2APPLE/tools/engine.py" ] \
        || die "no NX2Apple checkout at $NX2APPLE: clone github.com/LNPANDY/NX2Apple there, or set NX2APPLE_DIR to one"
    if [ ! -f "$NX2APPLE/engine/scripts/build_ipa_from_nsp.py" ]; then
        say "syncing the engine tree (this takes a while the first time)"
        python3 "$NX2APPLE/tools/engine.py" sync
    fi
    ln -sfn "$NX2APPLE/engine" "$ENGINE"
    [ -f "$ENGINE/scripts/build_ipa_from_nsp.py" ] || die "the engine tree has no scripts/build_ipa_from_nsp.py"
fi

say "our engine patches"
"$ROOT/tools/apply_patches.sh"

say "output folder"
mkdir -p "$OUT"
printf '  %s\n' "$OUT"

say "done"
cat <<EOF

Next:
  tools/build_mac.sh                  build the launcher (mac/NXPocket)
  tools/build_app.sh --sim            build the iPhone app for the simulator
  tools/build_app.sh --device-unsigned   produce an unsigned IPA for SideStore

Set NXPOCKET_ENGINE to point the launcher at another engine tree.
EOF
