#!/usr/bin/env bash
# dash_cli_docker.sh — оболочка для dash-cli внутри dashmate Core контейнера.
#
# Примеры:
#   ./dash_cli_docker.sh getblockcount
#   ./dash_cli_docker.sh -rpcwallet=operator protx list registered true
#
# По умолчанию выбирает контейнер по шаблону mainnet-core-1.
# Можно переопределить:
#   DASH_CORE_CONTAINER="dashmate_xxx_mainnet-core-1"

set -euo pipefail

CONTAINER="${DASH_CORE_CONTAINER:-}"
if [[ -z "$CONTAINER" ]]; then
  CONTAINER="$(docker ps --format '{{.Names}}' | rg 'mainnet-core-1$' | head -n 1 || true)"
fi

if [[ -z "$CONTAINER" ]]; then
  echo "[ERROR] Dash Core container not found (pattern: mainnet-core-1)." >&2
  echo "Set DASH_CORE_CONTAINER in .env or start dashmate core." >&2
  exit 1
fi

exec docker exec "$CONTAINER" dash-cli "$@"
