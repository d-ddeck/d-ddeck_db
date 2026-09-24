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
from app.models.service import (
    Customer,
    ServiceLog,
    ServicePart,
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketResponder,
)
from app.models.store import Store, StoreSet
from app.models.user import Department, Device, RefreshToken, User

__all__ = [
    "Base",
    # auth
    "User",
    "Department",
    "RefreshToken",
    "Device",
    # admin
    "ModuleSetting",
    "CodeGroup",
    "CodeItem",
    "AuditLog",
    "Attachment",
    # service
    "Customer",
    "ServiceTicket",
    "ServicePart",
    "ServiceLog",
    "ServiceTicketCause",
    "ServiceTicketResponder",
    # store
    "Store",
    "StoreSet",
    # inventory
    "Location",
    "Asset",
    "AssetMovement",
    # board
    "Board",
    "Post",
    "PostComment",
    # calendar
    "Calendar",
    "Event",
    "EventParticipant",
    "EventReminder",
    "Notification",
]
