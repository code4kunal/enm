#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] waiting for database..."
python - <<'PY'
import asyncio, os, sys, time
import asyncpg

url = os.environ.get("DATABASE_URL", "postgresql+asyncpg://enm:enm@db:5432/enm")
dsn = url.replace("postgresql+asyncpg://", "postgresql://")

async def wait():
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            conn = await asyncpg.connect(dsn)
            await conn.close()
            return
        except Exception as exc:
            print(f"  db not ready ({exc.__class__.__name__}), retrying...")
            await asyncio.sleep(2)
    sys.exit("database did not become ready in 60s")

asyncio.run(wait())
PY

echo "[entrypoint] running migrations..."
alembic upgrade head

if [ "${SEED_ON_START:-false}" = "true" ]; then
  echo "[entrypoint] seeding master data..."
  python -m scripts.seed
fi

echo "[entrypoint] starting: $*"
exec "$@"
