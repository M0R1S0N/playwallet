import os
from dotenv import load_dotenv

load_dotenv()

PW_USE_PROD = os.getenv("PW_USE_PROD", "false").lower() == "true"
PW_FORCE_IPV4 = os.getenv("PW_FORCE_IPV4", "false").lower() == "true"
PW_DEV_URL = os.getenv("PW_DEV_URL")
PW_DEV_TOKEN = os.getenv("PW_DEV_TOKEN")
PW_PROD_URL = os.getenv("PW_PROD_URL")
PW_PROD_TOKEN = os.getenv("PW_PROD_TOKEN")

DB_HOST = os.getenv("DB_HOST")
DB_PORT = int(os.getenv("DB_PORT", 5432))
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")

TG_BOT_TOKEN = os.getenv("TG_BOT_TOKEN")
TG_CHAT_ID = os.getenv("TG_CHAT_ID")

DEFAULT_SERVICE_ID = os.getenv("DEFAULT_SERVICE_ID")

# ---- Новые настройки комиссий ----
def _to_float(env_name: str, default: float) -> float:
    try:
        return float(os.getenv(env_name, default))
    except Exception:
        return default

# 0.06 = 6%
COMMISSION_RATE = _to_float("COMMISSION_RATE", 0.06)
# Минимальная сумма, которую отправляем в PlayWallet (USD)
MIN_SEND_USD = _to_float("MIN_SEND_USD", 0.25)
