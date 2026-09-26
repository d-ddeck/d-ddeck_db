"""Read-only shipment serial reconciliation against live inventory."""

from collections import Counter

from sqlalchemy import select

from app.core.errors import AppError
from app.models.inventory import Asset


def compare(db, serials, store_id=None):
    normalized = [str(value).strip().lower() for value in serials if str(value).strip()]
    if not normalized or len(normalized) > 5000:
        raise AppError("INVALID_SERIALS", "시리얼은 1~5,000개까지 입력하세요.")
    expected = set(normalized)
    query = select(Asset).where(Asset.deleted_at.is_(None))
    if store_id:
        query = query.where(Asset.store_id == store_id)
    rows = db.scalars(query.order_by(Asset.name, Asset.serial_no)).all()
    found = [
        asset for asset in rows if (asset.serial_no or "").strip().lower() in expected
    ]
    actual = {(asset.serial_no or "").strip().lower() for asset in found}

    def brief(asset):
        return {
            "id": str(asset.id),
            "name": asset.name,
            "serial_no": asset.serial_no,
            "status": asset.status.value,
        }

    return {
        "found": [brief(asset) for asset in found],
        "missing": sorted(expected - actual),
        "unexpected": [
            brief(asset)
            for asset in rows
            if store_id and (asset.serial_no or "").strip().lower() not in expected
        ],
        "duplicates": sorted(
            value for value, count in Counter(normalized).items() if count > 1
        ),
    }
