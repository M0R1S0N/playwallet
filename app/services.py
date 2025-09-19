import httpx
import hashlib
from uuid import UUID
from datetime import datetime
from .config import (
    PW_USE_PROD,
    PW_DEV_URL,
    PW_DEV_TOKEN,
    PW_PROD_URL,
    PW_PROD_TOKEN,
    PW_FORCE_IPV4,
)

BASE_URL = (PW_PROD_URL if PW_USE_PROD else PW_DEV_URL).rstrip("/")
TOKEN = PW_PROD_TOKEN if PW_USE_PROD else PW_DEV_TOKEN
HEADERS = {"pw-api-key": TOKEN}

def _client_kwargs():
    timeout = httpx.Timeout(10.0, read=10.0)
    kw = {"timeout": timeout, "follow_redirects": True}
    if PW_FORCE_IPV4:
        kw["transport"] = httpx.AsyncHTTPTransport(local_address="0.0.0.0")
    return kw

# -----------------------------
# API calls
# -----------------------------

async def get_balance():
    async with httpx.AsyncClient(**_client_kwargs()) as client:
        r = await client.get(f"{BASE_URL}/get-balance", headers=HEADERS)
        r.raise_for_status()
        return r.json()

async def create_order(*, external_id: str, service_id: str, amount: float, login: str):
    payload = {
        "externalId": str(external_id),
        "serviceId": str(service_id),
        "amount": f"{amount:.2f}",
        "login": login,
    }
    async with httpx.AsyncClient(**_client_kwargs()) as client:
        r = await client.post(f"{BASE_URL}/create-order/", json=payload, headers=HEADERS)
        r.raise_for_status()
        return r.json()

def _pay_token(order_id: str, created_datetime: str) -> str:
    return hashlib.sha512(f"{order_id}{created_datetime}".encode()).hexdigest()

async def pay_order(order_id, external_id, created_datetime):
    if isinstance(order_id, UUID):
        order_id = str(order_id)
    if isinstance(external_id, UUID):
        external_id = str(external_id)
    if isinstance(created_datetime, datetime):
        created_datetime = created_datetime.isoformat()

    payload = {"id": order_id, "externalId": external_id, "token": _pay_token(order_id, created_datetime)}
    async with httpx.AsyncClient(**_client_kwargs()) as client:
        r = await client.post(f"{BASE_URL}/pay-order/", json=payload, headers=HEADERS)
        r.raise_for_status()
        return r.json()

async def get_order(order_id: str):
    async with httpx.AsyncClient(**_client_kwargs()) as client:
        r = await client.get(f"{BASE_URL}/get-order/{order_id}", headers=HEADERS)
        r.raise_for_status()
        return r.json()

async def get_order_list(offset: int, limit: int):
    async with httpx.AsyncClient(**_client_kwargs()) as client:
        r = await client.get(
            f"{BASE_URL}/get-order-list/",
            params={"offset": offset, "limit": limit},
            headers=HEADERS,
        )
        r.raise_for_status()
        return r.json()

async def get_usd_rate(currency: str) -> float:
    if currency.upper() == "USD":
        return 1.0
    url = f"https://api.frankfurter.app/latest?from={currency.upper()}&to=USD"
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(url)
            r.raise_for_status()
            data = r.json()
            return float(data["rates"]["USD"])
    except Exception:
        return 1.0
