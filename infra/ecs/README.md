# Transvolt E&M — ECS Fargate task definitions

Account `654654496534`, region `ap-south-1`. Two services (recommended): **enm-backend** and **enm-frontend**. Postgres is **not** an ECS task.

Both web and API are served via ALB on `https://enm.transvolt.org` (path `/api/*` → API, default → web). Set `PUBLIC_BASE_URL` and `CORS_ORIGINS` to that same origin (scheme + host, no path). Never use `*`, a placeholder, or a separate API host unless CORS is updated to match the browser origin.

## Architecture

| Piece | Where it runs | Why |
| --- | --- | --- |
| Database | **Amazon RDS** PostgreSQL 16 | Fargate disks are ephemeral; backups, Multi-AZ, and a stable hostname belong on RDS. Do not run `postgres` as a Fargate task in production. |
| API | ECS Fargate service `enm-backend` | FastAPI on container port **8000**. Entrypoint waits for DB, runs Alembic, then uvicorn. |
| Web | ECS Fargate service `enm-frontend` | nginx serving the Flutter web build on port **80**. URLs are **runtime env**: `docker-entrypoint.sh` writes `config.json` from `API_BASE_URL` / `SITEOPS_BASE_URL` / `ENVIRONMENT` at container start (one image for all environments). |
| Combined (optional) | One task, two containers | `task-definition-combined.json` if you insist on a single service. **Still no Postgres.** `networkMode` is `awsvpc` (container `links` are ignored). The browser still cannot use `localhost` or the docker hostname `api`. |

Local compose ports (`5433→5432`, `8123→8000`, `8080/8089→80`) are host mappings only (`API_PORT` / `WEB_PORT` / `DB_PORT` are not app env). On ECS, publish **8000** (API) and **80** (web) through an ALB (or CloudFront in front of the ALB).

IAM: `arn:aws:iam::654654496534:role/ecsTaskExecutionRole` is used as both execution role (ECR pull, logs, SSM Parameter Store inject) and task role. Add a dedicated task role later if the app calls AWS APIs (S3/EFS).

## Files

| File | Family | CPU / memory |
| --- | --- | --- |
| `task-definition-api.json` | `enm-backend` | 512 / 1024 |
| `task-definition-web.json` | `enm-frontend` | 256 / 512 |
| `task-definition-combined.json` | `enm-combined` | 512 / 1024 |

## ECR images

Repos: `enm-backend` and `enm-frontend` in `ap-south-1`.

```powershell
# Login
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 654654496534.dkr.ecr.ap-south-1.amazonaws.com

# Tag local compose images (names may be backend-api / enm_backend / backend-web)
docker tag <local-api> 654654496534.dkr.ecr.ap-south-1.amazonaws.com/enm-backend:latest
docker tag <local-web> 654654496534.dkr.ecr.ap-south-1.amazonaws.com/enm-frontend:latest

docker push 654654496534.dkr.ecr.ap-south-1.amazonaws.com/enm-backend:latest
docker push 654654496534.dkr.ecr.ap-south-1.amazonaws.com/enm-frontend:latest
```

Build from source if you do not have local images:

```powershell
docker build -t 654654496534.dkr.ecr.ap-south-1.amazonaws.com/enm-backend:latest backend

# Web — URLs are injected at container start via ECS env (see task-definition-web.json).
# No build-args required; one image works for all environments.
docker build `
  -t 654654496534.dkr.ecr.ap-south-1.amazonaws.com/enm-frontend:latest `
  app
```

`ENVIRONMENT=production` (or `prod`) with a localhost `API_BASE_URL` **fails container start** (entrypoint guard), not the image build.

## Secrets (SSM Parameter Store — not Secrets Manager)

E&M stores `DATABASE_URL`, `JWT_SECRET`, and `SITEOPS_SERVICE_KEY` as **SSM Parameter Store SecureString** parameters (`/enm/...`). Task definitions must use **SSM** `valueFrom` ARNs. Pointing at Secrets Manager causes `ResourceNotFoundException` even when the SSM parameters exist. **API / combined only** — do not put `SITEOPS_SERVICE_KEY` on the web task (server-side `X-Service-Key` for SiteOps).

Task defs reference:

```text
arn:aws:ssm:ap-south-1:654654496534:parameter/enm/DATABASE_URL
arn:aws:ssm:ap-south-1:654654496534:parameter/enm/JWT_SECRET
arn:aws:ssm:ap-south-1:654654496534:parameter/enm/SITEOPS_SERVICE_KEY
```

For a parameter named `/enm/DATABASE_URL`, the ARN uses `parameter/enm/DATABASE_URL` (no extra slash after `parameter`).

Example (create if missing):

```powershell
aws ssm put-parameter --name /enm/DATABASE_URL --type SecureString --region ap-south-1 `
  --value "postgresql+asyncpg://USER:PASSWORD@RDS_ENDPOINT:5432/enm"

