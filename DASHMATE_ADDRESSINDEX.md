# Включение addressindex в Dash Core (dashmate)

Гайд для нод на **dashmate** (например `platformExp`, `mno@161.97.96.43`).

## Зачем нужен addressindex

RPC `getaddressbalance` (и другие [Address Index RPCs](https://docs.dash.org/projects/core/en/latest/docs/api/remote-procedure-calls-address-index.html)) требуют `-addressindex=1`.

Без индекса:

```
Address index is disabled. You should run Dash Core with -addressindex (requires reindex)
```

На сервере с обычным `dashd` (например `109.73.195.123`, кошелёк `/home/dash01/.dashcore`) параметр задаётся в `dash.conf` напрямую. На **dashmate** так делать нельзя — см. ниже.

## Почему нельзя править dash.conf вручную

Файл `~/.dashmate/mainnet/core/dash.conf` **пересобирается из** `~/.dashmate/config.json` при каждом `dashmate start` / `dashmate restart`.

Если добавить строку вручную:

```bash
echo 'addressindex=1' >> ~/.dashmate/mainnet/core/dash.conf
dashmate start
```

— после старта строка **исчезнет**.

Источник шаблона: `/usr/lib/dashmate/templates/core/dash.conf.dot` — индексы подставляются из `core.indexes` в config.json.

В `ContaboOps/zevo.sh` то же правило: *«НЕ редактируйте dash.conf в nano — ключ хранится в config.json»* (`dashmateCheckConfigMasternode`).

## Правильный способ: `dashmate config set`

### 1. Проверить текущие индексы

```bash
dashmate config get core.indexes
jq '.configs.mainnet.core.indexes' ~/.dashmate/config.json
grep -E 'index=1' ~/.dashmate/mainnet/core/dash.conf
```

По умолчанию после setup (см. `zevo.sh`) обычно только:

```bash
dashmate config set core.indexes '["tx"]'
```

В `dash.conf` будет `txindex=1`, без `addressindex=1`.

### 2. Включить address index

В **config.json** значение называется `address`, не `addressindex`. Dashmate сам сгенерирует `addressindex=1` в dash.conf:

```bash
dashmate config set core.indexes '["tx", "address"]'
```

Допустимые значения в dashmate 3.x: `address`, `tx`, `timestamp`, `spent`.

Для explorer / insight иногда нужен полный набор (локальный preset dashmate):

```bash
dashmate config set core.indexes '["tx", "address", "timestamp", "spent"]'
```

Для `mn_info` и `getaddressbalance` достаточно `["tx", "address"]`.

### 3. Reindex

При первом включении `address` Core должен **перестроить индекс**. Не редактируйте `reindex=1` в dash.conf — используйте встроенную команду:

```bash
dashmate stop --safe
dashmate core reindex
```

Что делает `dashmate core reindex`:

- временно ставит `reindex=1` в сгенерированный dash.conf;
- запускает Core и ждёт построения индексов (прогресс вроде `Reindex Core … 45.2%, 3400 / 7488`);
- после завершения убирает `reindex=1` и поднимает сервисы.

**Не прерывайте** reindex (`stop -f`, kill, reboot).

Если reindex уже завершился, но нода не поднялась:

```bash
dashmate start
dashmate status core
```

### 4. Проверка

```bash
grep addressindex ~/.dashmate/mainnet/core/dash.conf
# ожидаемо: addressindex=1

~/bin/dash_cli_docker.sh getaddressbalance '{"addresses":["ВАШ_PAYOUT_ADDRESS"]}'
# ожидаемо: JSON с полем "balance", без ошибки address index
```

Или через dashmate:

```bash
dashmate core cli getaddressbalance '{"addresses":["ВАШ_PAYOUT_ADDRESS"]}'
```

## Краткая шпаргалка (platformExp)

```bash
ssh mno@161.97.96.43

dashmate config set core.indexes '["tx", "address"]'
dashmate config get core.indexes

dashmate stop --safe
dashmate core reindex
# дождаться 100%

dashmate status core
grep addressindex ~/.dashmate/mainnet/core/dash.conf
```

## Альтернатива без reindex

Скрипт `~/bin/mn_info.sh` на platformExp может считать балансы payout-адресов через **`scantxoutset`** (один batch-запрос на все адреса, ~3–4 с для ~40 нод). Reindex не нужен, но `getaddressbalance` останется недоступен.

Для cron-уведомлений `mn_info` этого обычно достаточно. Reindex имеет смысл, если нужен быстрый `getaddressbalance` в других скриптах.

## Сравнение: dashd vs dashmate

| | Обычный dashd (`109.73.195.123`) | dashmate (`platformExp`) |
|---|---|---|
| Конфиг | `/home/dash01/.dashcore/dash.conf` | `~/.dashmate/config.json` → генерирует `dash.conf` |
| Включить addressindex | `addressindex=1` в dash.conf + reindex | `dashmate config set core.indexes '["tx", "address"]'` + `dashmate core reindex` |
| Ручное редактирование dash.conf | да | **нет** (перезаписывается) |

## Ссылки

- [Dashmate on a new host](https://docs.dash.org/en/stable/docs/user/masternodes/dashmate-new-host.html) — `dashmate config set core.indexes '["tx"]'`
- [Address Index RPCs](https://docs.dash.org/projects/core/en/latest/docs/api/remote-procedure-calls-address-index.html)
- [Dashmate — config set](https://docs.dash.org/en/stable/docs/user/network/dashmate/index.html)
- Локально: `ContaboOps/zevo.sh` (setup: `core.indexes`, проверка config vs dash.conf)
