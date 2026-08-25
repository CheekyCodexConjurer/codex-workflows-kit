[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
    [string]$CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
Import-Module (Join-Path $repo 'scripts\backend-routing.psm1') -Force

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$requestedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) { $defaultCodexHome } else { $CodexHome }
$CodexHome = [IO.Path]::GetFullPath($requestedCodexHome)
$root = [IO.Path]::GetPathRoot($CodexHome)
if ($CodexHome.TrimEnd('\') -eq $root.TrimEnd('\')) {
    throw "Refusing to use a filesystem root as a Codex home: $CodexHome"
}

$configPath = Join-Path $CodexHome 'config.toml'
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$backupRoot = Join-Path $CodexHome ('backups\codex-workflows-kit\backend-switch-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Get-StateConfigEntry {
    param([object]$State)

    if ($null -eq $State) {
        return $null
    }
    $allEntries = @()
    if ($State.PSObject.Properties.Name -contains 'files') {
        $allEntries += @($State.files)
    }
    if ($State.PSObject.Properties.Name -contains 'pendingFiles') {
        $allEntries += @($State.pendingFiles)
    }
    $fullConfigPath = [IO.Path]::GetFullPath($configPath)
    foreach ($entry in $allEntries) {
        if ($null -ne $entry -and [IO.Path]::GetFullPath([string]$entry.path) -eq $fullConfigPath) {
            return $entry
        }
    }
    return $null
}

function Read-ExistingInstallState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Install state is invalid and switching is blocked: $($_.Exception.Message)"
    }

    foreach ($property in @('schemaVersion', 'product', 'files')) {
        if (-not ($state.PSObject.Properties.Name -contains $property)) {
            throw "Install state is missing required property '$property'; switching is blocked."
        }
    }
    if ([string]$state.product -cne 'codex-workflows-kit') {
        throw 'Install state belongs to another product; switching is blocked.'
    }
    if ([string]$state.schemaVersion -notin @('1', '2', '3', '4')) {
        throw "Install state has unsupported schema $($state.schemaVersion); switching is blocked."
    }
    if ([int]$state.schemaVersion -ge 3 -and (-not ($state.PSObject.Properties.Name -contains 'pendingFiles'))) {
        throw "Schema $($state.schemaVersion) install state is missing pendingFiles; switching is blocked."
    }
    return $state
}

function Get-UpdatedFiles {
    param([object]$State, [Parameter(Mandatory)][string]$ConfigHash)

    $files = New-Object System.Collections.Generic.List[object]
    $found = $false
    if ($null -ne $State -and $State.PSObject.Properties.Name -contains 'files') {
        foreach ($entry in @($State.files)) {
            if ($null -eq $entry) { continue }
            $path = [IO.Path]::GetFullPath([string]$entry.path)
            $hash = [string]$entry.sha256
            if ($path -eq [IO.Path]::GetFullPath($configPath)) {
                $hash = $ConfigHash
                $found = $true
            }
            $files.Add([ordered]@{ path = $path; sha256 = $hash })
        }
    }
    if (-not $found) {
        $files.Add([ordered]@{ path = [IO.Path]::GetFullPath($configPath); sha256 = $ConfigHash })
    }
    return @($files.ToArray())
}

function Get-ExistingPendingFiles {
    param([object]$State)

    if ($null -eq $State -or -not ($State.PSObject.Properties.Name -contains 'pendingFiles')) {
        return @()
    }
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($State.pendingFiles)) {
        if ($null -eq $entry) { continue }
        $reason = if ($entry.PSObject.Properties.Name -contains 'reason') { [string]$entry.reason } else { 'unverified' }
        $pending.Add([ordered]@{
                path = [IO.Path]::GetFullPath([string]$entry.path)
                sha256 = [string]$entry.sha256
                reason = $reason
            })
    }
    return @($pending.ToArray())
}

