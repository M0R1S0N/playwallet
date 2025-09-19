CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,           -- ID заказа в PlayWallet
    external_id TEXT,              -- внешний ID (Plati id/inv/код)
    login TEXT,                    -- логин Steam
    service_id TEXT,
    amount NUMERIC,                -- сумма, отправленная в PlayWallet (USD)
    status TEXT,                   -- статус (created/paid/...)
    created_at TIMESTAMP DEFAULT NOW(),
    created_datetime TIMESTAMP     -- точное время из PlayWallet (ISO → TIMESTAMP)
);

-- Индексы для быстрых выборок
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders (created_at);
CREATE INDEX IF NOT EXISTS idx_orders_created_dt ON orders (created_datetime);
CREATE INDEX IF NOT EXISTS idx_orders_external_id ON orders (external_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
