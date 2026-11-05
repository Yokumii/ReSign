#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -n "${RESIGN_BUILD_NUMBER:-}" && ! "$RESIGN_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "RESIGN_BUILD_NUMBER 必须是正整数。" >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "请先安装 Homebrew，并安装 libimobiledevice、libplist 和 pkgconf。" >&2
    exit 1
fi
BREW_PREFIX="$(brew --prefix)"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if ! pkg-config --exists libimobiledevice-1.0 libplist-2.0; then
    echo "缺少设备通信依赖。请运行：brew install libimobiledevice libplist pkgconf" >&2
    exit 1
fi

swift build -c release --product ReSign
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PROJECT_ROOT/dist/ReSign.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/ReSign" "$APP/Contents/MacOS/ReSign"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${RESIGN_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RESIGN_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
cp Vendor/MacAnisette-LICENSE "$APP/Contents/Resources/Licenses/"

# Bundle the Homebrew dylib closure, preserving Apple system libraries.
# Resolve each copied library's dependencies using its original load commands.
python3 scripts/bundle-libraries.py "$APP" "$BIN_DIR" "$BREW_PREFIX"
python3 scripts/collect-notices.py "$APP"

IDENTITY="${RESIGN_CODESIGN_IDENTITY:--}"
while IFS= read -r -d '' library; do
    codesign --force --sign "$IDENTITY" "$library"
done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print0)
while IFS= read -r -d '' framework; do
    codesign --force --sign "$IDENTITY" "$framework"
done < <(find "$APP/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
codesign --force --sign "$IDENTITY" "$APP"
echo "已生成：$APP"
