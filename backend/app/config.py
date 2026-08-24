from __future__ import annotations

from functools import lru_cache
from typing import Annotated

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

#: The default in `.env.example`. Present so the app runs out of the box for
#: development, and refused at startup anywhere else.
INSECURE_JWT_SECRET = "change-me-in-production"

#: Environments that must be fully configured before the app will serve.
PRODUCTION_ENVIRONMENTS = frozenset({"production", "prod", "staging"})

#: The shortest secret worth having for HS256.
MIN_JWT_SECRET_LENGTH = 32


class ConfigurationError(RuntimeError):
    """The app is not safe to start with the configuration it was given."""


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # --- app ---
    app_name: str = "Transvolt E&M Maintenance API"
    version: str = "1.1.0"
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
    #: Never ship this value. `assert_production_ready` refuses to start with
    #: it outside development — a forged token is indistinguishable from a real
    #: one, so a placeholder secret is a silent total compromise rather than a
    #: visible failure.
    jwt_secret: str = INSECURE_JWT_SECRET
    jwt_algorithm: str = "HS256"
    # Ground staff sessions: 24h access token, 30d refresh.
    access_token_ttl_seconds: int = 86_400
    refresh_token_ttl_seconds: int = 2_592_000
    bcrypt_rounds: int = 12

    # --- SiteOps platform ---
    siteops_base_url: str = "https://dev-siteops-platform.transvolt.org/api/v1"
    #: Server-to-server key for master-data reads (sites, vehicles) that don't
    #: depend on which user is asking. Never sent to the Flutter client — kept
    #: server-side and attached as `X-Service-Key` by `app/services/siteops.py`.
    siteops_service_key: str | None = None

    # --- Microsoft Entra ID (SSO) ---
    ms_tenant_id: str | None = None
    ms_client_id: str | None = None
    ms_jwks_cache_seconds: int = 3600

    # --- CORS ---
    # NoDecode: these arrive as plain comma-separated strings in .env, not
    # JSON, and `_split_csv` below is what turns them into lists.
    # Never default to "*": CORSMiddleware keeps allow_credentials=True, and
    # browsers reject Access-Control-Allow-Origin: * with credentials.
    cors_origins: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: [
            "http://localhost:8080",
            "http://localhost:8089",
            "http://127.0.0.1:8080",
            "http://127.0.0.1:8089",
        ]
    )

    # --- media / photo upload ---
    media_root: str = "media"
    media_url_path: str = "/media"
    public_base_url: str = "http://localhost:8000"
    max_photo_bytes: int = 10 * 1024 * 1024
    allowed_photo_types: Annotated[list[str], NoDecode] = Field(
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

    # --- inspection schedule ---
    # The nightly run: plan tomorrow, mark what was missed, raise alerts.
    schedule_generator_enabled: bool = True
    schedule_generator_hour: int = 22
    schedule_generator_minute: int = 0

    # --- odometers ---
    # Master switch for the server-side pull. Each site still has its own
    # `odometer_sync_minutes`; this is only how often we check which are due.
    odometer_sync_enabled: bool = True
    odometer_scan_minutes: int = 5

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

    @property
    def is_production(self) -> bool:
        return self.environment.strip().lower() in PRODUCTION_ENVIRONMENTS

    @property
    def sso_enabled(self) -> bool:
        return bool(self.ms_tenant_id and self.ms_client_id)

    def problems(self) -> list[str]:
        """Everything that makes this configuration unsafe to serve.

        Returned rather than raised so the caller can report all of them at
        once — finding these one redeploy at a time is how a rollout stalls.
        """
        found: list[str] = []
        if not self.is_production:
            return found

        if self.jwt_secret == INSECURE_JWT_SECRET:
            found.append(
                "JWT_SECRET is still the development placeholder. Anyone who "
                "has read the repository can mint valid tokens for any user."
            )
        elif len(self.jwt_secret) < MIN_JWT_SECRET_LENGTH:
            found.append(
                f"JWT_SECRET is shorter than {MIN_JWT_SECRET_LENGTH} characters."
            )

        if "*" in self.cors_origins:
            found.append(
                "CORS_ORIGINS is '*'. Name the origins that may call this API."
            )

        if self.debug:
            found.append("DEBUG is on, which leaks stack traces to clients.")

        if not self.public_base_url.startswith("https://"):
            found.append(
                f"PUBLIC_BASE_URL is {self.public_base_url!r} — not https, so "
                "passwords and tokens cross the wire in clear."
            )
        return found

    def assert_production_ready(self) -> None:
        """Refuse to start rather than serve with a known-bad configuration.

        A misspelled environment variable would otherwise boot a perfectly
        healthy-looking API that anyone can forge a token for. Failing loudly
        at startup is the only version of this that gets noticed.
        """
        problems = self.problems()
        if problems:
            raise ConfigurationError(
                f"Refusing to start in environment {self.environment!r}:\n  - "
                + "\n  - ".join(problems)
            )


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
