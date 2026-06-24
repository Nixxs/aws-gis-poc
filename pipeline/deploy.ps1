<#
.SYNOPSIS
    One-command deploy for the GIS POC data pipeline.

.DESCRIPTION
    Reads configuration from ../.env (simple KEY=VALUE lines) and brings AWS to
    the desired state. Safe to run repeatedly - it does NOT create duplicate
    resources:

      1. Builds the Docker image and pushes it to ECR.
      2. Ensures the IAM roles exist (creates if missing) and (re)applies their
         inline policies.
      3. Ensures the Batch compute environment + job queue exist (creates if missing).
      4. Registers the Batch job definition (this adds a new *revision* each run -
         that is how Batch versions job definitions; the latest is always used).
      5. Enables S3 -> EventBridge notifications and (re)applies the rule + target.

    The *.json files are TEMPLATES containing {{TOKEN}} placeholders. They are
    rendered with the .env values into ./.deploy-tmp before being applied, so no
    real account IDs / bucket names are hard-coded in the committed files.

.NOTES
    Requires: AWS CLI (configured via `aws configure`), Docker running.
    Run from anywhere: powershell -File pipeline\deploy.ps1
#>

$ErrorActionPreference = "Stop"

$pipelineDir = $PSScriptRoot
$repoRoot    = Split-Path -Parent $pipelineDir
$envFile     = Join-Path $repoRoot ".env"
$iamDir      = Join-Path $pipelineDir "iam"
$batchDir    = Join-Path $pipelineDir "batch"
$ebDir       = Join-Path $pipelineDir "eventbridge"
$tmpDir      = Join-Path $pipelineDir ".deploy-tmp"

# --- helpers ---------------------------------------------------------------

function Read-DotEnv($path) {
    if (-not (Test-Path $path)) { throw ".env not found at $path" }
    $cfg = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') {
            $cfg[$Matches[1]] = $Matches[2]
        }
    }
    foreach ($key in 'REGION', 'ACCT', 'ING', 'APP', 'REPO') {
        if (-not $cfg.ContainsKey($key)) { throw ".env is missing required key: $key" }
    }
    return $cfg
}

# Render a {{TOKEN}} template with the .env values; returns a file:// path.
function Render-Template($templatePath) {
    $content = Get-Content -Raw $templatePath
    foreach ($key in $cfg.Keys) {
        $content = $content -replace "{{\s*$key\s*}}", [string]$cfg[$key]
    }
    if ($content -match '{{') {
        throw "Unresolved token(s) in $templatePath - check your .env has every key the template needs."
    }
    $outPath = Join-Path $tmpDir ([System.IO.Path]::GetFileName($templatePath))
    # Write UTF-8 WITHOUT a BOM. Windows PowerShell 5.1's "-Encoding utf8" adds a
    # BOM, which AWS rejects (MalformedPolicyDocument / "Syntax errors in policy").
    [System.IO.File]::WriteAllText($outPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return "file://" + ($outPath -replace '\\', '/')
}

# file:// path for a static (non-templated) file.
function File-Uri($path) { return "file://" + ($path -replace '\\', '/') }

# Run the AWS CLI and throw if it returns a non-zero exit code.
function Invoke-AWS {
    & aws @args
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

# Create an IAM role if it does not exist; otherwise refresh its trust policy.
function Ensure-Role($roleName, $trustUri) {
    aws iam get-role --role-name $roleName *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    creating role $roleName" -ForegroundColor DarkGray
        Invoke-AWS iam create-role --role-name $roleName --assume-role-policy-document $trustUri
    } else {
        Write-Host "    role $roleName exists" -ForegroundColor DarkGray
        Invoke-AWS iam update-assume-role-policy --role-name $roleName --policy-document $trustUri
    }
}

# --- setup -----------------------------------------------------------------

$cfg = Read-DotEnv $envFile
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
Write-Host "Deploying with ACCT=$($cfg.ACCT) REGION=$($cfg.REGION)" -ForegroundColor Green

# --- 1. Docker image -> ECR ------------------------------------------------

Write-Host "==> 1/6 Building and pushing Docker image" -ForegroundColor Cyan
$registry = "$($cfg.ACCT).dkr.ecr.$($cfg.REGION).amazonaws.com"
aws ecr get-login-password --region $cfg.REGION | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR docker login failed" }
docker build -t gis-poc-pipeline $pipelineDir
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
docker tag gis-poc-pipeline:latest "$($cfg.REPO):latest"
docker push "$($cfg.REPO):latest"
if ($LASTEXITCODE -ne 0) { throw "docker push failed" }

# --- 2. IAM roles + policies ----------------------------------------------

Write-Host "==> 2/6 Ensuring IAM roles and policies" -ForegroundColor Cyan
$batchTrust = File-Uri (Join-Path $iamDir "trust-policy.json")
$ebTrust    = File-Uri (Join-Path $ebDir  "trust-policy.json")

# Execution role: lets Fargate pull the image + write logs (AWS-managed policy).
Ensure-Role "gisPocBatchExecutionRole" $batchTrust
Invoke-AWS iam attach-role-policy --role-name gisPocBatchExecutionRole `
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Job role: the script's own S3 read/write/delete permissions.
Ensure-Role "gisPocBatchJobRole" $batchTrust
Invoke-AWS iam put-role-policy --role-name gisPocBatchJobRole `
    --policy-name gisPocS3Access --policy-document (Render-Template (Join-Path $iamDir "job-role-policy.json"))

# EventBridge role: lets EventBridge submit the Batch job.
Ensure-Role "gisPocEventBridgeRole" $ebTrust
Invoke-AWS iam put-role-policy --role-name gisPocEventBridgeRole `
    --policy-name gisPocSubmitBatch --policy-document (Render-Template (Join-Path $ebDir "submit-batch-policy.json"))

# --- 3. Batch compute environment + job queue (create if missing) ---------

Write-Host "==> 3/6 Ensuring Batch compute environment and job queue" -ForegroundColor Cyan
$ceCount = aws batch describe-compute-environments --compute-environments gis-poc-ce `
    --query "length(computeEnvironments)" --output text 2>$null
if ($ceCount -ne "1") {
    foreach ($key in 'SUBNET', 'SG') {
        if (-not $cfg.ContainsKey($key)) { throw "Creating compute env needs '$key' in .env" }
    }
    Write-Host "    creating compute environment gis-poc-ce" -ForegroundColor DarkGray
    Invoke-AWS batch create-compute-environment --compute-environment-name gis-poc-ce --type MANAGED `
        --compute-resources "type=FARGATE,maxvCpus=4,subnets=$($cfg.SUBNET),securityGroupIds=$($cfg.SG)"

    Write-Host "    waiting for compute environment to become VALID..." -ForegroundColor DarkGray
    for ($i = 0; $i -lt 30; $i++) {
        $status = aws batch describe-compute-environments --compute-environments gis-poc-ce `
            --query "computeEnvironments[0].status" --output text 2>$null
        if ($status -eq "VALID") { break }
        Start-Sleep -Seconds 5
    }
} else {
    Write-Host "    compute environment gis-poc-ce exists" -ForegroundColor DarkGray
}

