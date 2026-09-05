[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('minimal', 'safe')]
    [string]$Profile = 'safe',

    [string]$CodexHome,
    [string]$AgentsHome,
    [string]$AntigravityHome,
    [string]$AhkDestination,

    [switch]$InstallAhk,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$nl = [Environment]::NewLine

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$backendRoutingModule = Join-Path $repo 'scripts\backend-routing.psm1'
Import-Module $backendRoutingModule -Force

function Confirm-InstallAction {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action
    )

    if ($WhatIfPreference) {
        Write-Host ("What if: Performing '{0}' on '{1}'." -f $Action, $Target)
        return $false
    }

    return $true
}

function Resolve-HomePath {
    param(
        [string]$Requested,
        [Parameter(Mandatory)][string]$Fallback
    )

    $value = if ([string]::IsNullOrWhiteSpace($Requested)) { $Fallback } else { $Requested }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'A destination path could not be resolved.'
    }

    return [IO.Path]::GetFullPath($value)
}

function Assert-SafeDestination {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\') -eq $root.TrimEnd('\')) {
        throw "Refusing to use a filesystem root as an installation destination: $fullPath"
    }

    return $fullPath
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $fullPath.StartsWith($fullParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to manage a path outside its declared destination: $fullPath"
    }

    return $fullPath
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-RequiredFileHash {
    param([Parameter(Mandatory)][string]$Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        if (-not (Get-Item -LiteralPath $Path).PSIsContainer) {
            throw "Destination exists but is not a directory: $Path"
        }
        return
    }

    if (Confirm-InstallAction -Target $Path -Action 'create installation directory') {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$defaultAntigravityHome = if ($env:ANTIGRAVITY_HOME) { $env:ANTIGRAVITY_HOME } else { Join-Path $env:USERPROFILE '.gemini' }

$CodexHome = Assert-SafeDestination (Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome)
$AgentsHome = Assert-SafeDestination (Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome)
$AntigravityHome = Assert-SafeDestination (Resolve-HomePath -Requested $AntigravityHome -Fallback $defaultAntigravityHome)

if ([string]::IsNullOrWhiteSpace($AhkDestination)) {
    $AhkDestination = Join-Path $env:USERPROFILE 'Documents\Codex\PromptPad\codex_prompt_pad.ahk'
}
$AhkDestination = Assert-SafeDestination $AhkDestination

$skillsSource = Join-Path $repo 'skills'
$workflowSource = Join-Path $skillsSource 'workflows'
$evidenceSource = Join-Path $skillsSource 'evidence-first'
$mcpSource = Join-Path $skillsSource 'mcp-foundation'
$codebaseMemorySource = Join-Path $skillsSource 'codebase-memory-mcp'
$context7Source = Join-Path $skillsSource 'context7-mcp'
$agentsMdSource = Join-Path $repo 'codex\AGENTS.md'
$geminiMdSource = Join-Path $repo 'antigravity\GEMINI.md'
$ahkSource = Join-Path $repo 'ahk\codex_prompt_pad.ahk'

$skillsDest = Join-Path $AgentsHome 'skills'
$antigravitySkillsDest1 = Join-Path $AntigravityHome 'antigravity\skills'
$antigravitySkillsDest2 = Join-Path $AntigravityHome 'config\skills'
$agentsMdDest = Join-Path $CodexHome 'AGENTS.md'
$geminiMdDest = Join-Path (Join-Path $AntigravityHome 'config') 'GEMINI.md'
$configPath = Join-Path $CodexHome 'config.toml'
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'

$script:BackupRoot = Join-Path $CodexHome ('backups\codex-workflows-kit\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:QuarantineRoot = Join-Path $script:BackupRoot 'quarantine'
$script:BackupManifest = New-Object System.Collections.Generic.List[object]
$script:BackedUp = @{}
$script:ManagedFiles = @{}
$script:PriorHashes = @{}
$script:PriorPaths = New-Object System.Collections.Generic.List[string]
$script:PendingFiles = @{}
$script:RemovedParents = New-Object System.Collections.Generic.List[string]
$script:PriorFeaturesRecord = $null
$script:PriorBackendState = $null
$script:PriorDelegationState = $null
$script:PriorStrategyState = $null
$script:PriorContinuationState = $null
$script:SelectedBackend = 'deepseek'
$script:SelectedPolicy = 'balanced'
$script:SelectedStrategy = 'worker'
$script:SelectedContinuation = 'active_follow'
$script:FeaturesGateApplied = $false
$script:FeaturesPrior = [ordered]@{ present = $false; value = $null }
$script:ConfigModified = $false

function Assert-InstallState {
    param([Parameter(Mandatory)][object]$State)

    $required = @('schemaVersion', 'product', 'files')
    foreach ($property in $required) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) {
            throw "Install state is missing required property: $property"
        }
    }

    $schemaText = [string]$State.schemaVersion
    if ($schemaText -notin @('1', '2', '3', '4', '5')) {
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
    if ($schema -ge 3) {
        if (-not ($State.PSObject.Properties.Name -contains 'pendingFiles') -or $null -eq $State.pendingFiles -or -not ($State.pendingFiles -is [System.Array])) {
            throw "Schema $schema install state is missing pendingFiles."
        }
        $entries += @($State.pendingFiles)
    }
    elseif ($State.PSObject.Properties.Name -contains 'pendingFiles') {
        throw 'Only schema 3 and later install state may contain pendingFiles.'
    }

    if ($schema -ge 4) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or $null -eq $State.codexFeaturesPrior) {
            throw "Schema $schema install state is missing codexFeaturesPrior."
        }
        if (-not ($State.codexFeaturesPrior.PSObject.Properties.Name -contains 'multi_agent')) {
            throw "Schema $schema install state is missing the multi_agent feature record."
        }
        $featureRecord = $State.codexFeaturesPrior.multi_agent
        if ($null -eq $featureRecord -or -not ($featureRecord.PSObject.Properties.Name -contains 'present') -or -not ($featureRecord.PSObject.Properties.Name -contains 'value')) {
            throw "Schema $schema install state contains an invalid multi_agent feature record."
        }
        if ($featureRecord.present -notin @($true, $false)) {
            throw "Schema $schema install state has an invalid multi_agent presence flag."
        }
        if ([bool]$featureRecord.present -and $null -eq $featureRecord.value) {
            throw "Schema $schema install state has a present multi_agent record without a value."
        }
        if (-not [bool]$featureRecord.present -and $null -ne $featureRecord.value) {
            throw "Schema $schema install state has an absent multi_agent record with a value."
        }
    }

    if ($State.PSObject.Properties.Name -contains 'codexBackend') {
        if ($null -eq $State.codexBackend) {
            throw "Install state contains an invalid codexBackend property."
        }
        Assert-CodexBackendState -BackendState $State.codexBackend
    }
    if ($State.PSObject.Properties.Name -contains 'codexDelegation') {
        if ($null -eq $State.codexDelegation) {
            throw "Install state contains an invalid codexDelegation property."
        }
        Assert-CodexDelegationState -DelegationState $State.codexDelegation
    }
    if ($State.PSObject.Properties.Name -contains 'codexStrategy') {
        if ($null -eq $State.codexStrategy) {
            throw "Install state contains an invalid codexStrategy property."
        }
        Assert-CodexStrategyState -StrategyState $State.codexStrategy
    }
    if ($State.PSObject.Properties.Name -contains 'codexContinuation') {
        if ($null -eq $State.codexContinuation) {
            throw "Install state contains an invalid codexContinuation property."
        }
        Assert-CodexContinuationState -ContinuationState $State.codexContinuation
    }

    if ($schema -ge 5) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexBackend') -or $null -eq $State.codexBackend) {
            throw "Schema $schema install state is missing required codexBackend."
        }
        Assert-CodexBackendState -BackendState $State.codexBackend
        if (-not ($State.PSObject.Properties.Name -contains 'codexDelegation') -or $null -eq $State.codexDelegation) {
            throw "Schema $schema install state is missing required codexDelegation."
        }
        Assert-CodexDelegationState -DelegationState $State.codexDelegation
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

    if ($schema -ge 3) {
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

function Initialize-PriorState {
    $existingState = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $schema = Assert-InstallState -State $state
            $existingState = $state
            $priorEntries = @($state.files)
            if ($schema -ge 3) {
                $priorEntries += @($state.pendingFiles)
            }
            foreach ($file in $priorEntries) {
                $path = [IO.Path]::GetFullPath([string]$file.path)
                if (-not $script:PriorHashes.ContainsKey($path)) {
                    $script:PriorPaths.Add($path)
                }
                $script:PriorHashes[$path] = [string]$file.sha256
            }
            if ($schema -ge 4 -and ($state.PSObject.Properties.Name -contains 'codexFeaturesPrior')) {
                $script:PriorFeaturesRecord = $state.codexFeaturesPrior
            }
            if ($state.PSObject.Properties.Name -contains 'codexBackend') {
                Assert-CodexBackendState -BackendState $state.codexBackend
                $script:PriorBackendState = $state.codexBackend
                $script:SelectedBackend = [string]$state.codexBackend.selected
                if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                    $existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
                    try {
                        Assert-CodexBackendMatrix -Text $existingConfig -Backend $script:SelectedBackend -BackendState $script:PriorBackendState | Out-Null
                    }
                    catch {
                        throw "Backend configuration drift detected; safe install is blocked until $configPath is reviewed: $($_.Exception.Message)"
                    }
                }
            }
            if ($state.PSObject.Properties.Name -contains 'codexDelegation') {
                Assert-CodexDelegationState -DelegationState $state.codexDelegation
                $script:PriorDelegationState = $state.codexDelegation
                $script:SelectedPolicy = [string]$state.codexDelegation.selected
            }
            if ($state.PSObject.Properties.Name -contains 'codexStrategy') {
                Assert-CodexStrategyState -StrategyState $state.codexStrategy
                $script:PriorStrategyState = $state.codexStrategy
                $script:SelectedStrategy = [string]$state.codexStrategy.selected
            }
            if ($state.PSObject.Properties.Name -contains 'codexContinuation') {
                Assert-CodexContinuationState -ContinuationState $state.codexContinuation
                $script:PriorContinuationState = $state.codexContinuation
                $script:SelectedContinuation = [string]$state.codexContinuation.selected
            }
        }
        catch {
            throw "Previous install state is invalid: $($_.Exception.Message)"
        }
    }

    if ($null -eq $script:PriorBackendState) {
        $existingConfig = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { '' }
        $cleanedConfig = Remove-KitBlocks -Text $existingConfig
        $snap = Get-BackendConfigSnapshot -Text $cleanedConfig
        $script:PriorBackendState = New-CodexBackendState -Snapshot $snap -ExistingInstallState $existingState
        $script:SelectedBackend = [string]$script:PriorBackendState.selected
    }

    if ($null -eq $script:PriorDelegationState) {
        $script:PriorDelegationState = New-CodexDelegationState -ExistingInstallState $existingState
        $script:SelectedPolicy = [string]$script:PriorDelegationState.selected
    }

    if ($null -eq $script:PriorStrategyState) {
        $script:PriorStrategyState = New-CodexStrategyState -ExistingInstallState $existingState
        $script:SelectedStrategy = [string]$script:PriorStrategyState.selected
    }

    if ($null -eq $script:PriorContinuationState) {
        $script:PriorContinuationState = New-CodexContinuationState -ExistingInstallState $existingState
        $script:SelectedContinuation = [string]$script:PriorContinuationState.selected
    }
}

