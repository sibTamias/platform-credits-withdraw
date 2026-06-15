#!/usr/bin/env bash
#
# export-private-keys-protx.sh — локальный скрипт для MacBook с Dash Core.
#
# Берёт protx list из кошелька operator, отбирает свои Evo (GUI: Owned + Evo):
#   type == "Evo" и wallet.hasOwnerKey == true
# Для каждого ownerAddress — dumpprivkey → privkey_protx.txt:
#   private_key_1:proTxHash_1
#   private_key_2:proTxHash_2
#
# Файл all-ips.txt НЕ используется.
#
# Требования:
#   - Dash Core на localhost, кошелёк operator загружен
#   - Кошелёк разблокирован или WALLET_PASSPHRASE в .env
#   - jq, curl
#
# Переменные:
#   RPC_URL, RPC_USER, RPC_PASS, WALLET (operator), WALLET_FEE (fees)
#   OUT_FILE — privkey_protx.txt

set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -r "$BIN/.env" ]] && source "$BIN/.env"

RPC_URL="${RPC_URL:-http://127.0.0.1:9998}"
RPC_USER="${RPC_USER:-dashrpc}"
RPC_PASS="${RPC_PASS:-password}"
WALLET="${WALLET:-operator}"
WALLET_FEE="${WALLET_FEE:-fee}"
OUT_FILE="${OUT_FILE:-$BIN/privkey_protx.txt}"
WALLET_UNLOCK_SECONDS="${WALLET_UNLOCK_SECONDS:-120}"
DASH_CLI_CMD="${DASH_CLI_CMD:-${BALANCE_DASH_CLI_CMD:-}}"

# rpc [wallet] method params_json  — wallet опционален (по умолч. WALLET)
rpc() {
  local wallet method params_json
  if [[ $# -eq 3 ]]; then
    wallet="$1"
    method="$2"
    params_json="$3"
  else
    wallet="$WALLET"
    method="$1"
    params_json="$2"
  fi
  if [[ -n "$DASH_CLI_CMD" ]]; then
    dash_cli_rpc "$wallet" "$method" "$params_json"
    return
  fi
  local body
  if [[ -n "$params_json" ]]; then
    body="{\"jsonrpc\":\"1.0\",\"id\":\"curl\",\"method\":\"$method\",\"params\":$params_json}"
  else
    body="{\"jsonrpc\":\"1.0\",\"id\":\"curl\",\"method\":\"$method\",\"params\":[]}"
  fi
  curl -s --user "$RPC_USER:$RPC_PASS" \
    --data-binary "$body" \
    -H 'content-type:text/plain;' "$RPC_URL/wallet/$wallet"
}

dash_cli_rpc() {
  local wallet="$1" method="$2" params_json="${3:-[]}"
  local raw err rc=0 tmp
  case "$method" in
    protx)
      tmp=$(mktemp)
      if ! $DASH_CLI_CMD -rpcwallet="$wallet" protx list registered true >"$tmp" 2>"${tmp}.err"; then
        err=$(cat "${tmp}.err" 2>/dev/null || true)
        [[ -z "$err" ]] && err=$(head -c 4000 "$tmp" 2>/dev/null || true)
        jq -n --arg m "$err" '{error: {message: $m}}'
        rm -f "$tmp" "${tmp}.err"
        return 1
      fi
      if ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
        err=$(head -c 4000 "$tmp" 2>/dev/null || true)
        jq -n --arg m "$err" '{error: {message: $m}}'
        rm -f "$tmp" "${tmp}.err"
        return 1
      fi
      jq -c '{result: .}' "$tmp"
      rm -f "$tmp" "${tmp}.err"
      ;;
    walletpassphrase)
      local pass secs
      pass=$(echo "$params_json" | jq -r '.[0]')
      secs=$(echo "$params_json" | jq -r '.[1]')
      err=$($DASH_CLI_CMD -rpcwallet="$wallet" walletpassphrase "$pass" "$secs" 2>&1) || rc=$?
      if [[ ${rc:-0} -ne 0 ]]; then
        [[ -z "$err" ]] && err="walletpassphrase failed (exit ${rc:-?}); wallet '$wallet' not loaded? Run: sudo ~/bin/install-operator-wallet.sh"
        jq -n --arg m "$err" '{error: {message: $m}}'
        return 1
      fi
      echo '{"result":null}'
      ;;
    dumpprivkey)
      local addr
      addr=$(echo "$params_json" | jq -r '.[0]')
      raw=$($DASH_CLI_CMD -rpcwallet="$wallet" dumpprivkey "$addr" 2>&1) || {
        jq -n --arg m "$raw" '{error: {message: $m}}'
        return 1
      }
      jq -n --arg r "$raw" '{result: $r}'
      ;;
    *)
      echo "{\"error\":{\"message\":\"dash_cli_rpc: unsupported method $method\"}}" >&2
      return 1
      ;;
  esac
}

unlock_wallet() {
  local w="$1"
  echo "Unlocking wallet $w for ${WALLET_UNLOCK_SECONDS}s..." >&2
  local unlock_resp err
  unlock_resp=$(rpc "$w" "walletpassphrase" "[\"$WALLET_PASSPHRASE\", $WALLET_UNLOCK_SECONDS]")
  if echo "$unlock_resp" | jq -e '.error != null' >/dev/null 2>&1; then
    err=$(echo "$unlock_resp" | jq -r '.error.message // "unknown"')
    echo "Wallet $w unlock failed: $err" >&2
    return 1
  fi
  return 0
}

