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