function Add-PendingFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [string]$ExpectedHash
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        $ExpectedHash = Get-RequiredFileHash -Path $fullPath
    }
    $script:PendingFiles[$fullPath] = [ordered]@{
        path = $fullPath
        sha256 = $ExpectedHash
        reason = $Reason
    }
}

function Save-BackupManifest {
    if ($WhatIfPreference) {
        return
    }

    Ensure-Directory -Path $script:BackupRoot
    $manifestPath = Join-Path $script:BackupRoot 'backup-manifest.json'
    $arr = $script:BackupManifest.ToArray()
    $json = ConvertTo-Json -InputObject $arr -Depth 5
    Write-Utf8NoBom -Path $manifestPath -Content ($json + $nl)
}

function Backup-ExistingFile {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string]$Category = 'existing_file_backup'
    )

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        return
    }

    $fullDestination = [IO.Path]::GetFullPath($Destination)
    if ($script:BackedUp.ContainsKey($fullDestination)) {
        return
    }

    $safeName = [regex]::Replace($fullDestination, '[^A-Za-z0-9._-]', '_')
    $backupPath = Join-Path $script:BackupRoot $safeName
    if (Confirm-InstallAction -Target $Destination -Action "back up existing file to $backupPath") {
        Ensure-Directory -Path $script:BackupRoot
        Copy-Item -LiteralPath $Destination -Destination $backupPath -Force
        $sha = Get-RequiredFileHash -Path $backupPath
        $script:BackedUp[$fullDestination] = $backupPath
        $script:BackupManifest.Add([ordered]@{
            source = $fullDestination
            backup = $backupPath
            sha256 = $sha
            category = $Category
            timestampUtc = [datetime]::UtcNow.ToString('o')
        })
        Save-BackupManifest
    }
}

