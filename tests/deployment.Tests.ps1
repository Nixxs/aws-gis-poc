#Requires -Version 5.1
# Offline tests: strict AWS/npm mocks, no credentials or live deployment calls.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'deploy-common.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gis-deploy-tests-' + [guid]::NewGuid().ToString())
$componentDir = Join-Path $fixture 'component'
$null = New-Item -ItemType Directory -Path $componentDir -Force
$deploymentMockState = @{ Account = '878564871075'; ExitCode = 0; Calls = (New-Object 'System.Collections.Generic.List[object]'); NpmExit = 0 }
$passed = 0

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Expect-Error([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -like "*$Pattern*") "Expected '$Pattern', got '$message'"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:passed++
    Write-Host "PASS $Name"
}
function Write-Fixture([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
# Initialize-Deployment resolves an application before wrapping aws. Redirect
# that resolution to a mock function; no real AWS executable can be reached.
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -ne 'aws' -or $CommandType -ne 'Application') { throw "Unexpected executable lookup: $Name" }
    [pscustomobject]@{ Source = 'Invoke-MockAws' }
}
function Invoke-MockAws {
    $deploymentMockState.Calls.Add(@($args))
    Assert ($args[0] -eq 'sts' -and $args[1] -eq 'get-caller-identity') 'Only identity checks allowed in tests'
    $global:LASTEXITCODE = $deploymentMockState.ExitCode
    if ($deploymentMockState.ExitCode) { 'MockExpiredCredentials'; return }
    @{ Account = $deploymentMockState.Account; Arn = 'mock-caller' } | ConvertTo-Json -Compress
}
function npm {
    Assert ($env:VITE_QUERY_API_URL -ceq 'https://personal.example/') 'Personal API overrides inherited/DTP values'
    Assert ($env:VITE_PMTILES_BASE_URL -ceq '/public/pmtiles/') 'Personal tiles setting passed to build'
    Assert ($env:VITE_CONFIG_URL -ceq '/config.json') 'Personal config setting passed to build'
    Assert ($env:VITE_FOREIGN_ONLY -ceq ' ') 'Other-account fallback is masked'
    $global:LASTEXITCODE = $deploymentMockState.NpmExit
}

