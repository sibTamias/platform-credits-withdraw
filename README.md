# platform-credits-withdraw

Локальный массовый вывод **Platform credits** для Dash Evo-нод. Аналог формы **«Массовая рассылка»** в EvoWatch WebMuxValidator, но запускается на своём сервере через [dash-platform-mass-send](https://github.com/pshenmic/dash-platform-mass-send).

Поддерживает:
- экспорт приватных ключей из кошелька `operator` (Owned + Evo);
- вывод credits на зарегистрированные **payout-адреса**;
- привязку запуска к **началу новой эпохи** через platform-explorer API;
- автоматическое обновление **cron** на следующую эпоху.

---

## Состав репозитория

| Файл | Назначение |
|------|------------|
| `platform_credits_withdraw.sh` | Основной скрипт вывода credits |
| `export-private-keys-protx.sh` | Экспорт `privkey:proTxHash` из Dash Core |
| `get_platform_epoch.sh` | Текущая эпоха и время начала/конца (API + человекочитаемый формат) |
| `setup_platform_credits_server.sh` | Деплой на сервер через `git pull` + симлинки в `~/bin` |
| `.env.example` | Пример переменных окружения |

---

## Требования

### Для вывода credits
- **Node.js 18+** (на сервере 109: `~/bin/node-v24.8.0-linux-x64/bin/node`)
- **dash-platform-mass-send** в `~/dash-platform-mass-send` (`npm install`)
- Файл ключей `privkey_protx.txt` (формат ниже)

### Для `--update-keys`
- **Dash Core** с загруженным кошельком `operator`
- **jq**, **curl** (или `DASH_CLI_CMD` на сервере)
- Разблокированный кошелёк или `WALLET_PASSPHRASE` в `.env`

### Для планирования по эпохам
- Доступ к API: `https://platform-explorer.pshenmic.dev` (или локальный `localhost:3005`)
- **python3** (конвертация времени и cron)

---

## Формат файла ключей

По одной строке в `privkey_protx.txt`:

```
private_key_WIF:proTxHash
```

Credits при `withdrawal` уходят на **payout-адрес**, зарегистрированный в protx (не на произвольный адрес).

---

## Быстрый старт

### 1. Клонирование

```bash
git clone git@github.com:sibTamias/platform-credits-withdraw.git
cd platform-credits-withdraw
cp .env.example .env
chmod 600 .env
# отредактируйте .env
```

### 2. Установка dash-platform-mass-send

```bash
git clone https://github.com/pshenmic/dash-platform-mass-send ~/dash-platform-mass-send
cd ~/dash-platform-mass-send && npm install
```

### 3. Экспорт ключей и вывод

```bash
./platform_credits_withdraw.sh --update-keys
./platform_credits_withdraw.sh
```

---

## Использование `platform_credits_withdraw.sh`

```bash
./platform_credits_withdraw.sh [options]
```

### Опции

| Опция | Описание |
|-------|----------|
| `--update-keys`, `-u` | Обновить `privkey_protx.txt` из кошелька operator |
| `--keys-file PATH` | Путь к файлу ключей |
| `--network NET` | `mainnet` \| `testnet` (по умолчанию `mainnet`) |
| `--type TYPE` | `withdrawal` \| `transfer` |
| `--recipient ADDR` | Адрес получателя (только для `transfer`) |
| `--amount N` | Сумма credits (по умолчанию весь баланс минус fee) |
| `--fee N` | Комиссия в credits (**минимум 400000000**, ниже нельзя) |
| `--dry-run` | Проверка окружения без выполнения |
| `--epoch-gate` | Запуск только после начала новой эпохи + offset |
| `--force` | Игнорировать проверку эпохи |
| `--reschedule-cron` | После прогона обновить crontab на следующую эпоху |
| `--schedule-only` | Только пересчитать cron, без вывода |
| `-h`, `--help` | Справка |

### Примеры

```bash
# Ручной вывод
./platform_credits_withdraw.sh --update-keys --force

# Проверка без выполнения
./platform_credits_withdraw.sh --dry-run

# Cron: вывод после эпохи + перепланирование
./platform_credits_withdraw.sh --update-keys --epoch-gate --reschedule-cron

# Только обновить cron на следующую эпоху
./platform_credits_withdraw.sh --schedule-only --reschedule-cron
```

---

## Минимальный баланс и комиссия

Протокол Dash Platform требует **fee ≥ 400 000 000 credits** на вывод.

Если баланс identity ~231M credits, вывод невозможен — нужно дождаться накопления **> 400M** (обычно к концу эпохи или в следующей).

Типичная ошибка в логе:

```
Amount + fee must be above zero
```

Скрипт в summary показывает, сколько credits не хватает до порога.

---

## Планирование по эпохам

### Как это работает

1. Скрипт запрашивает `GET /status` у platform-explorer API.
2. Из ответа берёт:
   - номер текущей эпохи;
   - `epoch.startTime` — начало текущей эпохи;
   - `epoch.endTime` — начало **следующей** эпохи.
3. С флагом `--epoch-gate`:
   - проверяет файл `~/.platform_credits_withdraw_last_epoch` (уже был вывод для этой эпохи?);
   - ждёт `EPOCH_WITHDRAW_OFFSET_SEC` секунд после начала эпохи (по умолчанию **5**).
4. С флагом `--reschedule-cron` **после прогона**:
   - вычисляет время: `следующая_эпоха + offset`;
   - обновляет одну строку в crontab (маркер `# platform_credits_withdraw epoch-scheduled`).

### Пример cron на BigBr (109.73.195.123)

```
TZ=Asia/Irkutsk
# platform_credits_withdraw epoch-scheduled
53 10 25 6 * /home/mno/bin/platform_credits_withdraw.sh --update-keys --epoch-gate --reschedule-cron >> /home/mno/tmp/cron.log 2>&1
```

После прогона cron автоматически сдвигается на **начало следующей эпохи + 5 секунд**.

### Переменные

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `PLATFORM_EXPLORER_URL` | `https://platform-explorer.pshenmic.dev` | API эпох |
| `EPOCH_WITHDRAW_OFFSET_SEC` | `5` | Секунд после начала эпохи до запуска (cron и ожидание в скрипте) |
| `CRON_TZ` | `Asia/Irkutsk` | Часовой пояс crontab |
| `CRON_LOG` | `~/tmp/cron.log` | Лог cron |
| `LAST_EPOCH_FILE` | `~/bin/.platform_credits_withdraw_last_epoch` | Последняя обработанная эпоха |

---

## `get_platform_epoch.sh`

Показывает время эпох в миллисекундах, UTC и локальной зоне:

```bash
./get_platform_epoch.sh        # текущая эпоха
./get_platform_epoch.sh 72     # конкретная эпоха
```

Пример вывода:

```
Current epoch: 72
startTime (epoch 72):
  ms:   1781560424283
  UTC:  2026-06-15 21:53:44 UTC
  Asia/Irkutsk: 2026-06-16 05:53:44 +08
Until next epoch: 9d 01:37:04
```

---

## `export-private-keys-protx.sh`

Отдельный скрипт для экспорта ключей (вызывается из `--update-keys`):

```bash
./export-private-keys-protx.sh
```

Критерий отбора нод: `type == "Evo"` и `wallet.hasOwnerKey == true` (как Owned+Evo в Dash Core GUI).

На masternode-сервере без wallet RPC (режим `-masternode=1`) экспорт с сервера невозможен — экспортируйте на Mac и скопируйте `privkey_protx.txt` на сервер.

---

## Деплой на сервер 109.73.195.123 (BigBr)

### С Mac (первичная установка)

```bash
./setup_platform_credits_server.sh
```

Скрипт:
1. `git clone` / `git pull` в `~/platform-credits-withdraw`;
2. симлинки в `~/bin/`;
3. дополняет `~/bin/.env`;
4. ставит Node.js (если нет);
5. `npm install` в `dash-platform-mass-send`;
6. планирует cron на следующую эпоху.

### Обновление на сервере

```bash
cd ~/platform-credits-withdraw && git pull
# симлинки в ~/bin уже указывают на репо — перезапуск не нужен
```

Или с Mac:

```bash
./setup_platform_credits_server.sh
```

---

## Переменные окружения (.env)

Скрипты читают `.env` из каталога репозитория или `~/bin/.env` (на сервере — через симлинки и `BIN`).

См. `.env.example`. **Не коммитьте** `.env` с паролями.

Ключевые переменные для BigBr:

```bash
export DASH_CLI_CMD="sudo -u dash01 /opt/dash/bin/dash-cli"
export MASS_SEND_DIR="$HOME/dash-platform-mass-send"
export KEYS_FILE="$HOME/bin/privkey_protx.txt"
export NODE_PATH="$HOME/bin/node-v24.8.0-linux-x64/bin/node"
export PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"
export EPOCH_WITHDRAW_OFFSET_SEC="5"
export CRON_TZ="Asia/Irkutsk"
```

---

## Итоговый отчёт (summary)

После прогона скрипт выводит:

- количество успешных / неудачных выводов;
- ошибки по каждой identity;
- сумму withdrawn по payout-адресам;
- причину `balance < 400M`;
- L1-баланс DASH на payout-адресах (если доступен RPC).

---

## Диагностика

```bash
# Эпоха и время следующего запуска
~/bin/get_platform_epoch.sh

# Текущий cron
crontab -l | grep platform_credits

# Проверка окружения
~/bin/platform_credits_withdraw.sh --dry-run

# API platform-explorer
curl -s https://platform-explorer.pshenmic.dev/status | jq '.epoch'

# Лог cron
tail -100 ~/tmp/cron.log
```

### localhost:3005 не отвечает

На BigBr **нет** локального platform-explorer. Используйте внешний API:

```bash
export PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"
```

---

## Безопасность

- `privkey_protx.txt` содержит **приватные ключи** — права `600`, не в git.
- `.env` с `WALLET_PASSPHRASE` — только на сервере, `chmod 600`.
- Cron и логи не должны попадать в публичные репозитории.

---

## Связанные проекты

- [pshenmic/dash-platform-mass-send](https://github.com/pshenmic/dash-platform-mass-send) — Node.js mass send
- [platform-explorer](https://platform-explorer.pshenmic.dev) — API эпох и валидаторов
- EvoWatch WebMuxValidator — веб-форма «Массовая рассылка» (тот же `index.js`)

---

## Лицензия

Скрипты для внутреннего использования. Используйте на свой риск; проверяйте транзакции на testnet перед mainnet.