function Quarantine-ExtraFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$BaseDir
    )

    $fullSource = [IO.Path]::GetFullPath($SourcePath)
    if (-not (Test-Path -LiteralPath $fullSource -PathType Leaf)) {
        return
    }

    Assert-ChildPath -Path $fullSource -Parent $BaseDir | Out-Null

    $fileItem = Get-Item -LiteralPath $fullSource -Force
    if ($fileItem.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        throw "Reparse point detected at file: $fullSource. Refusing to quarantine; fail closed."
    }

    $rel = $fullSource.Substring($BaseDir.Length).TrimStart('\')
    $quarantineDest = Join-Path $script:QuarantineRoot $rel
    Ensure-Directory -Path (Split-Path -Parent $quarantineDest)

    if (Confirm-InstallAction -Target $fullSource -Action "quarantine extra custom file to $quarantineDest") {
        Copy-Item -LiteralPath $fullSource -Destination $quarantineDest -Force
        $originalHash = Get-RequiredFileHash -Path $fullSource
        $quarantineHash = Get-RequiredFileHash -Path $quarantineDest
        if ($originalHash -ne $quarantineHash) {
            throw "Quarantine integrity check failed for ${fullSource}: SHA256 mismatch."
        }

        $script:BackupManifest.Add([ordered]@{
            source = $fullSource
            backup = $quarantineDest
            sha256 = $originalHash
            category = 'quarantined_custom_content'
            timestampUtc = [datetime]::UtcNow.ToString('o')
        })
        Save-BackupManifest

        Remove-Item -LiteralPath $fullSource -Force
    }
}

function Install-ManagedContent {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $fullDestination = [IO.Path]::GetFullPath($Destination)
    Ensure-Directory -Path (Split-Path -Parent $fullDestination)

    $changed = $true
    if (Test-Path -LiteralPath $fullDestination -PathType Leaf) {
        $changed = (Get-Content -LiteralPath $fullDestination -Raw -Encoding UTF8) -cne $Content
    }

    if ($changed) {
        Backup-ExistingFile -Destination $fullDestination
        if (Confirm-InstallAction -Target $fullDestination -Action 'install managed content') {
            Write-Utf8NoBom -Path $fullDestination -Content $Content
        }
    }

    $script:ManagedFiles[$fullDestination] = $null
}

function Copy-ManagedTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source directory is missing: $Source"
    }

    Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        Install-ManagedContent -Destination $target -Content $content
    }
}

