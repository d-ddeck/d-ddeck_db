"""Bounded per-process throttling for the supported single-worker deployment."""

from collections import OrderedDict, deque
from threading import Lock
from time import monotonic

from app.core.config import settings
from app.core.errors import AppError

_events: OrderedDict = OrderedDict()
_lock = Lock()


def auth_limit(ip: str | None, identifier: str, operation: str, limit: int) -> None:
    if not settings.AUTH_RATE_LIMIT_ENABLED:
        return
    now = monotonic()
    # Both IP-wide and identifier-wide: rotating accounts/IPs cannot evade both.
    keys = [
        (operation, "ip", ip or "unknown", limit * 5),
        (operation, "id", identifier.casefold(), limit),
    ]
    with _lock:
        for op, kind, value, cap in keys:
            key = (op, kind, value)
            entries = _events.setdefault(key, deque())
            while entries and entries[0] <= now - 60:
                entries.popleft()
            if len(entries) >= cap:
                raise AppError(
                    "RATE_LIMITED", "요청이 많습니다. 1분 후 다시 시도해 주세요.", 429
                )
        for op, kind, value, _ in keys:
            key = (op, kind, value)
            _events[key].append(now)
            _events.move_to_end(key)
        while len(_events) > 10000:
            _events.popitem(last=False)