try {
    Write-Fixture (Join-Path $fixture '.env.self') "ACCT=878564871075`nREGION=ap-southeast-2`nBOUNDARY=`n"
    Write-Fixture (Join-Path $componentDir '.env.self') "APP=personal-bucket`nASSIGN_PUBLIC_IP=ENABLED`nQUOTED='a value'`n"
    $dtpRoot = "ACCT=376640768813`nREGION=ap-southeast-2`nBOUNDARY=arn:aws:iam::376640768813:policy/boundary`nTAG_COSTCENTER=PlanningSpatial`nTAG_BACKUPPLAN=Daily`n"
    Write-Fixture (Join-Path $fixture '.env') $dtpRoot
    Write-Fixture (Join-Path $componentDir '.env') "APP=dtp-bucket`nVITE_FOREIGN_ONLY=dtp-secret-url`n"

    Test-Case 'select personal config without DTP fallback' {
        $config = Get-DeploymentConfig $fixture $componentDir 'self'
        Assert ($config.APP -eq 'personal-bucket' -and -not $config.BOUNDARY) 'Personal settings selected'
        Assert ($config.QUOTED -ceq 'a value') 'Quoted values parsed'
        Assert (-not $config.ContainsKey('VITE_FOREIGN_ONLY')) 'No DTP config merge'
    }
    Test-Case 'personal boundary and tags optional' {
        $config = Get-DeploymentConfig $fixture $componentDir 'self'
        Assert (@(Get-RoleBoundaryArguments $config).Count -eq 0) 'No boundary argument'
        $bucketArgs = @(Get-BucketCreateArguments $config)
        Assert ($bucketArgs.Count -eq 2 -and $bucketArgs[1] -ceq 'LocationConstraint=ap-southeast-2') 'No DTP tags'
    }
    Test-Case 'DTP protections and default networking retained' {
        $config = Get-DeploymentConfig $fixture $componentDir 'dtp'
        Assert (@(Get-RoleBoundaryArguments $config).Count -eq 2) 'DTP boundary included'
        Assert ((@(Get-BucketCreateArguments $config)[1]) -like '*lz:CostCenter*lz:BackupPlan*') 'DTP tags inline'
        Set-BatchPublicIpDefault $config
        Assert ($config.ASSIGN_PUBLIC_IP -ceq 'DISABLED') 'DTP stays private'
    }
    Test-Case 'DTP missing boundary rejected' {
        Write-Fixture (Join-Path $fixture '.env') "ACCT=376640768813`nREGION=ap-southeast-2`n"
        Expect-Error { Get-DeploymentConfig $fixture $componentDir 'dtp' } 'requires BOUNDARY'
        Write-Fixture (Join-Path $fixture '.env') $dtpRoot
    }
    Test-Case 'cross-account boundary rejected' {
        Write-Fixture (Join-Path $componentDir '.env.self') 'BOUNDARY=arn:aws:iam::376640768813:policy/boundary'
        Expect-Error { Get-DeploymentConfig $fixture $componentDir 'self' } 'boundary belongs to another account'
        Write-Fixture (Join-Path $componentDir '.env.self') 'APP=personal-bucket'
    }
    Test-Case 'component cannot change account' {
        Write-Fixture (Join-Path $componentDir '.env.self') 'ACCT=376640768813'
        Expect-Error { Get-DeploymentConfig $fixture $componentDir 'self' } 'mixed-account'
        Write-Fixture (Join-Path $componentDir '.env.self') 'APP=personal-bucket'
    }
    Test-Case 'personal network must be explicit' {
        $config = Get-DeploymentConfig $fixture $componentDir 'self'
        Expect-Error { Set-BatchPublicIpDefault $config } 'Set ASSIGN_PUBLIC_IP'
        $config.ASSIGN_PUBLIC_IP = 'ENABLED'
        Set-BatchPublicIpDefault $config
        Assert ($config.ASSIGN_PUBLIC_IP -ceq 'ENABLED') 'Personal public IP preserved'
        $config.ASSIGN_PUBLIC_IP = 'invalid'
        Expect-Error { Set-BatchPublicIpDefault $config } 'must be ENABLED or DISABLED'
    }
    Test-Case 'us-east-1 omits location constraint' {
        Assert (@(Get-BucketCreateArguments @{ REGION = 'us-east-1' }).Count -eq 0) 'No invalid us-east-1 location constraint'
    }
    Test-Case 'identity and explicit CLI profile/region' {
        Initialize-Deployment @{ ACCT = '878564871075'; REGION = 'ap-southeast-2' } 'personal-test'
        $call = $deploymentMockState.Calls[$deploymentMockState.Calls.Count - 1]
        Assert ($call -contains 'personal-test' -and $call -contains 'ap-southeast-2' -and $call -contains '--no-cli-pager') 'CLI pinned'
    }
    Test-Case 'wrong-account and expired login rejected' {
        $deploymentMockState.Account = '376640768813'
        Expect-Error { Initialize-Deployment @{ ACCT = '878564871075'; REGION = 'ap-southeast-2' } 'personal-test' } 'Account mismatch'
        $deploymentMockState.Account = '878564871075'
        $deploymentMockState.ExitCode = 254
        Expect-Error { Initialize-Deployment @{ ACCT = '878564871075'; REGION = 'ap-southeast-2' } 'personal-test' } 'identity check failed'
        $deploymentMockState.ExitCode = 0
    }
    Test-Case 'AWS calls cannot override verified profile or region' {
        Expect-Error { aws sts get-caller-identity --profile dtp } 'override verified --profile'
        Expect-Error { aws sts get-caller-identity --region us-east-1 } 'override verified --region'
    }
    Test-Case 'frontend variables isolated and restored on success/failure' {
        $previousApi = $env:VITE_QUERY_API_URL
        $previousForeign = $env:VITE_FOREIGN_ONLY
        try {
            $env:VITE_QUERY_API_URL = 'https://dtp.example/'
            $env:VITE_FOREIGN_ONLY = 'inherited'
            $config = @{ VITE_QUERY_API_URL = 'https://personal.example/'; VITE_PMTILES_BASE_URL = '/public/pmtiles/'; VITE_CONFIG_URL = '/config.json' }
            Invoke-FrontendBuild $config $componentDir
            Assert ($env:VITE_QUERY_API_URL -ceq 'https://dtp.example/' -and $env:VITE_FOREIGN_ONLY -ceq 'inherited') 'Process settings restored'
            $deploymentMockState.NpmExit = 1
            Expect-Error { Invoke-FrontendBuild $config $componentDir } 'Frontend build failed'
            Assert ($env:VITE_QUERY_API_URL -ceq 'https://dtp.example/') 'Restored after failure'
        } finally {
            $env:VITE_QUERY_API_URL = $previousApi
            $env:VITE_FOREIGN_ONLY = $previousForeign
            $deploymentMockState.NpmExit = 0
        }
    }
    Write-Host "All $passed offline deployment tests passed. No real AWS/npm calls made." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}