function Migrate-UnmanagedContext7Skill {
    param([Parameter(Mandatory)][string]$TargetDirectory)

    $targetFullPath = Assert-SafeDestination -Path ([IO.Path]::GetFullPath($TargetDirectory))

    $candidates = @(
        (Join-Path $targetFullPath 'context7-mcp'),
        (Join-Path $targetFullPath 'context7')
    )

    # Check for ambiguous custom conflict between context7 and context7-mcp
    $ctx1 = Join-Path $targetFullPath 'context7'
    $ctx2 = Join-Path $targetFullPath 'context7-mcp'
    $ctx1Skill = Join-Path $ctx1 'SKILL.md'
    $ctx2Skill = Join-Path $ctx2 'SKILL.md'
    if ((Test-Path -LiteralPath $ctx1Skill -PathType Leaf) -and (Test-Path -LiteralPath $ctx2Skill -PathType Leaf)) {
        $h1 = Get-RequiredFileHash -Path $ctx1Skill
        $h2 = Get-RequiredFileHash -Path $ctx2Skill
        if ($h1 -ne $h2) {
            $isManaged1 = $script:PriorHashes.ContainsKey([IO.Path]::GetFullPath($ctx1Skill))
            $isManaged2 = $script:PriorHashes.ContainsKey([IO.Path]::GetFullPath($ctx2Skill))
            if (-not $isManaged1 -or -not $isManaged2) {
                throw "Ambiguous custom conflict: both context7 and context7-mcp contain conflicting unmanaged SKILL.md. Fail closed."
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        # Canonical target bounds check
        $fullCandidate = Assert-ChildPath -Path $candidate -Parent $targetFullPath

        # Reparse point check on candidate
        $candItem = Get-Item -LiteralPath $fullCandidate -Force
        if ($candItem.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point detected at candidate directory: $fullCandidate. Refusing recursive operations; fail closed."
        }
        if (-not $candItem.PSIsContainer) {
            throw "Candidate skill path is not a directory: $fullCandidate"
        }

        # Reparse and bounds check on all items
        $allChildren = @(Get-ChildItem -LiteralPath $fullCandidate -Recurse -Force -ErrorAction Stop)
        foreach ($child in $allChildren) {
            Assert-ChildPath -Path $child.FullName -Parent $fullCandidate | Out-Null
            if ($child.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                throw "Reparse point detected inside candidate at '$($child.FullName)'. Refusing unmanaged migration; fail closed."
            }
        }

        $existingFiles = @($allChildren | Where-Object { -not $_.PSIsContainer })
        if ($existingFiles.Count -eq 0) {
            if ((Split-Path -Leaf $fullCandidate) -eq 'context7') {
                Remove-Item -LiteralPath $fullCandidate -Force
            }
            continue
        }

        $isUnmanaged = $false
        foreach ($file in $existingFiles) {
            $normalized = [IO.Path]::GetFullPath($file.FullName)
            if (-not $script:PriorHashes.ContainsKey($normalized)) {
                $isUnmanaged = $true
                break
            }
        }

        if (-not $isUnmanaged) {
            continue
        }

        Write-Host ("Migrating unmanaged pre-existing Context7 skill at '{0}' (backing up to '{1}')." -f $fullCandidate, $script:BackupRoot)

        $candidateLeaf = Split-Path -Leaf $fullCandidate

        # For actual existing skill just SKILL.md allowed backup migration
        $unmanagedSkillMd = Join-Path $fullCandidate 'SKILL.md'
        if (Test-Path -LiteralPath $unmanagedSkillMd -PathType Leaf) {
            Backup-ExistingFile -Destination $unmanagedSkillMd -Category 'superseded_skill_backup'
        }

        # Canonical source map
        $canonicalRelatives = @{}
        if (Test-Path -LiteralPath $context7Source -PathType Container) {
            Get-ChildItem -LiteralPath $context7Source -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($context7Source.Length).TrimStart('\')
                $canonicalRelatives[$rel] = $_.FullName
            }
        }

        foreach ($file in $existingFiles) {
            $rel = $file.FullName.Substring($fullCandidate.Length).TrimStart('\')

            if ($rel -eq 'SKILL.md') {
                if ($candidateLeaf -eq 'context7') {
                    Remove-Item -LiteralPath $file.FullName -Force
                }
                continue
            }

            if ($canonicalRelatives.ContainsKey($rel)) {
                $canonicalFilePath = $canonicalRelatives[$rel]
                $canonicalHash = Get-RequiredFileHash -Path $canonicalFilePath
                $fileHash = Get-RequiredFileHash -Path $file.FullName
                if ($fileHash -ne $canonicalHash) {
                    throw "Ambiguous custom conflict detected at '$($file.FullName)': file differs from canonical '$rel'. Fail closed."
                }
                if ($candidateLeaf -eq 'context7') {
                    Remove-Item -LiteralPath $file.FullName -Force
                }
            }
            else {
                # Preserve extra custom files via recoverable quarantined directory outside skill discovery
                Quarantine-ExtraFile -SourcePath $file.FullName -BaseDir $fullCandidate
            }
        }

        # Clean up empty subdirectories bottom-up (no recursive removal)
        $subDirs = @(Get-ChildItem -LiteralPath $fullCandidate -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        foreach ($d in $subDirs) {
            $remaining = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $d.FullName -Force
            }
        }

        if ($candidateLeaf -eq 'context7') {
            $remainingInCand = @(Get-ChildItem -LiteralPath $fullCandidate -Force -ErrorAction SilentlyContinue)
            if ($remainingInCand.Count -eq 0) {
                Remove-Item -LiteralPath $fullCandidate -Force
            }
            else {
                throw "Cannot remove unmanaged context7 directory '$fullCandidate': unresolved items remain. Fail closed."
            }
        }
    }
}

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return Join-Path $startup 'Codex Prompt Pad.lnk'
}

function Get-ExistingShortcutTarget {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        return [string]$shell.CreateShortcut($Path).TargetPath
    }
    catch {
        return $null
    }
}

function Resolve-AutoHotkeyExecutable {
    param([string]$ExistingTarget)

    if (-not [string]::IsNullOrWhiteSpace($ExistingTarget) -and (Test-Path -LiteralPath $ExistingTarget -PathType Leaf)) {
        return [IO.Path]::GetFullPath($ExistingTarget)
    }

    foreach ($name in @('AutoHotkey64.exe', 'AutoHotkey.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source) -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return [IO.Path]::GetFullPath($command.Source)
        }
    }

    return $null
}

function Install-StartupShortcut {
    param([Parameter(Mandatory)][string]$AhkPath)

    $shortcutPath = Get-StartupShortcutPath
    $existingTarget = Get-ExistingShortcutTarget -Path $shortcutPath
    $ahkExecutable = Resolve-AutoHotkeyExecutable -ExistingTarget $existingTarget
    if ([string]::IsNullOrWhiteSpace($ahkExecutable)) {
        Write-Warning "AutoHotkey executable was not found; skipping the Startup shortcut: $shortcutPath"
        return
    }

    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        Backup-ExistingFile -Destination $shortcutPath
    }

    if (-not (Confirm-InstallAction -Target $shortcutPath -Action 'install Startup shortcut')) {
        return
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $ahkExecutable
    $shortcut.Arguments = '"' + $AhkPath + '"'
    $shortcut.WorkingDirectory = Split-Path -Parent $AhkPath
    $shortcut.Description = 'Codex Workflows Kit Prompt Pad'
    $shortcut.Save()

    $script:ManagedFiles[$shortcutPath] = $null
}

function Install-GlobalAgentsFile {
    $raw = Get-Content -LiteralPath $agentsMdSource -Raw -Encoding UTF8
    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $existing = if (Test-Path -LiteralPath $agentsMdDest -PathType Leaf) {
        Get-Content -LiteralPath $agentsMdDest -Raw -Encoding UTF8
    }
    else {
        ''
    }

    if ($existing.IndexOf($begin, [StringComparison]::Ordinal) -lt 0 -and -not [string]::IsNullOrWhiteSpace($existing) -and -not $Force) {
        throw "An unmanaged AGENTS.md already exists. Review it and use -Force to replace it: $agentsMdDest"
    }

    $content = Set-CodexAgentsManagedBlockText -ExistingAgentsText $existing -TemplateText $raw -Backend $script:SelectedBackend -Policy $script:SelectedPolicy -Strategy $script:SelectedStrategy -Continuation $script:SelectedContinuation

    Install-ManagedContent -Destination $agentsMdDest -Content $content
}

function Install-GlobalGeminiFile {
    if (-not (Test-Path -LiteralPath $geminiMdSource -PathType Leaf)) {
        return
    }
    $raw = Get-Content -LiteralPath $geminiMdSource -Raw -Encoding UTF8
    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $end = '# END CODEX-WORKFLOWS-KIT'
    $managed = $begin + $nl + $raw.Trim() + $nl + $end + $nl
    $existing = if (Test-Path -LiteralPath $geminiMdDest -PathType Leaf) {
        Get-Content -LiteralPath $geminiMdDest -Raw -Encoding UTF8
    }
    else {
        ''
    }

    if ($existing.IndexOf($begin, [StringComparison]::Ordinal) -ge 0) {
        $start = $existing.IndexOf($begin, [StringComparison]::Ordinal)
        $endStart = $existing.IndexOf($end, $start, [StringComparison]::Ordinal)
        if ($endStart -lt 0) {
            throw "Managed GEMINI.md block is incomplete: $geminiMdDest"
        }
        $head = $existing.Substring(0, $start)
        $tail = $existing.Substring($endStart + $end.Length).TrimStart([char[]]@([char]13, [char]10))
        $content = $head + $managed + $tail
    }
    elseif (-not [string]::IsNullOrWhiteSpace($existing)) {
        $tail = $existing.TrimStart([char[]]@([char]13, [char]10))
        $content = $managed + $tail
    }
    else {
        $content = $managed
    }

    Install-ManagedContent -Destination $geminiMdDest -Content $content
}

function Remove-KitBlocks {
    param([AllowEmptyString()][string]$Text)

    $range = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT:.*?^# END CODEX-WORKFLOWS-KIT:.*?(?:\r?\n|$)'
    $result = [regex]::Replace($Text, $range, '')
    return [regex]::Replace($result, '(?m)^# (?:BEGIN|END) CODEX-WORKFLOWS-KIT:.*(?:\r?\n|$)', '').Trim()
}

function Test-TomlTableHeader {
    param([AllowEmptyString()][string]$Line)

    return ($Line -replace '\r\n?', '') -match '^[ \t]*\[\[?[^\r\n\]]*\]\]?[ \t]*(?:#.*)?$'
}

function Get-FeaturesTableInfo {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text = $Text -replace '\r\n', "`n"
    $lines = [System.Collections.Generic.List[string]]([regex]::Split($Text, '\r?\n'))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^[ \t]*\[features\][ \t]*(?:#.*)?$') {
            continue
        }

        $end = $lines.Count
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if (Test-TomlTableHeader -Line $lines[$j]) {
                $end = $j
                break
            }
        }

        $multiAgentLine = -1
        $multiAgentValue = ''
        for ($j = $i + 1; $j -lt $end; $j++) {
            $keyMatch = [regex]::Match($lines[$j], '^\s*multi_agent\s*=')
            if (-not $keyMatch.Success) {
                continue
            }
            $multiAgentLine = $j
            $valueMatch = [regex]::Match($lines[$j], '^\s*multi_agent\s*=\s*([^\s#]+)')
            if ($valueMatch.Success) {
                $multiAgentValue = $valueMatch.Groups[1].Value
            }
            break
        }

        return [pscustomobject]@{
            Index = $i
            EndIndex = $end
            MultiAgentLine = $multiAgentLine
            MultiAgentValue = $multiAgentValue
        }
    }

    return [pscustomobject]@{
        Index = -1
        EndIndex = -1
        MultiAgentLine = -1
        MultiAgentValue = ''
    }
}

