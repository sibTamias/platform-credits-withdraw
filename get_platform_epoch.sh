#!/usr/bin/env bash
#
# get_platform_epoch.sh — текущая эпоха и время начала/конца через platform-explorer API.
#
# Примеры:
#   ./get_platform_epoch.sh
#   ./get_platform_epoch.sh 71
#   PLATFORM_EXPLORER_URL=http://localhost:3005 ./get_platform_epoch.sh
#

set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -r "$BIN/.env" ]] && source "$BIN/.env"

PLATFORM_EXPLORER_URL="${PLATFORM_EXPLORER_URL:-https://platform-explorer.pshenmic.dev}"
TZ_DISPLAY="${TZ_DISPLAY:-Asia/Irkutsk}"
EPOCH_ARG="${1:-}"

usage() {
	cat <<'EOF'
Platform epoch times (API + human-readable).

Usage:
  get_platform_epoch.sh [epoch_number]

Environment:
  PLATFORM_EXPLORER_URL  default: https://platform-explorer.pshenmic.dev
  TZ_DISPLAY             default: Asia/Irkutsk

Examples:
  get_platform_epoch.sh
  get_platform_epoch.sh 71
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

ms_to_lines() {
	local label="$1"
	local ms="$2"
	if [[ -z "$ms" || "$ms" == "null" ]]; then
		printf '%s: (unavailable)\n' "$label"
		return 0
	fi
	python3 - "$label" "$ms" "$TZ_DISPLAY" <<'PY'
import datetime
import sys

label, ms, tz_name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
utc = datetime.timezone.utc
dt_utc = datetime.datetime.fromtimestamp(ms / 1000, tz=utc)
print(f"{label}:")
print(f"  ms:   {ms}")
print(f"  UTC:  {dt_utc.strftime('%Y-%m-%d %H:%M:%S')} UTC")
try:
    tz = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=0)))
    # zoneinfo if available, else fixed offset for Irkutsk
    try:
        from zoneinfo import ZoneInfo
        dt_local = dt_utc.astimezone(ZoneInfo(tz_name))
    except Exception:
        if tz_name == "Asia/Irkutsk":
            dt_local = dt_utc.astimezone(datetime.timezone(datetime.timedelta(hours=8)))
        else:
            dt_local = dt_utc
    print(f"  {tz_name}: {dt_local.strftime('%Y-%m-%d %H:%M:%S %Z')}")
except Exception as e:
    print(f"  local: (conversion failed: {e})")
PY
}

fetch_json() {
	local url="$1"
	local data
	data=$(curl -sf --max-time 20 "$url") || {
		echo "[ERROR] API request failed: $url" >&2
		echo "Hint: curl -sv $url" >&2
		exit 1
	}
	echo "$data"
}

status_json=$(fetch_json "$PLATFORM_EXPLORER_URL/status")
cur_epoch=$(echo "$status_json" | jq -r '.epoch.number // .epochs.current // .data.epoch.number // empty')
if [[ -z "$cur_epoch" || "$cur_epoch" == "null" ]]; then
	echo "[ERROR] /status did not return epoch number" >&2
	echo "$status_json" | jq . >&2 || echo "$status_json" >&2
	exit 1
fi

target_epoch="${EPOCH_ARG:-$cur_epoch}"
epoch_json=$(fetch_json "$PLATFORM_EXPLORER_URL/epoch/$target_epoch")

start_ms=$(echo "$epoch_json" | jq -r '.epoch.startTime // empty')
end_ms=$(echo "$epoch_json" | jq -r '.epoch.endTime // empty')
next_start_ms=$(echo "$epoch_json" | jq -r '.nextEpoch.startTime // empty')

if [[ -z "$end_ms" || "$end_ms" == "null" ]]; then
	end_ms="$next_start_ms"
fi
if [[ -z "$end_ms" || "$end_ms" == "null" ]]; then
	next_json=$(fetch_json "$PLATFORM_EXPLORER_URL/epoch/$((target_epoch + 1))" 2>/dev/null || true)
	if [[ -n "${next_json:-}" ]]; then
		end_ms=$(echo "$next_json" | jq -r '.epoch.startTime // empty')
	fi
fi

echo "API: $PLATFORM_EXPLORER_URL"
echo "Current epoch: $cur_epoch"
echo "Showing epoch: $target_epoch"
echo

ms_to_lines "startTime (epoch $target_epoch)" "$start_ms"
echo
if [[ -n "$end_ms" && "$end_ms" != "null" ]]; then
	ms_to_lines "endTime / next epoch $((target_epoch + 1)) start" "$end_ms"
	echo
	now_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
	remaining_ms=$((end_ms - now_ms))
	if (( remaining_ms > 0 )); then
		python3 - "$remaining_ms" <<'PY'
import datetime
import sys
ms = int(sys.argv[1])
delta = datetime.timedelta(milliseconds=ms)
days = delta.days
secs = delta.seconds
hours, rem = divmod(secs, 3600)
mins, secs = divmod(rem, 60)
print(f"Until next epoch: {days}d {hours:02d}:{mins:02d}:{secs:02d}")
PY
	else
		echo "Until next epoch: already started or passed"
	fi
else
	echo "endTime / nextStart: (unavailable — epoch $((target_epoch + 1)) not in API yet)"
fi

echo
echo "--- raw JSON ---"
echo "$epoch_json" | jq '{
  epoch: .epoch.number,
  startTime: .epoch.startTime,
  endTime: .epoch.endTime,
  nextStart: .nextEpoch.startTime
}'
