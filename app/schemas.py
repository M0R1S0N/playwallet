# -*- coding: utf-8 -*-
from __future__ import annotations
from pydantic import BaseModel, Field

class CreateOrderIn(BaseModel):
    external_id: str = Field(..., description="Your external order id")
    service_id: str | None = Field(None, description="PlayWallet service id (optional)")
    amount: float = Field(..., description="Amount in merchant currency, two decimals")
    login: str = Field(..., description="Steam login (or target account id)")

class GetOrderIn(BaseModel):
    order_id: str = Field(..., description="Order ID to get info")

class PlatiCallbackIn(BaseModel):
    external_id: str = Field(..., description="Order ID from Plati")
    amount: float = Field(..., description="Amount paid by buyer")
    login: str = Field(..., description="Steam login from buyer")
    service_id: str | None = Field(None, description="Optional PlayWallet service id override")
