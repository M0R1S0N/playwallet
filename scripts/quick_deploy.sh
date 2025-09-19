#!/bin/bash
set -euo pipefail

DOMAIN="arieco.shop"
PROJECT_DIR="/opt/playwallet-v2"

echo "Быстрое развертывание PlayWallet v2..."

# Проверяем что находимся в правильной директории
if [ ! -f "docker-compose.yml" ]; then
    echo "Ошибка: запустите из директории с docker-compose.yml"
    exit 1
fi

# Останавливаем старую версию если запущена
if [ -d "/opt/playwallet" ]; then
    echo "Остановка старой версии..."
    cd /opt/playwallet && docker-compose down 2>/dev/null || true
fi

cd $PROJECT_DIR

# Собираем и запускаем новую версию
echo "Сборка контейнеров..."
docker-compose build --no-cache

echo "Запуск сервисов..."
docker-compose up -d

# Ждем запуска
echo "Ожидание готовности сервисов..."
sleep 30

# Проверяем статус
if curl -f http://localhost:8001/health > /dev/null 2>&1; then
    echo "✅ Сервис запущен успешно!"
    echo "🌐 API: http://localhost:8001"
    echo "📊 Grafana: http://localhost:3000"
    echo "📈 Prometheus: http://localhost:9090"
    echo "📖 Docs: https://$DOMAIN/docs"
else
    echo "❌ Сервис не отвечает"
    echo "Логи приложения:"
    docker-compose logs app
fi