function New-NextInstallState {
    param(
        [object]$ExistingState,
        [Parameter(Mandatory)][object]$BackendState,
        [Parameter(Mandatory)][string]$ConfigHash
    )

    $state = [ordered]@{}
    if ($null -ne $ExistingState) {
        foreach ($property in $ExistingState.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
    }
    $state.schemaVersion = 4
    $state.product = 'codex-workflows-kit'
    if (-not $state.Contains('profile')) {
        $state.profile = 'safe'
    }
    $state.installedAtUtc = [datetime]::UtcNow.ToString('o')
    $state.files = @(Get-UpdatedFiles -State $ExistingState -ConfigHash $ConfigHash)
    $state.pendingFiles = @(Get-ExistingPendingFiles -State $ExistingState)

    $multiPrior = Get-BackendPriorRecord -BackendState $BackendState -Path 'features.multi_agent'
    $state.codexFeaturesPrior = [ordered]@{
        multi_agent = [ordered]@{
            present = [bool]$multiPrior.present
            value = if ([bool]$multiPrior.present) { [string]$multiPrior.value } else { $null }
        }
    }
    $state.codexBackend = $BackendState
    return $state
}

$existingState = Read-ExistingInstallState
$configText = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
}
else {
    ''
}

$trackedConfig = Get-StateConfigEntry -State $existingState
$currentConfigHash = Get-BackendFileHash -Path $configPath
if ($null -ne $trackedConfig -and $null -ne $currentConfigHash -and $currentConfigHash -cne [string]$trackedConfig.sha256) {
    throw "Configuration drift detected at $configPath; review the user change before switching."
}

$snapshot = Get-BackendConfigSnapshot -Text $configText
$backendState = New-CodexBackendState -Snapshot $snapshot -ExistingInstallState $existingState
if ($null -ne $existingState -and ($existingState.PSObject.Properties.Name -contains 'codexBackend')) {
    $currentSelected = [string]$backendState.selected
    Assert-CodexBackendMatrix -Text $configText -Backend $currentSelected -BackendState $backendState | Out-Null
}

$nextConfigText = Set-CodexBackendConfigText -Text $configText -Backend $Backend -BackendState $backendState
$configChanged = $nextConfigText -cne $configText
$nextBackendState = [ordered]@{
    version = 1
    selected = $Backend
    prior = @(
        foreach ($definition in (Get-BackendKeyDefinitions)) {
            Get-BackendPriorRecord -BackendState $backendState -Path $definition.Path
        }
    )
}
Assert-CodexBackendState -BackendState $nextBackendState

$nextConfigHash = if ($configChanged) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($nextConfigText)
        [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}
else {
    $currentConfigHash
}

$stateNeedsWrite = $null -eq $existingState -or -not ($existingState.PSObject.Properties.Name -contains 'codexBackend') -or
    [string]$existingState.schemaVersion -ne '4' -or [string]$existingState.codexBackend.selected -cne $Backend -or
    $null -eq $trackedConfig -or [string]$trackedConfig.sha256 -cne [string]$nextConfigHash

if ($configChanged) {
    $backupPath = Backup-BackendFile -Path $configPath -BackupRoot $backupRoot
    Write-BackendUtf8NoBom -Path $configPath -Content $nextConfigText
}

if ($stateNeedsWrite) {
    $nextState = New-NextInstallState -ExistingState $existingState -BackendState $nextBackendState -ConfigHash $nextConfigHash
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Backup-BackendFile -Path $statePath -BackupRoot $backupRoot | Out-Null
    }
    Write-BackendUtf8NoBom -Path $statePath -Content (($nextState | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}

Write-Host "Selected subagent backend: $Backend"
if ($Backend -ceq 'native') {
    Write-Host 'Native children: model="gpt-5.6-luna", reasoning_effort="max", normal/default mode; Fast mode disabled.'
}
else {
    Write-Host 'DeepSeek/Gemini bridge route restored from its captured configuration values.'
}
Write-Host 'Scope: new Codex tasks and sessions.'
Write-Host 'Already-running tasks are unchanged. No restart or MCP was contacted.'
if ($configChanged -or $stateNeedsWrite) {
    Write-Host "Configuration and routing state updated under: $CodexHome"
}
else {
    Write-Host 'The selected backend was already active; no files changed.'
}
