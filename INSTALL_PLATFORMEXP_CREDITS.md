# Platform Credits Withdraw on platformExp

Полный гайд по переносу и запуску вывода credits на `platformExp` (`161.97.96.43`) с **локальным** `platform-explorer` (`http://127.0.0.1:3005`), включая импорт кошелька `operator`.

## 1. Цель и целевая архитектура

- Сервер выполнения вывода: `platformExp` (`mno@161.97.96.43`)
- Dash Core: в Docker через `dashmate` (mainnet core container)
- API эпох и балансов: локальный `platform-explorer` на `127.0.0.1:3005`
- Скрипт вывода: `platform_credits_withdraw.sh`
- Лог вывода credits: `~/tmp/platform_credits_withdraw.log`

## 2. Подготовка репозитория

На Mac:

```bash
cd /Users/mn/Projects/platform-credits-withdraw
git pull --ff-only
```

На `platformExp`:

```bash
ssh mno@161.97.96.43
cd ~/platform-credits-withdraw
git pull --ff-only
chmod +x *.sh
```

## 3. Проверка базовых зависимостей на platformExp

```bash
dashmate status core
docker ps --format '{{.Names}}' | grep mainnet-core-1
curl -s http://127.0.0.1:3005/status | jq .epoch.number
```

Ожидаемо:
- Core `running/up`
- найден контейнер `...mainnet-core-1`
- локальный API `:3005` отвечает

## 4. Установка Node.js и dash-platform-mass-send

Если уже установлено, шаг можно пропустить.

```bash
mkdir -p ~/bin && cd ~/bin
wget https://nodejs.org/dist/v24.8.0/node-v24.8.0-linux-x64.tar.xz
tar xf node-v24.8.0-linux-x64.tar.xz
rm -f node-v24.8.0-linux-x64.tar.xz
~/bin/node-v24.8.0-linux-x64/bin/node -v
```

```bash
git clone https://github.com/pshenmic/dash-platform-mass-send ~/dash-platform-mass-send
cd ~/dash-platform-mass-send
~/bin/node-v24.8.0-linux-x64/bin/npm install
```

## 5. Подготовка helper для Core в Docker

В репозитории есть `dash_cli_docker.sh` (уже с `grep`, без `rg`).

```bash
ln -sf ~/platform-credits-withdraw/dash_cli_docker.sh ~/bin/dash_cli_docker.sh
chmod +x ~/platform-credits-withdraw/dash_cli_docker.sh ~/bin/dash_cli_docker.sh
```

Проверка:

```bash
~/bin/dash_cli_docker.sh getblockcount
~/bin/dash_cli_docker.sh protx list registered 1 | jq 'length'
```

## 6. Импорт кошелька `operator` в Core (dashmate container)

### 6.1 Загрузка `wallet.dat` с Mac на platformExp

На Mac:

```bash
scp "/Users/mn/Library/Application Support/DashCore/wallets/operator/wallet.dat" \
  mno@161.97.96.43:/home/mno/tmp/operator.wallet.dat
```

### 6.2 Копирование в контейнер и загрузка wallet

На `platformExp`:

```bash
C=$(docker ps --format '{{.Names}}' | grep 'mainnet-core-1' | head -1)
docker exec "$C" mkdir -p /home/dash/.dashcore/wallets/operator
docker cp /home/mno/tmp/operator.wallet.dat "$C":/home/dash/.dashcore/wallets/operator/wallet.dat
docker exec "$C" chown -R dash:dash /home/dash/.dashcore/wallets/operator
docker exec "$C" dash-cli loadwallet operator
```

Если `loadwallet` говорит, что уже загружен, это нормально.

### 6.3 Проверка wallet

```bash
docker exec "$C" dash-cli listwallets
docker exec "$C" dash-cli -rpcwallet=operator getwalletinfo
```

Ожидаемо: в `listwallets` есть `"operator"`.

### 6.4 Очистка временного файла

```bash
rm -f /home/mno/tmp/operator.wallet.dat
```

## 7. Настройка `~/bin/.env` для вывода credits

