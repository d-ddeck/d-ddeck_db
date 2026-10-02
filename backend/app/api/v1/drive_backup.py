"""Google Drive backup configuration and OAuth callback."""

import html
import logging

import httpx
from fastapi import APIRouter, Query, Request
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

from app.core.deps import AdminUser
from app.core.errors import AppError
from app.services import drive_backup as service
from app.services import drive_restore, drive_setup


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
def status(request: Request, _: AdminUser):
    return {**service.status(), "setup_available": drive_setup.local_console(request)}


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


class PowerSettings(BaseModel):
    enabled: bool
    grace_minutes: int = Field(5, ge=1, le=60, description="백업 성공 후 끄기까지 유예")
    wake_hour: int = Field(7, ge=0, le=23, description="다시 켤 시각 (한국)")
    wake_minute: int = Field(0, ge=0, le=59)


@router.put("/power")
def power(payload: PowerSettings, _: AdminUser):
    return service.power_settings(
        payload.enabled, payload.grace_minutes, payload.wake_hour, payload.wake_minute
    )


@router.post("/power/cancel")
def power_cancel(_: AdminUser):
    return service.power_cancel()


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


class SharedDriveConfig(BaseModel):
    service_account_json: str = Field(default="", max_length=65536)
    folder: str = Field(min_length=1, max_length=1000)


@router.put("/shared-drive")
def configure_shared_drive(payload: SharedDriveConfig, _: AdminUser):
    return service.configure_shared_drive(payload.service_account_json, payload.folder)


class RcloneConfig(BaseModel):
    target: str = Field(min_length=1, max_length=1000)


@router.put("/rclone")
def configure_rclone(payload: RcloneConfig, _: AdminUser):
    return service.configure_rclone(payload.target)


class SetupAnswer(BaseModel):
    value: str = Field(max_length=4096)


class SetupFolder(BaseModel):
    folder: str = Field(min_length=1, max_length=1000)
    create: bool = False


@router.post("/setup")
def setup_start(request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_setup.start()


@router.get("/setup/{ident}")
def setup_status(ident: str, request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_setup.get(ident)


@router.post("/setup/{ident}/answer")
def setup_answer(ident: str, payload: SetupAnswer, request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_setup.answer(ident, payload.value)


@router.delete("/setup/{ident}")
def setup_cancel(ident: str, request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_setup.cancel(ident)


@router.get("/setup/{ident}/folders")
def setup_folders(
    ident: str,
    request: Request,
    _: AdminUser,
    parent: str = Query(default="", max_length=1000),
):
    drive_setup.require_console(request)
    return drive_setup.folders(ident, parent)


@router.post("/setup/{ident}/finish")
def setup_finish(ident: str, payload: SetupFolder, request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_setup.finish(ident, payload.folder, payload.create)


class RestoreRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    restore: bool = False
    confirmation: str = Field(default="", max_length=100)


class RestoreTicket(BaseModel):
    ticket: str = Field(min_length=32, max_length=100)


@router.get("/files")
def backup_files(request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_restore.files()


@router.post("/restore/start", status_code=202)
def restore_start(payload: RestoreRequest, request: Request, _: AdminUser):
    drive_setup.require_console(request)
    return drive_restore.start(payload.name, payload.restore, payload.confirmation)


@router.post("/restore/status")
def restore_status(payload: RestoreTicket, request: Request):
    drive_setup.require_console(request)
    return drive_restore.status(payload.ticket)


@router.post("/restore/download")
def restore_download(payload: RestoreTicket, request: Request):
    drive_setup.require_console(request)
    path, name = drive_restore.download(payload.ticket)
    return FileResponse(
        path,
        filename=name,
        media_type="application/zip",
        headers={"Cache-Control": "no-store"},
    )
