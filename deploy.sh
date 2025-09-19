#!/bin/bash
# deploy.sh - Основной скрипт развертывания

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для логирования
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Проверка root прав
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Не запускайте этот скрипт от root!"
        exit 1
    fi
}

# Проверка зависимостей
check_dependencies() {
    log_info "Проверка зависимостей..."
    
    local deps=("docker" "docker-compose" "git" "curl" "ufw")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "$dep не установлен"
            exit 1
        fi
    done
    
    log_success "Все зависимости установлены"
}

# Настройка файрвола
setup_firewall() {
    log_info "Настройка файрвола..."
    
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # SSH
    sudo ufw allow ssh
    
    # HTTP/HTTPS
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    
    # Мониторинг (только с localhost)
    sudo ufw allow from 127.0.0.1 to any port 3000  # Grafana
    sudo ufw allow from 127.0.0.1 to any port 9090  # Prometheus
    
    sudo ufw --force enable
    log_success "Файрвол настроен"
}

# Настройка SSL сертификатов
setup_ssl() {
    local domain=${1:-"yourdomain.com"}
    
    log_info "Настройка SSL для домена: $domain"
    
    # Установка certbot
    sudo apt update
    sudo apt install -y certbot python3-certbot-nginx
    
    # Получение сертификата
    sudo certbot --nginx -d "$domain" --non-interactive --agree-tos --email "admin@$domain"
    
    # Автообновление
    echo "0 12 * * * /usr/bin/certbot renew --quiet" | sudo crontab -
    
    log_success "SSL настроен для $domain"
}

# Оптимизация системы
optimize_system() {
    log_info "Оптимизация системы..."
    
    # Настройка sysctl для высокой нагрузки
    sudo tee /etc/sysctl.d/99-playwallet.conf > /dev/null <<EOF
# Network optimizations
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10

# File descriptors
fs.file-max = 2097152
fs.nr_open = 1048576

# PostgreSQL optimizations
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
EOF

    sudo sysctl -p /etc/sysctl.d/99-playwallet.conf
    
    # Увеличение лимитов файлов
    sudo tee /etc/security/limits.d/99-playwallet.conf > /dev/null <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

    log_success "Система оптимизирована"
}

# Создание директорий
create_directories() {
    log_info "Создание директорий..."
    
    mkdir -p {logs,ssl,nginx,monitoring,backups,uploads}
    mkdir -p monitoring/{prometheus,grafana,alertmanager}
    mkdir -p nginx/{sites-available,sites-enabled}
    
    log_success "Директории созданы"
}