function Set-FeaturesMultiAgentGate {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $script:FeaturesGateApplied = $true
    $info = Get-FeaturesTableInfo -Text $Text
    if ($info.Index -lt 0) {
        $script:FeaturesPrior = [ordered]@{ present = $false; value = $null }
        $block = $nl + '# BEGIN CODEX-WORKFLOWS-KIT: features' + $nl +
            '[features]' + $nl +
            'multi_agent = false' + $nl +
            '# END CODEX-WORKFLOWS-KIT: features'
        return ($Text.TrimEnd() + $nl + $block + $nl)
    }

    $lines = [System.Collections.Generic.List[string]]([regex]::Split($Text, '\r?\n'))
    if ($info.MultiAgentLine -lt 0) {
        $script:FeaturesPrior = [ordered]@{ present = $false; value = $null }
        $lines.Insert($info.Index + 1, 'multi_agent = false')
    }
    elseif ($info.MultiAgentValue -ceq 'false') {
        $script:FeaturesPrior = [ordered]@{ present = $true; value = 'false' }
        return $Text
    }
    else {
        $script:FeaturesPrior = [ordered]@{ present = $true; value = $info.MultiAgentValue }
        $line = $lines[$info.MultiAgentLine]
        $match = [regex]::Match($line, '^(\s*)multi_agent\s*=\s*[^\s#]+')
        $lines[$info.MultiAgentLine] = $match.Groups[1].Value + 'multi_agent = false' + $line.Substring($match.Index + $match.Length)
    }

    return (($lines -join $nl).TrimEnd() + $nl)
}

