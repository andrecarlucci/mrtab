#!/bin/bash
# Builds MrTab.app.
#
#   --debug              unoptimised build
#   --universal          fat binary for both Apple Silicon and Intel, for running on another Mac
#   --run                launch when done
#   --reset-permission   clear the Accessibility grant so the next launch prompts again
#
# Signing: set MRTAB_SIGN_IDENTITY to a code signing identity to get a stable signature that
# survives rebuilds. Without one the bundle is ad-hoc signed, and every rebuild invalidates the
# Accessibility grant -- see README.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID=dev.mrtab.app
# Keep in step with the platforms line in Package.swift.
MIN_MACOS=13.0

CONFIGURATION=release
RUN=0
RESET=0
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --debug)             CONFIGURATION=debug ;;
        --universal)         UNIVERSAL=1 ;;
        --run)               RUN=1 ;;
        --reset-permission)  RESET=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/MrTab.app"
SLICES=()

if [ "$UNIVERSAL" -eq 1 ]; then
    # Cross-compiling both slices needs only the command line tools; `swift build --arch`
    # would need a full Xcode install, which is why the triples are spelled out.
    for arch in arm64 x86_64; do
        echo "==> swift build -c $CONFIGURATION --triple $arch-apple-macosx$MIN_MACOS"
        swift build -c "$CONFIGURATION" --triple "$arch-apple-macosx$MIN_MACOS"
        SLICES+=(".build/$arch-apple-macosx/$CONFIGURATION/MrTab")
    done
else
    echo "==> swift build -c $CONFIGURATION"
    swift build -c "$CONFIGURATION"
    SLICES=("$(swift build -c "$CONFIGURATION" --show-bin-path)/MrTab")
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create -output "$APP/Contents/MacOS/MrTab" "${SLICES[@]}"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/MrTab"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${MRTAB_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    echo "==> codesign (ad-hoc; rebuilds invalidate the Accessibility grant)"
else
    echo "==> codesign ($IDENTITY)"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1

echo "built $APP"
echo "    arch   $(lipo -archs "$APP/Contents/MacOS/MrTab")"
echo "    cdhash $(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')"

if [ "$RESET" -eq 1 ]; then
    echo "==> tccutil reset Accessibility $BUNDLE_ID"
    pkill -x MrTab 2>/dev/null || true
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "    grant cleared; the next launch will prompt again"
fi

if [ "$RUN" -eq 1 ]; then
    pkill -x MrTab 2>/dev/null || true
    open "$APP"
fi
