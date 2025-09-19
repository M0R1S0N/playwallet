from contextlib import asynccontextmanager
import logging

from fastapi import FastAPI

from .db import init_pool, close_pool
from .metrics import MetricsMiddleware, router as metrics_router
from .routes import router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(name)s:%(lineno)d - %(message)s"
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    print("🚀 Starting PlayWallet v2.0...")
    await init_pool()
    yield
    await close_pool()
    print("🛑 PlayWallet stopped")

app = FastAPI(
    title="PlayWallet API v2.0",
    description="Автоматическое пополнение Steam с защитой от мошенничества",
    version="2.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

app.add_middleware(MetricsMiddleware)
app.include_router(metrics_router)
app.include_router(router)
