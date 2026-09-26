from starlette.responses import JSONResponse

from app.core.config import settings


class UploadLimitMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if (
            scope["type"] != "http"
            or scope["method"] != "POST"
            or scope["path"].rstrip("/") != settings.API_V1_PREFIX + "/files"
        ):
            return await self.app(scope, receive, send)
        limit = settings.MAX_UPLOAD_MB * 1024 * 1024 + 65536
        headers = dict(scope.get("headers", []))
        try:
            length = int(headers.get(b"content-length", b"0"))
        except ValueError:
            length = limit + 1

        async def reject():
            response = JSONResponse(
                {
                    "error": {
                        "code": "FILE_TOO_LARGE",
                        "message": "업로드 크기 제한을 초과했습니다.",
                        "details": None,
                    }
                },
                status_code=413,
            )
            await response(scope, receive, send)

        if length > limit:
            return await reject()
        # Bounded spool: read the body before Starlette multipart processing and
        # replay from disk. Chunked requests are limited too.
        from tempfile import SpooledTemporaryFile

        with SpooledTemporaryFile(max_size=1024 * 1024) as spool:
            size = 0
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    return
                body = message.get("body", b"")
                size += len(body)
                if size > limit:
                    return await reject()
                spool.write(body)
                if not message.get("more_body", False):
                    break
            spool.seek(0)

            async def replay():
                chunk = spool.read(65536)
                return {
                    "type": "http.request",
                    "body": chunk,
                    "more_body": spool.tell() < size,
                }

            await self.app(scope, replay, send)
