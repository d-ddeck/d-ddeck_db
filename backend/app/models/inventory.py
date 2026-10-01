"""재고관리 module: what the company owns and where each unit physically is."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone

from sqlalchemy import (
    Boolean,
    Date,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    Uuid,
    and_,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import (
    AuthorMixin,
    Base,
    SerialTrim,
    SoftDeleteMixin,
    TimestampMixin,
    UTCDateTime,
    UUIDMixin,
    enum_type,
)
from app.models.enums import AssetStatus, LocationType, MovementType


class Location(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    """Tree of physical places.

    `path` is a denormalised full-path cache (본사 > 2F > 창고) so list screens
    can show the whole location without recursing the tree.
    """

    __tablename__ = "locations"

    code: Mapped[str] = mapped_column(
        String(60), unique=True, index=True, nullable=False
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    type: Mapped[LocationType] = mapped_column(
        enum_type(LocationType), default=LocationType.ETC, nullable=False
    )
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("locations.id", ondelete="SET NULL"), index=True
    )
    path: Mapped[str | None] = mapped_column(String(500), index=True)
    address: Mapped[str | None] = mapped_column(String(300))
    manager_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    note: Mapped[str | None] = mapped_column(Text)

    parent: Mapped[Location | None] = relationship(
        remote_side="Location.id", back_populates="children"
    )
    children: Mapped[list[Location]] = relationship(back_populates="parent")
    assets: Mapped[list[Asset]] = relationship(back_populates="location")


class Asset(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "assets"

    asset_no: Mapped[str] = mapped_column(
        String(60), unique=True, index=True, nullable=False
    )
    name: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    model_name: Mapped[str | None] = mapped_column(String(150))
    manufacturer: Mapped[str | None] = mapped_column(String(150))
    serial_no: Mapped[str | None] = mapped_column(String(150), index=True)
    barcode: Mapped[str | None] = mapped_column(String(150), unique=True, index=True)
    spec: Mapped[str | None] = mapped_column(Text)

    # --- where it is right now ---
    status: Mapped[AssetStatus] = mapped_column(
        enum_type(AssetStatus), default=AssetStatus.IN_STOCK, nullable=False, index=True
    )
    location_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("locations.id", ondelete="SET NULL"), index=True
    )
    holder_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), index=True
    )  # 현 사용자 / 보관 책임자

    # 매장 - set when the unit is out at a customer site. Mutually exclusive
    # with location_id in practice: the old server split these too (an asset is
    # either at a 매장 or at a 창고), and keeping both columns preserves that.
    store_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("stores.id", ondelete="SET NULL"), index=True
    )
    # 납품 세트 번호 within that store; 0 = 세트 미지정. Points at StoreSet.set_no.
    set_no: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    # The old server tracked 13 states (설치 / 렌탈 중 / AS 대기 / 바른 회수 /
    # 미상 ...) where AssetStatus has 6. `status` keeps the coarse enum every
    # existing query relies on; this holds the original value so nothing is
    # lost and the fine-grained states can be restored later.
    status_item_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    # --- quantity: 1 for a serialised unit, N for consumables ---
    quantity: Mapped[float] = mapped_column(Numeric(14, 3), default=1, nullable=False)
    unit: Mapped[str] = mapped_column(String(20), default="EA", nullable=False)
    min_quantity: Mapped[float | None] = mapped_column(
        Numeric(14, 3)
    )  # 안전재고 경고선

    # --- money / lifecycle ---
    purchase_date: Mapped[date | None] = mapped_column(Date)
    purchase_price: Mapped[float | None] = mapped_column(Numeric(14, 2))
    supplier: Mapped[str | None] = mapped_column(String(150))
    warranty_until: Mapped[date | None] = mapped_column(Date)
    disposed_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    note: Mapped[str | None] = mapped_column(Text)

    location: Mapped[Location | None] = relationship(back_populates="assets")
    movements: Mapped[list[AssetMovement]] = relationship(
        back_populates="asset",
        cascade="all, delete-orphan",
        order_by="AssetMovement.moved_at.desc()",
    )

    @property
    def is_below_min(self) -> bool:
        if self.min_quantity is None:
            return False
        return float(self.quantity) < float(self.min_quantity)


class AssetMovement(UUIDMixin, TimestampMixin, Base):
    """Append-only history of every location / holder / status change.

    Asset.location_id caches where a unit is now; this table records how it got
    there.
    """

    __tablename__ = "asset_movements"

    hidden_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    # Preserve insertion order even for backdated moves within the same second.
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime,
        default=lambda: datetime.now(timezone.utc),
        server_default=func.now(),
        nullable=False,
        index=True,
    )

    asset_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("assets.id", ondelete="CASCADE"), nullable=False, index=True
    )
    movement_type: Mapped[MovementType] = mapped_column(
        enum_type(MovementType), nullable=False, index=True
    )
    from_location_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("locations.id", ondelete="SET NULL")
    )
    to_location_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("locations.id", ondelete="SET NULL")
    )
    from_holder_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    to_holder_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    # 매장 이동도 위치 이동만큼 자주 일어난다(창고 -> 설치, 미운영 -> 회수).
    # 여기에 남기지 않으면 "이 장비가 어느 매장에 있었나"를 되짚을 수 없다.
    from_store_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("stores.id", ondelete="SET NULL")
    )
    to_store_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("stores.id", ondelete="SET NULL")
    )

    from_status: Mapped[AssetStatus | None] = mapped_column(enum_type(AssetStatus))
    to_status: Mapped[AssetStatus | None] = mapped_column(enum_type(AssetStatus))
    # 구 서버의 13종 세부 상태. enum 6종으로 접히기 전의 값이라 이력에도 남긴다.
    from_status_item_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL")
    )
    to_status_item_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL")
    )
    quantity: Mapped[float | None] = mapped_column(Numeric(14, 3))
    moved_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False, index=True)
    moved_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    reason: Mapped[str | None] = mapped_column(Text)
    reference_type: Mapped[str | None] = mapped_column(String(60))
    reference_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)

    asset: Mapped[Asset] = relationship(back_populates="movements")


_serial_live = and_(
    Asset.deleted_at.is_(None),
    Asset.serial_no.isnot(None),
    SerialTrim(Asset.serial_no) != "",
)
Index(
    "uq_assets_category_serial_live",
    Asset.category_id,
    func.lower(SerialTrim(Asset.serial_no)),
    unique=True,
    sqlite_where=and_(_serial_live, Asset.category_id.isnot(None)),
    postgresql_where=and_(_serial_live, Asset.category_id.isnot(None)),
)
Index(
    "uq_assets_serial_no_category_live",
    func.lower(SerialTrim(Asset.serial_no)),
    unique=True,
    sqlite_where=and_(_serial_live, Asset.category_id.is_(None)),
    postgresql_where=and_(_serial_live, Asset.category_id.is_(None)),
)
