"""Google Drive backup configuration and OAuth callback."""

import html
import logging

import httpx
from fastapi import APIRouter, Query
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from app.core.deps import AdminUser
from app.core.errors import AppError
from app.services import drive_backup as service


class _RedactOAuthQuery(logging.Filter):
    def filter(self, record):
        args = record.args
        if (
            isinstance(args, tuple)
            and len(args) == 5
            and isinstance(args[2], str)
            and "/drive-backup/callback" in args[2]
        ):
            record.args = (*args[:2], args[2].split("?", 1)[0], *args[3:])
        return True


logging.getLogger("uvicorn.access").addFilter(_RedactOAuthQuery())


router = APIRouter(prefix="/admin/drive-backup", tags=["admin"])


class OAuthConfig(BaseModel):
    client_id: str = Field(min_length=1, max_length=300)
    client_secret: str = Field(default="", max_length=300)
    redirect_uri: str = Field(min_length=1, max_length=1000)


class Schedule(BaseModel):
    enabled: bool
    hour: int = Field(ge=0, le=23)


@router.get("")
def status(_: AdminUser):
    return service.status()


@router.put("/config")
def configure(payload: OAuthConfig, _: AdminUser):
    return service.configure(
        payload.client_id.strip(),
        payload.client_secret.strip(),
        payload.redirect_uri.strip(),
    )


@router.post("/connect")
def connect(_: AdminUser):
    return service.authorization_url()


@router.delete("/connection")
def disconnect(_: AdminUser):
    return service.disconnect()


@router.put("/schedule")
def schedule(payload: Schedule, _: AdminUser):
    return service.schedule(payload.enabled, payload.hour)


@router.post("/run", status_code=202)
def run(_: AdminUser):
    return service.request_backup()


@router.get("/callback", response_class=HTMLResponse)
def callback(
    state: str = Query(default="", max_length=200),
    code: str = Query(default="", max_length=4096),
    error: str = Query(default="", max_length=300),
):
    # OAuth state is issued only by the authenticated admin endpoint, expires
    # after ten minutes and is consumed once. No app access token in a browser.
    status_code = 200
    try:
        message = service.callback(state, code, bool(error))
    except AppError as exc:
        message, status_code = exc.message, exc.status_code
    except (httpx.HTTPError, OSError, ValueError, KeyError):
        message, status_code = (
            "Google 연결에 실패했습니다. 앱에서 다시 시도하세요. 기존 계정 연결은 유지됩니다.",
            502,
        )
    return HTMLResponse(
        '<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Drive 백업 연결</title><h2>Drive 백업 연결</h2><p>'
        + html.escape(message)
        + "</p></html>",
        status_code=status_code,
        headers={
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
        },
    )
