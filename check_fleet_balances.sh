#!/usr/bin/env bash
#
# check_fleet_balances.sh — замер времени опроса балансов всех нод через platform-explorer API.
# Использует тот же API /validator/, что check_fleet_balances.sh (диагностика, не используется в epoch-gate).
#
# Примеры:
#   ./check_fleet_balances.sh
#   ./check_fleet_balances.sh --verbose
#   KEYS_FILE=~/bin/privkey_protx.txt ./check_fleet_balances.sh
#

set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -r "$BIN/.env" ]] && source "$BIN/.env"
[[ -r "$HOME/bin/.env" ]] && source "$HOME/bin/.env"
# shellcheck source=platform_explorer_api.sh
source "$BIN/platform_explorer_api.sh"

KEYS_FILE="${KEYS_FILE:-$BIN/privkey_protx.txt}"
platform_explorer_resolve_url
MIN_WITHDRAWAL_FEE="${MIN_WITHDRAWAL_FEE:-400000000}"
VERBOSE=0
SAMPLE=0

usage() {
	cat <<'EOF'
Usage: check_fleet_balances.sh [options]

Options:
  --verbose, -v   Показать баланс и время по каждой ноде
  --sample        Один случайный proTx из privkey_protx.txt
  --keys-file F   Файл privkey:proTxHash (default: privkey_protx.txt)
  -h, --help      Справка

Environment:
  KEYS_FILE, PLATFORM_EXPLORER_URL, PLATFORM_EXPLORER_SSH, MIN_WITHDRAWAL_FEE
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-v|--verbose) VERBOSE=1; shift ;;
		--sample) SAMPLE=1; shift ;;
		--keys-file) KEYS_FILE="$2"; shift 2 ;;
		*) echo "[ERROR] unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

now_ms() {
	python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

list_protx_hashes() {
	grep -v '^[[:space:]]*#' "$KEYS_FILE" | grep -v '^[[:space:]]*$' | awk -F: '{print $NF}'
}

get_validator_balance_credits() {
	local protx="$1" bal
	bal=$(platform_api_get "/validator/$protx" \
		| jq -r '.identityBalance // 0' 2>/dev/null) || bal=0
	[[ "$bal" =~ ^[0-9]+$ ]] || bal=0
	echo "$bal"
}

if [[ ! -r "$KEYS_FILE" ]]; then
	echo "[ERROR] keys file not found: $KEYS_FILE" >&2
	exit 1
fi

mapfile -t PROTX_LIST < <(list_protx_hashes)
total=${#PROTX_LIST[@]}
if (( total == 0 )); then
	echo "[ERROR] no proTxHash entries in $KEYS_FILE" >&2
	exit 1
fi

if (( SAMPLE )); then
	protx="${PROTX_LIST[$RANDOM % total]}"
	echo "API:              $(platform_explorer_api_label)"
	echo "Keys file:        $KEYS_FILE"
	echo "Pool size:        $total"
	echo "Sample mode:      1 random proTx (epoch poll uses this)"
	echo ""
	t0=$(now_ms)
	bal=$(get_validator_balance_credits "$protx")
	t1=$(now_ms)
	echo "Sample proTx:       ${protx:0:16}...${protx: -8}"
	echo "Balance:            $bal credits"
	echo "Request time:       $((t1 - t0)) ms"
	echo "Min withdrawable:   > $MIN_WITHDRAWAL_FEE"
	if (( bal > MIN_WITHDRAWAL_FEE )); then
		echo "=> TRIGGER: would start withdrawal for all $total nodes"
	else
		echo "=> wait ${EPOCH_BALANCE_POLL_SEC:-10}s and sample another node"
	fi
	exit 0
fi

echo "API:              $(platform_explorer_api_label)"
echo "Keys file:        $KEYS_FILE"
echo "Nodes to check:   $total"
echo "Min withdrawable: > $MIN_WITHDRAWAL_FEE credits"
echo ""

t0=$(now_ms)
max=0
above=0
ok=0
fail=0
idx=0

for protx in "${PROTX_LIST[@]}"; do
	((idx++)) || true
	t_node0=$(now_ms)
	bal=$(get_validator_balance_credits "$protx") || bal=0
	t_node1=$(now_ms)
	node_ms=$((t_node1 - t_node0))

	if [[ "$bal" =~ ^[0-9]+$ ]]; then
		((ok++)) || true
	else
		((fail++)) || true
		bal=0
	fi
	(( bal > max )) && max=$bal
	(( bal > MIN_WITHDRAWAL_FEE )) && ((above++)) || true

	if (( VERBOSE )); then
		status="below min"
		(( bal > MIN_WITHDRAWAL_FEE )) && status="WITHDRAWABLE"
		printf "  %2d  %6d ms  %12s credits  %s  %s...%s\n" \
			"$idx" "$node_ms" "$bal" "$status" "${protx:0:8}" "${protx: -8}"
	fi
done

t1=$(now_ms)
total_ms=$((t1 - t0))
avg_ms=0
(( total > 0 )) && avg_ms=$((total_ms / total))

echo "=== FLEET BALANCE POLL TIMING ==="
echo "Nodes checked:    $total"
echo "API OK:           $ok"
echo "API failed:       $fail"
echo "Total time:       ${total_ms} ms  ($(awk -v ms="$total_ms" 'BEGIN { printf "%.2f", ms/1000 }') s)"
echo "Avg per node:     ${avg_ms} ms"
echo "Max balance:      $max credits"
echo "Above minimum:    $above / $total"
echo ""
if (( above > 0 )); then
	echo "=> Withdrawal can run now ($above node(s) above $MIN_WITHDRAWAL_FEE)"
else
	short=$((MIN_WITHDRAWAL_FEE - max))
	echo "=> Not yet withdrawable (max $max, short $short credits to minimum)"
fi
