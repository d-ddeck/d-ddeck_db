"""One snapshot format for inventory, store setup and rental transitions."""

from app.models.inventory import AssetMovement

FIELDS = ("location_id", "holder_id", "status", "store_id", "status_item_id")


def begin(asset, **values):
    before = {"from_" + field: getattr(asset, field) for field in FIELDS}
    return AssetMovement(asset_id=asset.id, **{**before, **values})


def finish(movement, asset):
    for field in FIELDS:
        setattr(movement, "to_" + field, getattr(asset, field))
    return movement


def inbound(asset, **values):
    return finish(AssetMovement(asset_id=asset.id, **values), asset)