aws ssm put-parameter --name /enm/JWT_SECRET --type SecureString --region ap-south-1 `
  --value "at-least-32-characters-not-the-repo-placeholder"

# Required for SiteOps login fallback (optional in config.py, but needed in prod if you use SiteOps).
# Do not commit the real value; create the SecureString yourself:
aws ssm put-parameter --name /enm/SITEOPS_SERVICE_KEY --type SecureString --region ap-south-1 `
  --value "YOUR_SITEOPS_SERVICE_KEY"
```

### IAM: `ecsTaskExecutionRole`

Execution role needs `ssm:GetParameters` (and related get) on the E&M path. Existing policies often cover `siteops` / `tims` / `mqtt` but **not** `enm` — add:

```json
"arn:aws:ssm:ap-south-1:654654496534:parameter/enm/*"
```

SecureString parameters also need `kms:Decrypt` on the KMS key that encrypts them (often the AWS-managed `alias/aws/ssm` key in `ap-south-1`).

Also keep ECR pull and CloudWatch Logs on the execution role.

`JWT_SECRET` must not be `change-me-in-production` when `ENVIRONMENT` is `production` / `prod` / `staging` — the API refuses to start (`backend/app/config.py`).

Do not put `BOOTSTRAP_PASSWORD` on ECS: `SEED_ON_START=false`, so seed/bootstrap secrets are unused.

After changing task def JSON or IAM, **register a new task definition revision** and **redeploy** the ECS service so tasks pick up the new `valueFrom` ARNs.

## API env (what the running process actually reads)

Only vars from `backend/app/config.py` plus `SEED_ON_START` (entrypoint). Dropped: compose host ports, `WEB_API_BASE_URL`, unused FCM/SSO blanks, bootstrap secrets.

| Name | Role |
| --- | --- |
| `ENVIRONMENT` | `production` |
| `DEBUG` | `false` |
| `SEED_ON_START` | `false` (entrypoint skips seed) |
| `PUBLIC_BASE_URL` | Public **API** origin (`https://…`). Used for media URLs. |
| `CORS_ORIGINS` | Comma-separated **browser** origins of the Flutter UI. Never `*`. |
| `SITEOPS_BASE_URL` | SiteOps platform (browser credential login + vehicle master); web task also sets this for `config.json` |
| `MEDIA_ROOT` | `/srv/media` (ephemeral on Fargate unless you add EFS) |

Secrets: `DATABASE_URL`, `JWT_SECRET`, `SITEOPS_SERVICE_KEY` (SSM `/enm/SITEOPS_SERVICE_KEY`; create SecureString before deploy).

Optional (defaults in `config.py`; add to the task def only if you need to override): `ACCESS_TOKEN_TTL_SECONDS`, `REFRESH_TOKEN_TTL_SECONDS`, `MS_TENANT_ID` / `MS_CLIENT_ID` (SSO), `FCM_*` (push; needs a file in the container, not an env JSON blob).

## Register and run

```powershell
aws logs create-log-group --log-group-name /ecs/enm-backend --region ap-south-1
aws logs create-log-group --log-group-name /ecs/enm-frontend --region ap-south-1

aws ecs register-task-definition --cli-input-json file://infra/ecs/task-definition-api.json --region ap-south-1
aws ecs register-task-definition --cli-input-json file://infra/ecs/task-definition-web.json --region ap-south-1
aws ecs register-task-definition --cli-input-json file://infra/ecs/task-definition-combined.json --region ap-south-1
```

Create two Fargate services in the same VPC/subnets as RDS. Security group: ALB → 8000 and ALB → 80.

## Health checks and ALB

| Target | Container port | Path | Notes |
| --- | --- | --- | --- |
| API | 8000 | `GET /api/v1/health` | Liveness; no DB. Image includes `curl`. |
| API ready | 8000 | `GET /api/v1/health/ready` | Hits Postgres. Prefer this for ALB if you want unhealthy when RDS is down; allow a long start period (migrations in entrypoint). |
| Web | 80 | `GET /` | nginx; image uses `wget` (alpine). |

Same-origin pattern (recommended): one HTTPS listener, path `/api/*` → API target group, default → web. Then set ECS env `API_BASE_URL=https://your-host/api/v1` and `CORS_ORIGINS=https://your-host`, `PUBLIC_BASE_URL=https://your-host`.

## Persistence

- **RDS** for Postgres.
- **Media** (`/srv/media`) is lost on task stop unless you attach EFS (or put objects on S3 and change the app).

## Combined task caveat

`awsvpc` puts both containers on the same elastic network interface, so `http://127.0.0.1:8000` works **inside** the task. The Flutter app still runs in the user's browser, so that loopback address is useless for `API_BASE_URL`. Treat combined as a packaging choice, not a way to avoid a public API URL.
