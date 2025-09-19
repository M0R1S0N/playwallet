#!/bin/bash
# БЫСТРОЕ ВНЕДРЕНИЕ PlayWallet v2.0
# Выполните команды по порядку на вашем сервере

echo "🚀 НАЧИНАЕМ МИГРАЦИЮ PlayWallet v1 → v2"

# 1. СОЗДАНИЕ РЕЗЕРВНОЙ КОПИИ
echo "Шаг 1: Создание резервной копии..."
sudo cp -r /opt/playwallet /opt/playwallet-backup-$(date +%Y%m%d_%H%M%S)
cd /opt/playwallet && sudo docker-compose down

# 2. СОЗДАНИЕ НОВОЙ СТРУКТУРЫ
echo "Шаг 2: Создание структуры v2..."
sudo mkdir -p \
    /opt/playwallet-v2/app \
    /opt/playwallet-v2/sql \
    /opt/playwallet-v2/nginx \
    /opt/playwallet-v2/monitoring/prometheus \
    /opt/playwallet-v2/monitoring/grafana/datasources \
    /opt/playwallet-v2/monitoring/grafana/dashboards \
    /opt/playwallet-v2/scripts \
    /opt/playwallet-v2/logs \
    /opt/playwallet-v2/backups \
    /opt/playwallet-v2/tests

# 3. КОПИРОВАНИЕ БАЗОВЫХ ФАЙЛОВ
echo "Шаг 3: Копирование конфигураций..."
cd /opt/playwallet-v2
sudo cp /opt/playwallet/.env .
sudo cp /opt/playwallet/app/__init__.py app/
sudo cp /opt/playwallet/app/schemas.py app/

# 4. СОЗДАНИЕ НОВЫХ ФАЙЛОВ ПРИЛОЖЕНИЯ
echo "Шаг 4: Создание улучшенных файлов..."

# app/main.py
sudo tee app/main.py > /dev/null <<'EOF'
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.db import close_pool, init_pool
from app.metrics import MetricsMiddleware, router as metrics_router
from app.routes import router as api_router


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(name)s:%(lineno)d - %(message)s",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    print("🚀 Starting PlayWallet v2.0...")
    await init_pool()
    yield
    await close_pool()
    print("🛑 PlayWallet stopped")


app = FastAPI(
    title="PlayWallet API v2.0",
    description="Автоматическое пополнение Steam с защитой от мошенничества",
    version="2.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

app.add_middleware(MetricsMiddleware)
app.include_router(metrics_router)
app.include_router(api_router)
EOF

sudo tee app/metrics.py > /dev/null <<'EOF'
from __future__ import annotations

import time

from fastapi import APIRouter, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest


REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    labelnames=("method", "path", "status"),
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    labelnames=("method", "path", "status"),
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)


