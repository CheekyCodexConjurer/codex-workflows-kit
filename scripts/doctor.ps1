[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-HomePath {
    param([string]$Requested, [Parameter(Mandatory)][string]$Fallback)

    $value = if ([string]::IsNullOrWhiteSpace($Requested)) { $Fallback } else { $Requested }
    return [IO.Path]::GetFullPath($value)
}

function Write-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$Detail,
        [switch]$Optional
    )

    if ($Passed) {
        Write-Host ("[OK]   {0}: {1}" -f $Name, $Detail) -ForegroundColor Green
    }
    elseif ($Optional) {
        $script:Warnings.Add(($Name + ': ' + $Detail))
        Write-Host ("[WARN] {0}: {1}" -f $Name, $Detail) -ForegroundColor Yellow
    }
    else {
        $script:Failures.Add(($Name + ': ' + $Detail))
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-InstallState {
    param([Parameter(Mandatory)][object]$State)

    $required = @('schemaVersion', 'product', 'files')
    foreach ($property in $required) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) {
            throw "Install state is missing required property: $property"
        }
    }

    $schemaText = [string]$State.schemaVersion
    if ($schemaText -notin @('1', '2', '3')) {
        throw "Install state has an unsupported schema: $schemaText"
    }
    $schema = [int]$schemaText
    if ([string]$State.product -ne 'codex-workflows-kit') {
        throw 'Install state belongs to a different product.'
    }
    if ($null -eq $State.files -or -not ($State.files -is [System.Array])) {
        throw 'Install state files must be an array.'
    }

    $entries = @($State.files)
    if ($schema -eq 3) {
        if (-not ($State.PSObject.Properties.Name -contains 'pendingFiles') -or $null -eq $State.pendingFiles -or -not ($State.pendingFiles -is [System.Array])) {
            throw 'Schema 3 install state is missing pendingFiles.'
        }
        $entries += @($State.pendingFiles)
    }
    elseif ($State.PSObject.Properties.Name -contains 'pendingFiles') {
        throw 'Only schema 3 install state may contain pendingFiles.'
    }

    $seenPaths = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry -or -not ($entry.PSObject.Properties.Name -contains 'path') -or -not ($entry.PSObject.Properties.Name -contains 'sha256')) {
            throw 'Install state contains an invalid file entry.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.path) -or -not (Test-FullyQualifiedPath -Path ([string]$entry.path)) -or [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Install state contains an invalid file path or hash.'
        }
        $fullPath = [IO.Path]::GetFullPath([string]$entry.path)
        if ($seenPaths.ContainsKey($fullPath)) {
            throw "Install state contains a duplicate file entry: $fullPath"
        }
        $seenPaths[$fullPath] = $true
    }

    if ($schema -eq 3) {
        foreach ($entry in @($State.pendingFiles)) {
            if (-not ($entry.PSObject.Properties.Name -contains 'reason') -or [string]$entry.reason -notin @('modified', 'outside-destinations', 'unverified')) {
                throw 'Schema 3 install state contains a pending file without a reason.'
            }
        }
    }

    return $schema
}

function Test-FullyQualifiedPath {
    param([Parameter(Mandatory)][string]$Path)

    return $Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]+\\[^\\]+\\'
}

function Test-ManagedAgentDefaults {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $text = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) -replace '\r\n', "`n"
        $allAgentsHeaders = @([regex]::Matches($text, '(?im)^[ \t]*\[\[?[ \t]*(?:agents|"agents"|''agents'')[ \t]*\]\]?[ \t]*(?:#.*)?$'))
        if ($allAgentsHeaders.Count -ne 1) {
            return $false
        }

        $blockPattern = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT: agents\r?\n(?<block>.*?)^# END CODEX-WORKFLOWS-KIT: agents\r?$'
        $blocks = @([regex]::Matches($text, $blockPattern))
        if ($blocks.Count -ne 1) {
            return $false
        }

        $block = $blocks[0].Groups['block'].Value
        $headers = @([regex]::Matches($block, '(?m)^[ \t]*\[\[?[^\r\n\]]+\]\]?[ \t]*(?:#.*)?$'))
        if ($headers.Count -ne 1 -or $headers[0].Value.Trim() -notmatch '^\[agents\][ \t]*(?:#.*)?$') {
            return $false
        }

        $requiredSettings = [ordered]@{
            default_subagent_model = 'gpt-5.6-luna'
            default_subagent_reasoning_effort = 'high'
        }
        foreach ($setting in $requiredSettings.GetEnumerator()) {
            $pattern = '(?m)^\s*' + [regex]::Escape([string]$setting.Key) + '\s*=\s*"([^\"]+)"\s*$'
            $matches = @([regex]::Matches($block, $pattern))
            if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne [string]$setting.Value) {
                return $false
            }
        }

        return $block -notmatch '(?m)^\s*default_subagent_reasoning_effort\s*=\s*"max"\s*$'
    }
    catch {
        return $false
    }
}

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$CodexHome = Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome
$AgentsHome = Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

