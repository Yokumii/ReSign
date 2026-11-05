#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
/bin/bash scripts/build-app.sh