class MetricsMiddleware:
    """Collect Prometheus metrics for each HTTP request."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        method = scope.get("method", "").upper()
        path = scope.get("path", "")
        if not path:
            raw_path = scope.get("raw_path")
            if isinstance(raw_path, (bytes, bytearray)):
                path = raw_path.decode("latin-1")

        start_time = time.perf_counter()
        status_code: int | None = None

        async def send_wrapper(message):
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration = time.perf_counter() - start_time
            status = str(status_code or 500)
            REQUEST_COUNT.labels(method=method, path=path, status=status).inc()
            REQUEST_LATENCY.labels(method=method, path=path, status=status).observe(duration)


router = APIRouter()


@router.get("/metrics", include_in_schema=False)
async def metrics_endpoint() -> Response:
    data = generate_latest()
    return Response(content=data, media_type=CONTENT_TYPE_LATEST)
EOF

# app/fraud_detection.py (минимальная версия для начала)
sudo tee app/fraud_detection.py > /dev/null <<'EOF'
import time
from typing import Dict, Any

class FraudDetector:
    def __init__(self):
        self.ip_history = {}
        self.max_orders_per_hour = 10
    
    async def calculate_risk_score(self, order_data: Dict[str, Any]) -> float:
        ip = order_data.get('ip', '')
        current_time = time.time()
        
        # Простая проверка частоты запросов с IP
        if ip in self.ip_history:
            recent_requests = [
                ts for ts in self.ip_history[ip]
                if current_time - ts < 3600  # 1 час
            ]
            if len(recent_requests) > self.max_orders_per_hour:
                return 0.9  # Высокий риск
        else:
            self.ip_history[ip] = []
        
        self.ip_history[ip].append(current_time)
        return 0.1  # Низкий риск
EOF

# requirements.txt
sudo tee requirements.txt > /dev/null <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.25.2
asyncpg==0.29.0
python-dotenv==1.0.1
python-telegram-bot==20.7
prometheus-client==0.19.0
aioredis==2.0.1
pydantic[email]==2.5.0
structlog==23.2.0
EOF

# Dockerfile (оптимизированный)
sudo tee Dockerfile > /dev/null <<'EOF'
FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r appuser && useradd -r -g appuser appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p /app/logs && chown -R appuser:appuser /app
COPY . /app/
WORKDIR /app
USER appuser

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# docker-compose.yml (приложение + мониторинг)
sudo tee docker-compose.yml > /dev/null <<'EOF'
services:
  db:
    image: postgres:15-alpine
    container_name: playwallet_db_v2
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    ports:
      - "127.0.0.1:5433:5432"
    volumes:
      - pgdata_v2:/var/lib/postgresql/data
      - ./sql/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    build: .
    container_name: playwallet_app_v2
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
    depends_on:
      db:
        condition: service_healthy
    env_file: .env
    volumes:
      - ./logs:/app/logs
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  topup:
    build: .
    container_name: playwallet_topup_v2
    restart: unless-stopped
    command: ["python", "app/auto_topup.py"]
    depends_on:
      app:
        condition: service_healthy
    env_file: .env
    volumes:
      - ./logs:/app/logs

  prometheus:
    image: prom/prometheus:latest
    container_name: playwallet_prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9090:9090"
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./monitoring/prometheus/alert_rules.yml:/etc/prometheus/alert_rules.yml:ro
      - prometheus_data:/prometheus

  grafana:
    image: grafana/grafana:latest
    container_name: playwallet_grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD:-admin}
    depends_on:
      - prometheus
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana/datasources:/etc/grafana/provisioning/datasources:ro
      - ./monitoring/grafana/dashboards:/etc/grafana/provisioning/dashboards:ro

volumes:
  pgdata_v2:
  prometheus_data:
  grafana_data:
EOF

sudo tee monitoring/prometheus/prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - alert_rules.yml

scrape_configs:
  - job_name: playwallet-app
    static_configs:
      - targets: ['app:8000']
    metrics_path: /metrics
    scrape_interval: 10s
EOF

sudo tee monitoring/prometheus/alert_rules.yml > /dev/null <<'EOF'
# Example alerting rules. Adjust thresholds to your production needs.
---
groups:
  - name: playwallet-alerts
    rules:
      - alert: PlayWalletAppDown
        expr: up{job="playwallet-app"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: PlayWallet API is down
          description: Prometheus has not scraped the FastAPI service successfully for 2 minutes.
EOF

sudo tee monitoring/grafana/datasources/datasource.yml > /dev/null <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF

sudo tee monitoring/grafana/dashboards/dashboards.yml > /dev/null <<'EOF'
apiVersion: 1
providers:
  - name: PlayWallet Dashboards
    folder: PlayWallet
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

sudo tee monitoring/grafana/dashboards/playwallet-overview.json > /dev/null <<'EOF'
{
  "id": null,
  "uid": "playwallet-overview",
  "title": "PlayWallet Overview",
  "timezone": "browser",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "30s",
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Requests per minute",
      "gridPos": { "h": 4, "w": 8, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total[1m]))",
          "legendFormat": "req/min"
        }
      ],
      "options": {
        "reduceOptions": { "calcs": ["sum"], "fields": "" },
        "orientation": "horizontal",
        "textMode": "value_and_name"
      }
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Request latency",
      "gridPos": { "h": 8, "w": 16, "x": 0, "y": 4 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "p95"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        },
        "overrides": []
      }
    }
  ],
  "templating": { "list": [] }
}
EOF

# 5. КОПИРОВАНИЕ ОСТАЛЬНЫХ ФАЙЛОВ ПРИЛОЖЕНИЯ
echo "Шаг 5: Копирование и адаптация файлов приложения..."

# Копируем и слегка адаптируем остальные файлы
sudo cp /opt/playwallet/app/config.py app/
sudo cp /opt/playwallet/app/db.py app/
sudo cp /opt/playwallet/app/services.py app/
sudo cp /opt/playwallet/app/routes.py app/
sudo cp /opt/playwallet/app/telegram_utils.py app/
sudo cp /opt/playwallet/app/auto_topup.py app/

# Копируем SQL схему
sudo cp /opt/playwallet/sql/init.sql sql/

# 6. ОБНОВЛЕНИЕ .ENV С НОВЫМИ НАСТРОЙКАМИ
echo "Шаг 6: Обновление конфигурации..."
sudo tee -a .env > /dev/null <<'EOF'

# ===== НОВЫЕ НАСТРОЙКИ V2 =====
FRAUD_DETECTION_ENABLED=true
MAX_RISK_SCORE=0.8
MAX_ORDERS_PER_IP_HOUR=10

RATE_LIMIT_ENABLED=true
API_RATE_LIMIT=30
CALLBACK_RATE_LIMIT=10

ENABLE_VIP_PROGRAM=true
VIP_THRESHOLD_ORDERS=10
VIP_COMMISSION_DISCOUNT=0.005

AUTO_BACKUP_ENABLED=true
BACKUP_RETENTION_DAYS=30
EOF

# 7. СОЗДАНИЕ СКРИПТОВ УПРАВЛЕНИЯ
echo "Шаг 7: Создание утилит..."

# Скрипт проверки здоровья
sudo tee health_check.sh > /dev/null <<'EOF'
#!/bin/bash
echo "=== Проверка PlayWallet v2 ==="

echo "Статус контейнеров:"
docker-compose ps

echo -e "\nПроверка API:"
curl -s http://localhost:8000/health | head -n 5

echo -e "\nПроверка БД:"
docker exec playwallet_db_v2 pg_isready -U postgres 2>/dev/null && echo "БД OK" || echo "БД недоступна"

echo -e "\nПоследние ошибки:"
tail -n 5 logs/app.log 2>/dev/null | grep -i error || echo "Ошибок не найдено"
EOF

# Скрипт переключения версий
sudo tee switch_version.sh > /dev/null <<'EOF'
#!/bin/bash
case "${1:-v2}" in
    "v1")
        echo "Переключение на v1..."
        cd /opt/playwallet-v2 && docker-compose down
        cd /opt/playwallet && docker-compose up -d
        ;;
    "v2")
        echo "Переключение на v2..."
        cd /opt/playwallet && docker-compose down 2>/dev/null || true
        cd /opt/playwallet-v2 && docker-compose up -d
        ;;
    *)
        echo "Использование: $0 {v1|v2}"
        exit 1
        ;;
esac
EOF

sudo chmod +x *.sh

# 8. ЗАПУСК НОВОЙ ВЕРСИИ
echo "Шаг 8: Запуск PlayWallet v2..."
sudo docker-compose build
sudo docker-compose up -d

# 9. ОЖИДАНИЕ ЗАПУСКА И ПРОВЕРКА
echo "Шаг 9: Проверка работоспособности..."
sleep 30

if curl -f http://localhost:8000/health > /dev/null 2>&1; then
    echo "✅ PlayWallet v2 запущен успешно!"
    echo ""
    echo "📋 ИНФОРМАЦИЯ О СИСТЕМЕ:"
    echo "• Основной API: http://localhost:8000"
    echo "• База данных: localhost:5433"
    echo "• Документация: https://arieco.shop/docs (после обновления Nginx)"
    echo "• Логи: /opt/playwallet-v2/logs/"
    echo ""
    echo "🔧 КОМАНДЫ УПРАВЛЕНИЯ:"
    echo "• Проверка: /opt/playwallet-v2/health_check.sh"
    echo "• Переключение: /opt/playwallet-v2/switch_version.sh v1|v2"
    echo "• Логи: docker-compose logs -f app"
    echo "• Рестарт: docker-compose restart"
    echo ""
    echo "⚠️ СЛЕДУЮЩИЕ ШАГИ:"
    echo "1. Протестируйте API: curl http://localhost:8000/balance"
    echo "2. Проверьте admin статистику: curl 'http://localhost:8000/admin/stats?secret=topup123super'"
    echo "3. Убедитесь, что Nginx проксирует на порт 8000"
    echo "4. Сделайте тестовый платеж для проверки callback"
    echo ""
    echo "Резервная копия старой версии: /opt/playwallet-backup-*"
else
    echo "❌ Ошибка запуска!"
    echo "Логи приложения:"
    sudo docker-compose logs app | tail -20
    echo ""
    echo "Для отката на старую версию:"
    echo "./switch_version.sh v1"
fi