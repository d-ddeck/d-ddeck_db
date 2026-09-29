"""Workspace shared-drive access with a non-delegated service account."""

import json
import re
from urllib.parse import urlsplit

import httpx
from google.auth.exceptions import GoogleAuthError
from google.auth.transport.requests import Request
from google.oauth2 import service_account

from app.core.errors import AppError

SCOPE = "https://www.googleapis.com/auth/drive"


def parse_key(raw):
    try:
        data = json.loads(raw)
        if not isinstance(data, dict) or data.get("type") != "service_account":
            raise ValueError("Not a service account")
        email = data["client_email"]
        if not isinstance(email, str) or not email.endswith(".iam.gserviceaccount.com"):
            raise ValueError("Invalid service account email")
        # Never accept a credential-supplied token server/universe/delegation.
        info = {
            key: data[key] for key in ("client_email", "private_key", "private_key_id")
        }
        info.update(
            type="service_account", token_uri="https://oauth2.googleapis.com/token"
        )
        service_account.Credentials.from_service_account_info(info, scopes=[SCOPE])
        return info
    except (ValueError, TypeError, KeyError):
        raise AppError(
            "INVALID_SERVICE_ACCOUNT",
            "Google Cloud에서 생성한 서비스 계정 JSON 키 파일을 선택하세요.",
            422,
        ) from None


def folder_id(value):
    value = value.strip()
    if "://" in value:
        uri = urlsplit(value)
        if uri.scheme != "https" or uri.hostname != "drive.google.com" or uri.username:
            raise AppError(
                "INVALID_DRIVE_FOLDER",
                "Google Drive 폴더 링크 또는 폴더 ID를 입력하세요.",
                422,
            )
        match = re.search(r"/folders/([A-Za-z0-9_-]+)(?:/|$)", uri.path)
        value = match[1] if match else ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{10,200}", value):
        raise AppError(
            "INVALID_DRIVE_FOLDER",
            "Google Drive 폴더 링크 또는 폴더 ID를 입력하세요.",
            422,
        )
    return value


def access_token(info):
    try:
        credentials = service_account.Credentials.from_service_account_info(
            info, scopes=[SCOPE]
        )
        request = Request()
        credentials.refresh(lambda **kwargs: request(timeout=30, **kwargs))
        return credentials.token
    except (GoogleAuthError, ValueError, TypeError):
        raise AppError(
            "SERVICE_ACCOUNT_AUTH_FAILED",
            "서비스 계정 인증에 실패했습니다. 키 유효성과 서버 연결을 확인하세요.",
            502,
        ) from None


def validate_folder(client, target):
    response = client.get(
        "https://www.googleapis.com/drive/v3/files/" + target,
        params={
            "supportsAllDrives": "true",
            "fields": "id,name,mimeType,driveId,trashed,capabilities(canAddChildren)",
        },
    )
    if response.status_code >= 400:
        raise AppError(
            "SHARED_DRIVE_ACCESS",
            "공유 드라이브 폴더에 접근할 수 없습니다. 서비스 계정을 공유 드라이브 멤버로 추가하고 업로드 권한을 부여하세요. Drive API 사용 설정도 확인하세요.",
            422,
        )
    data = response.json()
    if (
        not data.get("driveId")
        or data.get("mimeType") != "application/vnd.google-apps.folder"
        or data.get("trashed")
        or not data.get("capabilities", {}).get("canAddChildren")
    ):
        raise AppError(
            "SHARED_DRIVE_FOLDER_REQUIRED",
            "업로드 권한이 있는 Google Workspace 공유 드라이브 폴더를 지정하세요.",
            422,
        )
    return data


def validate_connection(info, target):
    with httpx.Client(
        timeout=30, headers={"Authorization": "Bearer " + access_token(info)}
    ) as client:
        return validate_folder(client, target)
