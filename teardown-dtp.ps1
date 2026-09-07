#Requires -Version 5.1
<#
.SYNOPSIS
    Preview or delete the GIS POC deployment in DTP, including ALL project data.
.DESCRIPTION
    Exact allowlist derived from frontend/deploy.ps1, lambda/deploy.ps1,
    pipeline/deploy.ps1 and pipeline/create-network.ps1, with DTP deployment names.
    Does NOT delete everything in the AWS account. Does not read .env files or
    touch shared policies, service-linked roles, backup vaults or shared log groups.

    Default is read-only live inventory. -Execute additionally requires
    -ConfirmDeletion 'DELETE GIS POC 376640768813'. -WhatIf never writes to AWS.
    Stop all deploys, uploads and manual job submissions before executing.

    CloudFront, Batch and endpoint deletion are asynchronous. If pending, rerun
    later; dependent resources are retained until workloads/distributions are gone.
    No polling or forced network-interface deletion. Exit codes: 0 = allowlist
    removed (or preview), 1 = failure/admin cleanup required, 2 = pending cleanup.
    An SCP denial is reported, never bypassed. In particular DTP may deny DeleteRole.
.EXAMPLE
    .\teardown-dtp.ps1 -Profile dtp
.EXAMPLE
    .\teardown-dtp.ps1 -Profile dtp -Execute -ConfirmDeletion 'DELETE GIS POC 376640768813'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()][string]$Profile = 'dtp',
    [switch]$Execute,
    [string]$ConfirmDeletion
)

$ErrorActionPreference = 'Stop'
$account = '376640768813'
$region = 'ap-southeast-2'
$vpcId = 'vpc-0add429362ec84a9f'
$bucketNames = @('gis-poc-ingestion-dtp', 'gis-poc-app-dtp', 'gis-poc-web-dtp')
$repoNames = @('gis-poc-pipeline', 'gis-poc-query')
$roleNames = @('gisPocBatchExecutionRole', 'gisPocBatchJobRole',
    'gisPocEventBridgeRole', 'gisPocQueryLambdaRole', 'gis-poc-perm-check')
$activeStates = @('SUBMITTED', 'PENDING', 'RUNNABLE', 'STARTING', 'RUNNING')
$issues = New-Object 'System.Collections.Generic.List[string]'
$pending = New-Object 'System.Collections.Generic.List[string]'
$tempDir = $null

# A failed discovery is NOT treated as an empty result. Only explicitly named
# service error codes can be treated as missing. Always pin profile AND region.
function Invoke-AwsJson {
    param([string[]]$Arguments, [string[]]$MissingCodes = @())
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & aws @Arguments --profile $Profile --region $region --output json --no-cli-pager 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0) {
        foreach ($missing in $MissingCodes) {
            if ($text -match ('\(' + [regex]::Escape($missing) + '\)')) { return $null }
        }
        throw "aws $($Arguments[0]) $($Arguments[1]) failed (exit $code): $text"
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) { return ($text | ConvertFrom-Json) }
}

function Write-JsonArgument($Value) {
    $path = Join-Path $tempDir (([guid]::NewGuid().ToString()) + '.json')
    [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 100 -Compress),
        (New-Object Text.UTF8Encoding($false)))
    return 'file://' + ($path -replace '\\', '/')
}

function Invoke-Phase([string]$Name, [scriptblock]$Action) {
    Write-Host "`n==> $Name" -ForegroundColor Cyan
    try { & $Action }
    catch {
        $message = "$Name : $($_.Exception.Message)"
        $issues.Add($message)
        Write-Warning $message
    }
}

function Add-Pending([string]$Message) {
    $pending.Add($Message)
    Write-Warning $Message
}

function Get-NameTag($Resource) {
    return (@($Resource.Tags | Where-Object { $_.Key -ceq 'Name' } | ForEach-Object { $_.Value }) -join '')
}

