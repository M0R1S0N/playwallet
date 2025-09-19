import asyncpg
from datetime import datetime
from .config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD

pool: asyncpg.Pool | None = None


async def init_pool():
    """Инициализация пула соединений"""
    global pool
    pool = await asyncpg.create_pool(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )


async def close_pool():
    """Закрытие пула соединений"""
    global pool
    if pool:
        await pool.close()
        pool = None


async def get_conn():
    """Получить соединение из пула"""
    if pool is None:
        raise RuntimeError("Connection pool has not been initialised")
    return await pool.acquire()


async def release_conn(conn):
    """Вернуть соединение в пул"""
    if pool is None:
        return
    await pool.release(conn)


async def ping() -> None:
    """Проверить доступность базы данных."""

    conn = None
    try:
        conn = await get_conn()
        await conn.execute("SELECT 1")
    finally:
        if conn is not None:
            await release_conn(conn)


async def insert_order(conn, **kwargs):
    """Вставить новый заказ в таблицу orders"""

    # ⚡️ Преобразуем created_datetime в datetime, если это строка
    created_dt = kwargs.get("created_datetime")
    if isinstance(created_dt, str):
        try:
            created_dt = datetime.fromisoformat(created_dt)
        except ValueError:
            created_dt = None

    await conn.execute(
        """
        INSERT INTO orders (
            id, external_id, login, service_id,
            amount, status, created_datetime
        )
        VALUES ($1,$2,$3,$4,$5,$6,$7)
        ON CONFLICT (id) DO NOTHING
        """,
        kwargs["id"],
        kwargs["external_id"],
        kwargs["login"],
        kwargs["service_id"],
        kwargs["amount"],
        kwargs["status"],
        created_dt
    )


async def update_order_status(conn, id: str, status: str):
    """Обновить статус заказа по ID"""
    await conn.execute(
        "UPDATE orders SET status=$1 WHERE id=$2",
        status, id
    )


async def get_order_by_id(conn, id: str):
    """Получить заказ по ID"""
    row = await conn.fetchrow("SELECT * FROM orders WHERE id=$1", id)
    return dict(row) if row else None


async def get_orders(conn, offset: int = 0, limit: int = 10):
    """Получить список заказов с пагинацией"""
    rows = await conn.fetch(
        "SELECT * FROM orders ORDER BY created_datetime DESC OFFSET $1 LIMIT $2",
        offset, limit
    )
    return [dict(r) for r in rows]
