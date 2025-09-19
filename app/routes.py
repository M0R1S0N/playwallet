from fastapi import HTTPException, APIRouter, Request, Query, Response, status
import os, uuid, math, traceback, time, hashlib
from datetime import datetime
import httpx

from .services import get_balance, create_order, pay_order, get_usd_rate
from .db import get_conn, release_conn, insert_order, update_order_status, ping
from .telegram_utils import notify
from .config import DEFAULT_SERVICE_ID, COMMISSION_RATE, MIN_SEND_USD

router = APIRouter()
ADMIN_SECRET = os.getenv("ADMIN_SECRET")

DIGI_SELLER_ID = os.getenv("DIGISELLER_SELLER_ID")
DIGI_API_KEY = os.getenv("DIGISELLER_API_KEY")

_digi_token: str | None = None
_digi_token_expire: float = 0.0

def parse_created_dt(dt_str: str | None):
    try:
        return datetime.fromisoformat(dt_str) if dt_str else None
    except Exception:
        return None

@router.get("/")
async def root():
    return {"ok": True}


@router.get("/health", include_in_schema=False)
async def health_check():
    try:
        await ping()
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc))
    return {"status": "ok"}


@router.head("/health", include_in_schema=False)
async def health_check_head():
    await health_check()
    return Response(status_code=status.HTTP_200_OK)

# -------- PlayWallet balance proxy (для удобной проверки из браузера) --------
@router.get("/balance")
async def balance_route():
    data = await get_balance()
    # возвращаем как есть, но дублируем ключ balance
    return {"ok": True, **data}

# =================== Авторизация и токен Digiseller ===================
async def get_digiseller_token() -> str | None:
    global _digi_token, _digi_token_expire
    if _digi_token and time.time() < _digi_token_expire:
        return _digi_token

    ts = str(int(time.time() * 1000))
    sign = hashlib.sha256(f"{DIGI_API_KEY}{ts}".encode()).hexdigest()
    payload = {"seller_id": int(DIGI_SELLER_ID), "timestamp": ts, "sign": sign}

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.post("https://api.digiseller.com/api/apilogin", json=payload)
            data = r.json()
            if data.get("retval") == 0:
                _digi_token = data.get("token")
                _digi_token_expire = time.time() + 60 * 110
                return _digi_token
    except Exception:
        pass
    return None

