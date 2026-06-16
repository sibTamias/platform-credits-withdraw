#!/usr/bin/env bash
# Деплой platform-credits-withdraw на BigBr (109.73.195.123).
# dashd у dash01, API эпох — внешний https://platform-explorer.pshenmic.dev
# Запуск с Mac:
#   ./setup_platform_credits_server.sh
#   REPO_URL=git@github.com:sibTamias/platform-credits-withdraw.git ./setup_platform_credits_server.sh

set -euo pipefail

SERVER="${SERVER:-mno@109.73.195.123}"
REPO_URL="${REPO_URL:-git@github.com:sibTamias/platform-credits-withdraw.git}"
REPO_DIR="${REPO_DIR:-platform-credits-withdraw}"
NODE_VER="v24.8.0"
NODE_DIR="node-${NODE_VER}-linux-x64"

echo "==> Deploy $REPO_URL to $SERVER:~/$REPO_DIR"
ssh "$SERVER" "bash -s" "$REPO_URL" "$REPO_DIR" <<'REMOTE'
set -euo pipefail
REPO_URL="$1"
REPO_DIR="$2"
cd ~
if [[ -d "$REPO_DIR/.git" ]]; then
  echo "git pull in ~/$REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only
else
  echo "git clone $REPO_URL"
  git clone "$REPO_URL" "$REPO_DIR"
fi
chmod +x ~/"$REPO_DIR"/*.sh
mkdir -p ~/bin
for s in platform_credits_withdraw.sh export-private-keys-protx.sh get_platform_epoch.sh platform_explorer_api.sh; do
  ln -sf ~/"$REPO_DIR"/"$s" ~/bin/"$s"
done
echo "Symlinks in ~/bin:"
ls -la ~/bin/platform_credits_withdraw.sh ~/bin/export-private-keys-protx.sh ~/bin/get_platform_epoch.sh
REMOTE

echo "==> Patch ~/bin/.env (platform_credits block)"
ssh "$SERVER" 'bash -s' <<'REMOTE'
set -euo pipefail
ENV=~/bin/.env
MARKER="# platform_credits_withdraw"
if grep -q "$MARKER" "$ENV" 2>/dev/null; then
  echo ".env already has platform_credits block"
else
  cat >>"$ENV" <<'EOF'

# platform_credits_withdraw (Mass Send локально на сервере)
export MASS_SEND_DIR="$HOME/dash-platform-mass-send"
export KEYS_FILE="$HOME/bin/privkey_protx.txt"
export OUT_FILE="$HOME/bin/privkey_protx.txt"
export NETWORK="mainnet"
export TIMEOUT_SEC="600"
export MIN_WITHDRAWAL_FEE="400000000"
export DEFAULT_WITHDRAWAL_FEE="400000000"
export NODE_PATH="$HOME/bin/node-v24.8.0-linux-x64/bin/node"
export PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"
export EPOCH_WITHDRAW_OFFSET_SEC="5"
export CRON_TZ="Asia/Irkutsk"
export DASH_CLI_CMD="sudo -u dash01 /opt/dash/bin/dash-cli"
EOF
  chmod 600 "$ENV"
  echo "Appended platform_credits block to $ENV"
fi
# Обновить URL API, если блок уже был без локального platform-explorer
if grep -q 'platform-explorer.pshenmic.dev' "$ENV" 2>/dev/null; then
  sed -i 's|export PLATFORM_EXPLORER_URL="http://127.0.0.1:13005"|export PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"|' "$ENV"
  echo "Updated PLATFORM_EXPLORER_URL in $ENV"
elif ! grep -q 'PLATFORM_EXPLORER_URL=' "$ENV" 2>/dev/null; then
  printf '\nexport PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"\n' >>"$ENV"
  echo "Added PLATFORM_EXPLORER_URL to $ENV"
fi
REMOTE

echo "==> Install Node $NODE_VER (if missing)"
ssh "$SERVER" "bash -s" "$NODE_VER" "$NODE_DIR" <<'REMOTE'
set -euo pipefail
NODE_VER="$1"
NODE_DIR="$2"
TARGET=~/bin/$NODE_DIR
if [[ -x "$TARGET/bin/node" ]]; then
  echo "Node already installed: $($TARGET/bin/node -v)"
  exit 0
fi
mkdir -p ~/bin
cd ~/bin
wget -q "https://nodejs.org/dist/${NODE_VER}/${NODE_DIR}.tar.xz"
tar xf "${NODE_DIR}.tar.xz"
rm -f "${NODE_DIR}.tar.xz"
echo "Installed: $($TARGET/bin/node -v)"
REMOTE

echo "==> npm install in dash-platform-mass-send"
ssh "$SERVER" 'cd ~/dash-platform-mass-send && ~/bin/node-v24.8.0-linux-x64/bin/node -v && npm install --silent 2>/dev/null || npm install'

echo "==> Schedule cron for next epoch"
ssh "$SERVER" '~/bin/platform_credits_withdraw.sh --schedule-only --reschedule-cron'

echo "Done."
echo "  ~/bin/platform_credits_withdraw.sh --update-keys --epoch-gate --reschedule-cron"
echo "  ~/bin/get_platform_epoch.sh"
