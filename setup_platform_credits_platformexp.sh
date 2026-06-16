#!/usr/bin/env bash
# Деплой утилит platform-credits-withdraw на platformExp (локальный platform-explorer :3005).
# Запуск с Mac:
#   ./setup_platform_credits_platformexp.sh
#
# На этом сервере cron для Mass Send не нужен (dashd/operator на BigBr 109).
# Здесь — get_platform_epoch.sh и диагностика с PLATFORM_EXPLORER_URL=http://127.0.0.1:3005.

set -euo pipefail

SERVER="${SERVER:-mno@161.97.96.43}"
REPO_URL="${REPO_URL:-git@github.com:sibTamias/platform-credits-withdraw.git}"
REPO_DIR="${REPO_DIR:-platform-credits-withdraw}"

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
for s in get_platform_epoch.sh check_fleet_balances.sh platform_explorer_api.sh; do
  ln -sf ~/"$REPO_DIR"/"$s" ~/bin/"$s"
done
echo "Symlinks in ~/bin:"
ls -la ~/bin/get_platform_epoch.sh ~/bin/check_fleet_balances.sh ~/bin/platform_explorer_api.sh
REMOTE

echo "==> Patch ~/bin/.env (platform_credits local API)"
ssh "$SERVER" 'bash -s' <<'REMOTE'
set -euo pipefail
ENV=~/bin/.env
MARKER="# platform_credits_withdraw local API"
touch "$ENV"
if grep -q "$MARKER" "$ENV" 2>/dev/null; then
  echo ".env already has platform_credits local API block"
else
  cat >>"$ENV" <<'EOF'

# platform_credits_withdraw local API
export PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"
export TZ_DISPLAY="Asia/Irkutsk"
EOF
  chmod 600 "$ENV"
  echo "Appended local API block to $ENV"
fi
REMOTE

echo "==> Verify local API"
ssh "$SERVER" 'curl -sf http://127.0.0.1:3005/status | jq -r ".epoch.number" && ~/bin/get_platform_epoch.sh | head -8'

echo "Done."
echo "  ~/bin/get_platform_epoch.sh"
echo "  curl -s http://127.0.0.1:3005/status | jq .epoch"
