#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]] || ! grep -Eq '^TUNNEL_TOKEN=[A-Za-z0-9_+/=-]+$' .env; then
    echo "请先在当前目录的 .env 中填写 TUNNEL_TOKEN，使用原始 Token，不加引号。" >&2
    exit 1
fi
docker compose --profile tunnel up -d cloudflared
