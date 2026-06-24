# Deploys the gis-poc-query Lambda (container image) + a public Function URL.
# Idempotent: safe to re-run. Driven by ../.env (needs REGION, ACCT, APP).
#
#   powershell -ExecutionPolicy Bypass -File lambda\deploy.ps1
#
# Requires Docker running + AWS CLI authenticated.

$ErrorActionPreference = "Stop"

# --- paths -----------------------------------------------------------------
$lambdaDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $lambdaDir
$envFile   = Join-Path $repoRoot ".env"
$iamDir    = Join-Path $lambdaDir "iam"
$tmpDir    = Join-Path $lambdaDir ".deploy-tmp"

$functionName = "gis-poc-query"
$roleName     = "gisPocQueryLambdaRole"
$ecrRepoName  = "gis-poc-query"

# --- helpers ---------------------------------------------------------------
function Read-DotEnv($path) {
    if (-not (Test-Path $path)) { throw ".env not found at $path" }
    $c = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([^=\s]+)\s*=\s*(.*)\s*$') { $c[$Matches[1]] = $Matches[2].Trim() }
    }
    foreach ($k in 'REGION', 'ACCT', 'APP') {
        if (-not $c.ContainsKey($k) -or -not $c[$k]) { throw ".env missing required key: $k" }
    }
    return $c
}

function File-Uri($path) { return "file://" + ($path -replace '\\', '/') }

