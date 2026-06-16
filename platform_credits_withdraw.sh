#!/usr/bin/env bash
#
# platform_credits_withdraw.sh — локальный вывод Platform credits (как Mass Send в EvoWatch).
#
# Аналог формы WebMuxValidator «Массовая рассылка»:
#   node index.js --private-keys-path <file> --network mainnet --type withdrawal
#
# Формат файла ключей (по одной строке):
#   private_key_WIF:proTxHash
#
# Типичный сценарий:
#   1) Обновить privkey_protx.txt из кошелька operator (--update-keys)
#   2) Вывести credits: ./platform_credits_withdraw.sh
#
# --update-keys: protx list (Owned+Evo) → dumpprivkey → privkey_protx.txt
# all-ips.txt не используется.
#
# Требования:
#   - dash-platform-mass-send (npm install), Node.js 18+
#   - jq, curl — только для --update-keys
#   - Dash Core с разблокированными кошельками operator/fees — для --update-keys
#

set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -r "$BIN/.env" ]] && source "$BIN/.env"

NETWORK="${NETWORK:-mainnet}"
TYPE="${TYPE:-withdrawal}"
KEYS_FILE="${KEYS_FILE:-$BIN/privkey_protx.txt}"
MASS_SEND_DIR="${MASS_SEND_DIR:-$HOME/dash-platform-mass-send}"
NODE_PATH="${NODE_PATH:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-300}"
PLATFORM_EXPLORER_URL="${PLATFORM_EXPLORER_URL:-https://platform-explorer.pshenmic.dev}"
EPOCH_WITHDRAW_OFFSET_SEC="${EPOCH_WITHDRAW_OFFSET_SEC:-}"
if [[ -z "$EPOCH_WITHDRAW_OFFSET_SEC" && -n "${EPOCH_WITHDRAW_OFFSET_MIN:-}" ]]; then
	EPOCH_WITHDRAW_OFFSET_SEC=$((EPOCH_WITHDRAW_OFFSET_MIN * 60))
fi
EPOCH_WITHDRAW_OFFSET_SEC="${EPOCH_WITHDRAW_OFFSET_SEC:-5}"
EPOCH_BALANCE_POLL_SEC="${EPOCH_BALANCE_POLL_SEC:-10}"
EPOCH_WITHDRAW_RETRY_SEC="${EPOCH_WITHDRAW_RETRY_SEC:-120}"
EPOCH_WITHDRAW_MAX_ROUNDS="${EPOCH_WITHDRAW_MAX_ROUNDS:-20}"
LAST_EPOCH_FILE="${LAST_EPOCH_FILE:-$BIN/.platform_credits_withdraw_last_epoch}"
CRON_LOG="${CRON_LOG:-$HOME/tmp/cron.log}"
CRON_TZ="${CRON_TZ:-Asia/Irkutsk}"
CRON_MARKER="# platform_credits_withdraw epoch-scheduled"
UPDATE_KEYS=0
DRY_RUN=0
EPOCH_GATE=0
FORCE_RUN=0
RESCHEDULE_CRON=0
SCHEDULE_ONLY=0
RECIPIENT=""
AMOUNT=""
FEE=""

usage() {
	cat <<'EOF'
Platform credits withdrawal (local Mass Send).

Usage:
  platform_credits_withdraw.sh [options]

Options:
  --update-keys, -u   Обновить privkey_protx.txt из кошелька operator (Owned+Evo)
  --keys-file PATH    Файл privkey:proTxHash (default: privkey_protx.txt)
  --network NET       mainnet | testnet (default: mainnet)
  --type TYPE         withdrawal | transfer (default: withdrawal)
  --recipient ADDR    Адрес получателя (для transfer; для withdrawal — payout из protx)
  --amount N          Сумма credits (default: весь баланс минус fee)
  --fee N             Fee in credits (protocol minimum 400000000; do not lower)
  --dry-run           Проверить окружение и показать команду, не выполнять
  --epoch-gate        Авто-режим эпохи: ждать баланс > fee, выводить в цикле, cron на старт эпохи
  --force             Игнорировать проверку эпохи и ожидание баланса (ручной запуск)
  --reschedule-cron   После прогона обновить crontab на следующую эпоху
  --schedule-only     Только пересчитать cron (без вывода credits)
  -h, --help          Эта справка

Environment (.env):
  KEYS_FILE, MASS_SEND_DIR, NODE_PATH, NETWORK, TYPE, TIMEOUT_SEC
  PLATFORM_EXPLORER_URL, EPOCH_WITHDRAW_OFFSET_SEC (default 5 — cron = старт эпохи + 5с)
  EPOCH_BALANCE_POLL_SEC (default 10 — опрос 1 случайной ноды), EPOCH_WITHDRAW_RETRY_SEC (120), EPOCH_WITHDRAW_MAX_ROUNDS (20)
  LAST_EPOCH_FILE, CRON_LOG, CRON_TZ
  RPC_URL, RPC_USER, RPC_PASS, WALLET, WALLET_FEE, WALLET_PASSPHRASE — для --update-keys
  DASH_CLI_CMD — на сервере 109: sudo -u dash01 /opt/dash/bin/dash-cli

Примеры:
  ./platform_credits_withdraw.sh --update-keys
  ./platform_credits_withdraw.sh --keys-file ./privkey_protx.txt
  ./platform_credits_withdraw.sh --network testnet --dry-run
  ./platform_credits_withdraw.sh --update-keys --epoch-gate --reschedule-cron
  ./platform_credits_withdraw.sh --schedule-only --reschedule-cron
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-u|--update-keys) UPDATE_KEYS=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--keys-file) KEYS_FILE="$2"; shift 2 ;;
		--network) NETWORK="$2"; shift 2 ;;
		--type) TYPE="$2"; shift 2 ;;
		--recipient) RECIPIENT="$2"; shift 2 ;;
		--amount) AMOUNT="$2"; shift 2 ;;
		--fee) FEE="$2"; shift 2 ;;
		--epoch-gate) EPOCH_GATE=1; shift ;;
		--force) FORCE_RUN=1; shift ;;
		--reschedule-cron) RESCHEDULE_CRON=1; shift ;;
		--schedule-only) SCHEDULE_ONLY=1; shift ;;
		*) echo "[ERROR] unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