function Get-QueueJobs {
    foreach ($state in $activeStates) {
        $result = Invoke-AwsJson -Arguments @('batch', 'list-jobs', '--job-queue', 'gis-poc-queue', '--job-status', $state)
        foreach ($job in $result.jobSummaryList) { $job }
    }
}

function Get-ProjectDistribution {
    $result = Invoke-AwsJson -Arguments @('cloudfront', 'list-distributions')
    $all = @($result.DistributionList.Items | Where-Object { $null -ne $_ })
    $owned = @($all | Where-Object { $_.Comment -ceq 'gis-poc-web' })
    if ($owned.Count -gt 1) { throw 'Multiple gis-poc-web distributions: review ownership manually.' }
    $domains = @($bucketNames | ForEach-Object { "$_.s3.$region.amazonaws.com"; "$_.s3.amazonaws.com" })
    foreach ($dist in $all) {
        $origins = @($dist.Origins.Items)
        if ($dist.Comment -ceq 'gis-poc-web') {
            if ($origins.Count -eq 0 -or @($origins | Where-Object { $_.DomainName -cnotin $domains }).Count) {
                throw "Distribution $($dist.Id) has unexpected origins. Refusing shared/changed distribution."
            }
        } elseif (@($origins | Where-Object { $_.DomainName -cin $domains }).Count) {
            throw "Other distribution $($dist.Id) uses a project bucket. Review before teardown."
        }
    }
    return $owned
}

function Remove-ProjectBucket([string]$Bucket) {
    # Owner check on EVERY S3 request, including object deletion. No retention
    # bypass, MFA-delete bypass, or backup deletion. AccessDenied remains an error.
    $ownerArgs = @('--bucket', $Bucket, '--expected-bucket-owner', $account)
    $null = Invoke-AwsJson -Arguments (@('s3api', 'head-bucket') + $ownerArgs)
    for ($page = 0; $page -lt 10000; $page++) {
        $uploads = Invoke-AwsJson -Arguments (@('s3api', 'list-multipart-uploads') + $ownerArgs + @('--max-uploads', '1000', '--no-paginate'))
        $items = @($uploads.Uploads | Where-Object { $null -ne $_ })
        if ($items.Count -eq 0) { break }
        foreach ($upload in $items) {
            $null = Invoke-AwsJson -Arguments (@('s3api', 'abort-multipart-upload') + $ownerArgs + @('--key', $upload.Key, '--upload-id', $upload.UploadId))
        }
    }
    # Always restart at the first page after deleting. Advancing markers while
    # deleting can skip entries. Includes current/noncurrent/null versions AND markers.
    for ($page = 0; $page -lt 10000; $page++) {
        $versions = Invoke-AwsJson -Arguments (@('s3api', 'list-object-versions') + $ownerArgs + @('--max-keys', '1000', '--no-paginate'))
        $objects = @(@($versions.Versions) + @($versions.DeleteMarkers) | Where-Object { $null -ne $_ } |
            ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } })
        if ($objects.Count -eq 0) {
            $null = Invoke-AwsJson -Arguments (@('s3api', 'delete-bucket') + $ownerArgs)
            return
        }
        $payload = Write-JsonArgument @{ Objects = $objects; Quiet = $true }
        $deleted = Invoke-AwsJson -Arguments (@('s3api', 'delete-objects') + $ownerArgs + @('--delete', $payload))
        if (@($deleted.Errors | Where-Object { $null -ne $_ }).Count) {
            throw "S3 object deletion failed for $Bucket : $($deleted.Errors | ConvertTo-Json -Compress). Retained objects require admin review."
        }
    }
    throw "Safety limit reached emptying $Bucket. Stop concurrent writers and rerun."
}

