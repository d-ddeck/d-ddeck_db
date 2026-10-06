from datetime import date, datetime
from decimal import Decimal
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

Text = Annotated[str, Field(max_length=200)]


class Party(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    company: str = Field(min_length=1, max_length=120)
    contact: Text = ""
    address: str = Field(default="", max_length=300)
    phone: Text = ""
    email: Text = ""


class QuoteLine(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    name: str = Field(min_length=1, max_length=160)
    specification: str = Field(default="", max_length=300)
    quantity: Decimal = Field(gt=0, le=1000000, max_digits=10, decimal_places=3)
    unit_price: Decimal = Field(ge=0, le=10000000000, max_digits=11, decimal_places=0)
    note: str = Field(default="", max_length=200)


class QuoteCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    base_version: int = Field(ge=0)
    quote_date: date = Field(ge=date(2000, 1, 1), le=date(2100, 12, 31))
    valid_until: date = Field(ge=date(2000, 1, 1), le=date(2100, 12, 31))
    supplier: Party
    recipient: Party
    bank_account: str = Field(default="", max_length=200)
    items: list[QuoteLine] = Field(min_length=1, max_length=100)
    notes: str = Field(default="", max_length=4000)
    revision_note: str = Field(default="", max_length=500)
    # 체크한 견적서 체크리스트 항목 id. 다음 버전을 쓸 때 체크 상태를 잇는다.
    checks: list[Annotated[str, Field(max_length=40)]] = Field(
        default_factory=list, max_length=50
    )

    @model_validator(mode="after")
    def check_dates(self):
        if self.valid_until < self.quote_date:
            raise ValueError("유효기간은 견적일자 이후여야 합니다.")
        return self


class QuoteSummary(BaseModel):
    can_delete: bool = False
    id: UUID
    version: int
    filename: str
    sha256: str
    created_at: datetime
    author_name: str
    total: int
    revision_note: str


class QuoteDetail(QuoteSummary):
    snapshot: dict