case "$NETWORK" in
	mainnet|testnet) ;;
	*) echo "[ERROR] --network must be mainnet or testnet" >&2; exit 1 ;;
esac

case "$TYPE" in
	withdrawal|transfer) ;;
	*) echo "[ERROR] --type must be withdrawal or transfer" >&2; exit 1 ;;
esac

if [[ "$TYPE" == "transfer" && -z "$RECIPIENT" ]]; then
	echo "[ERROR] --recipient required for transfer" >&2
	exit 1
fi

RPC_URL="${RPC_URL:-http://127.0.0.1:9998}"
RPC_USER="${RPC_USER:-dashrpc}"
RPC_PASS="${RPC_PASS:-password}"
WALLET="${WALLET:-operator}"
DASH_CLI_CMD="${DASH_CLI_CMD:-${BALANCE_DASH_CLI_CMD:-}}"

fetch_platform_status() {
	local data
	data=$(curl -sf --max-time 20 "$PLATFORM_EXPLORER_URL/status") || return 1
	[[ -n "${data//[$'\t\r\n ']}" ]] || return 1
	echo "$data"
}

# cur_epoch cur_start_ms next_epoch_start_ms (endTime текущей эпохи)
get_epoch_timing() {
	local status_json="$1"
	local cur_epoch cur_start next_start
	cur_epoch=$(echo "$status_json" | jq -r '.epoch.number // empty')
	cur_start=$(echo "$status_json" | jq -r '.epoch.startTime // empty')
	next_start=$(echo "$status_json" | jq -r '.epoch.endTime // .nextEpoch.startTime // empty')
	if [[ -z "$cur_epoch" || "$cur_epoch" == "null" ]]; then
		return 1
	fi
	if [[ -z "$next_start" || "$next_start" == "null" ]]; then
		local epoch_json
		epoch_json=$(curl -sf --max-time 20 "$PLATFORM_EXPLORER_URL/epoch/$cur_epoch") || return 1
		next_start=$(echo "$epoch_json" | jq -r '.epoch.endTime // .nextEpoch.startTime // empty')
	fi
	if [[ -z "$cur_start" || "$cur_start" == "null" ]]; then
		return 1
	fi
	if [[ -z "$next_start" || "$next_start" == "null" ]]; then
		return 1
	fi
	printf '%s %s %s\n' "$cur_epoch" "$cur_start" "$next_start"
}

format_epoch_ms() {
	local ms="$1"
	python3 - "$ms" "$CRON_TZ" <<'PY'
import datetime
import sys

ms, tz_name = int(sys.argv[1]), sys.argv[2]
utc = datetime.timezone.utc
dt = datetime.datetime.fromtimestamp(ms / 1000, tz=utc)
print(f"UTC:  {dt.strftime('%Y-%m-%d %H:%M:%S')}")
try:
    from zoneinfo import ZoneInfo
    local = dt.astimezone(ZoneInfo(tz_name))
except Exception:
    local = dt.astimezone(datetime.timezone(datetime.timedelta(hours=8)))
print(f"{tz_name}: {local.strftime('%Y-%m-%d %H:%M:%S %Z')}")
PY
}

read_last_withdraw_epoch() {
	if [[ -f "$LAST_EPOCH_FILE" ]]; then
		cat "$LAST_EPOCH_FILE"
	else
		echo "0"
	fi
}

write_last_withdraw_epoch() {
	local epoch="$1"
	printf '%s\n' "$epoch" >"$LAST_EPOCH_FILE"
}

