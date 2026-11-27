#!/bin/bash
# Builds a universal (Intel + Apple Silicon) app: build/ScreenDimmer.app
# Requires only the Command Line Tools (xcode-select --install) – no Xcode, no SwiftPM.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ScreenDimmer"
MIN_OS="14.0"
ARCHS=(x86_64 arm64)
APP="build/${APP_NAME}.app"
OBJ="build/obj"
SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$OBJ" "$APP"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Workaround for a known Command Line Tools issue: after a CLT update a stale
# usr/include/swift/module.modulemap may remain and duplicate bridging.modulemap
# ("redefinition of module 'SwiftBridging'"). It is hidden with a VFS overlay instead of deleted.
EXTRA_FLAGS=()
TOOLCHAIN_INCLUDE="$(dirname "$(dirname "$(xcrun --find swiftc)")")/include/swift"
if [[ -f "$TOOLCHAIN_INCLUDE/module.modulemap" && -f "$TOOLCHAIN_INCLUDE/bridging.modulemap" ]] \
   && grep -q "SwiftBridging" "$TOOLCHAIN_INCLUDE/module.modulemap"; then
    echo "==> Duplicate module.modulemap detected in CLT – using a VFS overlay"
    : > "$OBJ/empty.modulemap"
    cat > "$OBJ/vfs.yaml" <<YAML
{"version":0,"case-sensitive":"false","roots":[{"name":"$TOOLCHAIN_INCLUDE","type":"directory","contents":[{"name":"module.modulemap","type":"file","external-contents":"$PWD/$OBJ/empty.modulemap"}]}]}
YAML
    EXTRA_FLAGS+=(-vfsoverlay "$OBJ/vfs.yaml")
fi

# Version numbers are written into the built bundle only (Resources/Info.plist stays as is):
# - CFBundleShortVersionString: $VERSION, else the latest v* tag (v1.2.3 -> 1.2.3)
# - CFBundleVersion: $BUILD_NUMBER, else the number of commits (full clones only)
# - ScreenDimmerSourceRevision: `git describe`, e.g. v1.2.3-4-gabc1234-dirty
# Without git (e.g. a source zip) the placeholders from Resources/Info.plist are kept.
set_version() {
    local plist="$APP/Contents/Info.plist" version="${VERSION:-}" build="${BUILD_NUMBER:-}" revision=""
    if git rev-parse --git-dir >/dev/null 2>&1; then
        if [[ -z "$version" ]]; then
            version=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
            version="${version#v}"
        fi
        if [[ -z "$build" && "$(git rev-parse --is-shallow-repository)" == "false" ]]; then
            build=$(git rev-list --count HEAD)
        fi
        revision=$(git describe --tags --always --dirty --match 'v[0-9]*' 2>/dev/null || true)
    fi
    [[ -n "$version" ]] && plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    [[ -n "$build" ]] && plutil -replace CFBundleVersion -string "$build" "$plist"
    [[ -n "$revision" ]] && plutil -replace ScreenDimmerSourceRevision -string "$revision" "$plist"
    echo "==> Version $(plutil -extract CFBundleShortVersionString raw "$plist") ($(plutil -extract CFBundleVersion raw "$plist")), revision ${revision:-unknown}"
}

binaries=()
for arch in "${ARCHS[@]}"; do
    target="${arch}-apple-macosx${MIN_OS}"
    echo "==> Compiling ${target}"
    xcrun swiftc \
        -O -swift-version 5 \
        -target "$target" \
        -sdk "$SDK" \
        ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        -module-name "$APP_NAME" \
        Sources/ScreenDimmer/*.swift \
        -o "${OBJ}/${APP_NAME}-${arch}"
    binaries+=("${OBJ}/${APP_NAME}-${arch}")
done

echo "==> Assembling ${APP}"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
set_version
cp -R Resources/*.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing (required on Apple Silicon)"
codesign --force --deep --sign - --timestamp=none "$APP"

echo "==> Done"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
codesign --verify --strict "$APP" && echo "Signature OK: $APP"
