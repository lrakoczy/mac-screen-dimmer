#!/bin/bash
# Compiles and runs the logic tests (display simulator – real displays are never touched).
set -euo pipefail
cd "$(dirname "$0")/.."
OBJ="build/test"
mkdir -p "$OBJ"
EXTRA_FLAGS=()
TOOLCHAIN_INCLUDE="$(dirname "$(dirname "$(xcrun --find swiftc)")")/include/swift"
if [[ -f "$TOOLCHAIN_INCLUDE/module.modulemap" && -f "$TOOLCHAIN_INCLUDE/bridging.modulemap" ]] \
   && grep -q "SwiftBridging" "$TOOLCHAIN_INCLUDE/module.modulemap"; then
    : > "$OBJ/empty.modulemap"
    cat > "$OBJ/vfs.yaml" <<YAML
{"version":0,"case-sensitive":"false","roots":[{"name":"$TOOLCHAIN_INCLUDE","type":"directory","contents":[{"name":"module.modulemap","type":"file","external-contents":"$PWD/$OBJ/empty.modulemap"}]}]}
YAML
    EXTRA_FLAGS+=(-vfsoverlay "$OBJ/vfs.yaml")
fi
xcrun swiftc -swift-version 5 ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -module-name ScreenDimmerTests \
    Sources/ScreenDimmer/DisplayAPI.swift Sources/ScreenDimmer/DisplayManager.swift \
    Sources/ScreenDimmer/Preferences.swift Sources/ScreenDimmer/Localization.swift Tests/main.swift -o "$OBJ/tests"
"$OBJ/tests"
