#Requires -Version 5.1
# Shared account/configuration guard. Dot-source from a deployment script, not
# the interactive shell: the scoped aws wrapper disappears when it returns.
function Read-DeploymentEnv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Deployment configuration not found: $Path" }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $value = $Matches[2]
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                    ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $values[$key] = $value
        }
    }
    return $values
}

function Get-DeploymentConfig([string]$RootDir, [string]$ComponentDir, [string]$Environment) {
    $file = if ($Environment -eq 'self') { '.env.self' } else { '.env' }
    $config = Read-DeploymentEnv (Join-Path $RootDir $file)
    $component = Read-DeploymentEnv (Join-Path $ComponentDir $file)
    foreach ($key in 'ACCT', 'REGION') {
        if (-not $config[$key]) { throw "Root $file requires $key." }
        if ($component.ContainsKey($key) -and $component[$key] -cne $config[$key]) {
            throw "Component $file overrides $key with a different value. Refusing mixed-account configuration."
        }
    }
    foreach ($key in $component.Keys) { $config[$key] = $component[$key] }
    if ($config.ACCT -notmatch '^\d{12}$' -or $config.REGION -notmatch '^[a-z]{2}(-[a-z]+)+-\d+$') {
        throw 'Invalid ACCT or REGION in deployment configuration.'
    }
    if ($Environment -eq 'self' -and $config.ACCT -cne '878564871075') { throw 'Personal configuration must target account 878564871075.' }
    if ($Environment -eq 'dtp' -and $config.ACCT -cne '376640768813') { throw 'DTP configuration must target account 376640768813.' }
    if ($config.ACCT -ceq '376640768813') {
        foreach ($key in 'BOUNDARY', 'TAG_COSTCENTER', 'TAG_BACKUPPLAN') {
            if (-not $config[$key]) { throw "DTP deployment requires $key; Landing Zone protections remain mandatory." }
        }
    }
    if ($config.BOUNDARY -and $config.BOUNDARY -notlike "arn:aws:iam::$($config.ACCT):policy/*") {
        throw 'Permissions boundary belongs to another account or is not a policy ARN.'
    }
    if ([bool]$config.TAG_COSTCENTER -ne [bool]$config.TAG_BACKUPPLAN) { throw 'Provide both TAG_COSTCENTER and TAG_BACKUPPLAN, or neither outside DTP.' }
    if ($config.REPO -and $config.REPO -notlike "$($config.ACCT).dkr.ecr.$($config.REGION).amazonaws.com/*") {
        throw 'Pipeline REPO does not match the configured account and region.'
    }
    return $config
}

# Covers bare aws calls as well as existing Invoke-AWS/Test-AWS helpers.
function aws {
    $extra = @('--no-cli-pager')
    foreach ($option in @('--profile', '--region')) {
        $expected = if ($option -eq '--profile') { $script:DeploymentProfile } else { $script:DeploymentRegion }
        if ($args -contains $option) {
            for ($index = 0; $index -lt $args.Count; $index++) {
                if ($args[$index] -eq $option -and ($index + 1 -ge $args.Count -or $args[$index + 1] -cne $expected)) {
                    throw "AWS call attempted to override verified $option."
                }
            }
        } else { $extra += @($option, $expected) }
    }
    & $script:DeploymentAwsExecutable @args @extra
}

function Initialize-Deployment([hashtable]$Config, [string]$Profile) {
    if (-not $Profile) { $Profile = 'default' }
    $script:DeploymentAwsExecutable = (Get-Command aws -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $script:DeploymentProfile = $Profile
    $script:DeploymentRegion = $Config.REGION
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = aws sts get-caller-identity --output json 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "AWS identity check failed for profile '$Profile': $($output -join ' ')" }
    $identity = ($output -join "`n") | ConvertFrom-Json
    if ($identity.Account -cne $Config.ACCT) {
        throw "Account mismatch: profile '$Profile' is $($identity.Account), configuration expects $($Config.ACCT). No deployment changes made."
    }
    Write-Host "Verified AWS account $($identity.Account) | Region $($Config.REGION) | Profile $Profile" -ForegroundColor Green
}

function Get-RoleBoundaryArguments([hashtable]$Config) {
    if ($Config.BOUNDARY) { '--permissions-boundary'; $Config.BOUNDARY }
}

function Get-BucketCreateArguments([hashtable]$Config) {
    $parts = @()
    if ($Config.REGION -ne 'us-east-1') { $parts += "LocationConstraint=$($Config.REGION)" }
    if ($Config.TAG_COSTCENTER -and $Config.TAG_BACKUPPLAN) {
        $parts += "Tags=[{Key=lz:CostCenter,Value=$($Config.TAG_COSTCENTER)},{Key=lz:BackupPlan,Value=$($Config.TAG_BACKUPPLAN)}]"
    }
    if ($parts.Count) { '--create-bucket-configuration'; $parts -join ',' }
}

function Set-BatchPublicIpDefault([hashtable]$Config) {
    if (-not $Config.ASSIGN_PUBLIC_IP) {
        if ($Config.ACCT -eq '376640768813') { $Config.ASSIGN_PUBLIC_IP = 'DISABLED' }
        else { throw 'Set ASSIGN_PUBLIC_IP=ENABLED or DISABLED in the selected pipeline configuration to match its networking.' }
    }
    if ($Config.ASSIGN_PUBLIC_IP -cnotin @('ENABLED', 'DISABLED')) { throw 'ASSIGN_PUBLIC_IP must be ENABLED or DISABLED.' }
}

function Invoke-FrontendBuild([hashtable]$Config, [string]$FrontendDir) {
    # Vite prioritizes process variables over .env files. Override selected keys
    # and mask foreign-account keys, without copying config or changing the shell.
    foreach ($key in 'VITE_QUERY_API_URL', 'VITE_PMTILES_BASE_URL', 'VITE_CONFIG_URL') {
        if (-not $Config[$key]) { throw "Selected frontend configuration requires $key." }
    }
    $keys = @($Config.Keys | Where-Object { $_ -clike 'VITE_*' })
    foreach ($file in Get-ChildItem -LiteralPath $FrontendDir -Force -File | Where-Object { $_.Name -like '.env*' }) {
        $keys += @((Read-DeploymentEnv $file.FullName).Keys | Where-Object { $_ -clike 'VITE_*' })
    }
    $keys += @(Get-ChildItem Env: | Where-Object { $_.Name -clike 'VITE_*' } | ForEach-Object { $_.Name })
    $keys = @($keys | Select-Object -Unique)
    $previous = @{}
    try {
        foreach ($key in $keys) {
            $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            # Empty strings remove process variables on Windows. A space keeps a
            # foreign key defined so Vite cannot reload its other-account value.
            $value = if ($Config.ContainsKey($key) -and $Config[$key]) { $Config[$key] } else { ' ' }
            [Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
        & npm --prefix $FrontendDir run build
        if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed.' }
    } finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
}