function Restore-MultiAgentFeature {
    param([Parameter(Mandatory)][bool]$AllowWrite)

    if ($null -eq $script:PriorFeaturesRecord -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $info = Get-FeaturesTableInfo -Text $existing
    if ($info.Index -lt 0 -or $info.MultiAgentLine -lt 0) {
        return
    }

    $record = $script:PriorFeaturesRecord.multi_agent
    $priorPresent = [bool]$record.present
    $priorValue = if ($record.PSObject.Properties.Name -contains 'value' -and $null -ne $record.value) { [string]$record.value } else { '' }

    if ($info.MultiAgentValue -cne 'false') {
        if (-not ($priorPresent -and $priorValue -ceq $info.MultiAgentValue)) {
            Write-Warning "multi_agent is '$($info.MultiAgentValue)'; leaving it as-is: $configPath"
        }
        return
    }
    if ($priorPresent -and $priorValue -ceq 'false') {
        return
    }
    if (-not $AllowWrite) {
        Write-Warning "config.toml was modified; leaving multi_agent as-is: $configPath"
        return
    }

    $lines = [System.Collections.Generic.List[string]]([regex]::Split($existing, '\r?\n'))
    if ($priorPresent) {
        $line = $lines[$info.MultiAgentLine]
        $match = [regex]::Match($line, '^(\s*)multi_agent\s*=\s*[^\s#]+')
        $lines[$info.MultiAgentLine] = $match.Groups[1].Value + 'multi_agent = ' + $priorValue + $line.Substring($match.Index + $match.Length)
    }
    else {
        $lines.RemoveAt($info.MultiAgentLine)
    }

    if (Confirm-InstallAction -Target $configPath -Action 'restore prior multi_agent feature value') {
        Write-Utf8NoBom -Path $configPath -Content (($lines -join $nl).TrimEnd() + $nl)
    }
}

function Install-SafeConfig {
    $existing = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    }
    else {
        ''
    }

    $content = Remove-KitBlocks -Text $existing
    if ($null -ne $script:PriorBackendState) {
        $content = Set-CodexBackendConfigText -Text $content -Backend ([string]$script:PriorBackendState.selected) -BackendState $script:PriorBackendState
        $script:FeaturesGateApplied = $true
    }
    else {
        $content = Set-FeaturesMultiAgentGate -Text $content
    }

    Install-ManagedContent -Destination $configPath -Content ($content.Trim() + $nl)
}

function Test-CanRemoveManagedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Action
    )

    if ($Force) {
        return $true
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $script:PriorHashes.ContainsKey($fullPath)) {
        Write-Warning "Preserving $Action without a recorded hash: $fullPath"
        Add-PendingFile -Path $fullPath -Reason 'unverified'
        return $false
    }

    $actualHash = Get-RequiredFileHash -Path $fullPath
    $expectedHash = $script:PriorHashes[$fullPath]
    if ($actualHash -ne $expectedHash) {
        Write-Warning "Preserving modified ${Action}: $fullPath"
        Add-PendingFile -Path $fullPath -Reason 'modified' -ExpectedHash $expectedHash
        return $false
    }

    return $true
}

function Remove-ManagedConfigBlocks {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $content = Remove-KitBlocks -Text $existing
    if ($content -cne $existing.Trim()) {
        if (-not (Test-CanRemoveManagedFile -Path $configPath -Action 'managed configuration')) {
            return
        }
        Backup-ExistingFile -Destination $configPath
        if (Confirm-InstallAction -Target $configPath -Action 'remove managed configuration block') {
            Write-Utf8NoBom -Path $configPath -Content ($content + $nl)
            $script:ConfigModified = $true
        }
    }
}

function Remove-ManagedAgentsBlock {
    if (-not (Test-Path -LiteralPath $agentsMdDest -PathType Leaf)) {
        return
    }

    $content = Get-Content -LiteralPath $agentsMdDest -Raw -Encoding UTF8
    $blockRegex = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT\s*\r?\n.*?^# END CODEX-WORKFLOWS-KIT\s*(?:\r?\n|$)'
    $match = [regex]::Match($content, $blockRegex)
    if (-not $match.Success) {
        if ($content.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT', [StringComparison]::Ordinal) -ge 0) {
            throw "Managed AGENTS.md block is incomplete: $agentsMdDest"
        }
        return
    }

    if (-not (Test-CanRemoveManagedFile -Path $agentsMdDest -Action 'managed AGENTS.md block')) {
        return
    }

    $result = ($content.Substring(0, $match.Index) + $content.Substring($match.Index + $match.Length)).Trim()
    if (Confirm-InstallAction -Target $agentsMdDest -Action 'remove managed AGENTS.md block') {
        Backup-ExistingFile -Destination $agentsMdDest
        if ([string]::IsNullOrWhiteSpace($result)) {
            Remove-Item -LiteralPath $agentsMdDest -Force
            $script:RemovedParents.Add((Split-Path -Parent $agentsMdDest))
        }
        else {
            Write-Utf8NoBom -Path $agentsMdDest -Content ($result + $nl)
        }
    }
}

function Remove-ManagedGeminiBlock {
    if (-not (Test-Path -LiteralPath $geminiMdDest -PathType Leaf)) {
        return
    }

    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $end = '# END CODEX-WORKFLOWS-KIT'
    $content = Get-Content -LiteralPath $geminiMdDest -Raw -Encoding UTF8
    $start = $content.IndexOf($begin, [StringComparison]::Ordinal)
    if ($start -lt 0) {
        return
    }

    $endStart = $content.IndexOf($end, $start, [StringComparison]::Ordinal)
    if ($endStart -lt 0) {
        throw "Managed GEMINI.md block is incomplete: $geminiMdDest"
    }

    if (-not (Test-CanRemoveManagedFile -Path $geminiMdDest -Action 'managed GEMINI.md block')) {
        return
    }

    $result = ($content.Substring(0, $start) + $content.Substring($endStart + $end.Length)).Trim()
    if (Confirm-InstallAction -Target $geminiMdDest -Action 'remove managed GEMINI.md block') {
        Backup-ExistingFile -Destination $geminiMdDest
        if ([string]::IsNullOrWhiteSpace($result)) {
            Remove-Item -LiteralPath $geminiMdDest -Force
            $script:RemovedParents.Add((Split-Path -Parent $geminiMdDest))
        }
        else {
            Write-Utf8NoBom -Path $geminiMdDest -Content ($result + $nl)
        }
    }
}