# ALL discovery and ownership checks complete before the first mutation.
if ($Execute -and -not $WhatIfPreference -and $ConfirmDeletion -cne "DELETE GIS POC $account") {
    throw "Deletion requires -ConfirmDeletion 'DELETE GIS POC $account'. Omit -Execute for preview."
}
$null = Get-Command aws -ErrorAction Stop
$identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity')
if ($identity.Account -cne $account) {
    throw "Wrong AWS account: $($identity.Account). This script ONLY permits DTP $account. No changes made."
}
Write-Host "DTP GIS POC inventory | Account $account | Region $region | Profile $Profile" -ForegroundColor Green
Write-Host "Caller: $($identity.Arn)"

$distributions = @(Get-ProjectDistribution)
$oacs = @((Invoke-AwsJson -Arguments @('cloudfront', 'list-origin-access-controls')).OriginAccessControlList.Items |
    Where-Object { $_.Name -ceq 'gis-poc-web-oac' })
$functions = @((Invoke-AwsJson -Arguments @('lambda', 'list-functions')).Functions)
$lambda = @($functions | Where-Object { $_.FunctionName -ceq 'gis-poc-query' })
$rules = @((Invoke-AwsJson -Arguments @('events', 'list-rules', '--name-prefix', 'gis-poc-s3-trigger')).Rules |
    Where-Object { $_.Name -ceq 'gis-poc-s3-trigger' })
$queues = @((Invoke-AwsJson -Arguments @('batch', 'describe-job-queues')).jobQueues)
$queue = @($queues | Where-Object { $_.jobQueueName -ceq 'gis-poc-queue' })
$ces = @((Invoke-AwsJson -Arguments @('batch', 'describe-compute-environments')).computeEnvironments)
$ce = @($ces | Where-Object { $_.computeEnvironmentName -ceq 'gis-poc-ce' })
$definitions = @((Invoke-AwsJson -Arguments @('batch', 'describe-job-definitions', '--job-definition-name', 'gis-poc-job', '--status', 'ACTIVE')).jobDefinitions)
$jobs = @()
if ($queue.Count) { $jobs = @(Get-QueueJobs) }
foreach ($q in $queues) {
    foreach ($order in $q.computeEnvironmentOrder) {
        if ($q.jobQueueName -cne 'gis-poc-queue' -and $order.computeEnvironment -cin @($ce.computeEnvironmentArn)) {
            throw "Another queue $($q.jobQueueName) uses gis-poc-ce; refusing shared compute environment."
        }
        if ($q.jobQueueName -ceq 'gis-poc-queue' -and $order.computeEnvironment -cnotin @($ce.computeEnvironmentArn)) {
            throw 'gis-poc-queue uses another compute environment; review before teardown.'
        }
    }
}
$buckets = @((Invoke-AwsJson -Arguments @('s3api', 'list-buckets')).Buckets | Where-Object { $_.Name -cin $bucketNames })
foreach ($bucket in $buckets) {
    $location = Invoke-AwsJson -Arguments @('s3api', 'get-bucket-location', '--bucket', $bucket.Name, '--expected-bucket-owner', $account)
    if ($location.LocationConstraint -cne $region) { throw "Unexpected region for $($bucket.Name)." }
}
$repos = @((Invoke-AwsJson -Arguments @('ecr', 'describe-repositories')).repositories | Where-Object { $_.repositoryName -cin $repoNames })
$roles = @((Invoke-AwsJson -Arguments @('iam', 'list-roles')).Roles | Where-Object { $_.RoleName -cin $roleNames })
$lambdaLogs = @((Invoke-AwsJson -Arguments @('logs', 'describe-log-groups', '--log-group-name-prefix', '/aws/lambda/gis-poc-query')).logGroups |
    Where-Object { $_.logGroupName -ceq '/aws/lambda/gis-poc-query' })
$batchLogs = Invoke-AwsJson -Arguments @('logs', 'describe-log-streams', '--log-group-name', '/aws/batch/job', '--log-stream-name-prefix', 'gis-poc-job/') -MissingCodes @('ResourceNotFoundException')
# Batch-generated cluster names, not all clusters in this account. An attached
# compute environment prevents cleanup until Batch itself has been removed.
$clusters = @((Invoke-AwsJson -Arguments @('ecs', 'list-clusters')).clusterArns |
    Where-Object { ($_ -split '/')[-1] -cmatch '^gis-poc-ce_Batch_[A-Za-z0-9_-]+$' })

