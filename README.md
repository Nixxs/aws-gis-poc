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
- Prefer an explicit `-Profile` on each component deployment. Every AWS call
  uses that profile and the configured region, and STS must match `ACCT` before
  any build or cloud mutation. If omitted, the profile falls back to
  `AWS_PROFILE`, then `default`:
  ```powershell
  $env:AWS_PROFILE = 'dtp'
  ```

### Configuration

- Root [`.env`](.env) holds shared values: `REGION`, `ACCT`, the IAM
  `BOUNDARY` (permissions boundary required by the Landing Zone), and the
  mandatory `lz:` tag values (`TAG_COSTCENTER`, `TAG_BACKUPPLAN`).
- Each component also has its own `.env` (e.g. [`pipeline/.env`](pipeline/.env),
  [`lambda/.env`](lambda/.env), [`frontend/.env`](frontend/.env)).

### Selecting personal AWS or DTP

All three component deployment scripts accept:

- `-Environment self`: reads root and component **.env.self** files; requires
  personal account **878564871075**.
- `-Environment dtp`: reads root and component **.env** files; requires DTP
  account **376640768813**.
- `-Environment current` (default): reads **.env**, verifying its configured
  account against the selected AWS identity.
- `-Profile <name>`: selects credentials explicitly, without changing the shell's
  profile. A mismatched account or an attempted profile/region override aborts.
- `-CheckOnly`: validates configuration and AWS identity, then returns without
  building or deploying. This is not a full resource/permission dry run.

Personal and DTP configurations are **not copied over one another**. The personal
files are [.env.self](.env.self), [pipeline/.env.self](pipeline/.env.self),
[lambda/.env.self](lambda/.env.self), and [frontend/.env.self](frontend/.env.self).
The frontend build receives the selected `VITE_*` values explicitly; DTP values
from Vite's default environment files cannot leak into the personal build.

The personal AWS profile currently available is `intelligis.io`. Verify all
three components first:

```powershell
.\pipeline\deploy.ps1 -Environment self -Profile intelligis.io -CheckOnly
.\lambda\deploy.ps1 -Environment self -Profile intelligis.io -CheckOnly
.\frontend\deploy.ps1 -Environment self -Profile intelligis.io -CheckOnly
```

Personal application: **https://d2343zgqxmbmvm.cloudfront.net/**.
Redeployed and HTTP/API smoke-tested on **2026-09-07**: latest frontend bundle,
five-layer configuration/API listing, PMTiles access, and a one-feature GeoJSON
query all passed. CloudFront propagation and cache invalidation completed.
Batch job definition is revision **7**; the existing datasets were not reprocessed.

Then redeploy in order (stop if a command fails):

```powershell
.\pipeline\deploy.ps1 -Environment self -Profile intelligis.io
.\lambda\deploy.ps1 -Environment self -Profile intelligis.io
# Verify VITE_QUERY_API_URL in frontend/.env.self is the personal Lambda URL.
.\frontend\deploy.ps1 -Environment self -Profile intelligis.io
```

For DTP use `-Environment dtp -Profile dtp` instead. The DTP teardown remains
separate and account-pinned; these deployment changes do not modify its scope.

**Personal redeployment does not require another VPC.** Its existing Batch
environment uses a subnet with an internet-gateway route and
`ASSIGN_PUBLIC_IP=ENABLED` in [pipeline/.env.self](pipeline/.env.self). DTP defaults
to `DISABLED` with private endpoints. Other non-DTP configurations must explicitly
set `ASSIGN_PUBLIC_IP` to suit their network. Existing Batch compute environments
are reused, not automatically migrated to different subnets.

`BOUNDARY`, `TAG_COSTCENTER`, and `TAG_BACKUPPLAN` remain mandatory for DTP;
they are optional outside DTP (supply both tag values or neither). Any supplied
boundary must belong to the selected account. Existing IAM role trust policies
are left unchanged, preserving the DTP SCP restriction.

The latest frontend deploy adds app-data routing to the existing web CloudFront
distribution: `/config.json` and `/public/*` use the app bucket, while the SPA
uses the web bucket. Personal frontend URLs therefore use `/config.json` and
`/public/pmtiles/`. Existing datasets remain in S3; deploying the pipeline does
**not** reprocess them. Older separate data distributions are not deleted by
deployment and should only be retired after checking other consumers.

Offline safety tests (no real AWS or npm calls):

```powershell
.\tests\deployment.Tests.ps1
```

### Step 0 — DTP private network (only if missing)

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

- App data is served through CloudFront + OAC, not a public S3 policy. DTP
  blocks changes to S3 public-access-block settings; frontend deployment reports
  that restriction and relies on DTP's existing account-level protection.
