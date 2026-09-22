[CmdletBinding(DefaultParameterSetName = 'Switch')]
param(
    [Parameter(ParameterSetName = 'Switch', Mandatory = $true, Position = 0)]
    [ValidateSet('native', 'deepseek')]
    [string]$Backend,

    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status,

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
$agentsMdPath = Join-Path $CodexHome 'AGENTS.md'
$templatePath = Join-Path $repo 'codex\AGENTS.md'
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$backupRoot = Join-Path $CodexHome ('backups\codex-workflows-kit\backend-switch-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Get-StateEntryByPath {
    param([object]$State, [Parameter(Mandatory)][string]$TargetFilePath)

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
    $fullTargetPath = [IO.Path]::GetFullPath($TargetFilePath)
    foreach ($entry in $allEntries) {
        if ($null -ne $entry -and [IO.Path]::GetFullPath([string]$entry.path) -eq $fullTargetPath) {
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
    if ([string]$state.schemaVersion -notin @('1', '2', '3', '4', '5', '6')) {
        throw "Install state has unsupported schema $($state.schemaVersion); switching is blocked."
    }
    if ([int]$state.schemaVersion -ge 3 -and (-not ($state.PSObject.Properties.Name -contains 'pendingFiles'))) {
        throw "Schema $($state.schemaVersion) install state is missing pendingFiles; switching is blocked."
    }
    if ($state.PSObject.Properties.Name -contains 'codexBackend') {
        if ($null -eq $state.codexBackend) {
            throw "Install state contains invalid codexBackend property; switching is blocked."
        }
        Assert-CodexBackendState -BackendState $state.codexBackend
    }
    if ([int]$state.schemaVersion -le 5 -and $state.PSObject.Properties.Name -contains 'codexDelegation') {
        if ($null -eq $state.codexDelegation) {
            throw "Install state contains invalid codexDelegation property; switching is blocked."
        }
        Assert-CodexDelegationState -DelegationState $state.codexDelegation
    }
    if ([int]$state.schemaVersion -le 5 -and $state.PSObject.Properties.Name -contains 'codexStrategy') {
        if ($null -eq $state.codexStrategy) {
            throw "Install state contains invalid codexStrategy property; switching is blocked."
        }
        Assert-CodexStrategyState -StrategyState $state.codexStrategy
    }
    if ($state.PSObject.Properties.Name -contains 'codexContinuation') {
        if ($null -eq $state.codexContinuation) {
            throw "Install state contains invalid codexContinuation property; switching is blocked."
        }
        Assert-CodexContinuationState -ContinuationState $state.codexContinuation
    }
    if ([string]$state.schemaVersion -eq '5') {
        if (-not ($state.PSObject.Properties.Name -contains 'codexBackend') -or $null -eq $state.codexBackend) {
            throw "Schema 5 install state is missing required codexBackend; switching is blocked."
        }
        Assert-CodexBackendState -BackendState $state.codexBackend
        if (-not ($state.PSObject.Properties.Name -contains 'codexDelegation') -or $null -eq $state.codexDelegation) {
            throw "Schema 5 install state is missing required codexDelegation; switching is blocked."
        }
        Assert-CodexDelegationState -DelegationState $state.codexDelegation
    }
    if ([string]$state.schemaVersion -eq '6') {
        foreach ($property in @('codexBackend', 'codexContinuation')) {
            if (-not ($state.PSObject.Properties.Name -contains $property) -or $null -eq $state.$property) {
                throw "Schema 6 install state is missing required $property; switching is blocked."
            }
        }
        if (($state.PSObject.Properties.Name -contains 'codexDelegation') -or ($state.PSObject.Properties.Name -contains 'codexStrategy')) {
            throw 'Schema 6 install state contains retired orchestration selectors; switching is blocked.'
        }
    }
    return $state
}

function Get-UpdatedFilesWithEntries {
    param(
        [object]$State,
        [Parameter(Mandatory)][hashtable]$UpdatedMap
    )

    $files = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if ($null -ne $State -and $State.PSObject.Properties.Name -contains 'files') {
        foreach ($entry in @($State.files)) {
            if ($null -eq $entry) { continue }
            $path = [IO.Path]::GetFullPath([string]$entry.path)
            $hash = [string]$entry.sha256
            if ($UpdatedMap.ContainsKey($path)) {
                $hash = $UpdatedMap[$path]
                $seen[$path] = $true
            }
            $files.Add([ordered]@{ path = $path; sha256 = $hash })
        }
    }
    foreach ($path in $UpdatedMap.Keys) {
        if (-not $seen.ContainsKey($path)) {
            $files.Add([ordered]@{ path = $path; sha256 = $UpdatedMap[$path] })
        }
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

function Assert-ExistingRuntimeMatchesState {
    param([object]$State, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($null -eq $State) { return }
    $runtime = Get-CodexRuntimeBlockInfo -Text $Text
    if (-not $runtime.Present) {
        throw 'Install state exists but AGENTS.md has no managed runtime block; switching is blocked.'
    }
    if ($State.PSObject.Properties.Name -contains 'codexBackend' -and
        $runtime.Backend -cne [string]$State.codexBackend.selected) {
        throw 'Configuration drift detected: codexBackend differs between install state and AGENTS.md.'
    }
    if ($State.PSObject.Properties.Name -contains 'codexContinuation' -and
        $runtime.Continuation -cne [string]$State.codexContinuation.selected) {
        throw 'Configuration drift detected: codexContinuation differs between install state and AGENTS.md.'
    }

    if ([string]$State.schemaVersion -eq '5') {
        if (-not ($State.PSObject.Properties.Name -contains 'codexDelegation') -or
            $runtime.Policy -cne [string]$State.codexDelegation.selected) {
            throw 'Configuration drift detected: legacy delegation selector differs between install state and AGENTS.md.'
        }
        $hasStrategyState = $State.PSObject.Properties.Name -contains 'codexStrategy'
        if ($hasStrategyState -ne [bool]$runtime.HasStrategyKey -or
            ($hasStrategyState -and $runtime.Strategy -cne [string]$State.codexStrategy.selected)) {
            throw 'Configuration drift detected: legacy strategy selector differs between install state and AGENTS.md.'
        }
    }
    elseif ([string]$State.schemaVersion -eq '6') {
        Assert-CodexAgentsRuntimeBlock -Text $Text -Backend ([string]$State.codexBackend.selected) -Continuation ([string]$State.codexContinuation.selected)
    }
}

$existingState = Read-ExistingInstallState

if ($Status) {
    if ($null -eq $existingState) {
        throw "No active install state found at $statePath; cannot determine status."
    }
    if (-not (Test-Path -LiteralPath $agentsMdPath -PathType Leaf)) {
        throw "AGENTS.md is missing at $agentsMdPath; cannot determine status."
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "config.toml is missing at $configPath; cannot determine status."
    }

    $stateBackend = if ($existingState.PSObject.Properties.Name -contains 'codexBackend') {
        [string]$existingState.codexBackend.selected
    }
    else {
        throw 'Install state is missing codexBackend.'
    }
    $stateContinuation = if ($existingState.PSObject.Properties.Name -contains 'codexContinuation') {
        [string]$existingState.codexContinuation.selected
    }
    else {
        'active_follow'
    }

    if ($stateBackend -notin @('native', 'deepseek')) {
        throw "Install state has invalid selected backend: $stateBackend"
    }
    if ($stateContinuation -notin @('active_follow', 'park_and_wake')) {
        throw "Install state has invalid selected continuation: $stateContinuation"
    }

    $agentsText = Get-Content -LiteralPath $agentsMdPath -Raw -Encoding UTF8
    $rtInfo = Get-CodexRuntimeBlockInfo -Text $agentsText
    Assert-ExistingRuntimeMatchesState -State $existingState -Text $agentsText
    if (-not $rtInfo.Present) {
        throw 'Installed AGENTS.md is missing the managed runtime block (# BEGIN CODEX-WORKFLOWS-KIT: runtime).'
    }
    if ($rtInfo.Backend -cne $stateBackend) {
        throw "Active backend mismatch: state has '$stateBackend', but AGENTS.md runtime block has '$($rtInfo.Backend)'."
    }
    if ($rtInfo.Continuation -cne $stateContinuation) {
        throw "Active subagent continuation mismatch: state has '$stateContinuation', but AGENTS.md runtime block has '$($rtInfo.Continuation)'."
    }
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    Assert-CodexBackendMatrix -Text $configText -Backend $stateBackend -BackendState $existingState.codexBackend | Out-Null

    Write-Host "Active subagent backend: $stateBackend"
    Write-Host "Active subagent continuation: $stateContinuation"
    if ([string]$existingState.schemaVersion -eq '5') {
        Write-Host 'Migration required: the next backend or continuation switch will remove retired selectors.'
    }
    Write-Host "Codex home: $CodexHome"
    return
}

# --- Backend Switch ---
$configText = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
}
else {
    ''
}
$existingAgentsText = if (Test-Path -LiteralPath $agentsMdPath -PathType Leaf) {
    Get-Content -LiteralPath $agentsMdPath -Raw -Encoding UTF8
}
else {
    ''
}
$templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

$trackedConfig = Get-StateEntryByPath -State $existingState -TargetFilePath $configPath
$currentConfigHash = Get-BackendFileHash -Path $configPath

$trackedAgents = Get-StateEntryByPath -State $existingState -TargetFilePath $agentsMdPath
$currentAgentsHash = Get-BackendFileHash -Path $agentsMdPath
if ($null -ne $trackedAgents -and $null -ne $currentAgentsHash -and $currentAgentsHash -cne [string]$trackedAgents.sha256) {
    throw "Configuration drift detected at $agentsMdPath; review the user change before switching."
}

$snapshot = Get-BackendConfigSnapshot -Text $configText
$backendState = New-CodexBackendState -Snapshot $snapshot -ExistingInstallState $existingState
if ($null -ne $existingState -and ($existingState.PSObject.Properties.Name -contains 'codexBackend')) {
    $currentSelected = [string]$backendState.selected
    try {
        Assert-CodexBackendMatrix -Text $configText -Backend $currentSelected -BackendState $backendState | Out-Null
    }
    catch {
        throw "Configuration drift detected at $configPath; review the user change before switching: $($_.Exception.Message)"
    }
}

$currentContinuation = if ($null -ne $existingState -and ($existingState.PSObject.Properties.Name -contains 'codexContinuation')) {
    Assert-CodexContinuationState -ContinuationState $existingState.codexContinuation
    [string]$existingState.codexContinuation.selected
}
else {
    $rtInfo = Get-CodexRuntimeBlockInfo -Text $existingAgentsText
    if ($rtInfo.Present -and -not [string]::IsNullOrWhiteSpace($rtInfo.Continuation)) {
        if ($rtInfo.Continuation -notin @('active_follow', 'park_and_wake')) {
            throw "Invalid subagent continuation '$($rtInfo.Continuation)' in AGENTS.md runtime block."
        }
        $rtInfo.Continuation
    }
    else {
        'active_follow'
    }
}
if ($currentContinuation -notin @('active_follow', 'park_and_wake')) {
    throw "Invalid subagent continuation '$currentContinuation'; switching is blocked."
}
Assert-ExistingRuntimeMatchesState -State $existingState -Text $existingAgentsText

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

$nextContinuationState = if ($null -ne $existingState -and ($existingState.PSObject.Properties.Name -contains 'codexContinuation')) {
    $existingState.codexContinuation
}
else {
    New-CodexContinuationState -ExistingInstallState $existingState
}
Assert-CodexContinuationState -ContinuationState $nextContinuationState

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

$nextAgentsText = Set-CodexAgentsManagedBlockText -ExistingAgentsText $existingAgentsText -TemplateText $templateText -Backend $Backend -Continuation $currentContinuation
$agentsChanged = $nextAgentsText -cne $existingAgentsText
$nextAgentsHash = if ($agentsChanged) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($nextAgentsText)
        [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}
else {
    $currentAgentsHash
}

$stateNeedsWrite = $null -eq $existingState -or
    -not ($existingState.PSObject.Properties.Name -contains 'codexBackend') -or
    -not ($existingState.PSObject.Properties.Name -contains 'codexContinuation') -or
    ($existingState.PSObject.Properties.Name -contains 'codexDelegation') -or
    ($existingState.PSObject.Properties.Name -contains 'codexStrategy') -or
    [string]$existingState.schemaVersion -ne '6' -or
    [string]$existingState.codexBackend.selected -cne $Backend -or
    $null -eq $trackedConfig -or [string]$trackedConfig.sha256 -cne [string]$nextConfigHash -or
    $null -eq $trackedAgents -or [string]$trackedAgents.sha256 -cne [string]$nextAgentsHash

$preExisting = @{
    $configPath = Test-Path -LiteralPath $configPath -PathType Leaf
    $agentsMdPath = Test-Path -LiteralPath $agentsMdPath -PathType Leaf
    $statePath = Test-Path -LiteralPath $statePath -PathType Leaf
}
$newlyCreatedFiles = New-Object System.Collections.Generic.List[string]
$backedUpFiles = @{}
try {
    if ($configChanged) {
        if ($preExisting[$configPath]) {
            $bConfig = Backup-BackendFile -Path $configPath -BackupRoot $backupRoot
            if ($null -ne $bConfig) { $backedUpFiles[$configPath] = $bConfig }
        }
        else {
            $newlyCreatedFiles.Add($configPath)
        }
        Write-BackendUtf8NoBom -Path $configPath -Content $nextConfigText
    }

    if ($agentsChanged) {
        if ($preExisting[$agentsMdPath]) {
            $bAgents = Backup-BackendFile -Path $agentsMdPath -BackupRoot $backupRoot
            if ($null -ne $bAgents) { $backedUpFiles[$agentsMdPath] = $bAgents }
        }
        else {
            $newlyCreatedFiles.Add($agentsMdPath)
        }
        Write-BackendUtf8NoBom -Path $agentsMdPath -Content $nextAgentsText
    }

    if ($stateNeedsWrite) {
        $nextState = [ordered]@{}
        if ($null -ne $existingState) {
            foreach ($prop in $existingState.PSObject.Properties) {
                if ($prop.Name -in @('codexDelegation', 'codexStrategy')) { continue }
                $nextState[$prop.Name] = $prop.Value
            }
        }
        $nextState.schemaVersion = 6
        $nextState.product = 'codex-workflows-kit'
        if (-not $nextState.Contains('profile')) {
            $nextState.profile = 'safe'
        }
        $nextState.installedAtUtc = [datetime]::UtcNow.ToString('o')
        $updateMap = @{}
        if ($null -ne $nextConfigHash) { $updateMap[[IO.Path]::GetFullPath($configPath)] = $nextConfigHash }
        if ($null -ne $nextAgentsHash) { $updateMap[[IO.Path]::GetFullPath($agentsMdPath)] = $nextAgentsHash }
        $nextState.files = @(Get-UpdatedFilesWithEntries -State $existingState -UpdatedMap $updateMap)
        $nextState.pendingFiles = @(Get-ExistingPendingFiles -State $existingState)

        $multiPrior = Get-BackendPriorRecord -BackendState $nextBackendState -Path 'features.multi_agent'
        $nextState.codexFeaturesPrior = [ordered]@{
            multi_agent = [ordered]@{
                present = [bool]$multiPrior.present
                value = if ([bool]$multiPrior.present) { [string]$multiPrior.value } else { $null }
            }
        }
        $nextState.codexBackend = $nextBackendState
        $nextState.codexContinuation = $nextContinuationState

        if ($preExisting[$statePath]) {
            $bState = Backup-BackendFile -Path $statePath -BackupRoot $backupRoot
            if ($null -ne $bState) { $backedUpFiles[$statePath] = $bState }
        }
        else {
            $newlyCreatedFiles.Add($statePath)
        }
        Write-BackendUtf8NoBom -Path $statePath -Content (($nextState | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    }

    # Verify written surfaces
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Assert-CodexBackendMatrix -Text (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) -Backend $Backend -BackendState $nextBackendState | Out-Null
    }
    if (Test-Path -LiteralPath $agentsMdPath -PathType Leaf) {
        Assert-CodexAgentsRuntimeBlock -Text (Get-Content -LiteralPath $agentsMdPath -Raw -Encoding UTF8) -Backend $Backend -Continuation $currentContinuation
    }
    if ($stateNeedsWrite) {
        $writtenState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$writtenState.schemaVersion -cne '6' -or
            ($writtenState.PSObject.Properties.Name -contains 'codexDelegation') -or
            ($writtenState.PSObject.Properties.Name -contains 'codexStrategy')) {
            throw 'Written install state did not satisfy the schema 6 selector contract.'
        }
    }
}
catch {
    $rollbackFailed = $false
    foreach ($origPath in $backedUpFiles.Keys) {
        try {
            Copy-Item -LiteralPath $backedUpFiles[$origPath] -Destination $origPath -Force
        }
        catch {
            $rollbackFailed = $true
            Write-Warning "Rollback failed for ${origPath}: $($_.Exception.Message)"
        }
    }
    foreach ($createdPath in $newlyCreatedFiles) {
        if (-not $backedUpFiles.ContainsKey($createdPath)) {
            try {
                if (Test-Path -LiteralPath $createdPath -PathType Leaf) {
                    Remove-Item -LiteralPath $createdPath -Force
                }
            }
            catch {
                $rollbackFailed = $true
                Write-Warning "Rollback failed removing newly-created file ${createdPath}: $($_.Exception.Message)"
            }
        }
    }
    if ($rollbackFailed) {
        throw "Backend switch failed and rollback was incomplete: $($_.Exception.Message)"
    }
    throw "Backend switch failed and was rolled back: $($_.Exception.Message)"
}

Write-Host "Selected subagent backend: $Backend"
if ($Backend -ceq 'native') {
    Write-Host 'Native children: model="gpt-6-luna", reasoning_effort="max", normal/default mode; Fast mode disabled.'
}
else {
    Write-Host 'DeepSeek/Gemini bridge route restored from its captured configuration values.'
}
Write-Host "Active subagent continuation: $currentContinuation"
Write-Host 'Scope: new Codex tasks and sessions.'
Write-Host 'Already-running tasks are unchanged. No restart or MCP was contacted.'
if ($configChanged -or $agentsChanged -or $stateNeedsWrite) {
    Write-Host "Configuration and routing state updated under: $CodexHome"
}
else {
    Write-Host 'The selected backend was already active; no files changed.'
}
