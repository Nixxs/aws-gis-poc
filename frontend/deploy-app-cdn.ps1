<#
.SYNOPSIS
    Put a dedicated CloudFront distribution in front of the app DATA bucket so the
    frontend fetches pmtiles via the CDN (edge-cached) instead of direct S3.

.DESCRIPTION
    Idempotent - safe to run repeatedly. Reads ../.env (ACCT, REGION) and
    ./.env (APP_BUCKET, APP_CDN_COMMENT).

    Scope for now: PMTILES DELIVERY ONLY.
      - The data bucket stays PUBLIC. geoparquet, config.json and the Lambda keep
        reading it directly, so we do NOT touch the bucket policy or add OAC here.
      - OAC + private lockdown is a later branch.

    This script only:
      1. Ensures a CloudFront distribution with the app bucket as a PUBLIC S3 origin.
      2. Attaches the managed SimpleCORS response-headers policy (the app is served
         from a different CloudFront domain, so tile fetches are cross-origin).
      3. Uses the managed CachingOptimized cache policy. NO SPA error responses -
         this serves data, not an app, so a missing object should stay a real 404.

    Prints the CloudFront domain to drop into VITE_PMTILES_BASE_URL.

.NOTES
    Requires: AWS CLI (aws configure). Default *.cloudfront.net cert (no custom domain).
    Run: powershell -File frontend\deploy-app-cdn.ps1
#>

$ErrorActionPreference = "Stop"

$frontendDir = $PSScriptRoot
$repoRoot    = Split-Path -Parent $frontendDir
$envFile     = Join-Path $repoRoot ".env"       # shared config (ACCT, REGION)
$appEnvFile  = Join-Path $frontendDir ".env"    # frontend config (VITE_*, APP_*)

# AWS managed policy IDs (stable, account-agnostic).
$CACHING_OPTIMIZED_ID = "658327ea-f89d-4fab-a63d-7e88639e58f6"  # CachePolicy: CachingOptimized
$SIMPLE_CORS_ID       = "60669652-455b-4ae9-85a4-c4c02393f86c"  # ResponseHeadersPolicy: SimpleCORS

# --- helpers ---------------------------------------------------------------

function Read-DotEnv($path) {
    if (-not (Test-Path $path)) { throw ".env not found at $path" }
    $cfg = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
    }
    foreach ($key in 'REGION', 'ACCT') {
        if (-not $cfg.ContainsKey($key)) { throw ".env is missing required key: $key" }
    }
    return $cfg
}

function Invoke-AWS { & aws @args; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" } }

$cfg    = Read-DotEnv $envFile
$ACCT   = $cfg.ACCT
$REGION = $cfg.REGION

# APP_* live in frontend/.env; fall back to defaults if absent.
$app = @{}
if (Test-Path $appEnvFile) {
    foreach ($line in Get-Content $appEnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') { $app[$Matches[1]] = $Matches[2] }
    }
}
$APP_BUCKET = if ($app.APP_BUCKET)     { $app.APP_BUCKET }     else { "gis-poc-app-intelligis" }
$COMMENT    = if ($app.APP_CDN_COMMENT){ $app.APP_CDN_COMMENT }else { "gis-poc-app-cdn" }  # used to find the distribution again

Write-Host "Fronting data bucket with CloudFront  ACCT=$ACCT REGION=$REGION bucket=$APP_BUCKET" -ForegroundColor Green

# --- Ensure distribution ---------------------------------------------------

Write-Host "==> Ensuring CloudFront distribution ($COMMENT)" -ForegroundColor Cyan
$distId = aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$COMMENT'].Id | [0]" --output text
$origin = "$APP_BUCKET.s3.$REGION.amazonaws.com"
$ref    = "$COMMENT-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

if (-not $distId -or $distId -eq "None") {
    Write-Host "    creating distribution (public S3 origin, SimpleCORS, no SPA fallback)" -ForegroundColor DarkGray
    $distCfg = @"
{
  "CallerReference": "$ref",
  "Comment": "$COMMENT",
  "Enabled": true,
  "Origins": { "Quantity": 1, "Items": [ {
    "Id": "s3-$APP_BUCKET", "DomainName": "$origin",
    "S3OriginConfig": { "OriginAccessIdentity": "" } } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-$APP_BUCKET",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "$CACHING_OPTIMIZED_ID",
    "ResponseHeadersPolicyId": "$SIMPLE_CORS_ID",
    "Compress": true },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true }
}
"@
    $tmp = Join-Path $frontendDir "app-cdn-config.tmp.json"
    [System.IO.File]::WriteAllText($tmp, $distCfg, (New-Object System.Text.UTF8Encoding($false)))
    $distId = aws cloudfront create-distribution --distribution-config ("file://" + ($tmp -replace '\\','/')) --query "Distribution.Id" --output text
    Remove-Item $tmp
} else {
    Write-Host "    distribution already exists" -ForegroundColor DarkGray
}

$domain = aws cloudfront get-distribution --id $distId --query "Distribution.DomainName" --output text
Write-Host "    distribution=$distId  domain=$domain" -ForegroundColor DarkGray

Write-Host "`nDone. pmtiles CDN: https://$domain" -ForegroundColor Green
Write-Host "Set frontend/.env:" -ForegroundColor Yellow
Write-Host "    VITE_PMTILES_BASE_URL=https://$domain/public/pmtiles/" -ForegroundColor Yellow
Write-Host "then rebuild + redeploy the frontend (frontend\deploy.ps1)." -ForegroundColor Yellow
Write-Host "(First deploy can take ~5-15 min for CloudFront to finish provisioning.)" -ForegroundColor DarkGray
