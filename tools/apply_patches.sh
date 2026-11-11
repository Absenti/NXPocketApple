#!/bin/bash
# Applies patches/NNNN-*.patch, in the order of patches/series, on top of engine/.
#
# The engine is a build product, never edited directly: every change of ours is a patch with a Reason: header, so a
# new engine sync does not silently lose it. A patch's paths are relative to the *engine* tree (dm/ios/...).
#
# The engine normally lives inside another repository (third_party/NX2Apple/engine), and `git apply` resolves a
# patch's paths against the **repository root**, not the working directory. Worse, a path falling outside the working
# directory makes git skip the patch silently and still exit 0. Every call therefore gets
# --directory=<engine's path inside its repository>, empty for a standalone engine checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
ENGINE=${NXPOCKET_ENGINE:-$ROOT/engine}
SERIES=$ROOT/patches/series

[ -f "$ENGINE/scripts/build_ipa_from_nsp.py" ] || { echo "engine/ is not synced: run tools/bootstrap.sh" >&2; exit 1; }
[ -f "$SERIES" ] || { echo "no patches/series: nothing to do"; exit 0; }

# Where the engine sits inside its git repository: "engine/" for third_party/NX2Apple/engine, "" for a standalone
# nxnative checkout. A non-zero exit means the engine is not a git checkout at all.
if ! PREFIX=$(git -C "$ENGINE" rev-parse --show-prefix 2>/dev/null); then
    echo "FAIL: $ENGINE is not inside a git work tree, so a patch cannot be applied or probed." >&2
    echo "      Point NXPOCKET_ENGINE at a checkout, or run tools/bootstrap.sh." >&2
    exit 1
fi

GIT=(git -C "$ENGINE" apply)
[ -n "$PREFIX" ] && GIT+=(--directory="$PREFIX")

applied=0
skipped=0
while IFS= read -r line; do
    name=${line%%#*}
    name=$(printf '%s' "$name" | tr -d '[:space:]')
    [ -n "$name" ] || continue
    patch_file=$ROOT/patches/$name
    [ -f "$patch_file" ] || { echo "FAIL: patches/$name is listed but missing" >&2; exit 1; }

    if "${GIT[@]}" --check -R "$patch_file" 2>/dev/null; then
        echo "already applied  $name"
        skipped=$((skipped + 1))
        continue
    fi
    if ! "${GIT[@]}" --check "$patch_file" 2>/dev/null; then
        echo "FAIL: $name does not apply to this engine tree." >&2
        echo "      The engine moved: rebase the patch or drop it from patches/series." >&2
        "${GIT[@]}" --check -v "$patch_file" || true
        exit 1
    fi
    "${GIT[@]}" "$patch_file"
    # A patch git quietly skipped would otherwise be reported as applied.
    if ! "${GIT[@]}" --check -R "$patch_file" 2>/dev/null; then
        echo "FAIL: $name reported success but the engine tree does not show it." >&2
        echo "      Refusing to go on: the next build would use an unpatched engine." >&2
        exit 1
    fi
    echo "applied          $name"
    applied=$((applied + 1))
done < "$SERIES"

echo "patches: $applied applied, $skipped already there"
