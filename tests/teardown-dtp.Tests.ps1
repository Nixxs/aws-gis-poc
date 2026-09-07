#Requires -Version 5.1
<# Offline integration tests. The aws command is shadowed by a strict mock;
   no credentials, AWS calls, Pester installation, or cloud mutations are needed. #>
$ErrorActionPreference = 'Stop'
$teardown = Join-Path (Split-Path -Parent $PSScriptRoot) 'teardown-dtp.ps1'
$script:scenario = ''
$script:calls = New-Object 'System.Collections.Generic.List[object]'
$script:versionPage = 0
$script:uploadPage = 0
$script:distributionDeleted = $false
$script:passed = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function aws {
    # PowerShell resolves $script: against the invoking script here. Seed the
    # child script's mock state from the test scope, retaining the shared call log.
    if ($null -eq $script:calls) {
        $script:calls = $offlineState.Calls
        $script:scenario = $offlineState.Scenario
        $script:versionPage = 0
        $script:uploadPage = 0
        $script:distributionDeleted = $false
    }
    $a = @($args)
    $script:calls.Add($a)
    $global:LASTEXITCODE = 0
    Assert-True ($a -contains '--profile' -and $a -contains '--region' -and $a -contains '--no-cli-pager') 'Every AWS call is explicitly scoped'
    Assert-True ($a[[array]::IndexOf($a, '--profile') + 1] -ceq 'offline-test') 'Selected profile forwarded'
    Assert-True ($a[[array]::IndexOf($a, '--region') + 1] -ceq 'ap-southeast-2') 'Region pinned'
    $op = "$($a[0]) $($a[1])"
    $work = $script:scenario -in @('erase', 'retention', 'iam-denied', 'endpoints', 'network')
    $batch = $script:scenario -in @('preview', 'jobs', 'queue', 'compute')
    $cf = $script:scenario -in @('preview', 'cloudfront', 'cloudfront-ready', 'shared-cloudfront')
    $result = switch ($op) {
        'sts get-caller-identity' {
            @{ Account = $(if ($script:scenario -eq 'wrong-account') { '000000000000' } else { '376640768813' }); Arn = 'arn:aws:iam::376640768813:user/offline-test' }
        }
        'cloudfront list-distributions' {
            $items = @()
            if ($cf -and -not $script:distributionDeleted) {
                $domain = if ($script:scenario -eq 'shared-cloudfront') { 'unrelated.s3.amazonaws.com' } else { 'gis-poc-web-dtp.s3.ap-southeast-2.amazonaws.com' }
                $items = @(@{ Id = 'DIST'; Comment = 'gis-poc-web'; Origins = @{ Items = @(@{ DomainName = $domain; OriginAccessControlId = 'OAC' }) } })
            }
            @{ DistributionList = @{ Items = $items } }
        }
        'cloudfront list-origin-access-controls' { @{ OriginAccessControlList = @{ Items = $(if ($cf) { @(@{ Id = 'OAC'; Name = 'gis-poc-web-oac' }) } else { @() }) } } }
        'cloudfront get-distribution-config' { @{ ETag = 'v1'; DistributionConfig = @{ Enabled = ($script:scenario -ne 'cloudfront-ready'); CallerReference = 'original'; Origins = @{ Items = @() } } } }
        'cloudfront update-distribution' {
            $path = $a[[array]::IndexOf($a, '--distribution-config') + 1] -replace '^file://', ''
            $payload = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            Assert-True ($payload.Enabled -eq $false -and $payload.CallerReference -ceq 'original') 'CloudFront config preserved and disabled'
            @{}
        }
        'cloudfront get-distribution' { @{ ETag = 'v2'; Distribution = @{ Status = 'Deployed' } } }
        'cloudfront delete-distribution' { $script:distributionDeleted = $true; @{} }
        'cloudfront get-origin-access-control' { @{ ETag = 'oac-v1' } }
        'cloudfront delete-origin-access-control' { @{} }
        'lambda list-functions' { @{ Functions = $(if ($work -or $batch) { @(@{ FunctionName = 'gis-poc-query' }, @{ FunctionName = 'unrelated' }) } else { @() }) } }
        'lambda delete-function-url-config' { @{} }
        'lambda delete-function' { Assert-True ($a -contains 'gis-poc-query') 'Only project Lambda deleted'; @{} }
        'events list-rules' { @{ Rules = $(if ($batch) { @(@{ Name = 'gis-poc-s3-trigger' }) } else { @() }) } }
        'events disable-rule' { @{} }
        'events list-targets-by-rule' { @{ Targets = @(@{ Id = 'target-1' }) } }
        'events remove-targets' { @{ FailedEntryCount = 0 } }
        'events delete-rule' { @{} }
        'batch describe-job-queues' {
            @{ jobQueues = $(if ($batch -and $script:scenario -ne 'compute') {
                @(@{ jobQueueName = 'gis-poc-queue'; state = 'DISABLED'; status = 'VALID'; computeEnvironmentOrder = @(@{ computeEnvironment = 'ce-arn' }) })
            } else { @() }) }
        }
        'batch describe-compute-environments' {
            @{ computeEnvironments = $(if ($batch) { @(@{ computeEnvironmentName = 'gis-poc-ce'; computeEnvironmentArn = 'ce-arn'; state = 'ENABLED'; status = 'VALID' }) } else { @() }) }
        }
        'batch describe-job-definitions' { @{ jobDefinitions = $(if ($work) { @(@{ jobDefinitionArn = 'project-definition:1' }, @{ jobDefinitionArn = 'project-definition:2' }) } else { @() }) } }
        'batch list-jobs' { @{ jobSummaryList = $(if ($script:scenario -eq 'jobs' -and $a -contains 'RUNNING') { @(@{ jobId = 'job-1' }) } else { @() }) } }
        'batch terminate-job' { @{} }
        'batch delete-job-queue' { @{} }
        'batch update-compute-environment' { @{} }
        'batch deregister-job-definition' { @{} }
        's3api list-buckets' { @{ Buckets = $(if ($work -or $batch -or $cf) { @(@{ Name = 'gis-poc-app-dtp' }, @{ Name = 'gis-poc-ingestion-dtp' }, @{ Name = 'unrelated-bucket' }) } else { @() }) } }
        's3api get-bucket-location' { @{ LocationConstraint = 'ap-southeast-2' } }
        's3api head-bucket' { @{} }
        's3api list-multipart-uploads' {
            $script:uploadPage++
            @{ Uploads = $(if ($script:uploadPage -eq 1) { @(@{ Key = 'unfinished'; UploadId = 'upload-1' }) } else { @() }) }
        }
        's3api abort-multipart-upload' { @{} }
        's3api list-object-versions' {
            $script:versionPage++
            if ($script:versionPage -eq 1) {
                @{ Versions = @(@{ Key = ('folder/a space + unicode-' + [char]0x00E9 + '.txt'); VersionId = 'null' }, @{ Key = 'old'; VersionId = 'v1' }); DeleteMarkers = @(@{ Key = 'deleted'; VersionId = 'marker' }) }
            } else { @{ Versions = @(); DeleteMarkers = @() } }
        }
        's3api delete-objects' {
            $path = $a[[array]::IndexOf($a, '--delete') + 1] -replace '^file://', ''
            $bytes = [IO.File]::ReadAllBytes($path)
            Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'AWS JSON has no UTF8 BOM'
            $payload = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($payload.Objects.Count -eq 3) 'Delete includes versions and markers'
            Assert-True (@($payload.Objects | Where-Object { $_.VersionId -ceq 'null' }).Count -eq 1) 'Unversioned/null version included'
            @{ Errors = $(if ($script:scenario -eq 'retention') { @(@{ Code = 'AccessDenied'; Key = 'locked-object' }) } else { @() }) }
        }
        's3api delete-bucket' { Assert-True (-not ($a -contains 'unrelated-bucket')) 'Unrelated bucket preserved'; @{} }
        'ecr describe-repositories' { @{ repositories = $(if ($work) { @(@{ repositoryName = 'gis-poc-query' }, @{ repositoryName = 'unrelated' }) } else { @() }) } }
        'ecr delete-repository' { Assert-True ($a -contains '--force' -and $a -contains 'gis-poc-query') 'Project ECR images deleted'; @{} }
        'iam list-roles' { @{ Roles = $(if ($work) { @(@{ RoleName = 'gisPocQueryLambdaRole' }, @{ RoleName = 'AWSServiceRoleForBatch' }) } else { @() }) } }
        'iam list-instance-profiles-for-role' { @{ InstanceProfiles = @() } }
        'iam list-attached-role-policies' { @{ AttachedPolicies = @(@{ PolicyArn = 'arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole' }) } }
        'iam list-role-policies' { @{ PolicyNames = @('gisPocQueryS3Access') } }
        'iam detach-role-policy' { @{} }
        'iam delete-role-policy' { @{} }
        'iam delete-role' {
            if ($script:scenario -eq 'iam-denied') {
                $global:LASTEXITCODE = 254
                return 'An error occurred (AccessDenied) when calling DeleteRole: explicit deny in SCP'
            }
            @{}
        }
        'logs describe-log-groups' { @{ logGroups = $(if ($work) { @(@{ logGroupName = '/aws/lambda/gis-poc-query' }) } else { @() }) } }
        'logs describe-log-streams' {
            if ($script:scenario -eq 'discovery-denied') {
                $global:LASTEXITCODE = 254
                return 'An error occurred (AccessDeniedException) when calling DescribeLogStreams'
            }
            if ($script:scenario -eq 'logs-missing') {
                $global:LASTEXITCODE = 254
                return 'An error occurred (ResourceNotFoundException) when calling DescribeLogStreams'
            }
            @{ logStreams = $(if ($work) { @(@{ logStreamName = 'gis-poc-job/default/job-1' }) } else { @() }) }
        }
        'logs delete-log-group' { Assert-True ($a -notcontains '/aws/batch/job') 'Shared Batch log group preserved'; @{} }
        'logs delete-log-stream' { @{} }
        'ecs list-clusters' { @{ clusterArns = @('arn:aws:ecs:ap-southeast-2:376640768813:cluster/unrelated') } }
        'ec2 describe-vpcs' {
            @{ Vpcs = $(if ($script:scenario -in @('foreign-vpc', 'endpoints', 'network')) {
                @(@{ VpcId = 'vpc-0add429362ec84a9f'; IsDefault = $false; Tags = @(@{ Key = 'Name'; Value = $(if ($script:scenario -eq 'foreign-vpc') { 'shared' } else { 'gis-poc-vpc' }) }) })
            } else { @() }) }
        }
        'ec2 describe-vpc-endpoints' { @{ VpcEndpoints = $(if ($script:scenario -eq 'endpoints') { @(@{ VpcEndpointId = 'vpce-1'; State = 'available'; ServiceName = 'com.amazonaws.ap-southeast-2.ecr.api'; Tags = @(@{ Key = 'Name'; Value = 'gis-poc-ecr-api' }) }) } else { @() }) } }
        'ec2 describe-subnets' { @{ Subnets = @(@{ SubnetId = 'subnet-1'; CidrBlock = '10.20.1.0/24'; Tags = @(@{ Key = 'Name'; Value = 'gis-poc-subnet' }) }) } }
        'ec2 describe-security-groups' { @{ SecurityGroups = @(@{ GroupName = 'default'; GroupId = 'default' }, @{ GroupName = 'gis-poc-batch-sg'; GroupId = 'tasks' }, @{ GroupName = 'gis-poc-endpoints-sg'; GroupId = 'endpoints' }) } }
        'ec2 describe-route-tables' { @{ RouteTables = @(@{ RouteTableId = 'main'; Associations = @(@{ Main = $true }) }, @{ RouteTableId = 'project'; Tags = @(@{ Key = 'Name'; Value = 'gis-poc-rt' }); Associations = @(@{ Main = $false; RouteTableAssociationId = 'assoc-1' }) }) } }
        'ec2 describe-network-interfaces' { @{ NetworkInterfaces = @() } }
        'ec2 delete-vpc-endpoints' { @{ Unsuccessful = @() } }
        'ec2 disassociate-route-table' { @{} }
        'ec2 delete-route-table' { Assert-True ($a -notcontains 'main') 'Main route table not explicitly deleted'; @{} }
        'ec2 delete-security-group' { Assert-True ($a -notcontains 'default') 'Default SG not explicitly deleted'; @{} }
        'ec2 delete-subnet' { @{} }
        'ec2 delete-vpc' { @{} }
        default { throw "UNMOCKED AWS OPERATION (no real AWS call made): $op" }
    }
    # PS 5.1 serializes the AutomationNull from empty conditional fixtures as
    # {} (other versions use null). Nested empty fixture values are exclusively
    # collection fields; real AWS responses use [] for these, not {} or null.
    (ConvertTo-Json -InputObject $result -Depth 50 -Compress) -replace ':(null|\{\})', ':[]'
}

