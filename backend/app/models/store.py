"""매장 module: the sites our equipment is installed at.

A 매장 is not a `Customer` and not a `Location`, and it took a migration from
the previous server to make that obvious:

* `Customer` (service.py) is a flat contact record - no brand hierarchy, and
  only `is_active` where a store needs 개점일 / 폐점 / 폐점일 to answer
  "how many stores were we running in 2024?".
* `Location` (inventory.py) is our *own* physical tree (사업장 > 층 > 랙) that
  `Asset.location_id` points at. Putting customer sites in it would turn the
  warehouse tree into a customer directory and erase the distinction the old
  system kept deliberately: an asset sits either at a 매장 or at a 창고.

So stores get their own table, and `Asset` gains a `store_id` that lives
alongside `location_id` rather than replacing it.
"""

from __future__ import annotations

import uuid
from datetime import date

from sqlalchemy import (
    Boolean,
    Date,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import (
    AuthorMixin,
    Base,
    SoftDeleteMixin,
    TimestampMixin,
    UUIDMixin,
)


class Store(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "stores"

    name: Mapped[str] = mapped_column(
        String(150), unique=True, index=True, nullable=False
    )

    # 브랜드는 코드 마스터(CodeGroup "STORE_BRAND"). A FK rather than the old
    # system's free text: renaming 바른치킨 there had to UPDATE three tables by
    # hand, and here it is a single row edit.
    brand_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    # --- lifecycle: these three answer "운영 매장 수" per year ---
    open_date: Mapped[date | None] = mapped_column(Date)
    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="1", nullable=False
    )
    is_closed: Mapped[bool] = mapped_column(
        Boolean, default=False, nullable=False, index=True
    )
    closed_date: Mapped[date | None] = mapped_column(Date)

    # 전동 / 비전동 - decides which equipment slots a 납품 세트 has.
    gripper_type: Mapped[str | None] = mapped_column(String(20))

    contact_name: Mapped[str | None] = mapped_column(String(150))
    contact_phone: Mapped[str | None] = mapped_column(String(50))
    address: Mapped[str | None] = mapped_column(String(300))

    note: Mapped[str | None] = mapped_column(Text)

    # Optional bridge to the existing 거래처 master, for sites that are also
    # billed as a customer. Nothing requires it.
    customer_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )

    sets: Mapped[list[StoreSet]] = relationship(
        back_populates="store",
        cascade="all, delete-orphan",
        order_by="StoreSet.set_no",
    )


class StoreSet(UUIDMixin, TimestampMixin, Base):
    """One 납품 세트 - a robot arm, controller, gripper and tool changer
    delivered to a store as a unit.

    A store can hold several (평택 삼성전자 P3 runs 1호기 through 5호기), so the
    set carries a per-store number and an optional name. `Asset.set_no` points
    back here by that number; 0 means the asset is not assigned to a set.
    """

    __tablename__ = "store_sets"
    __table_args__ = (UniqueConstraint("store_id", "set_no", name="uq_store_set_no"),)

    store_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("stores.id", ondelete="CASCADE"), nullable=False, index=True
    )
    set_no: Mapped[int] = mapped_column(Integer, nullable=False)
    name: Mapped[str | None] = mapped_column(String(80))

    store: Mapped[Store] = relationship(back_populates="sets")
