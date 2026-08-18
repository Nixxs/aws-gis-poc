<#
.SYNOPSIS
    Create a private VPC network (no internet gateway) for the GIS POC Batch pipeline.

.DESCRIPTION
    DTP's Landing Zone SCP denies ec2:CreateInternetGateway and there is no
    Transit Gateway egress yet, so the Fargate Batch tasks cannot reach the
    internet. They don't need to: everything the pipeline touches at runtime is
    an AWS service (ECR + S3 + CloudWatch Logs). This script wires those up over
    private VPC endpoints instead of a public subnet, idempotently by Name tag:

      1. A VPC (10.20.0.0/16) with DNS support + hostnames (needed for the
         interface endpoints' private DNS).
      2. A PRIVATE subnet (10.20.1.0/24) - no public IP, no IGW route.
      3. A route table associated with the subnet (for the S3 gateway endpoint).
      4. A task security group (egress-all, no inbound) for the Batch tasks.
      5. An endpoints security group allowing inbound 443 from the task SG.
      6. Interface endpoints: ecr.api, ecr.dkr, logs (private DNS enabled).
      7. An S3 gateway endpoint associated with the route table.

    The Batch job definition must run with assignPublicIp=DISABLED to use these.

    It prints the three lines to paste into pipeline\.env:
        VPC=... / SUBNET=... / SG=...   (SG = the TASK security group)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File pipeline\create-network.ps1 -Profile dtp
#>
param(
    [string]$Profile = "dtp",
    [string]$Region  = "ap-southeast-2",
    [string]$Name    = "gis-poc"
)

$ErrorActionPreference = "Stop"

function Invoke-AWS {
    $result = & aws @args --profile $Profile --region $Region --output text
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $result
}

Write-Host "Creating PRIVATE network '$Name' in $Region (profile $Profile)" -ForegroundColor Green

# --- 1. VPC ----------------------------------------------------------------
$vpcId = & aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$Name-vpc" `
    --query "Vpcs[0].VpcId" --profile $Profile --region $Region --output text
if (-not $vpcId -or $vpcId -eq "None") {
    Write-Host "==> creating VPC 10.20.0.0/16" -ForegroundColor Cyan
    $vpcId = Invoke-AWS ec2 create-vpc --cidr-block 10.20.0.0/16 `
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$Name-vpc}]" `
        --query "Vpc.VpcId"
} else {
    Write-Host "==> VPC exists: $vpcId" -ForegroundColor DarkGray
}
# Always (re)apply DNS attributes so a half-created VPC self-heals on re-run.
# Private DNS on the interface endpoints requires BOTH of these to be true.
# Shorthand "Value=true" avoids PowerShell stripping the quotes from inline JSON.
Invoke-AWS ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-support Value=true | Out-Null
Invoke-AWS ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames Value=true | Out-Null

# --- 2. Private subnet -----------------------------------------------------
$subnetId = & aws ec2 describe-subnets --filters "Name=tag:Name,Values=$Name-subnet" `
    --query "Subnets[0].SubnetId" --profile $Profile --region $Region --output text
if (-not $subnetId -or $subnetId -eq "None") {
    Write-Host "==> creating private subnet 10.20.1.0/24" -ForegroundColor Cyan
    $subnetId = Invoke-AWS ec2 create-subnet --vpc-id $vpcId --cidr-block 10.20.1.0/24 `
        --availability-zone "$($Region)a" `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$Name-subnet}]" `
        --query "Subnet.SubnetId"
    # No map-public-ip-on-launch: this is a private subnet.
} else {
    Write-Host "==> subnet exists: $subnetId" -ForegroundColor DarkGray
}

# --- 3. Route table (no IGW route; needed for the S3 gateway endpoint) ------
$rtId = & aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$Name-rt" `
    --query "RouteTables[0].RouteTableId" --profile $Profile --region $Region --output text
if (-not $rtId -or $rtId -eq "None") {
    Write-Host "==> creating route table" -ForegroundColor Cyan
    $rtId = Invoke-AWS ec2 create-route-table --vpc-id $vpcId `
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$Name-rt}]" `
        --query "RouteTable.RouteTableId"
    Invoke-AWS ec2 associate-route-table --route-table-id $rtId --subnet-id $subnetId | Out-Null
} else {
    Write-Host "==> route table exists: $rtId" -ForegroundColor DarkGray
}

