"""Import every model so Base.metadata is complete before create_all / Alembic."""

from app.models.admin import (
    Attachment,
    AuditLog,
    CodeGroup,
    CodeItem,
    ModuleSetting,
)
from app.models.base import Base
from app.models.board import Board, Post, PostComment
from app.models.calendar import (
    Calendar,
    Event,
    EventParticipant,
    EventReminder,
    Notification,
)
from app.models.inventory import Asset, AssetMovement, Location
from app.models.quotation import QuotationRevision
from app.models.service import (
    Customer,
    ServiceLog,
    ServicePart,
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketNumber,
    ServiceTicketResponder,
)
from app.models.store import Store, StoreSet
from app.models.user import Department, Device, RefreshToken, User
from app.models.worklog import WorkLog, WorkLogDraft

__all__ = [
    "Asset",
    "AssetMovement",
    "Attachment",
    "AuditLog",
    "Base",
    "Board",
    "Calendar",
    "CodeGroup",
    "CodeItem",
    "Customer",
    "Department",
    "Device",
    "Event",
    "EventParticipant",
    "EventReminder",
    "Location",
    "ModuleSetting",
    "Notification",
    "Post",
    "PostComment",
    "QuotationRevision",
    "RefreshToken",
    "ServiceLog",
    "ServicePart",
    "ServiceTicket",
    "ServiceTicketCause",
    "ServiceTicketNumber",
    "ServiceTicketResponder",
    "Store",
    "StoreSet",
    "User",
    "WorkLog",
    "WorkLogDraft",
]
