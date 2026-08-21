#!/bin/bash
# Builds mrtab.app.
#
#   --debug              unoptimised build
#   --run                launch when done
#   --reset-permission   clear the Accessibility grant so the next launch prompts again
#
# Signing: set MRTAB_SIGN_IDENTITY to a code signing identity to get a stable signature that
# survives rebuilds. Without one the bundle is ad-hoc signed, and every rebuild invalidates the
# Accessibility grant -- see README.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID=dev.mrtab.app
CONFIGURATION=release
RUN=0
RESET=0
for arg in "$@"; do
    case "$arg" in
        --debug)             CONFIGURATION=debug ;;
        --run)               RUN=1 ;;
        --reset-permission)  RESET=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/mrtab.app"

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/mrtab"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/mrtab"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${MRTAB_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    echo "==> codesign (ad-hoc; rebuilds invalidate the Accessibility grant)"
else
    echo "==> codesign ($IDENTITY)"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1

echo "built $APP"
echo "    cdhash $(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')"

if [ "$RESET" -eq 1 ]; then
    echo "==> tccutil reset Accessibility $BUNDLE_ID"
    pkill -x mrtab 2>/dev/null || true
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "    grant cleared; the next launch will prompt again"
fi

if [ "$RUN" -eq 1 ]; then
    pkill -x mrtab 2>/dev/null || true
    open "$APP"
fi