Write-Host 'Codex Workflows Kit doctor'
Write-Host "Codex home: $CodexHome"
Write-Host "Agents home: $AgentsHome"
Write-Check -Name 'Install state' -Passed (Test-Path -LiteralPath $statePath -PathType Leaf) -Detail $statePath

$state = $null
$stateSchema = $null
$installedProfile = ''
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stateSchema = Assert-InstallState -State $state
        Write-Check -Name 'State schema' -Passed $true -Detail "schema $stateSchema"
        if ($state.PSObject.Properties.Name -contains 'profile') {
            $installedProfile = [string]$state.profile
            Write-Check -Name 'Install profile' -Passed ($installedProfile -in @('minimal', 'safe')) -Detail $installedProfile
        }
        else {
            Write-Check -Name 'Install profile' -Passed $false -Detail 'profile is missing from install state'
        }
    }
    catch {
        Write-Check -Name 'Install state' -Passed $false -Detail $_.Exception.Message
        $state = $null
        $stateSchema = $null
    }
}

$coreFiles = @(
    (Join-Path $AgentsHome 'skills\workflows\SKILL.md'),
    (Join-Path $AgentsHome 'skills\evidence-first\SKILL.md')
)
if ($installedProfile -eq 'safe') {
    $coreFiles += @(
        (Join-Path $CodexHome 'AGENTS.md')
    )
}
foreach ($path in $coreFiles) {
    Write-Check -Name 'Core artifact' -Passed (Test-Path -LiteralPath $path -PathType Leaf) -Detail $path
}

if ($installedProfile -eq 'safe') {
    $configPath = Join-Path $CodexHome 'config.toml'
    Write-Check -Name 'Sub-agent defaults' -Passed (Test-ManagedAgentDefaults -Path $configPath) -Detail $configPath
}

if ($null -ne $state) {
    foreach ($file in @($state.files)) {
        $path = [string]$file.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Check -Name 'Managed artifact' -Passed $false -Detail "Missing: $path"
            continue
        }

        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Write-Check -Name 'Managed artifact' -Passed ($actual -eq [string]$file.sha256) -Detail $path
    }

    if ($stateSchema -eq 3) {
        foreach ($file in @($state.pendingFiles)) {
            $path = [string]$file.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Check -Name 'Pending artifact' -Passed $false -Detail "Missing: $path" -Optional
                continue
            }

            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $reason = if ($file.PSObject.Properties.Name -contains 'reason') { [string]$file.reason } else { 'review required' }
            Write-Check -Name 'Pending artifact' -Passed ($actual -eq [string]$file.sha256) -Detail "${reason}: $path" -Optional
        }
    }
}

Write-Check -Name 'Git' -Passed (Test-Command -Name 'git') -Detail 'Required for repository operations'
Write-Check -Name 'PowerShell' -Passed ($PSVersionTable.PSVersion.Major -ge 5) -Detail $PSVersionTable.PSVersion
Write-Check -Name 'AutoHotkey v2' -Passed (Test-Command -Name 'AutoHotkey64.exe') -Detail 'Required only for the prompt pad' -Optional

if ($Detailed) {
    Write-Host ''
    Write-Host "Installed paths are recorded in: $statePath"
    Write-Host 'The doctor is read-only and does not modify configuration or profiles.'
}

if ($script:Failures.Count -gt 0) {
    exit 1
}

Write-Host ''
Write-Host "Doctor OK. Optional warnings: $($script:Warnings.Count)."