now_ms() {
	python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

epoch_run_at_ms() {
	local start_ms="$1"
	echo $((start_ms + EPOCH_WITHDRAW_OFFSET_SEC * 1000))
}

list_protx_hashes() {
	grep -v '^[[:space:]]*#' "$KEYS_FILE" | grep -v '^[[:space:]]*$' | awk -F: '{print $NF}'
}

pick_random_protx() {
	local -a protx_arr=()
	mapfile -t protx_arr < <(list_protx_hashes)
	((${#protx_arr[@]})) || return 1
	echo "${protx_arr[$RANDOM % ${#protx_arr[@]}]}"
}

get_validator_balance_credits() {
	local protx="$1" bal
	bal=$(curl -sf --max-time 20 "$PLATFORM_EXPLORER_URL/validator/$protx" \
		| jq -r '.identityBalance // 0' 2>/dev/null) || bal=0
	[[ "$bal" =~ ^[0-9]+$ ]] || bal=0
	echo "$bal"
}

# stdout: max_balance count_above_min checked
fleet_balance_stats() {
	local protx max=0 count=0 checked=0 bal
	while IFS= read -r protx; do
		[[ -n "$protx" ]] || continue
		bal=$(get_validator_balance_credits "$protx")
		((checked++)) || true
		if (( bal > max )); then max=$bal; fi
		if (( bal > MIN_WITHDRAWAL_FEE )); then ((count++)) || true; fi
	done < <(list_protx_hashes)
	echo "$max $count $checked"
}

wait_until_run_time() {
	local start_ms="$1" target_ms now
	target_ms=$(epoch_run_at_ms "$start_ms")
	echo "[INFO] Waiting until epoch start + ${EPOCH_WITHDRAW_OFFSET_SEC}s..." >&2
	format_epoch_ms "$target_ms" >&2
	while true; do
		now=$(now_ms)
		(( now >= target_ms )) && break
		sleep 1
	done
	echo "[INFO] Run time reached." >&2
}

wait_for_withdrawable_balance() {
	local epoch_end_ms="$1"
	local protx bal now poll=0 pool_size
	pool_size=$(list_protx_hashes | wc -l | tr -d ' ')
	echo "[INFO] Polling 1 random node every ${EPOCH_BALANCE_POLL_SEC}s (pool=${pool_size}, trigger if balance > ${MIN_WITHDRAWAL_FEE})..." >&2
	echo "[INFO] Poll deadline (epoch end):" >&2
	format_epoch_ms "$epoch_end_ms" >&2
	while true; do
		((poll++)) || true
		protx=$(pick_random_protx) || {
			echo "[ERROR] No proTxHash in $KEYS_FILE" >&2
			return 1
		}
		bal=$(get_validator_balance_credits "$protx")
		now=$(now_ms)
		echo "[INFO] Poll #$poll: sample ${protx:0:16}... balance=${bal} credits" >&2
		if (( bal > MIN_WITHDRAWAL_FEE )); then
			echo "[INFO] Sampled node above minimum — starting withdrawal for all ${pool_size} nodes." >&2
			return 0
		fi
		if (( now >= epoch_end_ms )); then
			echo "[WARN] Epoch ended without sampled balance above minimum (last=${bal})." >&2
			return 1
		fi
		sleep "$EPOCH_BALANCE_POLL_SEC"
	done
}

# Запуск разрешён: новая эпоха (ещё не обработана).
epoch_gate_allows_run() {
	local cur_epoch="$1" cur_start_ms="$2"
	local last_epoch now_ms run_after_ms
	last_epoch=$(read_last_withdraw_epoch)
	now_ms=$(now_ms)
	run_after_ms=$(epoch_run_at_ms "$cur_start_ms")

	echo "[INFO] Epoch gate: current=$cur_epoch, last completed epoch=$last_epoch" >&2
	echo "[INFO] Current epoch started:" >&2
	format_epoch_ms "$cur_start_ms" >&2
	echo "[INFO] Earliest run (epoch + ${EPOCH_WITHDRAW_OFFSET_SEC}s):" >&2
	format_epoch_ms "$run_after_ms" >&2

	if [[ "$cur_epoch" -le "$last_epoch" ]]; then
		echo "[SKIP] Epoch $cur_epoch already completed (last=$last_epoch)." >&2
		return 1
	fi
	if (( now_ms < run_after_ms )); then
		echo "[SKIP] Too early — waiting in-process until run time." >&2
	fi
	return 0
}

# cron: M H D M * в CRON_TZ для run_at_ms
ms_to_cron_fields() {
	local run_at_ms="$1"
	python3 - "$run_at_ms" "$CRON_TZ" <<'PY'
import datetime
import sys

ms, tz_name = int(sys.argv[1]), sys.argv[2]
utc = datetime.timezone.utc
dt_utc = datetime.datetime.fromtimestamp(ms / 1000, tz=utc)
try:
    from zoneinfo import ZoneInfo
    dt = dt_utc.astimezone(ZoneInfo(tz_name))
except Exception:
    dt = dt_utc.astimezone(datetime.timezone(datetime.timedelta(hours=8)))
print(f"{dt.minute} {dt.hour} {dt.day} {dt.month} *")
PY
}

reschedule_withdraw_cron() {
	local next_epoch_start_ms="$1"
	local run_at_ms cron_fields cron_line tmp
	run_at_ms=$(epoch_run_at_ms "$next_epoch_start_ms")
	cron_fields=$(ms_to_cron_fields "$run_at_ms")
	cron_line="$cron_fields $BIN/platform_credits_withdraw.sh --update-keys --epoch-gate --reschedule-cron >> $CRON_LOG 2>&1"

	echo "[INFO] Next epoch starts:" >&2
	format_epoch_ms "$next_epoch_start_ms" >&2
	echo "[INFO] Scheduled cron run (+${EPOCH_WITHDRAW_OFFSET_SEC}s):" >&2
	format_epoch_ms "$run_at_ms" >&2
	echo "[INFO] Crontab ($CRON_TZ): $cron_fields $BIN/platform_credits_withdraw.sh ..." >&2

	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "[DRY-RUN] Would set cron: $cron_line" >&2
		return 0
	fi

	mkdir -p "$(dirname "$CRON_LOG")"
	tmp=$(mktemp)
	{
		crontab -l 2>/dev/null | grep -v "platform_credits_withdraw.sh" | grep -v "^${CRON_MARKER}$" || true
		if ! crontab -l 2>/dev/null | grep -q '^TZ='; then
			echo "TZ=$CRON_TZ"
		fi
		echo "$CRON_MARKER"
		echo "$cron_line"
	} >"$tmp"
	crontab "$tmp"
	rm -f "$tmp"
	echo "[INFO] Crontab updated." >&2
}

handle_epoch_scheduling() {
	local status_json timing cur_epoch cur_start_ms next_start_ms
	status_json=$(fetch_platform_status) || {
		echo "[ERROR] Cannot fetch $PLATFORM_EXPLORER_URL/status" >&2
		return 1
	}
	timing=$(get_epoch_timing "$status_json") || {
		echo "[ERROR] Cannot parse epoch timing from platform-explorer API" >&2
		return 1
	}
	read -r cur_epoch cur_start_ms next_start_ms <<<"$timing"

	EPOCH_CURRENT="$cur_epoch"
	EPOCH_NEXT_START_MS="$next_start_ms"

	if [[ "$SCHEDULE_ONLY" -eq 1 ]]; then
		[[ "$RESCHEDULE_CRON" -eq 1 ]] && reschedule_withdraw_cron "$next_start_ms" || true
		exit 0
	fi

	if [[ "$EPOCH_GATE" -eq 1 && "$FORCE_RUN" -eq 0 ]]; then
		epoch_gate_allows_run "$cur_epoch" "$cur_start_ms" || exit 0
		wait_until_run_time "$cur_start_ms"
	fi
}

run_withdrawal_round() {
	local round="${1:-1}" rc=0
	local log_file payout_file summary_out summary_display payouts_line fail_count

	echo "[INFO] === Withdrawal round $round ===" >&2
	echo "[INFO] Starting withdrawal (timeout ${TIMEOUT_SEC}s)..." >&2
	echo "[WARN] Credits will be sent to registered payout address for each proTxHash." >&2

	payout_file=$(mktemp "${TMPDIR:-/tmp}/platform_credits_payout.XXXXXX.json")
	log_file=$(mktemp "${TMPDIR:-/tmp}/platform_credits_withdraw.XXXXXX.log")

	if payout_map=$(fetch_protx_payout_map 2>/dev/null); then
		printf '%s' "$payout_map" >"$payout_file"
		echo "[INFO] Loaded payout addresses for $(echo "$payout_map" | jq 'length') owned Evo proTx" >&2
	else
		printf '%s' '{}' >"$payout_file"
		echo "[WARN] Could not load protx payout map (payout in summary may be empty)" >&2
	fi

	set +e
	(
		cd "$MASS_SEND_DIR"
		if command -v timeout &>/dev/null; then
			timeout "$TIMEOUT_SEC" "$NODE_BIN" index.js "${node_args[@]}"
		elif command -v gtimeout &>/dev/null; then
			gtimeout "$TIMEOUT_SEC" "$NODE_BIN" index.js "${node_args[@]}"
		else
			"$NODE_BIN" index.js "${node_args[@]}"
		fi
	) 2>&1 | tee "$log_file"
	rc=${PIPESTATUS[0]}
	set -e

	echo "" >&2
	if ! summary_out=$(DEFAULT_WITHDRAWAL_FEE="${DEFAULT_WITHDRAWAL_FEE:-400000000}" \
		MIN_WITHDRAWAL_FEE="${MIN_WITHDRAWAL_FEE:-400000000}" \
		summarize_withdraw_log "$log_file" "$KEYS_FILE" "$payout_file" 2>&1); then
		echo "[WARN] summarize_withdraw_log failed; raw log tail:" >&2
		tail -20 "$log_file" >&2
		summary_out="=== WITHDRAWAL SUMMARY ===
Keys in file:     ${key_lines}
Success:          ?
Failed:           ?
(parse error — see log above)"
	fi
	payouts_line=$(echo "$summary_out" | grep '^__PAYOUTS_JSON__' || true)
	summary_display=$(echo "$summary_out" | grep -v '^__PAYOUTS_JSON__' || true)
	echo "$summary_display"

	if [[ -n "$payouts_line" ]]; then
		payouts_json="${payouts_line#__PAYOUTS_JSON__}"
		print_payout_l1_balances "$payouts_json"
	fi

	rm -f "$log_file" "$payout_file"

	if [[ "$rc" -eq 124 ]]; then
		echo "[ERROR] round $round timed out after ${TIMEOUT_SEC}s" >&2
	fi
	return 0
}

run_epoch_withdrawal_loop() {
	local epoch_end_ms="$1" round=1 max count checked

	if [[ "$FORCE_RUN" -eq 0 ]]; then
		wait_for_withdrawable_balance "$epoch_end_ms" || true
	fi

	while (( round <= EPOCH_WITHDRAW_MAX_ROUNDS )); do
		echo "[INFO] Full fleet balance check (all nodes)..." >&2
		read -r max count checked <<<"$(fleet_balance_stats)"
		echo "[INFO] Pre-round: checked=$checked, above_min=$count, max_balance=${max}" >&2
		if (( count == 0 )); then
			echo "[INFO] All validators below minimum — epoch withdrawal complete." >&2
			break
		fi
		run_withdrawal_round "$round" || true
		((round++)) || true
		if (( round > EPOCH_WITHDRAW_MAX_ROUNDS )); then
			echo "[WARN] Reached EPOCH_WITHDRAW_MAX_ROUNDS=$EPOCH_WITHDRAW_MAX_ROUNDS" >&2
			break
		fi
		echo "[INFO] Post-round full fleet check..." >&2
		read -r max count checked <<<"$(fleet_balance_stats)"
		if (( count == 0 )); then
			echo "[INFO] All balances now below minimum (max=${max})." >&2
			break
		fi
		echo "[INFO] ${count}/${checked} still above min — next round in ${EPOCH_WITHDRAW_RETRY_SEC}s..." >&2
		sleep "$EPOCH_WITHDRAW_RETRY_SEC"
	done
}

finalize_epoch_run() {
	if [[ -n "${EPOCH_CURRENT:-}" ]]; then
		write_last_withdraw_epoch "$EPOCH_CURRENT"
		echo "[INFO] Epoch $EPOCH_CURRENT marked complete in $LAST_EPOCH_FILE" >&2
	fi
	if [[ "$RESCHEDULE_CRON" -eq 1 && -n "${EPOCH_NEXT_START_MS:-}" ]]; then
		reschedule_withdraw_cron "$EPOCH_NEXT_START_MS" || true
	fi
}

fetch_protx_payout_map() {
	local tmp payout_json
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' RETURN
	if [[ -n "$DASH_CLI_CMD" ]]; then
		$DASH_CLI_CMD -rpcwallet="$WALLET" protx list registered true >"$tmp" 2>/dev/null || return 1
	else
		curl -s --user "$RPC_USER:$RPC_PASS" \
			--data-binary '{"jsonrpc":"1.0","id":"curl","method":"protx","params":["list","registered",true]}' \
			-H 'content-type:text/plain;' "$RPC_URL/wallet/$WALLET" 2>/dev/null \
			| jq -c '.result // empty' >"$tmp" || return 1
	fi
	jq -e 'type == "array"' "$tmp" >/dev/null 2>&1 || return 1
	payout_json=$(jq -c '
		[.[]
			| select(.type == "Evo" and .wallet.hasOwnerKey == true)
			| {key: (.proTxHash | ascii_downcase), value: .state.payoutAddress}
		]
		| from_entries
	' "$tmp" 2>/dev/null) || return 1
	[[ -n "$payout_json" && "$payout_json" != "null" && "$payout_json" != "{}" ]] || return 1
	echo "$payout_json"
}

get_l1_balance() {
	local addr="$1" resp sat url base params body
	if [[ -n "$DASH_CLI_CMD" ]]; then
		params=$(jq -n -c --arg a "$addr" '{addresses: [$a]}')
		resp=$($DASH_CLI_CMD -rpcwallet="$WALLET" getaddressbalance "$params" 2>/dev/null) || return 1
		sat=$(echo "$resp" | jq -r '.balance // empty' 2>/dev/null)
		[[ -n "$sat" && "$sat" != "null" ]] || return 1
		awk -v s="$sat" 'BEGIN { printf "%.8f", s / 100000000 }'
		return 0
	fi
	base="${RPC_URL%%/wallet/*}"
	params=$(jq -n -c --arg a "$addr" '{addresses: [$a]}')
	body=$(jq -n -c --arg m "getaddressbalance" --argjson p "$params" '{jsonrpc:"1.0",id:"curl",method:$m,params:[$p]}')
	for url in \
		"$RPC_URL/wallet/${WALLET_FEE:-fees}" \
		"$RPC_URL/wallet/$WALLET" \
		"$base" \
		"$RPC_URL"; do
		[[ -n "$url" ]] || continue
		resp=$(curl -s --user "$RPC_USER:$RPC_PASS" \
			--data-binary "$body" \
			-H 'content-type:text/plain;' "$url" 2>/dev/null) || continue
		sat=$(echo "$resp" | jq -r '.result.balance // empty' 2>/dev/null)
		[[ -n "$sat" && "$sat" != "null" ]] || continue
		awk -v s="$sat" 'BEGIN { printf "%.8f", s / 100000000 }'
		return 0
	done
	return 1
}

MIN_WITHDRAWAL_FEE="${MIN_WITHDRAWAL_FEE:-400000000}"

summarize_withdraw_log() {
	local log_file="$1" keys_file="$2" payout_file="$3"
	python3 - "$log_file" "$keys_file" "$payout_file" <<'PY'
import re, sys, json, os
from collections import defaultdict

log_path, keys_path, payout_path = sys.argv[1], sys.argv[2], sys.argv[3]
default_fee = int(os.environ.get('DEFAULT_WITHDRAWAL_FEE', '400000000'))
min_fee = int(os.environ.get('MIN_WITHDRAWAL_FEE', '400000000'))
payout_map = {}
try:
    with open(payout_path) as f:
        raw = f.read().strip()
    if raw:
        payout_map = {k.lower(): v for k, v in json.loads(raw).items()}
except (json.JSONDecodeError, OSError, TypeError, ValueError):
    payout_map = {}

keys = []
with open(keys_path) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ':' not in line:
            continue
        pk, protx = line.split(':', 1)
        keys.append({'privkey': pk, 'protx': protx.lower(), 'prefix': pk[:8]})

lines = open(log_path).read().splitlines()
key_idx = 0
successes = []
errors = []
cur_balance = None
cur_amount = None

def take_key():
    global key_idx
    if key_idx >= len(keys):
        return None
    k = keys[key_idx]
    key_idx += 1
    return k

for line in lines:
    m_id = re.search(r'Identity ([^,]+), balance: (\d+) credits', line)
    if m_id:
        cur_balance = m_id.group(2)
        continue

    m_amt = re.search(r'Processing a withdrawal request of (\d+) credits', line)
    if m_amt:
        cur_amount = m_amt.group(1)
        continue

    if 'Transaction successfully broadcasted' in line:
        k = take_key()
        if k:
            successes.append({
                'protx': k['protx'],
                'privkey_prefix': k['prefix'],
                'amount_credits': cur_amount or '0',
                'payout': payout_map.get(k['protx'], ''),
                'balance_before': cur_balance,
            })
        cur_balance = None
        cur_amount = None
        continue

    m_err = re.search(r'Error during processing private key \(([^)]+)\): (.+)', line)
    if m_err:
        k = take_key()
        prefix = m_err.group(1).rstrip('.')
        err_text = m_err.group(2).strip()
        if 'broadcastStateTransition' in err_text and 'INVALID_ARGUMENT' in err_text:
            err_text = (
                'Platform rejected withdrawal (broadcastStateTransition INVALID_ARGUMENT). '
                f'Fee below network minimum ({min_fee} credits) or invalid tx.'
            )
        if k:
            errors.append({
                'protx': k['protx'],
                'privkey_prefix': prefix,
                'error': err_text,
                'balance_before': cur_balance,
                'payout': payout_map.get(k['protx'], ''),
            })
        cur_balance = None
        cur_amount = None
        continue

    if 'Error during importing private key, skipping' in line:
        k = take_key()
        if k:
            errors.append({
                'protx': k['protx'],
                'privkey_prefix': k['prefix'],
                'error': 'invalid private key (import failed)',
                'balance_before': None,
                'payout': payout_map.get(k['protx'], ''),
            })
        cur_balance = None
        cur_amount = None
        continue

    m_line = re.search(r'Error processing line: (.+)', line)
    if m_line:
        k = take_key()
        if k:
            errors.append({
                'protx': k['protx'],
                'privkey_prefix': k['prefix'],
                'error': m_line.group(1).strip(),
                'balance_before': cur_balance,
                'payout': payout_map.get(k['protx'], ''),
            })
        cur_balance = None
        cur_amount = None

by_payout = defaultdict(lambda: {'credits': 0, 'nodes': 0})
total_credits = 0
for s in successes:
    amt = int(s['amount_credits'])
    total_credits += amt
    payout = s['payout'] or '(unknown payout)'
    by_payout[payout]['credits'] += amt
    by_payout[payout]['nodes'] += 1

print('=== WITHDRAWAL SUMMARY ===')
print(f'Keys in file:     {len(keys)}')
print(f'Success:          {len(successes)}')
print(f'Failed:           {len(errors)}')
print(f'Unprocessed:      {max(0, len(keys) - len(successes) - len(errors))}')
print()

if errors:
    print('--- Errors ---')
    for e in errors:
        bal = f", balance: {e['balance_before']} credits" if e.get('balance_before') else ''
        payout = f", payout: {e['payout']}" if e.get('payout') else ''
        print(f"  {e['privkey_prefix']}...  proTx {e['protx'][:16]}...{bal}{payout}")
        print(f"    {e['error']}")
    print()

if successes:
    print('--- Withdrawn by payout address (this run, credits) ---')
    for payout in sorted(by_payout.keys()):
        info = by_payout[payout]
        print(f"  {payout}")
        print(f"    withdrawn: {info['credits']} credits  ({info['nodes']} node(s))")
    print()
    print(f'Total withdrawn:  {total_credits} credits')
    print()
else:
    print('Total withdrawn:  0 credits')
    print()

fee_shortfall = [
    e for e in errors
    if 'Amount + fee must be above zero' in e.get('error', '')
    or 'Not enough balance' in e.get('error', '')
]
if fee_shortfall:
    print('--- Note (balance < withdrawal fee) ---')
    print(f'Network minimum withdrawal fee: {min_fee} credits (fixed by Platform protocol).')
    print(f'Script/mass-send default fee: {default_fee} credits.')
    for e in fee_shortfall:
        if e.get('balance_before'):
            bal = int(e['balance_before'])
            print(f"  {e['privkey_prefix']}...  balance {bal} — need > {min_fee}  (short {min_fee - bal} credits)")
    print('  Lower --fee does NOT work: DAPI rejects fee < 400000000.')
    print('  Wait until epoch credits accumulate above 400M per identity.')
    print()

broadcast_rejected = [e for e in errors if 'broadcastStateTransition' in e.get('error', '') or 'Platform rejected withdrawal' in e.get('error', '')]
if broadcast_rejected:
    print('--- Note (broadcast rejected) ---')
    print(f'You used --fee below {min_fee}. Tx was built locally but Platform DAPI rejected it.')
    print(f'Required: identity balance > {min_fee} credits, and fee must be >= {min_fee}.')
    print()

all_payouts = set()
for k in keys:
    p = payout_map.get(k['protx'], '')
    if p:
        all_payouts.add(p)
for payout in by_payout:
    if payout and payout != '(unknown payout)':
        all_payouts.add(payout)

if all_payouts and not successes:
    print('--- Platform credits on failed nodes (by payout) ---')
    by_payout_bal = defaultdict(int)
    for e in errors:
        if e.get('payout') and e.get('balance_before'):
            by_payout_bal[e['payout']] += int(e['balance_before'])
    for payout in sorted(by_payout_bal.keys()):
        print(f"  {payout}")
        print(f"    platform credits (not withdrawn): {by_payout_bal[payout]}")
    print()

print('__PAYOUTS_JSON__' + json.dumps(sorted(all_payouts)))
PY
}

print_payout_l1_balances() {
	local payouts_json="$1"
	[[ -n "$payouts_json" ]] || return 0
	local count
	count=$(echo "$payouts_json" | jq 'length' 2>/dev/null || echo 0)
	[[ "$count" -gt 0 ]] || return 0
	echo "--- L1 balance on payout addresses (DASH) ---"
	while IFS= read -r payout; do
		[[ -n "$payout" && "$payout" != "(unknown payout)" ]] || continue
		bal=$(get_l1_balance "$payout" 2>/dev/null) || bal=""
		if [[ -n "$bal" ]]; then
			printf "  %s  %s DASH\n" "$payout" "$bal"
		else
			printf "  %s  (balance unavailable — Dash Core RPC / addressindex=1)\n" "$payout"
		fi
	done < <(echo "$payouts_json" | jq -r '.[]')
	echo
}

find_node() {
	if [[ -n "$NODE_PATH" && -x "$NODE_PATH" ]]; then
		echo "$NODE_PATH"
		return 0
	fi
	local candidate
	for candidate in \
		"$HOME/bin/node-v24.8.0-linux-x64/bin/node" \
		"$HOME/bin/node-v24.8.0-darwin-arm64/bin/node" \
		"$HOME/bin/node-v24.8.0-darwin-x64/bin/node" \
		"$(command -v node 2>/dev/null || true)"; do
		[[ -n "$candidate" && -x "$candidate" ]] || continue
		echo "$candidate"
		return 0
	done
	return 1
}

if [[ "$EPOCH_GATE" -eq 1 || "$RESCHEDULE_CRON" -eq 1 || "$SCHEDULE_ONLY" -eq 1 ]]; then
	handle_epoch_scheduling
fi

if [[ "$UPDATE_KEYS" -eq 1 ]]; then
	export_script="$BIN/export-private-keys-protx.sh"
	[[ -x "$export_script" ]] || { echo "[ERROR] not found: $export_script" >&2; exit 1; }
	echo "[INFO] Updating privkey_protx.txt from wallet operator (Owned+Evo)..." >&2
	OUT_FILE="$KEYS_FILE" "$export_script"
fi

if [[ ! -r "$KEYS_FILE" ]]; then
	echo "[ERROR] keys file not found: $KEYS_FILE" >&2
	echo "Run: $BIN/export-private-keys-protx.sh" >&2
	echo "Or:  $BIN/platform_credits_withdraw.sh --update-keys" >&2
	exit 1
fi

key_lines=$(grep -v '^[[:space:]]*#' "$KEYS_FILE" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
if [[ "$key_lines" -eq 0 ]]; then
	echo "[ERROR] no keys in $KEYS_FILE" >&2
	exit 1
fi

if [[ ! -d "$MASS_SEND_DIR" ]]; then
	echo "[ERROR] dash-platform-mass-send not found: $MASS_SEND_DIR" >&2
	echo "Install: git clone https://github.com/pshenmic/dash-platform-mass-send $MASS_SEND_DIR && cd $MASS_SEND_DIR && npm install" >&2
	exit 1
fi

if [[ ! -f "$MASS_SEND_DIR/index.js" ]]; then
	echo "[ERROR] index.js missing in $MASS_SEND_DIR" >&2
	exit 1
fi

if [[ ! -d "$MASS_SEND_DIR/node_modules" ]]; then
	echo "[ERROR] node_modules missing — run: cd $MASS_SEND_DIR && npm install" >&2
	exit 1
fi

NODE_BIN="$(find_node)" || {
	echo "[ERROR] node not found. Set NODE_PATH in .env" >&2
	exit 1
}

node_ver="$("$NODE_BIN" -v 2>/dev/null || true)"
echo "[INFO] Node: $NODE_BIN ($node_ver)" >&2
echo "[INFO] Mass send: $MASS_SEND_DIR" >&2
echo "[INFO] Keys: $KEYS_FILE ($key_lines lines)" >&2
echo "[INFO] Network: $NETWORK, type: $TYPE" >&2

extra_args=()
[[ -n "$RECIPIENT" ]] && extra_args+=(--recipient "$RECIPIENT")
[[ -n "$AMOUNT" ]] && extra_args+=(--amount "$AMOUNT")
[[ -n "$FEE" ]] && extra_args+=(--fee "$FEE")

if [[ -n "$FEE" && "$FEE" -lt "$MIN_WITHDRAWAL_FEE" ]]; then
	echo "[WARN] --fee $FEE < protocol minimum $MIN_WITHDRAWAL_FEE — broadcast will be rejected by Platform" >&2
fi

node_args=(
	--private-keys-path "$KEYS_FILE"
	--network "$NETWORK"
	--type "$TYPE"
)
if ((${#extra_args[@]})); then
	node_args+=("${extra_args[@]}")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "[DRY-RUN] cd $MASS_SEND_DIR && $NODE_BIN index.js \\"
	echo "  --private-keys-path $KEYS_FILE \\"
	echo "  --network $NETWORK \\"
	echo "  --type $TYPE ${extra_args[*]:-}"
	if [[ -n "${EPOCH_CURRENT:-}" ]]; then
		echo "[DRY-RUN] Would record last withdrawal epoch: $EPOCH_CURRENT"
	fi
	exit 0
fi

if [[ "$EPOCH_GATE" -eq 1 ]]; then
	run_epoch_withdrawal_loop "$EPOCH_NEXT_START_MS"
	finalize_epoch_run
	exit 0
fi

echo "[INFO] Starting withdrawal (timeout ${TIMEOUT_SEC}s)..." >&2
echo "[WARN] Credits will be sent to registered payout address for each proTxHash." >&2
echo "[WARN] Press Ctrl+C within 5s to abort." >&2
sleep 5

PAYOUT_MAP='{}'
PAYOUT_FILE=$(mktemp "${TMPDIR:-/tmp}/platform_credits_payout.XXXXXX.json")
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/platform_credits_withdraw.XXXXXX.log")
trap 'rm -f "$LOG_FILE" "$PAYOUT_FILE"' EXIT

if payout_map=$(fetch_protx_payout_map 2>/dev/null); then
	PAYOUT_MAP="$payout_map"
	printf '%s' "$PAYOUT_MAP" > "$PAYOUT_FILE"
	echo "[INFO] Loaded payout addresses for $(echo "$PAYOUT_MAP" | jq 'length') owned Evo proTx" >&2
else
	printf '%s' '{}' > "$PAYOUT_FILE"
	echo "[WARN] Could not load protx payout map (payout in summary may be empty)" >&2
fi

set +e
(
	cd "$MASS_SEND_DIR"
	if command -v timeout &>/dev/null; then
		timeout "$TIMEOUT_SEC" "$NODE_BIN" index.js "${node_args[@]}"
	elif command -v gtimeout &>/dev/null; then
		gtimeout "$TIMEOUT_SEC" "$NODE_BIN" index.js "${node_args[@]}"
	else
		"$NODE_BIN" index.js "${node_args[@]}"
	fi
) 2>&1 | tee "$LOG_FILE"
rc=${PIPESTATUS[0]}
set -e

echo "" >&2
if ! summary_out=$(DEFAULT_WITHDRAWAL_FEE="${DEFAULT_WITHDRAWAL_FEE:-400000000}" \
	MIN_WITHDRAWAL_FEE="${MIN_WITHDRAWAL_FEE:-400000000}" \
	summarize_withdraw_log "$LOG_FILE" "$KEYS_FILE" "$PAYOUT_FILE" 2>&1); then
	echo "[WARN] summarize_withdraw_log failed; raw log tail:" >&2
	tail -20 "$LOG_FILE" >&2
	summary_out="=== WITHDRAWAL SUMMARY ===
Keys in file:     ${key_lines}
Success:          ?
Failed:           ?
(parse error — see log above)"
fi
payouts_line=$(echo "$summary_out" | grep '^__PAYOUTS_JSON__' || true)
summary_display=$(echo "$summary_out" | grep -v '^__PAYOUTS_JSON__' || true)
echo "$summary_display"

if [[ -n "$payouts_line" ]]; then
	payouts_json="${payouts_line#__PAYOUTS_JSON__}"
	print_payout_l1_balances "$payouts_json"
fi

if [[ "$rc" -eq 124 ]]; then
	echo "[ERROR] timed out after ${TIMEOUT_SEC}s" >&2
	exit 124
fi

# exit 1 if any failures in log or node returned non-zero (manual mode only)
fail_count=$(echo "$summary_display" | awk -F': *' '/^Failed:/ {gsub(/ /,"",$2); print $2; exit}')
[[ -n "$fail_count" && "$fail_count" -gt 0 ]] && exit 1
exit "$rc"
