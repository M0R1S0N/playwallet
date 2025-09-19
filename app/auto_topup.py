import os, sys, time, hmac, json, httpx, hashlib, asyncio, logging
from logging.handlers import RotatingFileHandler
from dotenv import load_dotenv
from telegram import Bot

load_dotenv()

# -------- PlayWallet PROD/DEV --------
PW_USE_PROD   = os.getenv("PW_USE_PROD", "true").lower() == "true"
PW_DEV_URL    = os.getenv("PW_DEV_URL", "").rstrip("/")
PW_DEV_TOKEN  = os.getenv("PW_DEV_TOKEN", "")
PW_PROD_URL   = os.getenv("PW_PROD_URL", "").rstrip("/")
PW_PROD_TOKEN = os.getenv("PW_PROD_TOKEN", "")

PW_BASE   = PW_PROD_URL if PW_USE_PROD else PW_DEV_URL
PW_TOKEN  = PW_PROD_TOKEN if PW_USE_PROD else PW_DEV_TOKEN

BYBIT_API_KEY    = os.getenv("BYBIT_API_KEY")
BYBIT_API_SECRET = os.getenv("BYBIT_API_SECRET")
BYBIT_UID        = os.getenv("BYBIT_UID")

MIN_PW_BALANCE = float(os.getenv("MIN_PW_BALANCE", 60))
TOPUP_AMOUNT   = float(os.getenv("TOPUP_AMOUNT", 120))

TG_TOKEN   = os.getenv("TG_BOT_TOKEN")
TG_CHAT_ID = os.getenv("TG_CHAT_ID")

CHECK_INTERVAL_SEC = int(os.getenv("TOPUP_CHECK_INTERVAL", "600"))
DRY_RUN = os.getenv("TOPUP_DRY_RUN", "false").lower() == "true"
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

# ---------- logging ----------
LOG_DIR = os.getenv("LOG_DIR", "/app/logs")
LOG_PATH = os.path.join(LOG_DIR, "auto_topup.log")

logger = logging.getLogger("auto_topup")
logger.setLevel(LOG_LEVEL)

handlers: list[logging.Handler] = []

try:
    os.makedirs(LOG_DIR, exist_ok=True)
    file_handler = RotatingFileHandler(
        LOG_PATH,
        maxBytes=5_000_000,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s | %(levelname)s | %(message)s", "%Y-%m-%d %H:%M:%S")
    )
    handlers.append(file_handler)
except (OSError, PermissionError) as exc:
    sys.stderr.write(
        f"[auto_topup] Unable to open log file '{LOG_PATH}': {exc}. Falling back to stdout only.\n"
    )

stream_handler = logging.StreamHandler()
stream_handler.setFormatter(
    logging.Formatter("%(asctime)s | %(levelname)s | %(message)s", "%Y-%m-%d %H:%M:%S")
)
handlers.append(stream_handler)

if not logger.handlers:
    for handler in handlers:
        logger.addHandler(handler)

bot = Bot(token=TG_TOKEN)

# ---------- helpers ----------

async def get_pw_balance() -> float:
    """Получить баланс PlayWallet через API"""
    url = f"{PW_BASE}/get-balance/"
    headers = {"pw-api-key": PW_TOKEN}
    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.get(url, headers=headers)
        r.raise_for_status()
        data = r.json()
        logger.info(f"PW raw response: {data}")  # логируем всё
        balance_str = (data.get("data") or {}).get("balance", "0")
        try:
            return float(balance_str)
        except Exception:
            logger.warning(f"Не смогли распарсить баланс: {balance_str}")
            return 0.0


def sign_bybit(payload: dict | None = None, query: str = "") -> dict:
    """
    Универсальная подпись для Bybit v5.
    Для GET с query: передаём строку query (например, "accountType=UNIFIED").
    Для POST с телом: передаём payload.
    """
    ts = str(int(time.time() * 1000))
    if query:  # GET
        sign_str = f"{ts}{BYBIT_API_KEY}5000{query}"
    else:      # POST
        body = json.dumps(payload, separators=(',', ':')) if payload else ""
        sign_str = f"{ts}{BYBIT_API_KEY}5000{body}"

    sign = hmac.new(
        BYBIT_API_SECRET.encode(),
        sign_str.encode(),
        hashlib.sha256
    ).hexdigest()

    return {
        "X-BAPI-API-KEY": BYBIT_API_KEY,
        "X-BAPI-SIGN": sign,
        "X-BAPI-TIMESTAMP": ts,
        "X-BAPI-RECV-WINDOW": "5000",
        "Content-Type": "application/json",
    }


