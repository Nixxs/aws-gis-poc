# aws-gis-poc
An AWS hosted modern GIS webmapping architecture POC

<img width="1780" height="1874" alt="DTP - POC Architecture DRAFT" src="https://github.com/user-attachments/assets/64697499-b9b5-470b-8110-6c41f9b34641" />

## Project structure

The repository is split by component, each self-contained with its own
`deploy.ps1`, `Dockerfile` (where relevant), `requirements.txt` and `.env`:

- **`pipeline/`** — the data-processing pipeline. A containerised job (run on AWS
  Batch / Fargate) that ingests source data, converts it to GeoParquet and
  PMTiles, and writes the outputs to the app S3 bucket. Triggered by uploads to
  the ingestion bucket via S3 → EventBridge. Includes `create-network.ps1` for
  the private VPC + endpoints it runs on.
- **`lambda/`** — the query API backend. A container-image Lambda exposing a
  public Function URL that answers spatial/attribute queries against the
  processed data.
- **`frontend/`** — the web map application (Vite + TypeScript). Built to static
  assets and served from a private S3 bucket via CloudFront.
- **`performance-script/`** — standalone performance/benchmark utilities (API
  latency/throughput and frontend/map loading metrics). Not part of the deployed
  stack; see [`performance-script/readme.md`](performance-script/readme.md).
- **`data/`** — sample source data and `config.json` used by the pipeline / app.

## How to deploy

The stack has **three independent components**, each with its own `deploy.ps1`.
There is no single root deploy script — you run them in order. All scripts are
idempotent (safe to re-run).

### Prerequisites

- **AWS CLI v2**, **Docker Desktop running**, and **Node.js / npm**.
- An AWS CLI profile for the target account. For DTP, the profile is `dtp`:
  ```powershell
  aws configure --profile dtp        # one-time, if not already set up
  aws sts get-caller-identity --profile dtp   # should show account 376640768813
  ```
- The deploy scripts call bare `aws` (no `--profile`), so **you must select the
  profile in the terminal before running anything**:
  ```powershell
  $env:AWS_PROFILE = 'dtp'
  ```

### Configuration

- Root [`.env`](.env) holds shared values: `REGION`, `ACCT`, the IAM
  `BOUNDARY` (permissions boundary required by the Landing Zone), and the
  mandatory `lz:` tag values (`TAG_COSTCENTER`, `TAG_BACKUPPLAN`).
- Each component also has its own `.env` (e.g. [`pipeline/.env`](pipeline/.env),
  [`lambda/.env`](lambda/.env), [`frontend/.env`](frontend/.env)).

### Step 0 — Private network (once per account)

DTP's Landing Zone blocks internet gateways, so the pipeline runs on a private
VPC that reaches AWS services (ECR, S3, CloudWatch Logs) over VPC endpoints.
Create it, then paste the printed values into [`pipeline/.env`](pipeline/.env):

```powershell
$env:AWS_PROFILE = 'dtp'
powershell -ExecutionPolicy Bypass -File pipeline\create-network.ps1 -Profile dtp
# copy the printed VPC= / SUBNET= / SG= lines into pipeline/.env
```

### Step 1 — Pipeline (data processing)

Builds the processing image, pushes to ECR, creates the Batch roles (with the
permissions boundary), compute environment + queue on the private subnet,
ensures the ingestion + app buckets (compliantly tagged), and wires the
S3 → EventBridge trigger.

```powershell
$env:AWS_PROFILE = 'dtp'
powershell -ExecutionPolicy Bypass -File pipeline\deploy.ps1
```

### Step 2 — Lambda (query API)

Builds the query image, pushes to ECR, creates the execution role (with the
permissions boundary), deploys the function, and creates a public Function URL.
Copy the printed Function URL into [`frontend/.env`](frontend/.env) as
`VITE_QUERY_API_URL`.

```powershell
$env:AWS_PROFILE = 'dtp'
powershell -ExecutionPolicy Bypass -File lambda\deploy.ps1
```

### Step 3 — Frontend (web app)

Runs `npm run build`, uploads to a private S3 bucket (tagged), and serves it
via CloudFront with Origin Access Control (HTTPS).

```powershell
$env:AWS_PROFILE = 'dtp'
powershell -ExecutionPolicy Bypass -File frontend\deploy.ps1
```

### Deploy order & why

1. **Pipeline** first — creates the `APP` bucket that the Lambda reads from and
   the frontend serves data from.
2. **Lambda** next — then put its Function URL into `frontend/.env`.
3. **Frontend** last — so the built app has the API URL baked in.

### Known Landing Zone caveats (DTP account)

- The app bucket is made publicly readable via a bucket **policy** (pipeline
  step 5). If the `PreventPublicBucketACL` SCP blocks this, app-data delivery
  must move to CloudFront + OAC (private bucket).
- The Lambda **public Function URL** (auth NONE) may be restricted; if so, front
  it with CloudFront instead.


