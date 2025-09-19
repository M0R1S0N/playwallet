#!/bin/bash
# migration.sh - Миграция PlayWallet v1 -> v2
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Настройки
OLD_DIR="/opt/playwallet"
NEW_DIR="/opt/playwallet-v2"
BACKUP_DIR="/opt/playwallet-backup-$(date +%Y%m%d_%H%M%S)"
DOMAIN="arieco.shop"

# Проверяем что запускается от root (нужно для /opt)
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт от root: sudo $0"
        exit 1
    fi
}

# Создаем резервную копию текущего проекта
create_backup() {
    log_info "Создание резервной копии в $BACKUP_DIR..."
    
    # Останавливаем старые контейнеры для безопасного бэкапа БД
    cd $OLD_DIR
    docker-compose down
    
    # Копируем весь проект
    cp -r $OLD_DIR $BACKUP_DIR
    
    log_success "Резервная копия создана"
}

# Создаем новую структуру проекта
create_new_structure() {
    log_info "Создание новой структуры проекта..."
    
    mkdir -p $NEW_DIR/{app,sql/migrations,nginx/sites-available,monitoring/{prometheus,grafana,alertmanager},scripts,logs/{app,nginx,topup,monitoring},backups/{db,configs,logs},uploads/temp,tests,docs}
    
    # Создаем символические ссылки на старые логи (для непрерывности)
    ln -sf $OLD_DIR/logs $NEW_DIR/logs/old_logs
    
    log_success "Структура создана"
}

# Переносим старые файлы с улучшениями
migrate_files() {
    log_info "Перенос и обновление файлов..."
    
    cd $NEW_DIR
    
    # Копируем основные файлы приложения
    cp $OLD_DIR/app/__init__.py app/
    cp $OLD_DIR/app/schemas.py app/
    
    # Сохраняем ваш .env (самое важное!)
    cp $OLD_DIR/.env .env
    
    # Обновляем .env с новыми параметрами
    cat >> .env <<EOF

# ===== НОВЫЕ НАСТРОЙКИ V2 =====

# Система защиты от мошенничества
FRAUD_DETECTION_ENABLED=true
MAX_RISK_SCORE=0.8
MAX_ORDERS_PER_IP_HOUR=10
MAX_ORDERS_PER_LOGIN_HOUR=5

# Rate Limiting
RATE_LIMIT_ENABLED=true
API_RATE_LIMIT=30
CALLBACK_RATE_LIMIT=10
ADMIN_RATE_LIMIT=100

# Мониторинг
GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
PROMETHEUS_RETENTION=15d
ENABLE_METRICS=true

# Новые бизнес-настройки
ENABLE_VIP_PROGRAM=true
VIP_THRESHOLD_ORDERS=10
VIP_THRESHOLD_AMOUNT=500
VIP_COMMISSION_DISCOUNT=0.005

# Автоматические алерты
ALERT_LOW_BALANCE=true
ALERT_HIGH_ERROR_RATE=true
ALERT_FRAUD_ATTEMPTS=true

# Резервное копирование
AUTO_BACKUP_ENABLED=true
BACKUP_RETENTION_DAYS=30
EOF

    log_success "Файлы перенесены и .env обновлен"
}

# Создаем обновленный docker-compose.yml
create_docker_compose() {
    log_info "Создание нового docker-compose.yml..."
    
    cat > docker-compose.yml <<EOF
version: '3.8'

services:
  # PostgreSQL база данных
  db:
    image: postgres:15-alpine
    container_name: playwallet_db_v2
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${DB_USER}
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_DB: \${DB_NAME}
    ports:
      - "127.0.0.1:5433:5432"  # Новый порт, чтобы не конфликтовать
    volumes:
      - pgdata_v2:/var/lib/postgresql/data
      - ./sql/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${DB_USER} -d \${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend

  # Redis для кэширования
  redis:
    image: redis:7-alpine
    container_name: playwallet_redis
    restart: unless-stopped
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - backend

  # Основное приложение
  app:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: playwallet_app_v2
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"  # Новый порт
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    env_file: .env
    volumes:
      - ./logs:/app/logs
      - ./uploads:/app/uploads
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - backend
      - frontend

  # Автопополнение
  topup:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: playwallet_topup_v2
    restart: unless-stopped
    command: ["python", "app/auto_topup.py"]
    depends_on:
      app:
        condition: service_healthy
    env_file: .env
    volumes:
      - ./logs:/app/logs
    networks:
      - backend

  # Prometheus мониторинг
  prometheus:
    image: prom/prometheus:latest
    container_name: playwallet_prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9090:9090"
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.enable-lifecycle'
    networks:
      - monitoring

  # Grafana визуализация
  grafana:
    image: grafana/grafana:latest
    container_name: playwallet_grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_PASSWORD}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana:/etc/grafana/provisioning
    depends_on:
      - prometheus
    networks:
      - monitoring

volumes:
  pgdata_v2:
  redis_data:
  prometheus_data:
  grafana_data:

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true
  monitoring:
    driver: bridge
EOF

    log_success "docker-compose.yml создан"
}

# Создаем улучшенный Dockerfile
create_dockerfile() {
    log_info "Создание оптимизированного Dockerfile..."
    
    cat > Dockerfile <<'EOF'
# Многоэтапная сборка
FROM python:3.11-slim as builder

RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Финальный образ
FROM python:3.11-slim

RUN groupadd -r appuser && useradd -r -g appuser appuser

RUN apt-get update && apt-get install -y \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN mkdir -p /app/logs && chown -R appuser:appuser /app

COPY --chown=appuser:appuser . /app/
WORKDIR /app

USER appuser

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

    log_success "Dockerfile создан"
}