async def get_bybit_balance() -> float:
    query = "accountType=UNIFIED"
    url = f"https://api.bybit.com/v5/account/wallet-balance?{query}"
    headers = sign_bybit(query=query)
    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.get(url, headers=headers)
        r.raise_for_status()
        data = r.json()
        logger.info(f"Bybit raw response: {data}")
        try:
            coins = data["result"]["list"][0]["coin"]
            for coin in coins:
                if coin.get("coin") == "USDT":
                    return float(coin.get("walletBalance", 0))
        except Exception as e:
            logger.warning(f"Ошибка парсинга Bybit баланса: {e}")
            return 0.0
        return 0.0

async def transfer_usdt(amount: float) -> dict:
    """Внутренний перевод USDT по UID (Bybit v5)"""
    url = "https://api.bybit.com/v5/asset/transfer/inter-transfer"
    payload = {"transferType": 2, "coin": "USDT", "amount": str(amount), "toUserId": str(BYBIT_UID)}
    headers = sign_bybit(payload)
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.post(url, headers=headers, json=payload)
        r.raise_for_status()
        return r.json()


async def notify(text: str):
    if not TG_TOKEN or not TG_CHAT_ID:
        return
    try:
        await bot.send_message(chat_id=TG_CHAT_ID, text=text)
    except Exception as e:
        logger.warning(f"Telegram notify failed: {e}")


# ---------- main loop ----------
async def main_loop():
    logger.info(
        f"AutoTopUp started | MIN_PW_BALANCE={MIN_PW_BALANCE} | "
        f"TOPUP_AMOUNT={TOPUP_AMOUNT} | interval={CHECK_INTERVAL_SEC}s | dry_run={DRY_RUN}"
    )
    await notify("🔄 Автопополнение запущено")

    while True:
        try:
            pw  = await get_pw_balance()
            byb = await get_bybit_balance()
            logger.info(f"Check balances | PW={pw:.2f} USD | Bybit={byb:.2f} USDT")

            if pw < MIN_PW_BALANCE:
                if byb >= TOPUP_AMOUNT:
                    if DRY_RUN:
                        logger.info(f"[DRY RUN] Would transfer {TOPUP_AMOUNT} USDT → UID {BYBIT_UID}")
                        await notify(f"🧪 DRY RUN: PW={pw:.2f}$ < {MIN_PW_BALANCE}$, Bybit={byb:.2f} USDT")
                    else:
                        resp = await transfer_usdt(TOPUP_AMOUNT)
                        logger.info(f"Transfer OK | amount={TOPUP_AMOUNT} | resp={resp}")
                        await notify(
                            f"⚡ Автопополнение: отправлено {TOPUP_AMOUNT} USDT на UID {BYBIT_UID}\n"
                            f"📊 Балансы: PW={pw:.2f}$ | Bybit={byb:.2f} USDT\nОтвет: {resp}"
                        )
                else:
                    logger.warning(f"Need {TOPUP_AMOUNT} USDT, but Bybit={byb:.2f}")
                    await notify(
                        f"⚠️ Нужен перевод {TOPUP_AMOUNT} USDT, но на Bybit только {byb:.2f} USDT.\n"
                        f"PW={pw:.2f}$ < {MIN_PW_BALANCE}$"
                    )
            else:
                logger.info("Topup not required")
        except httpx.HTTPStatusError as e:
            logger.exception(f"HTTP error: {e.response.status_code} {e.response.text}")
            await notify(f"❌ HTTP ошибка автопополнения: {e.response.status_code} {e.response.text}")
        except Exception as e:
            logger.exception(f"Unexpected error: {e}")
            await notify(f"❌ Ошибка автопополнения: {e}")

        await asyncio.sleep(CHECK_INTERVAL_SEC)


if __name__ == "__main__":
    try:
        asyncio.run(main_loop())
    except KeyboardInterrupt:
        logger.info("AutoTopUp stopped by user")
