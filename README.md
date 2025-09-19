# PlayWallet v2 Deployment Notes

## Запуск основных сервисов

```bash
docker compose up -d --build
```

Команда соберёт контейнер приложения, фонового воркера и Postgres. Healthcheck API (`/health`) будет доступен на `http://localhost:8000/health` после успешного старта.

## Мониторинг Prometheus и Grafana

Мониторинговые контейнеры входят в `docker-compose.yml`. Их можно запустить вместе с остальными сервисами либо отдельно:

```bash
docker compose up -d prometheus grafana
```

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (логин `admin`, пароль `GRAFANA_PASSWORD` из `.env` либо `admin` по умолчанию)

## Проверка базы данных

Перед выполнением команд инициализируйте переменные окружения из `.env`:

```bash
set -a
source .env
set +a
```

Теперь можно запускать `psql` внутри контейнера, даже если переменные окружения не экспортированы в текущую сессию:

```bash
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM orders LIMIT 5;"'
```

Для быстрой вставки тестового заказа воспользуйтесь тем же приёмом:

```bash
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<"SQL"\
INSERT INTO orders (id, external_id, login, service_id, amount, status, created_datetime)\
VALUES ("test-order-001", "PLATI-TEST-001", "test_login", "ff71c998-14be-4e3d-8ad3-0ffc8357265b", 1.23, "created", NOW())\
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status\
RETURNING *;\
SQL'
```

## Проверка метрик

После запуска приложения убедитесь, что Prometheus может получить метрики напрямую:

```bash
curl http://localhost:8000/metrics | head
```

Через внешний домен метрики доступны на `https://arieco.shop/metrics` (эндпойнт отключён в OpenAPI, поэтому в Swagger его нет).

Теперь любая команда `docker compose exec` корректно подставит `DB_USER` и `DB_NAME`:

```bash
docker compose exec db psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM orders LIMIT 5;"
```

Для быстрой вставки тестового заказа:

```bash
docker compose exec db psql -U "$DB_USER" -d "$DB_NAME" <<'SQL'
INSERT INTO orders (id, external_id, login, service_id, amount, status, created_datetime)
VALUES ('test-order-001', 'PLATI-TEST-001', 'test_login', 'ff71c998-14be-4e3d-8ad3-0ffc8357265b', 1.23, 'created', NOW())
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status
RETURNING *;
SQL
```

## Скрипт миграции

`deploy_v2.sh` автоматизирует развертывание новой версии из старой установки `/opt/playwallet`. Скопируйте его на сервер, сделайте исполняемым и запустите:

```bash
chmod +x deploy_v2.sh
./deploy_v2.sh
```

Скрипт создаёт резервную копию, разворачивает структуру v2 с мониторингом и обновлёнными зависимостями, а также запускает все контейнеры.