# Генерация конфигурации Nginx
generate_nginx_config() {
    local domain=${1:-"yourdomain.com"}
    
    log_info "Генерация конфигурации Nginx..."
    
    cat > nginx/sites-available/playwallet <<EOF
# Upstream backend servers
upstream backend {
    server app:8000 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

# Rate limiting zones
limit_req_zone \$binary_remote_addr zone=api:10m rate=30r/m;
limit_req_zone \$binary_remote_addr zone=callback:10m rate=10r/m;
limit_req_zone \$binary_remote_addr zone=admin:10m rate=100r/m;

# Cache zone for static content
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=static_cache:10m max_size=100m inactive=60m use_temp_path=off;

server {
    listen 80;
    server_name $domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types
        application/json
        text/plain
        text/css
        application/javascript
        text/xml
        application/xml
        application/xml+rss
        text/javascript;

    # Request size limits
    client_max_body_size 5M;
    client_body_timeout 10s;
    client_header_timeout 10s;

    # Callback endpoint (highest security)
    location /plati/callback {
        limit_req zone=callback burst=5 nodelay;
        
        # Block known bad IPs (update as needed)
        # deny 192.0.2.0/24;
        
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
        proxy_connect_timeout 10s;
    }

    # Admin endpoints (IP restricted)
    location /admin/ {
        limit_req zone=admin burst=10 nodelay;
        
        # Restrict to admin IPs only
        allow 192.168.1.0/24;  # Local network
        allow 10.0.0.0/8;      # VPN range
        deny all;
        
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # API endpoints
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Enable caching for read-only endpoints
        proxy_cache static_cache;
        proxy_cache_valid 200 1m;
        proxy_cache_key "$scheme$request_method$host$request_uri";
    }

    # Health check (no rate limit, no logging)
    location /health {
        access_log off;
        proxy_pass http://backend;
        proxy_connect_timeout 1s;
        proxy_read_timeout 3s;
    }

    # Metrics endpoint (localhost only)
    location /metrics {
        allow 127.0.0.1;
        deny all;
        proxy_pass http://backend;
    }

    # Default location
    location / {
        limit_req zone=api burst=10 nodelay;
        
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Connection keep-alive
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }

    # Static files (if any)
    location /static/ {
        alias /app/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Deny access to sensitive files
    location ~ /\\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    log_success "Конфигурация Nginx создана для $domain"
}

# Генерация .env файла
generate_env_file() {
    log_info "Генерация .env файла..."
    
    # Генерация случайных паролей
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    ADMIN_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)

    cat > .env <<EOF
# Database Configuration
DB_HOST=db
DB_PORT=5432
DB_NAME=playwallet
DB_USER=postgres
DB_PASSWORD=$DB_PASSWORD

# PlayWallet API Configuration
PW_USE_PROD=true
PW_FORCE_IPV4=false
PW_DEV_URL=
PW_DEV_TOKEN=
PW_PROD_URL=https://api.playwallet.bot
PW_PROD_TOKEN=your_playwallet_token_here

# Bybit API Configuration (for auto-topup)
BYBIT_API_KEY=your_bybit_api_key_here
BYBIT_API_SECRET=your_bybit_api_secret_here
BYBIT_UID=your_bybit_uid_here

# Digiseller API Configuration
DIGISELLER_SELLER_ID=your_digiseller_id_here
DIGISELLER_API_KEY=your_digiseller_api_key_here

# Telegram Bot Configuration
TG_BOT_TOKEN=your_telegram_bot_token_here
TG_CHAT_ID=your_telegram_chat_id_here

# Business Configuration
DEFAULT_SERVICE_ID=your_default_service_id
COMMISSION_RATE=0.06
MIN_SEND_USD=0.25
MIN_PW_BALANCE=60
TOPUP_AMOUNT=120

# System Configuration
ADMIN_SECRET=$ADMIN_SECRET
LOG_LEVEL=INFO
TOPUP_CHECK_INTERVAL=600
TOPUP_DRY_RUN=false

# Monitoring
GRAFANA_PASSWORD=$GRAFANA_PASSWORD

# Rate Limiting
MAX_ORDERS_PER_IP_PER_HOUR=10
MAX_CALLBACKS_PER_IP_PER_HOUR=50
EOF

    chmod 600 .env
    log_success ".env файл создан (не забудьте заполнить API ключи!)"
}

# Создание службы systemd для мониторинга
create_systemd_service() {
    log_info "Создание systemd службы..."
    
    sudo tee /etc/systemd/system/playwallet.service > /dev/null <<EOF
[Unit]
Description=PlayWallet Steam Auto-Topup Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$(pwd)
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0
User=$USER
Group=docker

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable playwallet.service
    
    log_success "Systemd служба создана и включена"
}

# Функция резервного копирования
setup_backups() {
    log_info "Настройка автоматических резервных копий..."
    
    mkdir -p backups/{db,logs,configs}
    
    # Скрипт резервного копирования
    cat > backup.sh <<'EOF'
#!/bin/bash

BACKUP_DIR="./backups"
DATE=$(date +%Y%m%d_%H%M%S)
DB_CONTAINER="playwallet_db"

# Database backup
docker exec $DB_CONTAINER pg_dump -U postgres playwallet | gzip > "$BACKUP_DIR/db/playwallet_$DATE.sql.gz"

# Logs backup
tar -czf "$BACKUP_DIR/logs/logs_$DATE.tar.gz" logs/

# Config backup
tar -czf "$BACKUP_DIR/configs/configs_$DATE.tar.gz" .env docker-compose.yml nginx/

# Cleanup old backups (keep 30 days)
find $BACKUP_DIR -type f -name "*.gz" -mtime +30 -delete

echo "Backup completed: $DATE"
EOF

    chmod +x backup.sh
    
    # Добавление в crontab
    (crontab -l 2>/dev/null; echo "0 2 * * * $(pwd)/backup.sh") | crontab -
    
    log_success "Автоматические резервные копии настроены (каждый день в 2:00)"
}

# Создание мониторинга логов
setup_log_monitoring() {
    log_info "Настройка мониторинга логов..."
    
    cat > monitor_logs.sh <<'EOF'
#!/bin/bash

LOG_FILE="logs/app.log"
ALERT_KEYWORDS=("ERROR" "CRITICAL" "FRAUD" "FAILED")
TG_TOKEN=${TG_BOT_TOKEN}
TG_CHAT=${TG_CHAT_ID}

if [ ! -f "$LOG_FILE" ]; then
    exit 0
fi

# Check for critical errors in last 5 minutes
for keyword in "${ALERT_KEYWORDS[@]}"; do
    count=$(tail -n 1000 "$LOG_FILE" | grep -c "$keyword" || true)
    if [ "$count" -gt 5 ]; then
        message="🚨 Обнаружено $count экземпляров '$keyword' в логах за последние 5 минут"
        curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
             -d "chat_id=$TG_CHAT" \
             -d "text=$message" > /dev/null
    fi
done
EOF

    chmod +x monitor_logs.sh
    
    # Добавление в crontab для запуска каждые 5 минут
    (crontab -l 2>/dev/null; echo "*/5 * * * * $(pwd)/monitor_logs.sh") | crontab -
    
    log_success "Мониторинг логов настроен"
}

# Установка и настройка fail2ban
setup_fail2ban() {
    log_info "Настройка fail2ban..."
    
    sudo apt install -y fail2ban
    
    # Конфигурация для нашего приложения
    sudo tee /etc/fail2ban/jail.d/playwallet.conf > /dev/null <<EOF
[playwallet-api]
enabled = true
port = 80,443
protocol = tcp
filter = playwallet-api
logpath = $(pwd)/logs/nginx/access.log
maxretry = 10
bantime = 3600
findtime = 600

[playwallet-fraud]
enabled = true
port = 80,443
protocol = tcp
filter = playwallet-fraud
logpath = $(pwd)/logs/app.log
maxretry = 3
bantime = 86400
findtime = 3600
EOF

    # Фильтр для API
    sudo tee /etc/fail2ban/filter.d/playwallet-api.conf > /dev/null <<EOF
[Definition]
failregex = ^<HOST> .* "(GET|POST) .* HTTP/.*" (4[0-9][0-9]|5[0-9][0-9]) .*$
ignoreregex = ^<HOST> .* "(GET|POST) /health.* HTTP/.*" (2[0-9][0-9]) .*$
EOF

    # Фильтр для мошенничества
    sudo tee /etc/fail2ban/filter.d/playwallet-fraud.conf > /dev/null <<EOF
[Definition]
failregex = FRAUD ALERT.*IP <HOST>
ignoreregex =
EOF

    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    
    log_success "fail2ban настроен и запущен"
}

# Проверка работоспособности
health_check() {
    log_info "Проверка работоспособности системы..."
    
    # Проверка контейнеров
    if ! docker-compose ps | grep -q "Up"; then
        log_error "Не все контейнеры запущены"
        return 1
    fi
    
    # Проверка API
    if ! curl -s -f http://localhost/health > /dev/null; then
        log_error "API не отвечает"
        return 1
    fi
    
    # Проверка базы данных
    if ! docker exec playwallet_db pg_isready -U postgres > /dev/null; then
        log_error "База данных недоступна"
        return 1
    fi
    
    log_success "Все системы работают нормально"
}

# Основная функция развертывания
main() {
    local domain=${1:-"yourdomain.com"}
    
    log_info "Запуск развертывания PlayWallet для домена: $domain"
    
    check_root
    check_dependencies
    
    create_directories
    generate_env_file
    generate_nginx_config "$domain"
    
    optimize_system
    setup_firewall
    
    # Создание и запуск контейнеров
    log_info "Сборка и запуск контейнеров..."
    docker-compose build --no-cache
    docker-compose up -d
    
    # Ждем запуска служб
    log_info "Ожидание запуска служб..."
    sleep 30
    
    setup_ssl "$domain"
    create_systemd_service
    setup_backups
    setup_log_monitoring
    setup_fail2ban
    
    # Финальная проверка
    sleep 10
    if health_check; then
        log_success "Развертывание завершено успешно!"
        log_info "Не забудьте:"
        log_info "1. Заполнить API ключи в .env файле"
        log_info "2. Перезапустить сервисы: docker-compose restart"
        log_info "3. Проверить Grafana: http://$domain:3000"
        log_info "4. Настроить DNS для домена $domain"
    else
        log_error "Развертывание завершено с ошибками"
        exit 1
    fi
}

# Дополнительные команды
case "${1:-deploy}" in
    "deploy")
        main "${2:-yourdomain.com}"
        ;;
    "update")
        log_info "Обновление системы..."
        git pull
        docker-compose build --no-cache
        docker-compose up -d
        health_check
        ;;
    "backup")
        ./backup.sh
        ;;
    "restore")
        if [ -z "${2:-}" ]; then
            log_error "Укажите файл резервной копии"
            exit 1
        fi
        log_info "Восстановление из $2..."
        gunzip -c "$2" | docker exec -i playwallet_db psql -U postgres playwallet
        ;;
    "logs")
        docker-compose logs -f "${2:-app}"
        ;;
    "stats")
        docker stats
        ;;
    "health")
        health_check
        ;;
    *)
        echo "Использование: $0 {deploy|update|backup|restore|logs|stats|health} [параметры]"
        exit 1
        ;;
esac