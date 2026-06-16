#!/usr/bin/env bash
# Обратный SSH-туннель: platform-explorer (localhost:3005 на platformExp)
# → localhost:13005 на BigBr (109.73.195.123).
#
# Запуск на platformExp (161.97.96.43):
#   ./setup_platform_explorer_tunnel.sh
#   ./setup_platform_explorer_tunnel.sh --install-cron
#
# На BigBr в ~/bin/.env:
#   export PLATFORM_EXPLORER_URL="http://127.0.0.1:13005"

set -euo pipefail

BIGBR_HOST="${BIGBR_HOST:-mno@109.73.195.123}"
LOCAL_API_PORT="${LOCAL_API_PORT:-3005}"
REMOTE_BIND_PORT="${REMOTE_BIND_PORT:-13005}"
INSTALL_CRON=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--install-cron) INSTALL_CRON=1; shift ;;
		-h|--help)
			sed -n '1,12p' "$0"
			exit 0
			;;
		*) echo "[ERROR] unknown option: $1" >&2; exit 1 ;;
	esac
done

start_tunnel() {
	pkill -f "ssh.*-R ${REMOTE_BIND_PORT}:127.0.0.1:${LOCAL_API_PORT}.*${BIGBR_HOST}" 2>/dev/null || true
	sleep 1
	ssh -f -N \
		-o BatchMode=yes \
		-o ServerAliveInterval=30 \
		-o ServerAliveCountMax=3 \
		-o ExitOnForwardFailure=yes \
		-R "${REMOTE_BIND_PORT}:127.0.0.1:${LOCAL_API_PORT}" \
		"$BIGBR_HOST"
}

echo "==> Reverse tunnel ${LOCAL_API_PORT} (local) → ${BIGBR_HOST}:${REMOTE_BIND_PORT}"
start_tunnel
sleep 1
if curl -sf --max-time 5 "http://127.0.0.1:${LOCAL_API_PORT}/status" >/dev/null; then
	echo "Local API OK on :${LOCAL_API_PORT}"
else
	echo "[WARN] Local API not responding on :${LOCAL_API_PORT}" >&2
fi
ssh -o BatchMode=yes "$BIGBR_HOST" "curl -sf --max-time 5 http://127.0.0.1:${REMOTE_BIND_PORT}/status | jq -r '.epoch.number'" \
	&& echo "Tunnel OK on BigBr :${REMOTE_BIND_PORT}" \
	|| { echo "[ERROR] Tunnel check failed on BigBr" >&2; exit 1; }

if (( INSTALL_CRON )); then
	BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	CRON_LINE="@reboot sleep 30 && ${BIN}/setup_platform_explorer_tunnel.sh >> ${HOME}/tmp/tunnel.log 2>&1"
	CRON_MARKER="# platform_explorer_tunnel_to_bigbr"
	( crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | grep -v 'setup_platform_explorer_tunnel.sh'; \
	  echo "$CRON_MARKER"; echo "$CRON_LINE" ) | crontab -
	echo "Cron @reboot installed: $CRON_LINE"
fi

echo "Done. On BigBr set: export PLATFORM_EXPLORER_URL=\"http://127.0.0.1:${REMOTE_BIND_PORT}\""
