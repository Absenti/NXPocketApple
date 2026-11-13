#!/bin/bash
# Runs the iPhone app's tests in the simulator.
#
#   tools/test_app.sh                      iPhone 17, the simulator Xcode names that
#   tools/test_app.sh 'iPhone 18 Pro'      another simulator
#
# The app's tests link the signing engine, so a checkout that never ran tools/build_zsign.sh cannot build them ("no
# XCFramework at app/Signing/OpenSSL.xcframework"). This builds it first when it is missing, then makes the Xcode
# project from app/project.yml (the project is generated and ignored by git, and lists its files when it is made, so a
# test file added since is only run after this step) and runs the one scheme that has a test action: NXPocket. The
# NXShellHost and NXShellUI schemes XcodeGen makes by itself have none.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SIMULATOR=${1:-iPhone 17}

if [ ! -d "$ROOT/app/Signing/libnxzsign.xcframework" ] || [ ! -d "$ROOT/app/Signing/OpenSSL.xcframework" ]; then
    echo "the signing engine is not built: tools/build_zsign.sh (network, once)"
    tools/build_zsign.sh
fi
# The engine's stand-ins for the console's fonts, copied in by tools/build_app.sh from the engine's own build. The
# tests only need the folder to exist, as the app's resources list it.
mkdir -p "$ROOT/app/Gen/dm"

(cd app && xcodegen generate --spec project.yml)
xcodebuild test -project app/NXPocket.xcodeproj -scheme NXPocket \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -derivedDataPath "$ROOT/.build/dd" CODE_SIGNING_ALLOWED=NO