# --- 4. Task security group (egress-all, no inbound) -----------------------
$sgId = & aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$vpcId" "Name=group-name,Values=$Name-batch-sg" `
    --query "SecurityGroups[0].GroupId" --profile $Profile --region $Region --output text
if (-not $sgId -or $sgId -eq "None") {
    Write-Host "==> creating task security group (egress-all, no inbound)" -ForegroundColor Cyan
    $sgId = Invoke-AWS ec2 create-security-group --group-name "$Name-batch-sg" `
        --description "GIS POC Batch tasks - outbound only" --vpc-id $vpcId `
        --query "GroupId"
    # Default SG already allows all egress; no inbound rules needed on the task SG.
} else {
    Write-Host "==> task security group exists: $sgId" -ForegroundColor DarkGray
}

# --- 5. Endpoints security group (inbound 443 from the task SG) -------------
$epSgId = & aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$vpcId" "Name=group-name,Values=$Name-endpoints-sg" `
    --query "SecurityGroups[0].GroupId" --profile $Profile --region $Region --output text
if (-not $epSgId -or $epSgId -eq "None") {
    Write-Host "==> creating endpoints security group (inbound 443 from task SG)" -ForegroundColor Cyan
    $epSgId = Invoke-AWS ec2 create-security-group --group-name "$Name-endpoints-sg" `
        --description "GIS POC interface VPC endpoints - HTTPS from tasks" --vpc-id $vpcId `
        --query "GroupId"
    Invoke-AWS ec2 authorize-security-group-ingress --group-id $epSgId `
        --protocol tcp --port 443 --source-group $sgId | Out-Null
} else {
    Write-Host "==> endpoints security group exists: $epSgId" -ForegroundColor DarkGray
}

# --- 6. Interface endpoints: ecr.api, ecr.dkr, logs ------------------------
function Ensure-InterfaceEndpoint($shortName) {
    $service = "com.amazonaws.$Region.$shortName"
    $existing = & aws ec2 describe-vpc-endpoints `
        --filters "Name=vpc-id,Values=$vpcId" "Name=service-name,Values=$service" `
        --query "VpcEndpoints[0].VpcEndpointId" --profile $Profile --region $Region --output text
    if (-not $existing -or $existing -eq "None") {
        Write-Host "==> creating interface endpoint $service" -ForegroundColor Cyan
        Invoke-AWS ec2 create-vpc-endpoint --vpc-id $vpcId --vpc-endpoint-type Interface `
            --service-name $service --subnet-ids $subnetId --security-group-ids $epSgId `
            --private-dns-enabled `
            --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$Name-$($shortName -replace '\.','-')}]" `
            --query "VpcEndpoint.VpcEndpointId" | Out-Null
    } else {
        Write-Host "==> interface endpoint $service exists: $existing" -ForegroundColor DarkGray
    }
}
Ensure-InterfaceEndpoint "ecr.api"
Ensure-InterfaceEndpoint "ecr.dkr"
Ensure-InterfaceEndpoint "logs"

# --- 7. S3 gateway endpoint (attached to the route table) ------------------
$s3Service = "com.amazonaws.$Region.s3"
$s3Ep = & aws ec2 describe-vpc-endpoints `
    --filters "Name=vpc-id,Values=$vpcId" "Name=service-name,Values=$s3Service" `
    --query "VpcEndpoints[0].VpcEndpointId" --profile $Profile --region $Region --output text
if (-not $s3Ep -or $s3Ep -eq "None") {
    Write-Host "==> creating S3 gateway endpoint" -ForegroundColor Cyan
    Invoke-AWS ec2 create-vpc-endpoint --vpc-id $vpcId --vpc-endpoint-type Gateway `
        --service-name $s3Service --route-table-ids $rtId `
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$Name-s3}]" `
        --query "VpcEndpoint.VpcEndpointId" | Out-Null
} else {
    Write-Host "==> S3 gateway endpoint exists: $s3Ep" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Private network ready. Paste these into pipeline\.env:" -ForegroundColor Green
Write-Host ""
Write-Host "VPC=$vpcId"
Write-Host "SUBNET=$subnetId"
Write-Host "SG=$sgId"
Write-Host ""
Write-Host "Remember: job-definition.json must use assignPublicIp=DISABLED." -ForegroundColor Yellow
