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
