from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class AppError(Exception):
    """Base error mapped 1:1 onto the API error envelope."""

    code: str = "SERVER_ERROR"
    http_status: int = status.HTTP_500_INTERNAL_SERVER_ERROR

    def __init__(
        self, message: str, fields: dict[str, str] | None = None
    ) -> None:
        super().__init__(message)
        self.message = message
        self.fields = fields

    def to_response(self) -> JSONResponse:
        return error_response(
            self.http_status, self.code, self.message, self.fields
        )


class ValidationError(AppError):
    code = "VALIDATION_ERROR"
    http_status = status.HTTP_400_BAD_REQUEST


class Unauthorized(AppError):
    code = "UNAUTHORIZED"
    http_status = status.HTTP_401_UNAUTHORIZED


class InactiveUser(AppError):
    code = "INACTIVE_USER"
    http_status = status.HTTP_403_FORBIDDEN


class Forbidden(AppError):
    code = "FORBIDDEN"
    http_status = status.HTTP_403_FORBIDDEN


class NotFound(AppError):
    code = "NOT_FOUND"
    http_status = status.HTTP_404_NOT_FOUND


class Conflict(AppError):
    code = "CONFLICT"
    http_status = status.HTTP_409_CONFLICT


def error_response(
    http_status: int,
    code: str,
    message: str,
    fields: dict[str, str] | None = None,
) -> JSONResponse:
    body: dict[str, Any] = {"error": {"code": code, "message": message}}
    if fields:
        body["error"]["fields"] = fields
    return JSONResponse(status_code=http_status, content=body)


_STATUS_TO_CODE = {
    400: "VALIDATION_ERROR",
    401: "UNAUTHORIZED",
    403: "FORBIDDEN",
    404: "NOT_FOUND",
    405: "NOT_FOUND",
    409: "CONFLICT",
    413: "VALIDATION_ERROR",
    415: "VALIDATION_ERROR",
    422: "VALIDATION_ERROR",
}


def _flatten_pydantic_errors(exc: RequestValidationError) -> dict[str, str]:
    fields: dict[str, str] = {}
    for err in exc.errors():
        loc = [str(p) for p in err["loc"]]
        # drop the "body"/"query"/"path" prefix so the UI sees plain field names
        if loc and loc[0] in {"body", "query", "path", "header"}:
            loc = loc[1:]
        key = ".".join(loc) or "_"
        fields.setdefault(key, err.get("msg", "invalid"))
    return fields


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError) -> JSONResponse:
        return exc.to_response()

    @app.exception_handler(RequestValidationError)
    async def _validation(
        _: Request, exc: RequestValidationError
    ) -> JSONResponse:
        fields = _flatten_pydantic_errors(exc)
        first = next(iter(fields.items()), None)
        message = (
            f"{first[0]}: {first[1]}" if first else "Request validation failed"
        )
        return error_response(400, "VALIDATION_ERROR", message, fields)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _STATUS_TO_CODE.get(exc.status_code, "SERVER_ERROR")
        return error_response(exc.status_code, code, str(exc.detail))

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:  # noqa: ARG001
        return error_response(500, "SERVER_ERROR", "Internal server error")