Открой:

```bash
nano ~/bin/.env
```

Добавь/проверь:

```bash
export DASH_CLI_CMD="$HOME/bin/dash_cli_docker.sh"
# optional, если автопоиск контейнера не подходит:
# export DASH_CORE_CONTAINER="dashmate_XXXX_mainnet-core-1"

export PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"

export MASS_SEND_DIR="$HOME/dash-platform-mass-send"
export KEYS_FILE="$HOME/bin/privkey_protx.txt"
export OUT_FILE="$HOME/bin/privkey_protx.txt"
export NETWORK="mainnet"
export TIMEOUT_SEC="600"
export MIN_WITHDRAWAL_FEE="400000000"
export DEFAULT_WITHDRAWAL_FEE="400000000"
export NODE_PATH="$HOME/bin/node-v24.8.0-linux-x64/bin/node"

export EPOCH_WITHDRAW_OFFSET_SEC="5"
export EPOCH_BALANCE_POLL_SEC="10"
export CRON_TZ="Asia/Irkutsk"
export CRON_LOG="$HOME/tmp/platform_credits_withdraw.log"
export LAST_EPOCH_FILE="$HOME/bin/.platform_credits_withdraw_last_epoch"

export WALLET="operator"
export WALLET_FEE="fees"
export WALLET_PASSPHRASE="YOUR_REAL_PASSWORD"
export WALLET_UNLOCK_SECONDS="120"
```

Важно:
- не оставляй дубли `export DASH_CLI_CMD=...`
- `WALLET_PASSPHRASE` должен быть реальным значением

## 8. Экспорт ключей и dry-run проверки

```bash
~/bin/get_platform_epoch.sh | head -5
~/bin/platform_credits_withdraw.sh --update-keys --dry-run
~/bin/export-private-keys-protx.sh
wc -l ~/bin/privkey_protx.txt
```

## 9. Установка cron для epoch-режима

```bash
~/bin/platform_credits_withdraw.sh --schedule-only --reschedule-cron
crontab -l | grep -A1 platform_credits_withdraw
```

Ожидаемая строка:

```cron
# platform_credits_withdraw epoch-scheduled
MM HH DD MM * /home/mno/bin/platform_credits_withdraw.sh --update-keys --epoch-gate --reschedule-cron >> /home/mno/tmp/platform_credits_withdraw.log 2>&1
```

Где `MM HH DD MM` скрипт вычисляет автоматически из времени старта следующей эпохи + offset.

## 10. Логи и мониторинг

Лог вывода credits:

```bash
tail -f ~/tmp/platform_credits_withdraw.log
```

Отдельный старый лог BigBrother (`db.json`) обычно в:

```bash
tail -f ~/tmp/cron.log
```

Рекомендуется держать эти логи раздельно.

## 11. Переключение с BigBr (без дублей)

Когда `platformExp` готов и проверен:

На BigBr отключи cron `platform_credits_withdraw`:

```bash
ssh mno@109.73.195.123
crontab -l | grep -v platform_credits_withdraw | crontab -
crontab -l | grep platform_credits_withdraw || true
```

Оставь только один активный cron вывода credits (на `platformExp`).

## 12. Быстрый smoke-test перед production

```bash
~/bin/dash_cli_docker.sh -rpcwallet=operator protx list registered true | jq 'length'
~/bin/platform_credits_withdraw.sh --update-keys --dry-run
~/bin/check_fleet_balances.sh --sample
crontab -l | grep -A1 platform_credits_withdraw
```

## 13. Частые проблемы и решения

- `rg: command not found` в `dash_cli_docker.sh`
  - Исправлено: используется `grep`.

- `Requested wallet does not exist or is not loaded`
  - Проверь импорт `wallet.dat` и `loadwallet operator`.

- Логи смешаны с BigBrother
  - Установи `CRON_LOG="$HOME/tmp/platform_credits_withdraw.log"` и пересоздай cron.

- `--update-keys` не работает
  - Проверь `WALLET_PASSPHRASE`, `DASH_CLI_CMD`, доступность wallet `operator`.

