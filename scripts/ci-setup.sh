#!/bin/bash
set -euo pipefail

if [[ "$(uname -m)" != arm64 ]]; then
    echo "构建需要 Apple Silicon（arm64）运行器。" >&2
    exit 1
fi
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MACOS_MAJOR < 27 )); then
    echo "构建需要 macOS 27 或更高版本。" >&2
    exit 1
fi
xcodebuild -version
swift --version
brew install libplist libimobiledevice-glue libusbmuxd openssl@4 pkgconf
PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
export PKG_CONFIG_PATH
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
fi