function Remove-ObsoleteManagedFiles {
    foreach ($priorPath in $script:PriorPaths) {
        if ($priorPath -eq $statePath -or $priorPath -eq $configPath -or $priorPath -eq $agentsMdDest -or $priorPath -eq $geminiMdDest) {
            continue
        }
        if ($script:ManagedFiles.ContainsKey($priorPath)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $priorPath -PathType Leaf)) {
            continue
        }

        $expectedHash = $script:PriorHashes[$priorPath]
        $actualHash = Get-RequiredFileHash -Path $priorPath
        if ($actualHash -ne $expectedHash) {
            Write-Warning "Preserving modified file no longer managed by this profile: $priorPath"
            Add-PendingFile -Path $priorPath -Reason 'modified' -ExpectedHash $expectedHash
            continue
        }

        $isCodexPath = $priorPath.StartsWith($CodexHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        $isAgentsPath = $priorPath.StartsWith($AgentsHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        $isAntigravityPath = $priorPath.StartsWith($AntigravityHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not ($isCodexPath -or $isAgentsPath -or $isAntigravityPath)) {
            Write-Warning "Preserving obsolete managed file outside the selected destinations: $priorPath"
            Add-PendingFile -Path $priorPath -Reason 'outside-destinations' -ExpectedHash $expectedHash
            continue
        }

        $parent = if ($isCodexPath) { $CodexHome } elseif ($isAgentsPath) { $AgentsHome } else { $AntigravityHome }
        Assert-ChildPath -Path $priorPath -Parent $parent | Out-Null
        if (Confirm-InstallAction -Target $priorPath -Action 'remove obsolete managed file') {
            Remove-Item -LiteralPath $priorPath -Force
            $script:RemovedParents.Add((Split-Path -Parent $priorPath))
        }
    }

    foreach ($parent in ($script:RemovedParents | Sort-Object -Unique)) {
        $current = $parent
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $isCodexRoot = $current.TrimEnd('\') -eq $CodexHome.TrimEnd('\')
            $isAgentsRoot = $current.TrimEnd('\') -eq $AgentsHome.TrimEnd('\')
            $isAntigravityRoot = $current.TrimEnd('\') -eq $AntigravityHome.TrimEnd('\')
            if ($isCodexRoot -or $isAgentsRoot -or $isAntigravityRoot -or -not (Test-Path -LiteralPath $current -PathType Container)) {
                break
            }

            $children = @(Get-ChildItem -LiteralPath $current -Force)
            if ($children.Count -ne 0) {
                break
            }

            $isCodexPath = $current.StartsWith($CodexHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
            $isAgentsPath = $current.StartsWith($AgentsHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
            $parentRoot = if ($isCodexPath) { $CodexHome } elseif ($isAgentsPath) { $AgentsHome } else { $AntigravityHome }
            Assert-ChildPath -Path $current -Parent $parentRoot | Out-Null
            if (Confirm-InstallAction -Target $current -Action 'remove empty managed directory') {
                Remove-Item -LiteralPath $current -Force
            }
            $current = Split-Path -Parent $current
        }
    }
}

function Save-InstallState {
    $managedEntries = @{}
    foreach ($path in ($script:ManagedFiles.Keys | Sort-Object)) {
        if ($path -eq $statePath -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $managedEntries[$path] = [ordered]@{
            path = $path
            sha256 = Get-RequiredFileHash -Path $path
        }
    }

    $entries = @(
        foreach ($path in ($managedEntries.Keys | Sort-Object)) {
            $managedEntries[$path]
        }
    )
    $pendingEntries = @(
        foreach ($path in ($script:PendingFiles.Keys | Sort-Object)) {
            if ($managedEntries.ContainsKey($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                continue
            }
            $script:PendingFiles[$path]
        }
    )

    if (-not $script:FeaturesGateApplied) {
        $existing = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        }
        else {
            ''
        }
        $info = Get-FeaturesTableInfo -Text $existing
        $script:FeaturesPrior = [ordered]@{
            present = $info.MultiAgentLine -ge 0
            value = if ($info.MultiAgentLine -ge 0) { $info.MultiAgentValue } else { $null }
        }
    }

    $featuresPrior = if ($null -ne $script:PriorFeaturesRecord) {
        $script:PriorFeaturesRecord
    }
    elseif ($null -ne $script:PriorBackendState) {
        $multiPrior = Get-BackendPriorRecord -BackendState $script:PriorBackendState -Path 'features.multi_agent'
        [ordered]@{
            multi_agent = [ordered]@{
                present = [bool]$multiPrior.present
                value = if ([bool]$multiPrior.present) { [string]$multiPrior.value } else { $null }
            }
        }
    }
    else {
        [ordered]@{
            multi_agent = [ordered]@{
                present = [bool]$script:FeaturesPrior.present
                value = $script:FeaturesPrior.value
            }
        }
    }

    $backendState = $script:PriorBackendState
    $delegationState = $script:PriorDelegationState
    $strategyState = $script:PriorStrategyState
    $continuationState = $script:PriorContinuationState

    $state = [ordered]@{
        schemaVersion = 5
        product = 'codex-workflows-kit'
        profile = $Profile
        installedAtUtc = [datetime]::UtcNow.ToString('o')
        files = $entries
        pendingFiles = $pendingEntries
        codexFeaturesPrior = $featuresPrior
        codexBackend = $backendState
        codexDelegation = $delegationState
        codexStrategy = $strategyState
        codexContinuation = $continuationState
    }

    Install-ManagedContent -Destination $statePath -Content (($state | ConvertTo-Json -Depth 8) + $nl)
}

function Assert-InstallPreflight {
    if (-not (Test-Path -LiteralPath $workflowSource -PathType Container)) {
        throw "Canonical workflow skill is missing: $workflowSource"
    }
    if (-not (Test-Path -LiteralPath $evidenceSource -PathType Container)) {
        throw "Evidence skill is missing: $evidenceSource"
    }
    if (-not (Test-Path -LiteralPath $mcpSource -PathType Container)) {
        throw "Canonical mcp-foundation skill is missing: $mcpSource"
    }
    if (-not (Test-Path -LiteralPath $codebaseMemorySource -PathType Container)) {
        throw "Canonical codebase-memory-mcp skill is missing: $codebaseMemorySource"
    }
    $cbmSkill = Join-Path $codebaseMemorySource 'SKILL.md'
    if (-not (Test-Path -LiteralPath $cbmSkill -PathType Leaf)) {
        throw "Canonical codebase-memory-mcp SKILL.md is missing: $cbmSkill"
    }

    if (-not (Test-Path -LiteralPath $context7Source -PathType Container)) {
        throw "Canonical context7-mcp skill is missing: $context7Source"
    }
    $ctxSkill = Join-Path $context7Source 'SKILL.md'
    if (-not (Test-Path -LiteralPath $ctxSkill -PathType Leaf)) {
        throw "Canonical context7-mcp SKILL.md is missing: $ctxSkill"
    }
    if ($InstallAhk -and -not (Test-Path -LiteralPath $ahkSource -PathType Leaf)) {
        throw "Prompt pad source is missing: $ahkSource"
    }

    if ($Profile -ne 'safe') {
        return
    }

    if (Test-Path -LiteralPath $agentsMdDest -PathType Leaf) {
        $existing = Get-Content -LiteralPath $agentsMdDest -Raw -Encoding UTF8
        $blockRegex = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT\s*\r?\n.*?^# END CODEX-WORKFLOWS-KIT\s*(?:\r?\n|$)'
        $hasBegin = $existing.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT', [StringComparison]::Ordinal) -ge 0
        if ($hasBegin -and -not [regex]::IsMatch($existing, $blockRegex)) {
            throw "Managed AGENTS.md block is incomplete: $agentsMdDest"
        }
        if (-not $hasBegin -and -not [string]::IsNullOrWhiteSpace($existing) -and -not $Force) {
            throw "An unmanaged AGENTS.md already exists. Review it and use -Force to replace it: $agentsMdDest"
        }
    }

    if (Test-Path -LiteralPath $geminiMdDest -PathType Leaf) {
        $existing = Get-Content -LiteralPath $geminiMdDest -Raw -Encoding UTF8
        $blockRegex = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT\s*\r?\n.*?^# END CODEX-WORKFLOWS-KIT\s*(?:\r?\n|$)'
        $hasBegin = $existing.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT', [StringComparison]::Ordinal) -ge 0
        if ($hasBegin -and -not [regex]::IsMatch($existing, $blockRegex)) {
            throw "Managed GEMINI.md block is incomplete: $geminiMdDest"
        }
    }
}

$installationSucceeded = $false
try {
    Assert-InstallPreflight
    Initialize-PriorState

    $skillTargets = @(
        $skillsDest,
        $antigravitySkillsDest1,
        $antigravitySkillsDest2
    )

    foreach ($target in $skillTargets) {
        Ensure-Directory -Path $target
        Copy-ManagedTree -Source $workflowSource -Destination (Join-Path $target 'workflows')
        Copy-ManagedTree -Source $evidenceSource -Destination (Join-Path $target 'evidence-first')
        Copy-ManagedTree -Source $mcpSource -Destination (Join-Path $target 'mcp-foundation')

        Copy-ManagedTree -Source $codebaseMemorySource -Destination (Join-Path $target 'codebase-memory-mcp')
        Migrate-UnmanagedContext7Skill -TargetDirectory $target
        Copy-ManagedTree -Source $context7Source -Destination (Join-Path $target 'context7-mcp')
    }

    if ($Profile -eq 'safe') {
        Install-GlobalAgentsFile
        Install-GlobalGeminiFile

        Install-SafeConfig
    }
    else {
        Remove-ManagedConfigBlocks
        Remove-ManagedAgentsBlock
        Remove-ManagedGeminiBlock
        if ($null -ne $script:PriorFeaturesRecord) {
            $allowWrite = $script:ConfigModified
            if (-not $allowWrite) {
                $allowWrite = Test-CanRemoveManagedFile -Path $configPath -Action 'managed configuration'
            }
            Restore-MultiAgentFeature -AllowWrite $allowWrite
        }
    }

    if ($InstallAhk) {
        Install-ManagedContent -Destination $AhkDestination -Content (Get-Content -LiteralPath $ahkSource -Raw -Encoding UTF8)
        Install-StartupShortcut -AhkPath $AhkDestination
    }

    Remove-ObsoleteManagedFiles
    $installationSucceeded = $true
}
finally {
    if (-not $WhatIfPreference -and $script:ManagedFiles.Count -gt 0) {
        try {
            Save-InstallState
        }
        catch {
            if ($installationSucceeded) {
                throw
            }
            Write-Warning "Installation failed before its partial state could be saved: $($_.Exception.Message)"
        }
    }
}

if ($WhatIfPreference) {
    Write-Host "What-if complete for Codex Workflows Kit profile '$Profile'."
}
else {
    Write-Host "Installed Codex Workflows Kit profile '$Profile'."
}
Write-Host "Codex home: $CodexHome"
Write-Host "Agents home: $AgentsHome"
Write-Host "Antigravity home: $AntigravityHome"
Write-Host "Skills: $skillsDest"
if ($Profile -eq 'safe' -and -not $WhatIfPreference) {
    $backendLabel = if ($null -ne $script:PriorBackendState) { [string]$script:PriorBackendState.selected } else { $script:SelectedBackend }
    $policyLabel = if ($null -ne $script:PriorDelegationState) { [string]$script:PriorDelegationState.selected } else { $script:SelectedPolicy }
    Write-Host "Subagent backend: $backendLabel"
    Write-Host "Delegation policy: $policyLabel"
    $strategyLabel = if ($null -ne $script:PriorStrategyState) { [string]$script:PriorStrategyState.selected } else { $script:SelectedStrategy }
    Write-Host "Subagent strategy: $strategyLabel"
    $continuationLabel = if ($null -ne $script:PriorContinuationState) { [string]$script:PriorContinuationState.selected } else { $script:SelectedContinuation }
    Write-Host "Subagent continuation: $continuationLabel"
    Write-Host "Backend matrix: $backendLabel active in $configPath"
}
if ($InstallAhk) { Write-Host "AHK: $AhkDestination" }
if ($script:BackedUp.Count -gt 0 -or $script:BackupManifest.Count -gt 0) { Write-Host "Backups: $script:BackupRoot" }