function Render-Template($templatePath) {
    $content = Get-Content -Raw $templatePath
    foreach ($key in $cfg.Keys) { $content = $content -replace "{{\s*$key\s*}}", [string]$cfg[$key] }
    if ($content -match '{{') { throw "Unresolved token(s) in $templatePath - check your .env." }
    $outPath = Join-Path $tmpDir ([System.IO.Path]::GetFileName($templatePath))
    # UTF-8 WITHOUT BOM - AWS rejects a BOM (MalformedPolicyDocument).
    [System.IO.File]::WriteAllText($outPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return File-Uri $outPath
}

function Invoke-AWS {
    & aws @args
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

# Runs an aws command quietly and returns $true if it succeeded (exit 0).
# Used for existence checks that are EXPECTED to fail - the local
# SilentlyContinue stops a CLI 'NotFound' on stderr from becoming a
# terminating error under $ErrorActionPreference = 'Stop'.
function Test-AWS {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & aws @args 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $old
    }
}

function Ensure-Role($name, $trustUri) {
    if (-not (Test-AWS iam get-role --role-name $name)) {
        Write-Host "    creating role $name" -ForegroundColor DarkGray
        Invoke-AWS iam create-role --role-name $name --assume-role-policy-document $trustUri
    } else {
        Write-Host "    role $name exists" -ForegroundColor DarkGray
        Invoke-AWS iam update-assume-role-policy --role-name $name --policy-document $trustUri
    }
}

# --- setup -----------------------------------------------------------------
$cfg = Read-DotEnv $envFile
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$registry = "$($cfg.ACCT).dkr.ecr.$($cfg.REGION).amazonaws.com"
$imageUri = "$registry/$($ecrRepoName):latest"
$roleArn  = "arn:aws:iam::$($cfg.ACCT):role/$roleName"
$envVars  = "Variables={APP_BUCKET=$($cfg.APP),GEOPARQUET_PREFIX=public/geoparquet/}"
Write-Host "Deploying $functionName (ACCT=$($cfg.ACCT) REGION=$($cfg.REGION))" -ForegroundColor Green

# --- 1. Build + push image -> ECR ------------------------------------------
Write-Host "==> 1/4 Building and pushing Lambda image" -ForegroundColor Cyan
if (-not (Test-AWS ecr describe-repositories --repository-names $ecrRepoName --region $cfg.REGION)) {
    Write-Host "    creating ECR repo $ecrRepoName" -ForegroundColor DarkGray
    Invoke-AWS ecr create-repository --repository-name $ecrRepoName --region $cfg.REGION
}
aws ecr get-login-password --region $cfg.REGION | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR docker login failed" }
# --provenance=false: Docker Desktop's buildx defaults to producing an OCI
# image index with provenance/attestation manifests, which AWS Lambda cannot
# read ("image manifest ... media type ... is not supported"). Force a plain
# single-platform Docker manifest instead.
docker build --platform linux/amd64 --provenance=false -t $ecrRepoName $lambdaDir
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
docker tag "$($ecrRepoName):latest" $imageUri
docker push $imageUri
if ($LASTEXITCODE -ne 0) { throw "docker push failed" }

# --- 2. IAM execution role -------------------------------------------------
Write-Host "==> 2/4 Ensuring Lambda execution role" -ForegroundColor Cyan
Ensure-Role $roleName (File-Uri (Join-Path $iamDir "trust-policy.json"))
# CloudWatch Logs permissions (AWS-managed).
Invoke-AWS iam attach-role-policy --role-name $roleName `
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
# Read access to the app bucket's public/ data.
Invoke-AWS iam put-role-policy --role-name $roleName `
    --policy-name gisPocQueryS3Access --policy-document (Render-Template (Join-Path $iamDir "role-policy.json"))

# --- 3. Lambda function (create or update) ---------------------------------
Write-Host "==> 3/4 Deploying Lambda function" -ForegroundColor Cyan
if (-not (Test-AWS lambda get-function --function-name $functionName --region $cfg.REGION)) {
    Write-Host "    creating function $functionName" -ForegroundColor DarkGray
    # A freshly created role can take a few seconds before Lambda can assume it.
    # Only that specific error is worth retrying; surface anything else at once.
    $created = $false
    for ($i = 0; $i -lt 12; $i++) {
        $out = & aws lambda create-function --function-name $functionName --region $cfg.REGION `
            --package-type Image --code "ImageUri=$imageUri" --role $roleArn `
            --architectures x86_64 --timeout 30 --memory-size 512 --environment $envVars 2>&1
        if ($LASTEXITCODE -eq 0) { $created = $true; break }
        if ($out -notmatch "cannot be assumed|InvalidParameterValueException.*role") {
            throw "create-function failed: $out"
        }
        Write-Host "    waiting for IAM role to become assumable..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
    if (-not $created) { throw "create-function failed (IAM role propagation?)" }
} else {
    Write-Host "    updating function code + config" -ForegroundColor DarkGray
    Invoke-AWS lambda update-function-code --function-name $functionName --region $cfg.REGION `
        --image-uri $imageUri
    Invoke-AWS lambda wait function-updated --function-name $functionName --region $cfg.REGION
    Invoke-AWS lambda update-function-configuration --function-name $functionName --region $cfg.REGION `
        --role $roleArn --timeout 30 --memory-size 512 --environment $envVars
}
Invoke-AWS lambda wait function-active --function-name $functionName --region $cfg.REGION

# --- 4. Public Function URL ------------------------------------------------
Write-Host "==> 4/4 Ensuring public Function URL" -ForegroundColor Cyan
$corsUri = File-Uri (Join-Path $iamDir "function-url-cors.json")
if (-not (Test-AWS lambda get-function-url-config --function-name $functionName --region $cfg.REGION)) {
    Invoke-AWS lambda create-function-url-config --function-name $functionName --region $cfg.REGION `
        --auth-type NONE --cors $corsUri
} else {
    Invoke-AWS lambda update-function-url-config --function-name $functionName --region $cfg.REGION `
        --auth-type NONE --cors $corsUri
}

# Allow anonymous (public) invocation of the Function URL. Since Oct 2025, AWS
# requires BOTH lambda:InvokeFunctionUrl AND lambda:InvokeFunction on the
# resource policy, each as a separate statement, or the URL returns 403 even
# with auth-type NONE. Always (re)apply so older functions self-heal; the
# probe tolerates the "statement already exists" conflict on re-runs.
Test-AWS lambda add-permission --function-name $functionName --region $cfg.REGION `
    --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl `
    --principal "*" --function-url-auth-type NONE | Out-Null
Test-AWS lambda add-permission --function-name $functionName --region $cfg.REGION `
    --statement-id FunctionURLInvokeAllowPublicAccess --action lambda:InvokeFunction `
    --principal "*" --invoked-via-function-url | Out-Null

$url = aws lambda get-function-url-config --function-name $functionName --region $cfg.REGION `
    --query "FunctionUrl" --output text
Write-Host "Deploy complete." -ForegroundColor Green
Write-Host "Function URL: $url" -ForegroundColor Green
Write-Host "Try: curl `"$($url)?action=list-layers`"" -ForegroundColor Green