if [[ -n "$DASH_CLI_CMD" ]]; then
  if ! $DASH_CLI_CMD help 2>/dev/null | grep -q walletpassphrase; then
    echo "ERROR: dashd работает в режиме masternode — wallet RPC отключён (нет walletpassphrase/dumpprivkey)." >&2
    echo "  Вариант A: экспорт на Mac → scp ~/bin/privkey_protx.txt на сервер → platform_credits_withdraw.sh" >&2
    echo "  Вариант B: временно wallet-режим на сервере: sudo ~/bin/dash01-wallet-mode-export.sh" >&2
    exit 1
  fi
fi

wallet_loaded() {
  local w="$1"
  if [[ -n "$DASH_CLI_CMD" ]]; then
    $DASH_CLI_CMD -rpcwallet="$w" getwalletinfo >/dev/null 2>&1
    return
  fi
  curl -s --user "$RPC_USER:$RPC_PASS" \
    --data-binary '{"jsonrpc":"1.0","id":"curl","method":"getwalletinfo","params":[]}' \
    -H 'content-type:text/plain;' "$RPC_URL/wallet/$w" | jq -e '.result' >/dev/null 2>&1
}

if [[ -n "${WALLET_PASSPHRASE:-}" ]]; then
  unlock_wallet "$WALLET" || exit 1
  if [[ "$WALLET_FEE" != "$WALLET" ]]; then
    if wallet_loaded "$WALLET_FEE"; then
      unlock_wallet "$WALLET_FEE" || true
    else
      echo "NOTE: wallet $WALLET_FEE not loaded — skip unlock (operator only)." >&2
    fi
  fi
else
  echo "WARNING: WALLET_PASSPHRASE not set in .env — ensure wallets are unlocked manually." >&2
fi

echo "Fetching protx list (wallet=$WALLET, Evo + hasOwnerKey)..." >&2
PROTX_TMP=$(mktemp)
trap 'rm -f "$PROTX_TMP"' EXIT

if [[ -n "$DASH_CLI_CMD" ]]; then
  if ! $DASH_CLI_CMD -rpcwallet="$WALLET" protx list registered true >"$PROTX_TMP"; then
    echo "protx list failed (dash-cli)" >&2
    head -c 2000 "$PROTX_TMP" >&2
    exit 1
  fi
else
  protx_resp=$(rpc "protx" '["list","registered",true]')
  if ! echo "$protx_resp" | jq -e '.result' >/dev/null 2>&1; then
    echo "protx list failed:" >&2
    echo "$protx_resp" | jq '.' >&2
    exit 1
  fi
  echo "$protx_resp" | jq -c '.result' >"$PROTX_TMP"
fi

if ! jq -e 'type == "array"' "$PROTX_TMP" >/dev/null 2>&1; then
  echo "protx list failed: unexpected response" >&2
  head -c 2000 "$PROTX_TMP" >&2
  exit 1
fi

evo_count=$(jq '[.[] | select(.type == "Evo" and .wallet.hasOwnerKey == true)] | length' "$PROTX_TMP")
if [[ "$evo_count" -eq 0 ]]; then
  echo "No owned Evo nodes in wallet $WALLET (hasOwnerKey + type Evo)." >&2
  exit 1
fi
echo "Found $evo_count owned Evo node(s)." >&2
echo "Writing to: $OUT_FILE" >&2

: > "$OUT_FILE"
PROTX_HASHES=()

count=0
while IFS=$'\t' read -r proTxHash ownerAddress; do
  [[ -n "$proTxHash" && -n "$ownerAddress" ]] || continue
  echo "Getting privkey for $ownerAddress (proTx: ${proTxHash:0:16}...)..." >&2
  pk_resp=$(rpc "dumpprivkey" "[\"$ownerAddress\"]")
  privkey=$(echo "$pk_resp" | jq -r '.result // empty')
  err=$(echo "$pk_resp" | jq -r '.error.message // empty')
  if [[ -z "$privkey" ]]; then
    if [[ "$err" == *"is not known"* && "$WALLET_FEE" != "$WALLET" ]] && wallet_loaded "$WALLET_FEE"; then
      echo "  Not in $WALLET, trying $WALLET_FEE..." >&2
      pk_resp=$(rpc "$WALLET_FEE" "dumpprivkey" "[\"$ownerAddress\"]")
      privkey=$(echo "$pk_resp" | jq -r '.result // empty')
      err=$(echo "$pk_resp" | jq -r '.error.message // empty')
    fi
  fi
  if [[ -z "$privkey" ]]; then
    echo "  ERROR: $err" >&2
    continue
  fi
  line="${privkey}:${proTxHash}"
  echo "$line"
  echo "$line" >> "$OUT_FILE"
  PROTX_HASHES+=("$proTxHash")
  ((count++)) || true
done < <(
  jq -r '
    .[]
    | select(.type == "Evo" and .wallet.hasOwnerKey == true)
    | [.proTxHash, .state.ownerAddress]
    | @tsv
  ' "$PROTX_TMP"
)

echo "" >&2
echo "Done: $count entries -> $OUT_FILE" | tee >&2
if [[ ${#PROTX_HASHES[@]} -gt 0 ]]; then
  echo "" >&2
  echo "--- proTxHash (for copy) ---" >&2
  for h in "${PROTX_HASHES[@]}"; do
    echo "$h" >&2
  done
  echo "---" >&2
fi