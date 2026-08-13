from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # --- app ---
    app_name: str = "Transvolt E&M Maintenance API"
    version: str = "1.0.0"
    environment: str = "development"
    debug: bool = False
    api_prefix: str = "/api/v1"
    timezone: str = "Asia/Kolkata"

    # --- database ---
    database_url: str = "postgresql+asyncpg://enm:enm@localhost:5432/enm"
    db_echo: bool = False
    db_pool_size: int = 10
    db_max_overflow: int = 20

    # --- auth ---
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    # Ground staff sessions: 24h access token, 30d refresh.
    access_token_ttl_seconds: int = 86_400
    refresh_token_ttl_seconds: int = 2_592_000
    bcrypt_rounds: int = 12

    # --- Microsoft Entra ID (SSO) ---
    ms_tenant_id: str | None = None
    ms_client_id: str | None = None
    ms_jwks_cache_seconds: int = 3600

    # --- CORS ---
    cors_origins: list[str] = Field(default_factory=lambda: ["*"])

    # --- media / photo upload ---
    media_root: str = "media"
    media_url_path: str = "/media"
    public_base_url: str = "http://localhost:8000"
    max_photo_bytes: int = 10 * 1024 * 1024
    allowed_photo_types: list[str] = Field(
        default_factory=lambda: ["image/jpeg", "image/png"]
    )

    # --- pagination ---
    default_page_size: int = 50
    max_page_size: int = 200

    # --- notifications / FCM ---
    notifications_enabled: bool = True
    fcm_credentials_file: str | None = None
    fcm_project_id: str | None = None
    # SLA nudge for breakdowns left open
    breakdown_sla_enabled: bool = True
    breakdown_sla_hours: int = 4
    breakdown_sla_scan_minutes: int = 30

    @field_validator("cors_origins", "allowed_photo_types", mode="before")
    @classmethod
    def _split_csv(cls, v: object) -> object:
        if isinstance(v, str):
            return [item.strip() for item in v.split(",") if item.strip()]
        return v

    @property
    def ms_issuer(self) -> str | None:
        if not self.ms_tenant_id:
            return None
        return f"https://login.microsoftonline.com/{self.ms_tenant_id}/v2.0"

    @property
    def ms_jwks_url(self) -> str | None:
        if not self.ms_tenant_id:
            return None
        return f"https://login.microsoftonline.com/{self.ms_tenant_id}/discovery/v2.0/keys"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
