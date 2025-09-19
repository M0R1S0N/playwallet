import time
from typing import Dict, List, Tuple
from datetime import datetime
import asyncio

class RateLimiter:
    def __init__(self):
        self.requests: Dict[str, List[float]] = {}
        self.limits = {
            'order_creation': (5, 300),    # 5 заказов за 5 минут
            'callback': (20, 300),         # 20 callback'ов за 5 минут
            'admin': (50, 300),            # 50 admin запросов за 5 минут
        }
    
    async def allow_request(self, key: str, action: str) -> bool:
        """Проверка лимита запросов"""
        if action not in self.limits:
            return True
        
        max_requests, window_seconds = self.limits[action]
        current_time = time.time()
        
        # Создаем уникальный ключ для комбинации IP + действие
        rate_key = f"{key}:{action}"
        
        # Очищаем старые запросы
        if rate_key in self.requests:
            self.requests[rate_key] = [
                timestamp for timestamp in self.requests[rate_key]
                if current_time - timestamp < window_seconds
            ]
        else:
            self.requests[rate_key] = []
        
        # Проверяем лимит
        if len(self.requests[rate_key]) >= max_requests:
            return False
        
        # Добавляем текущий запрос
        self.requests[rate_key].append(current_time)
        return True