$vpcs = @((Invoke-AwsJson -Arguments @('ec2', 'describe-vpcs')).Vpcs)
$vpc = @($vpcs | Where-Object { $_.VpcId -ceq $vpcId })
if (@($vpcs | Where-Object { (Get-NameTag $_) -ceq 'gis-poc-vpc' -and $_.VpcId -cne $vpcId }).Count) {
    throw 'Another gis-poc-vpc ID exists. Review and update the explicit DTP allowlist, not a name wildcard.'
}
$endpoints = @(); $subnets = @(); $groups = @(); $routes = @(); $enis = @()
if ($vpc.Count) {
    if ((Get-NameTag $vpc[0]) -cne 'gis-poc-vpc' -or $vpc[0].IsDefault) { throw 'VPC ownership/default-VPC safety check failed.' }
    if (@($functions | Where-Object { $_.FunctionName -cne 'gis-poc-query' -and $_.VpcConfig.VpcId -ceq $vpcId }).Count) {
        throw 'Another Lambda uses this VPC. Refusing teardown.'
    }
    $filter = @('--filters', "Name=vpc-id,Values=$vpcId")
    $endpoints = @((Invoke-AwsJson -Arguments (@('ec2', 'describe-vpc-endpoints') + $filter)).VpcEndpoints)
    $subnets = @((Invoke-AwsJson -Arguments (@('ec2', 'describe-subnets') + $filter)).Subnets)
    $groups = @((Invoke-AwsJson -Arguments (@('ec2', 'describe-security-groups') + $filter)).SecurityGroups)
    $routes = @((Invoke-AwsJson -Arguments (@('ec2', 'describe-route-tables') + $filter)).RouteTables)
    $enis = @((Invoke-AwsJson -Arguments (@('ec2', 'describe-network-interfaces') + $filter)).NetworkInterfaces)
    $endpointServices = @{
        'gis-poc-ecr-api' = "com.amazonaws.$region.ecr.api"
        'gis-poc-ecr-dkr' = "com.amazonaws.$region.ecr.dkr"
        'gis-poc-logs' = "com.amazonaws.$region.logs"
        'gis-poc-s3' = "com.amazonaws.$region.s3"
    }
    foreach ($ep in $endpoints) {
        $tag = Get-NameTag $ep
        if (-not $endpointServices.ContainsKey($tag) -or $ep.ServiceName -cne $endpointServices[$tag]) {
            throw "Unexpected endpoint $($ep.VpcEndpointId) in VPC; refusing teardown."
        }
    }
    foreach ($subnet in $subnets) {
        if ((Get-NameTag $subnet) -cne 'gis-poc-subnet' -or $subnet.CidrBlock -cne '10.20.1.0/24') { throw 'Unexpected subnet in project VPC.' }
    }
    foreach ($group in $groups) {
        if ($group.GroupName -cnotin @('default', 'gis-poc-batch-sg', 'gis-poc-endpoints-sg')) { throw 'Unexpected security group in project VPC.' }
    }
    foreach ($route in $routes) {
        if (-not @($route.Associations | Where-Object { $_.Main }).Count -and (Get-NameTag $route) -cne 'gis-poc-rt') { throw 'Unexpected route table in project VPC.' }
    }
    foreach ($other in $ces | Where-Object { $_.computeEnvironmentName -cne 'gis-poc-ce' }) {
        if (@($other.computeResources.subnets | Where-Object { $_ -cin @($subnets.SubnetId) }).Count) { throw 'Another Batch compute environment uses the project subnet.' }
    }
}

