<#
.SYNOPSIS
    Deploy the built frontend as a secure static app: private S3 + CloudFront (OAC) + HTTPS.

.DESCRIPTION
    Reads ../.env for ACCT and REGION. Idempotent - safe to run repeatedly:
      1. npm run build -> dist/
      2. Ensures a PRIVATE S3 bucket (Block Public Access ON) for the build.
      3. Ensures a CloudFront Origin Access Control (OAC).
      4. Ensures a CloudFront distribution (HTTPS, SPA fallback to index.html)
         with a second origin for the private app-data bucket (public/*, config.json).
      5. Locks the web + app bucket policies so ONLY this distribution can read them.
      6. Syncs dist/ to S3 and invalidates the cache.

    Users hit https://<id>.cloudfront.net ; S3 is never publicly reachable.

.NOTES
    Requires: AWS CLI (aws configure), Node/npm. Default *.cloudfront.net cert (no domain setup).
    Run: powershell -File frontend\deploy-frontend.ps1
#>

$ErrorActionPreference = "Stop"

$frontendDir = $PSScriptRoot
$repoRoot    = Split-Path -Parent $frontendDir
$envFile     = Join-Path $repoRoot ".env"           # pipeline config (ACCT, REGION, ...)
$webEnvFile  = Join-Path $frontendDir ".env"        # frontend config (VITE_*, WEB_*)

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

# WEB_* live in frontend/.env; fall back to defaults if absent.
$web = @{}
if (Test-Path $webEnvFile) {
    foreach ($line in Get-Content $webEnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') { $web[$Matches[1]] = $Matches[2] }
    }
}
$WEB_BUCKET = if ($web.WEB_BUCKET)   { $web.WEB_BUCKET }   else { "gis-poc-web-intelligis" }
$APP_BUCKET = if ($web.APP_BUCKET)   { $web.APP_BUCKET }   else { "gis-poc-app-intelligis" }
$COMMENT    = if ($web.WEB_COMMENT)  { $web.WEB_COMMENT }  else { "gis-poc-web" }   # used to find the distribution again
$OAC_NAME   = if ($web.WEB_OAC_NAME) { $web.WEB_OAC_NAME } else { "gis-poc-web-oac" }

Write-Host "Deploying web app  ACCT=$ACCT REGION=$REGION bucket=$WEB_BUCKET" -ForegroundColor Green

# --- 1. Build --------------------------------------------------------------

Write-Host "==> 1/6 Building frontend (npm run build)" -ForegroundColor Cyan
npm --prefix $frontendDir run build
if ($LASTEXITCODE -ne 0) { throw "npm build failed" }
$dist = Join-Path $frontendDir "dist"
if (-not (Test-Path $dist)) { throw "dist/ not found after build" }

# --- 2. Private bucket -----------------------------------------------------

Write-Host "==> 2/6 Ensuring private bucket" -ForegroundColor Cyan
$ErrorActionPreference = "SilentlyContinue"
& aws s3api head-bucket --bucket $WEB_BUCKET 2>$null
$bucketMissing = ($LASTEXITCODE -ne 0)
$ErrorActionPreference = "Stop"
if ($bucketMissing) {
    Write-Host "    creating $WEB_BUCKET" -ForegroundColor DarkGray
    # DTP Landing Zone: lz: tags must be in the CreateBucket request (EnforceLzTags SCP).
    $bucketCfg = "LocationConstraint=$REGION,Tags=[{Key=lz:CostCenter,Value=$($cfg.TAG_COSTCENTER)},{Key=lz:BackupPlan,Value=$($cfg.TAG_BACKUPPLAN)}]"
    Invoke-AWS s3api create-bucket --bucket $WEB_BUCKET --region $REGION `
        --create-bucket-configuration $bucketCfg
}
# DTP Landing Zone denies s3:PutBucketPublicAccessBlock (SCP p-neh3z9jw); the account
# already enforces Block Public Access, and we never make this bucket public. Best-effort:
# warn + continue if the guardrail denies it.
$ErrorActionPreference = "SilentlyContinue"
& aws s3api put-public-access-block --bucket $WEB_BUCKET `
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "    put-public-access-block denied/failed (account-level BPA already enforced) - continuing" -ForegroundColor Yellow }
$ErrorActionPreference = "Stop"

# --- 3. Origin Access Control ---------------------------------------------

Write-Host "==> 3/6 Ensuring CloudFront OAC" -ForegroundColor Cyan
$oacId = aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='$OAC_NAME'].Id | [0]" --output text
if (-not $oacId -or $oacId -eq "None") {
    $oacCfg = @"
{ "Name": "$OAC_NAME", "SigningProtocol": "sigv4", "SigningBehavior": "always", "OriginAccessControlOriginType": "s3" }
"@
    $of = Join-Path $frontendDir "oac-config.tmp.json"
    [System.IO.File]::WriteAllText($of, $oacCfg, (New-Object System.Text.UTF8Encoding($false)))
    $oacId = aws cloudfront create-origin-access-control --origin-access-control-config ("file://" + ($of -replace '\\','/')) --query "OriginAccessControl.Id" --output text
    Remove-Item $of
}
Write-Host "    OAC=$oacId" -ForegroundColor DarkGray

# --- 4. Distribution (2 origins: SPA + app-data) ---------------------------

Write-Host "==> 4/6 Ensuring CloudFront distribution" -ForegroundColor Cyan
$distId    = aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$COMMENT'].Id | [0]" --output text
$webOrigin = "$WEB_BUCKET.s3.$REGION.amazonaws.com"
$appOrigin = "$APP_BUCKET.s3.$REGION.amazonaws.com"

# Builds the full DistributionConfig. Two S3 origins share one OAC:
#   default behavior          -> SPA (web bucket)
#   public/* , config.json    -> app-data bucket (Option A: same-origin delivery)
# CachePolicyId 658327ea... is the AWS-managed CachingOptimized policy.
function Build-DistConfig($ref) {
    # Origins + behaviors carry the FULL set of fields (CustomHeaders, AllowedMethods,
    # TrustedSigners, etc.). create-distribution would default these, but
    # update-distribution requires a complete config (it rejects a partial origin with
    # "The 'OriginCustomHeaders' field is missing."). Since the update path overwrites
    # only these three sections onto the fetched config, they must be self-complete.
    return @"
{
  "CallerReference": "$ref",
  "Comment": "$COMMENT",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": { "Quantity": 2, "Items": [
    { "Id": "s3-$WEB_BUCKET", "DomainName": "$webOrigin", "OriginPath": "",
      "CustomHeaders": { "Quantity": 0 },
      "OriginAccessControlId": "$oacId",
      "S3OriginConfig": { "OriginAccessIdentity": "" },
      "ConnectionAttempts": 3, "ConnectionTimeout": 10,
      "OriginShield": { "Enabled": false } },
    { "Id": "s3-$APP_BUCKET", "DomainName": "$appOrigin", "OriginPath": "",
      "CustomHeaders": { "Quantity": 0 },
      "OriginAccessControlId": "$oacId",
      "S3OriginConfig": { "OriginAccessIdentity": "" },
      "ConnectionAttempts": 3, "ConnectionTimeout": 10,
      "OriginShield": { "Enabled": false } } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-$WEB_BUCKET",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": true,
    "SmoothStreaming": false,
    "FieldLevelEncryptionId": "",
    "TrustedSigners": { "Enabled": false, "Quantity": 0 },
    "TrustedKeyGroups": { "Enabled": false, "Quantity": 0 },
    "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } },
    "LambdaFunctionAssociations": { "Quantity": 0 },
    "FunctionAssociations": { "Quantity": 0 } },
  "CacheBehaviors": { "Quantity": 2, "Items": [
    { "PathPattern": "public/*", "TargetOriginId": "s3-$APP_BUCKET",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
      "Compress": true, "SmoothStreaming": false, "FieldLevelEncryptionId": "",
      "TrustedSigners": { "Enabled": false, "Quantity": 0 },
      "TrustedKeyGroups": { "Enabled": false, "Quantity": 0 },
      "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"],
        "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } },
      "LambdaFunctionAssociations": { "Quantity": 0 },
      "FunctionAssociations": { "Quantity": 0 } },
    { "PathPattern": "config.json", "TargetOriginId": "s3-$APP_BUCKET",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
      "Compress": true, "SmoothStreaming": false, "FieldLevelEncryptionId": "",
      "TrustedSigners": { "Enabled": false, "Quantity": 0 },
      "TrustedKeyGroups": { "Enabled": false, "Quantity": 0 },
      "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"],
        "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } },
      "LambdaFunctionAssociations": { "Quantity": 0 },
      "FunctionAssociations": { "Quantity": 0 } } ] },
  "CustomErrorResponses": { "Quantity": 2, "Items": [
    { "ErrorCode": 403, "ResponseCode": "200", "ResponsePagePath": "/index.html", "ErrorCachingMinTTL": 10 },
    { "ErrorCode": 404, "ResponseCode": "200", "ResponsePagePath": "/index.html", "ErrorCachingMinTTL": 10 } ] },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true }
}
"@
}

if (-not $distId -or $distId -eq "None") {
    $ref = "$COMMENT-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tmp = Join-Path $frontendDir "dist-config.tmp.json"
    [System.IO.File]::WriteAllText($tmp, (Build-DistConfig $ref), (New-Object System.Text.UTF8Encoding($false)))
    $distId = aws cloudfront create-distribution --distribution-config ("file://" + ($tmp -replace '\\','/')) --query "Distribution.Id" --output text
    Remove-Item $tmp
} else {
    # Distribution exists: converge its routing to the template above (adds the
    # app-data origin + behaviors and ensures the OAC is attached). update-distribution
    # needs the FULL config + current ETag, so we fetch it and overwrite only the
    # routing sections, keeping the existing CallerReference (must not change).
    Write-Host "    updating existing distribution routing" -ForegroundColor DarkGray
    $etag    = aws cloudfront get-distribution-config --id $distId --query "ETag" --output text
    $current = aws cloudfront get-distribution-config --id $distId --query "DistributionConfig" | ConvertFrom-Json
    $tpl     = (Build-DistConfig $current.CallerReference) | ConvertFrom-Json
    $current.Origins              = $tpl.Origins
    $current.DefaultCacheBehavior = $tpl.DefaultCacheBehavior
    $current.CacheBehaviors       = $tpl.CacheBehaviors
    $uf = Join-Path $frontendDir "dist-update.tmp.json"
    [System.IO.File]::WriteAllText($uf, ($current | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
    Invoke-AWS cloudfront update-distribution --id $distId --if-match $etag --distribution-config ("file://" + ($uf -replace '\\','/')) | Out-Null
    Remove-Item $uf
}
$domain = aws cloudfront get-distribution --id $distId --query "Distribution.DomainName" --output text
Write-Host "    distribution=$distId  domain=$domain" -ForegroundColor DarkGray

# --- 5. Lock both buckets to this distribution only ------------------------

Write-Host "==> 5/6 Applying OAC bucket policies" -ForegroundColor Cyan
# Grants ONLY this CloudFront distribution (via OAC) s3:GetObject. This is not a
# public policy, so it is accepted even with Block Public Access fully on.
function Set-OacPolicy($bucket, $resourceJson) {
    $policy = @"
{ "Version": "2012-10-17", "Statement": [ {
  "Sid": "AllowCloudFrontRead", "Effect": "Allow",
  "Principal": { "Service": "cloudfront.amazonaws.com" },
  "Action": "s3:GetObject", "Resource": $resourceJson,
  "Condition": { "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::${ACCT}:distribution/$distId" } } } ] }
"@
    $pf = Join-Path $frontendDir "oac-policy.tmp.json"
    [System.IO.File]::WriteAllText($pf, $policy, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-AWS s3api put-bucket-policy --bucket $bucket --policy ("file://" + ($pf -replace '\\','/'))
    Remove-Item $pf
}

# SPA bucket: the whole bucket is readable by this distribution.
Set-OacPolicy $WEB_BUCKET "`"arn:aws:s3:::$WEB_BUCKET/*`""

# App-data bucket (created by pipeline\deploy.ps1): only the paths CloudFront
# serves - config.json and public/*.
$ErrorActionPreference = "SilentlyContinue"
& aws s3api head-bucket --bucket $APP_BUCKET 2>$null
$appMissing = ($LASTEXITCODE -ne 0)
$ErrorActionPreference = "Stop"
if ($appMissing) {
    Write-Host "    WARNING: app bucket $APP_BUCKET not found - run pipeline\deploy.ps1 first; skipping app OAC policy" -ForegroundColor Yellow
} else {
    Set-OacPolicy $APP_BUCKET "[`"arn:aws:s3:::$APP_BUCKET/config.json`", `"arn:aws:s3:::$APP_BUCKET/public/*`"]"
}

# --- 6. Upload + invalidate ------------------------------------------------

Write-Host "==> 6/6 Syncing dist/ and invalidating cache" -ForegroundColor Cyan
Invoke-AWS s3 sync $dist "s3://$WEB_BUCKET" --delete
Invoke-AWS cloudfront create-invalidation --distribution-id $distId --paths "/*"

Write-Host "`nDone. App: https://$domain" -ForegroundColor Green
Write-Host "(First deploy can take ~5-15 min for CloudFront to finish provisioning.)" -ForegroundColor DarkGray
