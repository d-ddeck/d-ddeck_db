"""Immutable quotation snapshots. PDF bytes share the DB backup transaction."""

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Integer, LargeBinary, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.core.security import now_utc
from app.models.base import Base, JSONType, UTCDateTime, UUIDMixin


class QuotationRevision(UUIDMixin, Base):
    __tablename__ = "quotation_revisions"
    __table_args__ = (
        UniqueConstraint("ticket_id", "version", name="uq_quotation_ticket_version"),
    )
    ticket_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("service_tickets.id", ondelete="CASCADE"), index=True
    )
    version: Mapped[int] = mapped_column(Integer)
    snapshot: Mapped[dict] = mapped_column(JSONType)
    filename: Mapped[str] = mapped_column(String(200))
    pdf: Mapped[bytes] = mapped_column(LargeBinary, deferred=True)
    sha256: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=now_utc)
    created_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    author_name: Mapped[str] = mapped_column(String(200))