Write-Host "`nEXACT DELETION SCOPE (only resources currently found):" -ForegroundColor Yellow
@(
    "CloudFront distributions: $($distributions.Id -join ', ')"
    "Origin access controls: $($oacs.Id -join ', ')"
    "Lambda: $($lambda.FunctionName -join ', ') (including Function URL and versions)"
    "EventBridge rules: $($rules.Name -join ', ') (all targets on this project rule)"
    "Batch queues: $($queue.jobQueueName -join ', '); compute environments: $($ce.computeEnvironmentName -join ', ')"
    "Active Batch jobs to terminate: $($jobs.Count); active job definitions to deregister: $($definitions.Count)"
    "Batch-generated ECS clusters: $($clusters -join ', ')"
    "S3 buckets, ALL versions/delete markers/uploads: $($buckets.Name -join ', ')"
    "ECR repositories, ALL images: $($repos.repositoryName -join ', ')"
    "IAM roles (may require DTP admin): $($roles.RoleName -join ', ')"
    "Lambda log groups: $($lambdaLogs.logGroupName -join ', ')"
    "Project streams in shared /aws/batch/job: $(@($batchLogs.logStreams | Where-Object { $null -ne $_ }).Count)"
    "VPC: $($vpc.VpcId -join ', '); subnets: $($subnets.SubnetId -join ', ')"
    "Endpoints: $($endpoints.VpcEndpointId -join ', ')"
    "Non-default security groups: $(($groups | Where-Object { $_.GroupName -cne 'default' }).GroupId -join ', ')"
    "Non-main route tables: $(($routes | Where-Object { -not @($_.Associations | Where-Object { $_.Main }).Count }).RouteTableId -join ', ')"
    "Network interfaces (NEVER force-deleted): $($enis.NetworkInterfaceId -join ', ')"
) | ForEach-Object { Write-Host "  $_" }
Write-Host 'PRESERVED: shared DTP infrastructure, managed policies, service-linked roles, shared Batch log group, backup vaults/recovery points, local files.'
Write-Warning 'Deletion is permanent: website, API and ingestion will stop; project S3 data and images will be erased. Stop external writers/deploys first.'
if (-not $Execute) { Write-Host 'PREVIEW ONLY. No AWS changes made.'; exit 0 }
if (-not $PSCmdlet.ShouldProcess("GIS POC ONLY in DTP $account ($region)", 'Permanently delete the listed resources and ALL project data')) { exit 0 }

