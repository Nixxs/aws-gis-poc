# run-local.ps1 - build the Lambda image and run it locally using the AWS Lambda
# Runtime Interface Emulator (RIE), which is baked into the base image. This lets
# you invoke the function exactly the way AWS does, WITHOUT deploying.
#
# Usage:
#   1. Run this script. It builds the image and starts the container in the
#      foreground, listening on http://localhost:9000.
#   2. In a SECOND terminal, POST an event to the emulator endpoint:
#        http://localhost:9000/2015-03-31/functions/function/invocations
#      (see invoke-local.ps1, or the curl examples in DEVLOG.)
#   3. Press Ctrl+C in this window to stop the container.
#
# Note: DuckDB reads the parquet straight from S3, so the container needs real
# AWS credentials. We export them from your configured AWS CLI profile and pass
# them in as environment variables.

$ErrorActionPreference = "Stop"

$IMAGE  = "gis-poc-query:local"
$REGION = "ap-southeast-2"
$APP    = "gis-poc-app-intelligis"
$PREFIX = "public/geoparquet/"

Write-Host "==> Building image $IMAGE" -ForegroundColor Cyan
docker build --platform linux/amd64 -t $IMAGE $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }

Write-Host "==> Exporting AWS credentials from your CLI profile" -ForegroundColor Cyan
$envLines = aws configure export-credentials --format env-no-export 2>$null
if (-not $envLines) {
    throw "Could not export AWS credentials. Run 'aws configure' (or 'aws sso login') first."
}

# Turn each "AWS_FOO=bar" line into a pair of "-e" "AWS_FOO=bar" docker args.
$credArgs = @()
foreach ($line in $envLines) {
    if ($line -match '^\s*(AWS_[A-Z_]+)=(.*)$') {
        $credArgs += "-e"
        $credArgs += "$($Matches[1])=$($Matches[2])"
    }
}

Write-Host "==> Starting container on http://localhost:9000 (Ctrl+C to stop)" -ForegroundColor Cyan
Write-Host ""
Write-Host "    Invoke URL (POST to this from Postman/curl):" -ForegroundColor Yellow
Write-Host "      http://localhost:9000/2015-03-31/functions/function/invocations" -ForegroundColor White
Write-Host ""
Write-Host "    This is the AWS Lambda Runtime Interface Emulator endpoint - the path" -ForegroundColor DarkGray
Write-Host "    is fixed ('2015-03-31' is the Lambda Invoke API version, not a date)." -ForegroundColor DarkGray
Write-Host "    Send the event in the body, e.g.:" -ForegroundColor DarkGray
Write-Host '      {"requestContext":{"http":{"method":"GET"}},"queryStringParameters":{"action":"list-layers"}}' -ForegroundColor White
Write-Host ""
docker run --rm -p 9000:8080 `
    -e APP_BUCKET=$APP `
    -e GEOPARQUET_PREFIX=$PREFIX `
    -e AWS_REGION=$REGION `
    -e AWS_DEFAULT_REGION=$REGION `
    @credArgs `
    $IMAGE
