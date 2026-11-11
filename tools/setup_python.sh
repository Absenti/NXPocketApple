#!/bin/bash
# Makes the Python the Mac launcher runs the engine with: a virtual environment with the modules
# engine/scripts/build_ipa_from_nsp.py imports, and nsz for NSZ / XCZ games. The launcher's Setup screen does the same
# without a terminal or Homebrew (it brings its own Python 3.14); this script is for a checkout that has a Python.
#
#   tools/setup_python.sh            creates or updates ~/Library/Application Support/NXPocket/venv
#
# The launcher looks there first (after a Python set in its Settings), so nothing else needs configuring. It needs a
# Python 3.12 or later to start from, and the network once, for pip.
set -euo pipefail

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

VENV="$HOME/Library/Application Support/NXPocket/venv"

BASE=""
for candidate in "${NXPOCKET_BASE_PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
        BASE=$candidate
        break
    fi
done
[ -n "$BASE" ] || die "no Python 3.12 or later found (brew install python@3.14, or set NXPOCKET_BASE_PYTHON)"
say "base Python: $BASE ($("$BASE" --version 2>&1))"

if [ ! -x "$VENV/bin/python3" ]; then
    say "creating $VENV"
    mkdir -p "$(dirname "$VENV")"
    "$BASE" -m venv "$VENV"
fi

# The same pinned versions and hashes the launcher's Setup screen installs. backports.zstd comes only before Python
# 3.14 (its line carries the marker): 3.14 has compression.zstd.
REQUIREMENTS="$(cd "$(dirname "$0")" && pwd)/python-requirements.txt"
say "installing the pinned packages (tools/python-requirements.txt)"
"$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary :all: -r "$REQUIREMENTS"

say "checking"
"$VENV/bin/python3" -I -c '
import importlib.util as u
missing = [n for n, ms in (("lz4", ["lz4.block"]), ("capstone", ["capstone"]), ("fontTools", ["fontTools"]),
                          ("zbic", ["zbic"]), ("zstd", ["compression.zstd", "backports.zstd"]), ("nsz", ["nsz"]))
           if not any(u.find_spec(m) for m in ms)]
raise SystemExit("still missing: " + ", ".join(missing) if missing else 0)
' || die "the environment is incomplete"
echo "  ready: $VENV/bin/python3"
echo "In the launcher: Settings, then reopen the app (or change a path) so the toolchain is checked again."