try {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('gis-poc-teardown-' + [guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $tempDir
    $script:batchGone = $false
    $script:lambdaGone = $false
    $script:cloudFrontGone = $false

    Invoke-Phase 'Stop triggers and remove Batch workloads' {
        foreach ($rule in $rules) {
            $null = Invoke-AwsJson -Arguments @('events', 'disable-rule', '--name', $rule.Name)
            $targets = @((Invoke-AwsJson -Arguments @('events', 'list-targets-by-rule', '--rule', $rule.Name)).Targets)
            if ($targets.Count) {
                $removed = Invoke-AwsJson -Arguments (@('events', 'remove-targets', '--rule', $rule.Name, '--ids') + @($targets.Id))
                if ($removed.FailedEntryCount -gt 0) { throw "Failed to remove rule targets: $($removed | ConvertTo-Json -Depth 10 -Compress)" }
            }
            $null = Invoke-AwsJson -Arguments @('events', 'delete-rule', '--name', $rule.Name)
        }
        $currentQueue = @((Invoke-AwsJson -Arguments @('batch', 'describe-job-queues', '--job-queues', 'gis-poc-queue')).jobQueues)
        if ($currentQueue.Count) {
            if ($currentQueue[0].status -eq 'DELETING') { Add-Pending 'Batch queue deletion in progress; rerun later.'; return }
            if ($currentQueue[0].state -ne 'DISABLED') {
                $null = Invoke-AwsJson -Arguments @('batch', 'update-job-queue', '--job-queue', 'gis-poc-queue', '--state', 'DISABLED')
            }
            $liveJobs = @(Get-QueueJobs)
            foreach ($job in $liveJobs) {
                # terminate-job handles queued as well as running jobs.
                $null = Invoke-AwsJson -Arguments @('batch', 'terminate-job', '--job-id', $job.jobId, '--reason', 'User-confirmed GIS POC teardown')
            }
            if ($liveJobs.Count) { Add-Pending 'Batch jobs terminating; data/images/network retained. Rerun later.'; return }
            $currentQueue = @((Invoke-AwsJson -Arguments @('batch', 'describe-job-queues', '--job-queues', 'gis-poc-queue')).jobQueues)
            if ($currentQueue.Count) {
                if ($currentQueue[0].state -ne 'DISABLED' -or $currentQueue[0].status -notin @('VALID', 'INVALID')) { Add-Pending 'Batch queue updating; rerun later.'; return }
                $null = Invoke-AwsJson -Arguments @('batch', 'delete-job-queue', '--job-queue', 'gis-poc-queue')
                Add-Pending 'Batch queue deletion requested; rerun later to delete compute environment.'
                return
            }
        }
        $currentCe = @((Invoke-AwsJson -Arguments @('batch', 'describe-compute-environments', '--compute-environments', 'gis-poc-ce')).computeEnvironments)
        if ($currentCe.Count) {
            if ($currentCe[0].status -eq 'DELETING') { Add-Pending 'Batch compute environment deleting; rerun later.'; return }
            if ($currentCe[0].state -ne 'DISABLED') {
                $null = Invoke-AwsJson -Arguments @('batch', 'update-compute-environment', '--compute-environment', 'gis-poc-ce', '--state', 'DISABLED')
                Add-Pending 'Batch compute environment disabling; rerun later.'
                return
            }
            if ($currentCe[0].status -notin @('VALID', 'INVALID')) { Add-Pending 'Batch compute environment updating; rerun later.'; return }
            $null = Invoke-AwsJson -Arguments @('batch', 'delete-compute-environment', '--compute-environment', 'gis-poc-ce')
            Add-Pending 'Batch compute environment deletion requested; rerun later.'
            return
        }
        foreach ($cluster in $clusters) {
            $details = Invoke-AwsJson -Arguments @('ecs', 'describe-clusters', '--clusters', $cluster)
            if (@($details.failures).Count -gt 0) { throw "Cannot inspect ECS cluster $cluster." }
            foreach ($item in $details.clusters | Where-Object { $_.status -ne 'INACTIVE' }) {
                if ($item.runningTasksCount -gt 0 -or $item.pendingTasksCount -gt 0 -or $item.activeServicesCount -gt 0 -or $item.registeredContainerInstancesCount -gt 0) {
                    throw "ECS cluster $cluster is not empty. Not deleting services, tasks or instances."
                }
                $null = Invoke-AwsJson -Arguments @('ecs', 'delete-cluster', '--cluster', $cluster)
            }
        }
        foreach ($definition in $definitions) {
            $null = Invoke-AwsJson -Arguments @('batch', 'deregister-job-definition', '--job-definition', $definition.jobDefinitionArn)
        }
        $script:batchGone = $true
    }

    Invoke-Phase 'Delete Lambda API' {
        foreach ($function in $lambda) {
            $null = Invoke-AwsJson -Arguments @('lambda', 'delete-function-url-config', '--function-name', $function.FunctionName) -MissingCodes @('ResourceNotFoundException')
            $null = Invoke-AwsJson -Arguments @('lambda', 'delete-function', '--function-name', $function.FunctionName) -MissingCodes @('ResourceNotFoundException')
        }
        $script:lambdaGone = $true
    }

    Invoke-Phase 'Disable/delete CloudFront and remove unused project OAC' {
        foreach ($dist in $distributions) {
            $config = Invoke-AwsJson -Arguments @('cloudfront', 'get-distribution-config', '--id', $dist.Id)
            if ($config.DistributionConfig.Enabled) {
                $config.DistributionConfig.Enabled = $false
                $file = Write-JsonArgument $config.DistributionConfig
                $null = Invoke-AwsJson -Arguments @('cloudfront', 'update-distribution', '--id', $dist.Id, '--if-match', $config.ETag, '--distribution-config', $file)
                Add-Pending "CloudFront $($dist.Id) disabling; rerun after deployment completes."
                return
            }
            $current = Invoke-AwsJson -Arguments @('cloudfront', 'get-distribution', '--id', $dist.Id)
            if ($current.Distribution.Status -ne 'Deployed') { Add-Pending "CloudFront $($dist.Id) still deploying; rerun later."; return }
            $null = Invoke-AwsJson -Arguments @('cloudfront', 'delete-distribution', '--id', $dist.Id, '--if-match', $current.ETag)
        }
        $remaining = Invoke-AwsJson -Arguments @('cloudfront', 'list-distributions')
        foreach ($oac in $oacs) {
            $references = @($remaining.DistributionList.Items | Where-Object { $oac.Id -cin @($_.Origins.Items.OriginAccessControlId) })
            if ($references.Count) { throw "OAC $($oac.Id) still used by distribution(s) $($references.Id -join ', '). Not deleting shared OAC." }
            $current = Invoke-AwsJson -Arguments @('cloudfront', 'get-origin-access-control', '--id', $oac.Id)
            $null = Invoke-AwsJson -Arguments @('cloudfront', 'delete-origin-access-control', '--id', $oac.Id, '--if-match', $current.ETag)
        }
        $script:cloudFrontGone = $true
    }

    if ($script:batchGone -and $script:lambdaGone -and $script:cloudFrontGone) {
        foreach ($bucket in $buckets) {
            Invoke-Phase "Erase all data and delete S3 bucket $($bucket.Name)" { Remove-ProjectBucket $bucket.Name }
        }
    } elseif ($buckets.Count) { Add-Pending 'S3 deletion deferred until Batch, Lambda and CloudFront cleanup succeeds.' }

    if ($script:batchGone -and $script:lambdaGone) {
        foreach ($repo in $repos) {
            Invoke-Phase "Delete ECR repository and images $($repo.repositoryName)" {
                $null = Invoke-AwsJson -Arguments @('ecr', 'delete-repository', '--registry-id', $account, '--repository-name', $repo.repositoryName, '--force')
            }
        }
        Invoke-Phase 'Delete project logs only' {
            foreach ($group in $lambdaLogs) {
                $null = Invoke-AwsJson -Arguments @('logs', 'delete-log-group', '--log-group-name', $group.logGroupName) -MissingCodes @('ResourceNotFoundException')
            }
            $streams = Invoke-AwsJson -Arguments @('logs', 'describe-log-streams', '--log-group-name', '/aws/batch/job', '--log-stream-name-prefix', 'gis-poc-job/') -MissingCodes @('ResourceNotFoundException')
            foreach ($stream in $streams.logStreams) {
                $null = Invoke-AwsJson -Arguments @('logs', 'delete-log-stream', '--log-group-name', '/aws/batch/job', '--log-stream-name', $stream.logStreamName) -MissingCodes @('ResourceNotFoundException')
            }
        }
        foreach ($role in $roles) {
            Invoke-Phase "Remove project role $($role.RoleName) (SCP may require admin)" {
                $instances = Invoke-AwsJson -Arguments @('iam', 'list-instance-profiles-for-role', '--role-name', $role.RoleName)
                if (@($instances.InstanceProfiles).Count) { throw 'Role is in an unexpected instance profile; left unchanged for admin review.' }
                $attached = Invoke-AwsJson -Arguments @('iam', 'list-attached-role-policies', '--role-name', $role.RoleName)
                $inline = Invoke-AwsJson -Arguments @('iam', 'list-role-policies', '--role-name', $role.RoleName)
                foreach ($policy in $attached.AttachedPolicies) {
                    $null = Invoke-AwsJson -Arguments @('iam', 'detach-role-policy', '--role-name', $role.RoleName, '--policy-arn', $policy.PolicyArn)
                }
                foreach ($policy in $inline.PolicyNames) {
                    $null = Invoke-AwsJson -Arguments @('iam', 'delete-role-policy', '--role-name', $role.RoleName, '--policy-name', $policy)
                }
                # Leave the permissions boundary attached. Never delete the shared
                # boundary policy or attempt to evade Landing Zone restrictions.
                $null = Invoke-AwsJson -Arguments @('iam', 'delete-role', '--role-name', $role.RoleName)
            }
        }
        Invoke-Phase 'Remove dedicated private network' {
            if (-not $vpc.Count) { return }
            if ($endpoints.Count) {
                $deleting = @($endpoints | Where-Object { $_.State -notin @('deleting', 'deleted') })
                if ($deleting.Count) {
                    $deleted = Invoke-AwsJson -Arguments (@('ec2', 'delete-vpc-endpoints', '--vpc-endpoint-ids') + @($deleting.VpcEndpointId))
                    if (@($deleted.Unsuccessful).Count) { throw "Endpoint deletion failed: $($deleted.Unsuccessful | ConvertTo-Json -Depth 10 -Compress)" }
                }
                Add-Pending 'VPC endpoints deleting; rerun later for subnet/security group/VPC cleanup.'
                return
            }
            $interfaces = @((Invoke-AwsJson -Arguments @('ec2', 'describe-network-interfaces', '--filters', "Name=vpc-id,Values=$vpcId")).NetworkInterfaces)
            if ($interfaces.Count) {
                throw "VPC still has ENIs: $($interfaces.NetworkInterfaceId -join ', '). Allow AWS cleanup or investigate owners; never force-delete them."
            }
            foreach ($route in $routes) {
                if (@($route.Associations | Where-Object { $_.Main }).Count) { continue }
                foreach ($association in $route.Associations) {
                    $null = Invoke-AwsJson -Arguments @('ec2', 'disassociate-route-table', '--association-id', $association.RouteTableAssociationId)
                }
                $null = Invoke-AwsJson -Arguments @('ec2', 'delete-route-table', '--route-table-id', $route.RouteTableId)
            }
            # The endpoint group references the task group: delete it first.
            foreach ($name in @('gis-poc-endpoints-sg', 'gis-poc-batch-sg')) {
                foreach ($group in $groups | Where-Object { $_.GroupName -ceq $name }) {
                    $null = Invoke-AwsJson -Arguments @('ec2', 'delete-security-group', '--group-id', $group.GroupId)
                }
            }
            foreach ($subnet in $subnets) {
                $null = Invoke-AwsJson -Arguments @('ec2', 'delete-subnet', '--subnet-id', $subnet.SubnetId)
            }
            $null = Invoke-AwsJson -Arguments @('ec2', 'delete-vpc', '--vpc-id', $vpcId)
        }
    } else { Add-Pending 'Images, logs, IAM roles and networking retained until Batch/Lambda cleanup succeeds.' }

    Write-Host "`nTeardown summary" -ForegroundColor Green
    if ($issues.Count) {
        Write-Host 'FAILED / ADMIN ACTION REQUIRED:' -ForegroundColor Red
        $issues | ForEach-Object { Write-Host "  $_" }
    }
    if ($pending.Count) {
        Write-Host 'PENDING (rerun the same command after AWS cleanup):' -ForegroundColor Yellow
        $pending | ForEach-Object { Write-Host "  $_" }
    }
    if ($issues.Count) { exit 1 }
    if ($pending.Count) { exit 2 }
    Write-Host 'Allowlisted resources removed. Run preview again to verify. Shared resources/backups and AWS-retained Batch history are not erased.'
    exit 0
} finally {
    if ($tempDir -and (Test-Path $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}