$qCount = aws batch describe-job-queues --job-queues gis-poc-queue `
    --query "length(jobQueues)" --output text 2>$null
if ($qCount -ne "1") {
    Write-Host "    creating job queue gis-poc-queue" -ForegroundColor DarkGray
    Invoke-AWS batch create-job-queue --job-queue-name gis-poc-queue --priority 1 `
        --compute-environment-order "order=1,computeEnvironment=gis-poc-ce"
} else {
    Write-Host "    job queue gis-poc-queue exists" -ForegroundColor DarkGray
}

# --- 4. Batch job definition (new revision each run) ----------------------

Write-Host "==> 4/6 Registering Batch job definition" -ForegroundColor Cyan
Invoke-AWS batch register-job-definition --cli-input-json (Render-Template (Join-Path $batchDir "job-definition.json"))

# --- 5. Make the app bucket's public/ prefix publicly readable -------------

Write-Host "==> 5/6 Configuring public read access on app bucket" -ForegroundColor Cyan
# Allow a public bucket policy (keep ACLs blocked - we use a bucket policy, not ACLs).
Invoke-AWS s3api put-public-access-block --bucket $cfg.APP `
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"
# Grant anonymous s3:GetObject on the public/ prefix only.
Invoke-AWS s3api put-bucket-policy --bucket $cfg.APP `
    --policy (Render-Template (Join-Path $iamDir "app-bucket-public-policy.json"))
# CORS so browser map clients can fetch PMTiles via HTTP range requests.
Invoke-AWS s3api put-bucket-cors --bucket $cfg.APP `
    --cors-configuration (File-Uri (Join-Path $iamDir "app-bucket-cors.json"))

# --- 6. S3 notifications + EventBridge rule + target ----------------------

Write-Host "==> 6/6 Configuring S3 notifications and EventBridge rule" -ForegroundColor Cyan
Invoke-AWS s3api put-bucket-notification-configuration --bucket $cfg.ING `
    --notification-configuration (File-Uri (Join-Path $ebDir "bucket-notification.json"))
Invoke-AWS events put-rule --name gis-poc-s3-trigger `
    --event-pattern (Render-Template (Join-Path $ebDir "event-pattern.json"))
Invoke-AWS events put-targets --rule gis-poc-s3-trigger `
    --targets (Render-Template (Join-Path $ebDir "targets.json"))

Write-Host "Deploy complete." -ForegroundColor Green
