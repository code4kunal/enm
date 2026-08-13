from __future__ import annotations

import contextlib
import os
import uuid
from pathlib import Path

from app.config import settings
from app.errors import ValidationError

_EXT = {"image/jpeg": ".jpg", "image/png": ".png"}


def _root() -> Path:
    root = Path(settings.media_root)
    root.mkdir(parents=True, exist_ok=True)
    return root


def validate_photo(content_type: str | None, size: int) -> str:
    if content_type not in settings.allowed_photo_types:
        raise ValidationError(
            "Photo must be a JPEG or PNG image", {"photo": "unsupported_type"}
        )
    if size <= 0:
        raise ValidationError("Photo is empty", {"photo": "empty"})
    if size > settings.max_photo_bytes:
        mb = settings.max_photo_bytes // (1024 * 1024)
        raise ValidationError(f"Photo must be {mb} MB or smaller", {"photo": "too_large"})
    return _EXT[content_type]


def save_photo(entry_id: str, content: bytes, ext: str) -> tuple[str, str]:
    """Write to disk and return (storage_key, public_url)."""
    key = f"entries/{entry_id}/{uuid.uuid4().hex}{ext}"
    path = _root() / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    url = f"{settings.public_base_url.rstrip('/')}{settings.media_url_path}/{key}"
    return key, url


def delete_photo(key: str | None) -> None:
    if not key:
        return
    path = _root() / key
    with contextlib.suppress(FileNotFoundError):
        os.remove(path)