function Get-Mutations {
    @($script:calls | Where-Object { $_[1] -notmatch '^(get-|list-|describe-|head-)' })
}

function Test-Scenario([string]$Name, [hashtable]$Parameters, [int]$ExpectedExit = 0, [string]$ExpectedError = '') {
    $script:scenario = $Name
    $script:calls.Clear()
    $script:versionPage = 0
    $script:uploadPage = 0
    $script:distributionDeleted = $false
    $global:LASTEXITCODE = 0
    $failure = ''
    $offlineState = @{ Calls = $script:calls; Scenario = $Name }
    try { & $teardown -Profile offline-test @Parameters 6>$null 3>$null }
    catch { $failure = $_.Exception.Message + "`n" + $_.ScriptStackTrace }
    if ($ExpectedError) { Assert-True ($failure -like "*$ExpectedError*") "$Name expected error '$ExpectedError', got '$failure'" }
    else {
        Assert-True (-not $failure) "$Name unexpected error: $failure"
        Assert-True ($LASTEXITCODE -eq $ExpectedExit) "$Name expected exit $ExpectedExit, got $LASTEXITCODE"
    }
    $script:passed++
    Write-Host "PASS $Name"
}

$execute = @{ Execute = $true; ConfirmDeletion = 'DELETE GIS POC 376640768813' }
Test-Scenario 'preview' @{}
Assert-True (@(Get-Mutations).Count -eq 0) 'Default preview has zero mutations'
Test-Scenario 'preview' @{ Execute = $true; WhatIf = $true }
Assert-True (@(Get-Mutations).Count -eq 0) 'WhatIf has zero mutations'
Test-Scenario 'confirmation' @{ Execute = $true } -ExpectedError 'Deletion requires'
Assert-True ($script:calls.Count -eq 0) 'Bad confirmation fails before AWS'
Test-Scenario 'wrong-account' $execute -ExpectedError 'Wrong AWS account'
Assert-True (@(Get-Mutations).Count -eq 0) 'Wrong account never mutates'
Test-Scenario 'discovery-denied' $execute -ExpectedError 'AccessDeniedException'
Assert-True (@(Get-Mutations).Count -eq 0) 'Discovery denial fails closed'
Test-Scenario 'foreign-vpc' $execute -ExpectedError 'VPC ownership'
Assert-True (@(Get-Mutations).Count -eq 0) 'Unexpected VPC is protected'
Test-Scenario 'shared-cloudfront' $execute -ExpectedError 'unexpected origins'
Assert-True (@(Get-Mutations).Count -eq 0) 'Unexpected CloudFront origin is protected'
Test-Scenario 'logs-missing' $execute
Test-Scenario 'empty' $execute
Assert-True (@(Get-Mutations).Count -eq 0) 'Empty rerun is a no-op'
Test-Scenario 'jobs' $execute 2
Assert-True (@($script:calls | Where-Object { $_[1] -eq 'terminate-job' }).Count -eq 1) 'Running job terminated'
Assert-True (@($script:calls | Where-Object { $_[1] -in @('delete-bucket', 'delete-vpc', 'delete-job-queue') }).Count -eq 0) 'Running jobs retain dependent resources'
Test-Scenario 'queue' $execute 2
Test-Scenario 'compute' $execute 2
Test-Scenario 'cloudfront' $execute 2
Assert-True (@($script:calls | Where-Object { $_[1] -in @('delete-bucket', 'delete-distribution') }).Count -eq 0) 'CloudFront deployment retains distribution and data'
Test-Scenario 'cloudfront-ready' $execute
Assert-True (@($script:calls | Where-Object { $_[1] -eq 'delete-distribution' }).Count -eq 1) 'Disabled deployed distribution deleted'
Test-Scenario 'erase' $execute
Assert-True (@($script:calls | Where-Object { $_[1] -eq 'delete-bucket' }).Count -eq 2) 'Both allowlisted buckets deleted'
foreach ($call in $script:calls | Where-Object { $_[0] -eq 's3api' -and $_[1] -ne 'list-buckets' }) {
    Assert-True ($call -contains '--expected-bucket-owner') 'All bucket-specific S3 requests verify owner'
}
Test-Scenario 'retention' $execute 1
Assert-True (@($script:calls | Where-Object { $_[1] -eq 'delete-bucket' -and $_ -contains 'gis-poc-app-dtp' }).Count -eq 0) 'Failed object deletion preserves its bucket'
Test-Scenario 'iam-denied' $execute 1
Assert-True (@($script:calls | Where-Object { $_[1] -in @('delete-policy', 'delete-role-permissions-boundary') }).Count -eq 0) 'SCP is not bypassed or shared policies deleted'
Test-Scenario 'endpoints' $execute 2
Assert-True (@($script:calls | Where-Object { $_[1] -eq 'delete-vpc' }).Count -eq 0) 'Endpoints must disappear before VPC deletion'
Test-Scenario 'network' $execute
$sgCalls = @($script:calls | Where-Object { $_[1] -eq 'delete-security-group' })
Assert-True ($sgCalls.Count -eq 2 -and $sgCalls[0] -contains 'endpoints' -and $sgCalls[1] -contains 'tasks') 'SG reference dependency order'
Assert-True (@($script:calls | Where-Object { $_[1] -eq 'delete-vpc' }).Count -eq 1) 'Empty project VPC deleted'
Write-Host "All $script:passed offline teardown scenarios passed. No real AWS calls made." -ForegroundColor Green