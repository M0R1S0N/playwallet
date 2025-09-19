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