# =================== Callback от Plati ===================
@router.get("/plati/callback")
async def plati_callback(
    uniquecode: str = Query(None),
    unique_code: str = Query(None),
    login: str = Query(None)
):
    code = unique_code or uniquecode
    if not code:
        raise HTTPException(400, "Не передан unique_code")

    token = await get_digiseller_token()
    if not token:
        raise HTTPException(500, "Нет токена Digiseller")

    try:
        url = f"https://api.digiseller.com/api/purchases/unique-code/{code}?token={token}"
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.get(url, headers={"Accept": "application/json"})
            data = r.json()
    except Exception as e:
        raise HTTPException(500, f"Ошибка проверки кода: {e}")

    if data.get("retval") != 0:
        raise HTTPException(400, f"Ошибка Digiseller: {data}")

    state = (data.get("unique_code_state") or {}).get("state")
    if state not in (2, 5):
        raise HTTPException(400, f"Код не готов к доставке (state={state})")

    # login из опций если не передан
    if not login:
        opts = data.get("options") or []
        login = (opts[0].get("value") if opts else None) or "unknown"

    amount_raw = float(data.get("amount", 0))
    currency = (data.get("type_curr") or "USD").upper()

    # дидемпотентность
    conn = await get_conn()
    try:
        exists = await conn.fetchrow("SELECT 1 FROM orders WHERE external_id=$1", code)
    finally:
        await release_conn(conn)
    if exists:
        return {"ok": True, "message": "Уже обработан"}

    try:
        await notify(f"⚙️ Новый платёж {code}\n{amount_raw} {currency} → {login}")

        rate = await get_usd_rate(currency)
        usd_before_fee = amount_raw * rate
        usd_after_fee = max(MIN_SEND_USD, math.floor(usd_before_fee * (1.0 - COMMISSION_RATE) * 100) / 100.0)

        resp = await create_order(
            external_id=code,
            service_id=DEFAULT_SERVICE_ID,
            amount=usd_after_fee,
            login=login
        )
        if resp.get("status") != "success" or not (d := resp.get("data")):
            await notify(f"⚠️ Не удалось создать заказ {code}: {resp}")
            raise HTTPException(500, "Не удалось создать заказ")

        created_dt = parse_created_dt(d.get("createdDateTime"))

        conn = await get_conn()
        try:
            await insert_order(conn, **{
                "id": d["id"],
                "external_id": d["externalId"],
                "login": login,
                "service_id": d["serviceId"],
                "amount": float(d["amount"]),
                "status": d["status"],
                "created_datetime": created_dt
            })
        finally:
            await release_conn(conn)

        pay_resp = await pay_order(
            order_id=d["id"],
            external_id=d["externalId"],
            created_datetime=created_dt
        )

        if pay_resp.get("status") == "success":
            conn = await get_conn()
            try:
                await update_order_status(conn, id=d["id"], status="paid")
            finally:
                await release_conn(conn)

            await notify(
                f"💰 Заказ {d['id']} оплачен\n"
                f"📥 Получено: {amount_raw:.2f} {currency}\n"
                f"💵 Отправлено: {usd_after_fee:.2f} USD\n"
                f"👤 {login}"
            )
        else:
            await notify(f"⚠️ Не удалось оплатить заказ {d['id']}: {pay_resp}")

    except Exception as e:
        tb = traceback.format_exc()
        await notify(f"❌ Ошибка при обработке {code}: {e}\n```{tb}```")
        raise

    return {"ok": True}

# =================== Admin Topup ===================
@router.post("/admin/topup")
async def admin_topup(
    request: Request,
    secret: str = Query(...),
    login: str = Query(...),
    amount: float = Query(...),
):
    if secret != ADMIN_SECRET:
        raise HTTPException(status_code=403, detail="Forbidden")

    resp = await create_order(
        external_id=f"manual_admin_{uuid.uuid4()}",
        service_id=DEFAULT_SERVICE_ID,
        amount=amount,
        login=login
    )

    if resp.get("status") == "success" and (d := resp.get("data")):
        created_dt = parse_created_dt(d.get("createdDateTime"))

        conn = await get_conn()
        try:
            await insert_order(conn, **{
                "id": d["id"],
                "external_id": d["externalId"],
                "login": login,
                "service_id": d["serviceId"],
                "amount": float(d["amount"]),
                "status": d["status"],
                "created_datetime": created_dt
            })
        finally:
            await release_conn(conn)

        pay_resp = await pay_order(
            order_id=d["id"],
            external_id=d["externalId"],
            created_datetime=created_dt
        )

        if pay_resp.get("status") == "success":
            conn = await get_conn()
            try:
                await update_order_status(conn, id=d["id"], status="paid")
            finally:
                await release_conn(conn)

            await notify(f"🛠 Админ пополнил Steam\n👤 {login}\n💵 {amount:.2f} USD (без комиссии)")
            return {"ok": True, "order_id": d["id"], "paid": True}

        return {"ok": True, "order_id": d["id"], "paid": False}

    return {"ok": False, "reason": resp}

# =================== Поиск заказа ===================
@router.get("/orders/find")
async def find_order(external_id: str):
    if not external_id:
        raise HTTPException(400, "Укажи external_id")

    conn = await get_conn()
    try:
        row = await conn.fetchrow("SELECT * FROM orders WHERE external_id = $1", external_id)
    finally:
        await release_conn(conn)

    if not row:
        raise HTTPException(404, "Заказ не найден")

    return dict(row)