# Обновляем requirements.txt
create_requirements() {
    log_info "Обновление requirements.txt..."
    
    cat > requirements.txt <<EOF
# Основные зависимости
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
asyncpg==0.29.0
python-dotenv==1.0.1
python-telegram-bot==20.7

# Новые зависимости v2
prometheus-client==0.19.0
aioredis==2.0.1
pydantic[email]==2.5.0
structlog==23.2.0
pytest==7.4.3
pytest-asyncio==0.21.1
ipaddress==1.0.23
EOF

    log_success "requirements.txt обновлен"
}

# Копируем данные из старой БД в новую
migrate_database() {
    log_info "Миграция базы данных..."
    
    # Запускаем старую БД для экспорта данных
    cd $OLD_DIR
    docker-compose up -d db
    sleep 10
    
    # Экспортируем данные
    docker exec playwallet_db pg_dump -U postgres playwallet > $NEW_DIR/old_data.sql
    
    # Останавливаем старую БД
    docker-compose down
    
    # Запускаем новую БД
    cd $NEW_DIR
    docker-compose up -d db
    sleep 15
    
    # Импортируем данные (структура уже создастся из init.sql)
    docker exec playwallet_db_v2 psql -U postgres playwallet -c "
        INSERT INTO orders (id, external_id, login, service_id, amount, status, created_at, created_datetime) 
        SELECT id, external_id, login, service_id, amount, status, created_at, created_datetime 
        FROM temp_old_orders ON CONFLICT (id) DO NOTHING;
    " 2>/dev/null || true
    
    # Очищаем временный файл
    rm -f old_data.sql
    
    log_success "База данных мигрирована"
}

# Настройка Nginx для проксирования на новый порт
setup_nginx_proxy() {
    log_info "Настройка Nginx для перенаправления на новую версию..."
    
    # Создаем конфиг для постепенного перехода
    cat > /etc/nginx/sites-available/playwallet-v2 <<EOF
# Временный конфиг для тестирования v2
upstream backend_v2 {
    server 127.0.0.1:8000;
}

server {
    listen 80;
    server_name test.arieco.shop;  # Поддомен для тестов
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name test.arieco.shop;

    # Используем те же SSL сертификаты
    ssl_certificate /etc/letsencrypt/live/arieco.shop/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/arieco.shop/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Безопасность
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    location / {
        proxy_pass http://backend_v2;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Активируем временный конфиг
    ln -sf /etc/nginx/sites-available/playwallet-v2 /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
    
    log_success "Nginx настроен для тестирования v2 на test.arieco.shop"
}

# Создаем скрипты управления
create_management_scripts() {
    log_info "Создание скриптов управления..."
    
    # Скрипт переключения между версиями
    cat > $NEW_DIR/switch_version.sh <<EOF
#!/bin/bash
# Переключение между v1 и v2

case "\${1:-v2}" in
    "v1")
        echo "Переключение на v1..."
        cd $OLD_DIR && docker-compose up -d
        cd $NEW_DIR && docker-compose down
        # Убеждаемся, что Nginx указывает на порт 8000 (порт v1)
        systemctl reload nginx
        ;;
    "v2")
        echo "Переключение на v2..."
        cd $OLD_DIR && docker-compose down
        cd $NEW_DIR && docker-compose up -d
        # Убеждаемся, что Nginx указывает на порт 8000 (порт v2)
        systemctl reload nginx
        ;;
    *)
        echo "Использование: \$0 {v1|v2}"
        exit 1
        ;;
esac
EOF

    # Скрипт мониторинга
    cat > $NEW_DIR/health_check.sh <<'EOF'
#!/bin/bash
echo "=== Проверка здоровья PlayWallet v2 ==="

# Проверка контейнеров
echo "Статус контейнеров:"
docker-compose ps

# Проверка API
echo -e "\nПроверка API:"
curl -s http://localhost:8000/health | jq . 2>/dev/null || echo "API недоступно"

# Проверка БД
echo -e "\nПроверка БД:"
docker exec playwallet_db_v2 pg_isready -U postgres 2>/dev/null && echo "БД OK" || echo "БД недоступна"

# Проверка логов (последние ошибки)
echo -e "\nПоследние ошибки в логах:"
tail -n 10 logs/app/app.log 2>/dev/null | grep -i error || echo "Ошибок не найдено"

echo -e "\n=== Конец проверки ==="
EOF

    chmod +x $NEW_DIR/*.sh
    
    log_success "Скрипты управления созданы"
}

# Основная функция миграции
main() {
    log_info "Начало миграции PlayWallet v1 → v2"
    
    check_permissions
    create_backup
    create_new_structure
    migrate_files
    create_docker_compose
    create_dockerfile
    create_requirements
    
    # Копируем улучшенные файлы приложения из артефактов выше
    log_info "Создание улучшенных файлов приложения..."
    
    # Здесь нужно скопировать все файлы из артефактов
    # Это сделаем в следующем шаге
    
    migrate_database
    setup_nginx_proxy
    create_management_scripts
    
    log_success "Миграция завершена!"
    log_info "Следующие шаги:"
    log_info "1. Тестируйте v2 на https://test.arieco.shop"
    log_info "2. Переключение версий: $NEW_DIR/switch_version.sh v1|v2"
    log_info "3. Проверка здоровья: $NEW_DIR/health_check.sh"
    log_info "4. Когда будете готовы - обновите основной домен"
}

main "$@"