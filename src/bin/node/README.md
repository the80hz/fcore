# FRKN Node Agent

Agent that runs on every proxy node. It registers the node with the API, syncs connections and reports stats.

## What it does

- Registers node info and inbounds with the API.
- Subscribes to API updates over ZeroMQ.
- Optionally drives Xray, WireGuard, AmneziaWG, Hysteria2 and MTProto proxies.
- Reports traffic/online metrics to the API metric receiver.
- Periodically saves local snapshots for fast restart.

## Files

- `node-example.toml` — full example configuration.
- `node.service` — systemd unit.

## Quick start

```bash
cp src/bin/node/node-example.toml /etc/fcore/node/config.toml
# edit config
cargo build --release --bin node --features xray,wireguard,amnezia-wg
sudo cp target/release/node /usr/local/bin/node
sudo cp src/bin/node/node.service /etc/systemd/system/node.service
sudo systemctl daemon-reload
sudo systemctl enable --now node
```

## Deploy from release

```bash
sudo ./deploy/node-deploy.sh v0.5.16
```

Choose the architecture file downloaded by the script: `node-x86_64`, `node-aarch64` or `node-armv7`.

## Ручное обновление self-hosted fnode

На VPS со штатной установкой FRKN запустите обновлятор из корня репозитория
и укажите конкретный стабильный релиз:

```bash
sudo ./deploy/fnode-update.sh v0.7.24
```

Скрипту нужны Bash, systemd с журналом `fnode.service`, `curl`, `jq`, `flock`
и стандартные GNU-утилиты. Он работает с активной службой, которая запускает
`/opt/fnode/fnode`, и читает версию текущего процесса из журнала. Запрос
текущей версии завершается успешно без перезапуска. Более старая версия
отклоняется. Перед заменой бинарника скрипт проверяет, что текущий запуск
дошёл до `Running metrics task`.

Обновлятор выбирает бинарник для архитектуры VPS, сверяет SHA-256 с
метаданными указанного релиза `frkn-dev/fcore` и сохраняет прежний бинарник
в `/opt/fnode/update-backups/`. После атомарной замены перезапускается только
`fnode.service`. Конфигурация, токен и снимки остаются на диске, а интерфейсы
VPN продолжают работать под управлением своих служб.

Скрипт ждёт до 60 секунд, пока новый запуск напечатает ожидаемую версию и
`Running metrics task` в журнале. Для этой проверки нужен доступный журнал
с обычным уровнем `info`. Маркер подтверждает завершение запросов стартовой
синхронизации. Трафик через конкретные туннели проверяется отдельно.

Если запуск не проходит, скрипт возвращает сохранённый бинарник и повторно
проверяет службу. Код выхода 1 означает ошибку обновления. Код выхода 2
означает, что восстановление службы не удалось подтвердить. Путь к резервной
копии выводится перед заменой. Он пригодится и для восстановления после
принудительного завершения процесса или выключения VPS.
