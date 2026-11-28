#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

MODE="default"
case "${1:-}" in
    ""|"--default") MODE="default" ;;
    "--static") MODE="static" ;;
    "--verify") MODE="verify" ;;
    "--swift-lint") MODE="swift-lint"; shift || true ;;
    "-h"|"--help")
        cat <<'EOF'
Usage: bash scripts/check.sh [--static | --default | --verify | --swift-lint [paths...]]

  --static      Run fast static consistency, token, version, hygiene, and script syntax checks.
  --default     Run --static + default isolated unit tests (swift test --filter ReSignTests).
  --verify      Run --default + release app build + strict deep codesign verification (CI parity).
  --swift-lint  Run advisory swift format lint using .swift-format on specified paths (or Sources/ReSign Tests/ReSignTests).
EOF
        exit 0
        ;;
    *)
        echo "Unknown option: $1 (try --help)" >&2
        exit 2
        ;;
esac

if [[ "$MODE" == "swift-lint" ]]; then
    if [[ $# -gt 0 ]]; then
        exec swift format lint --configuration .swift-format "$@"
    else
        exec swift format lint --configuration .swift-format --recursive Sources/ReSign Tests/ReSignTests
    fi
fi

echo "==> Running static consistency and hygiene checks"
python3 scripts/check-consistency.py

if [[ "$MODE" == "static" ]]; then
    exit 0
fi

if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix)"
    export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

echo "==> Running default unit tests (ReSignTests)"
unset RESIGN_DEVICE_TEST RESIGN_INTEGRATION_URL RESIGN_GSA_PROBE
swift test --filter ReSignTests

if [[ "$MODE" == "verify" ]]; then
    echo "==> Building release application bundle"
    bash scripts/build-app.sh
    echo "==> Verifying deep strict code signature"
    codesign --verify --deep --strict dist/ReSign.app
    echo "==> Verification passed"
fi
