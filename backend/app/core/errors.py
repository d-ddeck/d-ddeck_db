"""One error shape for the whole API so the Flutter client can parse it blindly."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import IntegrityError
from starlette.exceptions import HTTPException as StarletteHTTPException


class AppError(Exception):
    """Business-rule failure. Carries a stable machine code plus a Korean message."""

    def __init__(
        self,
        code: str,
        message: str,
        status_code: int = status.HTTP_400_BAD_REQUEST,
        details: Any = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details


def _body(code: str, message: str, details: Any = None) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "details": details}}


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError):
        return JSONResponse(
            status_code=exc.status_code,
            content=_body(exc.code, exc.message, exc.details),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, exc: StarletteHTTPException):
        return JSONResponse(
            status_code=exc.status_code,
            content=_body(f"HTTP_{exc.status_code}", str(exc.detail)),
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError):
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            content=_body(
                "VALIDATION_ERROR",
                "입력값이 올바르지 않습니다.",
                jsonable_encoder(
                    [
                        {k: v for k, v in error.items() if k not in {"input", "ctx"}}
                        for error in exc.errors()
                    ]
                ),
            ),
        )

    @app.exception_handler(IntegrityError)
    async def _integrity_error(_: Request, exc: IntegrityError):
        return JSONResponse(
            status_code=409,
            content=_body("DATA_CONFLICT", "중복되거나 참조할 수 없는 데이터입니다."),
        )

    @app.exception_handler(Exception)
    async def _unexpected_error(_: Request, exc: Exception):
        logging.getLogger("ddeck").exception("request failed", exc_info=exc)
        return JSONResponse(
            status_code=500,
            content=_body("INTERNAL_ERROR", "서버 처리 중 오류가 발생했습니다."),
        )