- DTP requires the permissions boundary and inline bucket creation tags. These
  requirements are retained even when selecting the configuration with `current`.
- The Lambda public Function URL (auth NONE) was permitted in this deployment;
  future account policy changes could require a different API entry point.


## Tear down the GIS POC in DTP

[teardown-dtp.ps1](teardown-dtp.ps1) removes **this project's deployment only**,
not everything in the DTP account. Its explicit allowlist is derived from the
three component deployment scripts and [pipeline/create-network.ps1](pipeline/create-network.ps1),
using the recorded DTP resource names. It pins account **376640768813**, region
**ap-southeast-2**, and the project's VPC ID. It does not load deployment `.env`
files, so switching local deployment settings cannot redirect deletion.

### 1. Preview first (read-only AWS inventory)

Requires AWS CLI v2 and a working DTP profile; Docker and Python are not needed.
Run from the repository root:

```powershell
.\teardown-dtp.ps1 -Profile dtp
```

The script verifies the caller's account, lists the exact resources found, and
checks for unexpected CloudFront origins, shared Batch compute environments and
unexpected project-VPC resources. Discovery/permission errors abort **before
any deletion**. This is not an account-wide resource audit: review the inventory
with DTP and confirm these project resources have not been reused elsewhere.
If names or the VPC ID have changed, review and update the allowlist explicitly.

### 2. Permanently delete the project

**This stops the website, API and ingestion, and permanently erases the project
S3 data, object versions, delete markers, unfinished uploads, container images
and project logs.** Back up anything needed elsewhere first. Stop uploads,
deployments and manual Batch job submissions before proceeding. Active jobs in
the project queue will be terminated, not allowed to finish.

```powershell
.\teardown-dtp.ps1 -Profile dtp -Execute -ConfirmDeletion 'DELETE GIS POC 376640768813'
```

Both `-Execute` and the exact confirmation phrase are required. `-WhatIf` is
also supported and prevents AWS mutations, including when `-Execute` is supplied.
**Creating the script or running its offline tests does not run a live teardown.**

The deletion scope is:

- The project EventBridge rule and targets; Batch jobs, queue, compute
  environment and active job-definition revisions; empty Batch-generated ECS
  clusters matching this compute environment.
- The query Lambda, including its Function URL and published versions.
- The project's CloudFront distribution and its OAC, only when the OAC is unused.
- The three DTP project S3 buckets and all their contents, plus the two ECR
  repositories and all their images.
- The Lambda log group and only `gis-poc-job/` streams in the shared Batch log group.
- The four project IAM roles and the known `gis-poc-perm-check` test role.
  Role policy attachments/inline policies are removed before deleting roles;
  managed policy objects and the shared permissions boundary are not deleted.
- The dedicated project's VPC endpoints, route-table association/table,
  security groups, subnet and VPC. Network interfaces are never force-deleted.

**Preserved:** DTP/shared infrastructure, AWS-managed policies, service-linked
roles (including `AWSServiceRoleForBatch`), the shared `/aws/batch/job` log group,
backup vaults/recovery points, and all local files. AWS-retained Batch job history
and inactive job-definition revisions are left to AWS retention. Retention locks
and MFA-delete restrictions are not bypassed; retained copies/backups need DTP
review if complete data erasure is required.

### 3. Rerun until cleanup is complete

AWS deletes CloudFront, Batch and interface endpoints asynchronously. The script
does not poll or force-delete dependencies: it reports pending work and retains
dependent data/images/networking until their workloads have been removed. **Run
the same confirmed command again after AWS finishes the pending operation.**
Several passes may be necessary; CloudFront changes can take several minutes.

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Preview completed, or allowlisted cleanup completed. Run preview again to verify. |
| `1` | A failure needs review/admin action; see the summary. Independent cleanup may have succeeded. |
| `2` | AWS cleanup is pending; rerun later. |

DTP has previously denied `iam:DeleteRole` through an SCP. Such roles are
reported as failures for **DTP administrator cleanup**, never silently treated
as deleted. An admin may also be needed for unexpected dependencies or retained
S3 objects. Do not rerun deployment scripts afterward unless recreating the POC
is intentional.

### Offline validation

[tests/teardown-dtp.Tests.ps1](tests/teardown-dtp.Tests.ps1) replaces `aws` with a
strict mock; it never connects to AWS. It exercises preview/WhatIf, account and
ownership checks, asynchronous cleanup, S3 versions/retention, IAM denial and
network dependency ordering, without needing Pester:

```powershell
.\tests\teardown-dtp.Tests.ps1
```

## Migration Plan Notes
- tooling layer needs to be added to the migration
- Add risks
    - ie arcgis > config.json file needs to be maintained as well