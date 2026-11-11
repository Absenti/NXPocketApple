#!/bin/bash
# Makes the app's dm/font: standard.ttf and nintendo_ext.ttf, both from Noto Sans JP.
#
# Usage: tools/make_fonts.sh <folder>      (tools/build_app.sh passes app/Gen/dm/font)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

# The stand-ins for the console's shared fonts, which a game's host reads from DM_FONT_DIR, the app's dm/font
# (EngineLaunchPlan). Both come from Noto Sans JP (SIL OFL 1.1, free to redistribute), fetched at a pinned revision
# of google/fonts and checked against its SHA-256: standard.ttf is its regular weight, and nintendo_ext.ttf the
# controller-button icons tools/fonts/make_ext_font.py draws with its bold letters. The engine's own build uses
# macOS's Arial Unicode and Arial Rounded, which an IPA given to anyone else may not carry, so they are never taken.
NOTO_REV=66a36c8c94b1a5d992ee4e7f392fccfe4945767c
NOTO_SHA256=c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f
make() {
    local target=$1 cache=$ROOT/.build/fonts
    local python=${NXPOCKET_PYTHON:-$HOME/Library/Application Support/NXPocket/venv/bin/python3}
    local noto=$cache/NotoSansJP-$NOTO_REV.ttf
    "$python" -c 'import fontTools' 2>/dev/null || { echo "  no fontTools: run tools/setup_python.sh" >&2; return 1; }
    mkdir -p "$target" "$cache"
    if [ ! -f "$noto" ] || [ "$(shasum -a 256 "$noto" | cut -d' ' -f1)" != "$NOTO_SHA256" ]; then
        curl -fsSL -o "$noto.part" \
            "https://raw.githubusercontent.com/google/fonts/$NOTO_REV/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf" || return 1
        [ "$(shasum -a 256 "$noto.part" | cut -d' ' -f1)" = "$NOTO_SHA256" ] \
            || { rm -f "$noto.part"; echo "  Noto Sans JP does not match its pinned SHA-256" >&2; return 1; }
        mv "$noto.part" "$noto"
    fi
    "$python" -m fontTools.varLib.instancer -q --update-name-table "$noto" wght=400 -o "$target/standard.ttf" || return 1
    "$python" -m fontTools.varLib.instancer -q --update-name-table "$noto" wght=700 -o "$cache/NotoSansJP-Bold.ttf" || return 1
    "$python" "$ROOT/tools/fonts/make_ext_font.py" "$target/nintendo_ext.ttf" "$cache/NotoSansJP-Bold.ttf" >/dev/null
}

make "${1:?usage: make_fonts.sh <folder>}"
echo "  $(ls "$1" | tr '\n' ' ')"
