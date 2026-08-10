[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [string]$AhkDestination,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$nl = [Environment]::NewLine

function Confirm-UninstallAction {
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
    param([string]$Requested, [Parameter(Mandatory)][string]$Fallback)

    $value = if ([string]::IsNullOrWhiteSpace($Requested)) { $Fallback } else { $Requested }
    return [IO.Path]::GetFullPath($value)
}

function Assert-SafeDestination {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\') -eq $root.TrimEnd('\')) {
        throw "Refusing to use a filesystem root as an uninstall destination: $fullPath"
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
        throw "Refusing to remove a path outside its declared destination: $fullPath"
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

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return Join-Path $startup 'Codex Prompt Pad.lnk'
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

function Assert-InstallState {
    param([Parameter(Mandatory)][object]$State)

    $required = @('schemaVersion', 'product', 'files')
    foreach ($property in $required) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) {
            throw "Install state is missing required property: $property"
        }
    }

    $schemaText = [string]$State.schemaVersion
    if ($schemaText -notin @('1', '2', '3', '4')) {
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

    if ($schema -eq 4) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or $null -eq $State.codexFeaturesPrior) {
            throw 'Schema 4 install state is missing codexFeaturesPrior.'
        }
        if (-not ($State.codexFeaturesPrior.PSObject.Properties.Name -contains 'multi_agent')) {
            throw 'Schema 4 install state is missing the multi_agent feature record.'
        }
        $featureRecord = $State.codexFeaturesPrior.multi_agent
        if ($null -eq $featureRecord -or -not ($featureRecord.PSObject.Properties.Name -contains 'present') -or -not ($featureRecord.PSObject.Properties.Name -contains 'value')) {
            throw 'Schema 4 install state contains an invalid multi_agent feature record.'
        }
        if ($featureRecord.present -notin @($true, $false)) {
            throw 'Schema 4 install state has an invalid multi_agent presence flag.'
        }
        if ([bool]$featureRecord.present -and $null -eq $featureRecord.value) {
            throw 'Schema 4 install state has a present multi_agent record without a value.'
        }
        if (-not [bool]$featureRecord.present -and $null -ne $featureRecord.value) {
            throw 'Schema 4 install state has an absent multi_agent record with a value.'
        }
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

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }

$CodexHome = Assert-SafeDestination (Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome)
$AgentsHome = Assert-SafeDestination (Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome)
if ([string]::IsNullOrWhiteSpace($AhkDestination)) {
    $AhkDestination = Join-Path $env:USERPROFILE 'Documents\Codex\PromptPad\codex_prompt_pad.ahk'
}
$AhkDestination = Assert-SafeDestination $AhkDestination
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$configPath = Join-Path $CodexHome 'config.toml'
$agentsMdPath = Join-Path $CodexHome 'AGENTS.md'
$StartupShortcutPath = Get-StartupShortcutPath
$script:Skipped = $false
$script:RemovedParents = New-Object System.Collections.Generic.List[string]
$script:BackedUp = @{}
$script:ConfigModified = $false
$script:BackupRoot = Join-Path $CodexHome ('backups\codex-workflows-kit\uninstall-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "No Codex Workflows Kit install state was found: $statePath"
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stateSchema = Assert-InstallState -State $state

$script:StateEntries = @{}
foreach ($file in @($state.files)) {
    $path = [IO.Path]::GetFullPath([string]$file.path)
    $script:StateEntries[$path] = [ordered]@{
        sha256 = [string]$file.sha256
        pending = $false
        reason = ''
    }
}
if ($stateSchema -ge 3) {
    foreach ($file in @($state.pendingFiles)) {
        $path = [IO.Path]::GetFullPath([string]$file.path)
        $script:StateEntries[$path] = [ordered]@{
            sha256 = [string]$file.sha256
            pending = $true
            reason = if ($file.PSObject.Properties.Name -contains 'reason') { [string]$file.reason } else { 'unverified' }
        }
    }
}

function Backup-ForcedFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $Force -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($script:BackedUp.ContainsKey($fullPath)) {
        return
    }

    $safeName = [regex]::Replace($fullPath, '[^A-Za-z0-9._-]', '_')
    $backupPath = Join-Path $script:BackupRoot $safeName
    if (Confirm-UninstallAction -Target $Path -Action "back up forced change to $backupPath") {
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        $script:BackedUp[$fullPath] = $backupPath
    }
}

function Test-CanRemoveRecordedFile {
    param([Parameter(Mandatory)][string]$Path)

    if ($Force) {
        return $true
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $script:StateEntries.ContainsKey($fullPath)) {
        $script:Skipped = $true
        Write-Warning "Skipping managed content without a recorded hash: $fullPath"
        return $false
    }

    $entry = $script:StateEntries[$fullPath]
    if ([bool]$entry.pending -and [string]$entry.reason -eq 'unverified') {
        $script:Skipped = $true
        Write-Warning "Skipping managed content that still needs review: $fullPath"
        return $false
    }

    $actualHash = Get-RequiredFileHash -Path $fullPath
    if ($actualHash -ne [string]$entry.sha256) {
        $script:Skipped = $true
        Write-Warning "Skipping modified managed file; use -Force after review: $fullPath"
        return $false
    }

    return $true
}

function Remove-ManagedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $isCodexPath = $Path.StartsWith($CodexHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    $isAgentsPath = $Path.StartsWith($AgentsHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    $isAhkPath = $Path -eq $AhkDestination
    $isStartupPath = $Path -eq $StartupShortcutPath
    if (-not ($isCodexPath -or $isAgentsPath -or $isAhkPath -or $isStartupPath)) {
        $script:Skipped = $true
        Write-Warning "Leaving state file outside the selected destinations untouched: $Path"
        return
    }

    if (-not (Test-CanRemoveRecordedFile -Path $Path)) {
        return
    }

    $entry = $script:StateEntries[[IO.Path]::GetFullPath($Path)]
    $needsForcedBackup = $Force -and (
        $null -eq $entry -or
        [bool]$entry.pending -or
        (Get-RequiredFileHash -Path $Path) -ne [string]$entry.sha256
    )

    $parentRoot = if ($isCodexPath) { $CodexHome } elseif ($isAgentsPath) { $AgentsHome } elseif ($isStartupPath) { Split-Path -Parent $StartupShortcutPath } else { Split-Path -Parent $AhkDestination }
    Assert-ChildPath -Path $Path -Parent $parentRoot | Out-Null
    if (Confirm-UninstallAction -Target $Path -Action 'remove managed file') {
        if ($needsForcedBackup) {
            Backup-ForcedFile -Path $Path
        }
        Remove-Item -LiteralPath $Path -Force
        if (-not $isAhkPath -and -not $isStartupPath) {
            $script:RemovedParents.Add((Split-Path -Parent $Path))
        }
    }
}

function Remove-KitBlocks {
    param([AllowEmptyString()][string]$Text)

    $range = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT:.*?^# END CODEX-WORKFLOWS-KIT:.*?(?:\r?\n|$)'
    $result = [regex]::Replace($Text, $range, '')
    return [regex]::Replace($result, '(?m)^# (?:BEGIN|END) CODEX-WORKFLOWS-KIT:.*(?:\r?\n|$)', '').Trim()
}

function Remove-ManagedAgentsBlock {
    if (-not (Test-Path -LiteralPath $agentsMdPath -PathType Leaf)) {
        return
    }

    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $end = '# END CODEX-WORKFLOWS-KIT'
    $content = Get-Content -LiteralPath $agentsMdPath -Raw -Encoding UTF8
    $start = $content.IndexOf($begin, [StringComparison]::Ordinal)
    if ($start -lt 0) {
        return
    }
    $endStart = $content.IndexOf($end, $start, [StringComparison]::Ordinal)
    if ($endStart -lt 0) {
        throw "Managed AGENTS.md block is incomplete: $agentsMdPath"
    }
    if (-not (Test-CanRemoveRecordedFile -Path $agentsMdPath)) {
        return
    }

    $result = ($content.Substring(0, $start) + $content.Substring($endStart + $end.Length)).Trim()
    if (Confirm-UninstallAction -Target $agentsMdPath -Action 'remove managed AGENTS.md block') {
        Backup-ForcedFile -Path $agentsMdPath
        if ([string]::IsNullOrWhiteSpace($result)) {
            Remove-Item -LiteralPath $agentsMdPath -Force
        }
        else {
            Write-Utf8NoBom -Path $agentsMdPath -Content ($result + $nl)
        }
    }
}

function Remove-ManagedConfigBlocks {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $result = Remove-KitBlocks -Text $content
    if ($result -cne $content.Trim()) {
        if (-not (Test-CanRemoveRecordedFile -Path $configPath)) {
            return
        }
        if (Confirm-UninstallAction -Target $configPath -Action 'remove managed configuration block') {
            Backup-ForcedFile -Path $configPath
            Write-Utf8NoBom -Path $configPath -Content ($result + $nl)
            $script:ConfigModified = $true
        }
    }
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

function Restore-MultiAgentFeature {
    param([Parameter(Mandatory)][bool]$AllowWrite)

    if ($stateSchema -lt 4 -or -not ($state.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $info = Get-FeaturesTableInfo -Text $existing
    if ($info.Index -lt 0 -or $info.MultiAgentLine -lt 0) {
        return
    }

    $record = $state.codexFeaturesPrior.multi_agent
    $priorPresent = [bool]$record.present
    $priorValue = if ($record.PSObject.Properties.Name -contains 'value' -and $null -ne $record.value) { [string]$record.value } else { '' }

    if ($info.MultiAgentValue -cne 'false') {
        if (-not ($priorPresent -and $priorValue -ceq $info.MultiAgentValue)) {
            Write-Warning "multi_agent is '$($info.MultiAgentValue)'; leaving it as-is. The safe profile expects false: $configPath"
            $script:Skipped = $true
        }
        return
    }
    if ($priorPresent -and $priorValue -ceq 'false') {
        return
    }
    if (-not $AllowWrite) {
        Write-Warning "config.toml was modified; leaving multi_agent as-is: $configPath"
        $script:Skipped = $true
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

    if (Confirm-UninstallAction -Target $configPath -Action 'restore prior multi_agent feature value') {
        if ($Force) {
            Backup-ForcedFile -Path $configPath
        }
        Write-Utf8NoBom -Path $configPath -Content (($lines -join $nl).TrimEnd() + $nl)
    }
}

foreach ($path in ($script:StateEntries.Keys | Sort-Object)) {
    if ($path -eq $statePath -or $path -eq $configPath -or $path -eq $agentsMdPath) {
        continue
    }
    Remove-ManagedFile -Path $path -ExpectedHash ([string]$script:StateEntries[$path].sha256)
}

Remove-ManagedConfigBlocks
Remove-ManagedAgentsBlock

if ($stateSchema -ge 4 -and ($state.PSObject.Properties.Name -contains 'codexFeaturesPrior')) {
    $fullConfigPath = [IO.Path]::GetFullPath($configPath)
    $isTracked = $script:StateEntries.ContainsKey($fullConfigPath)
    if ($isTracked -or $script:ConfigModified) {
        $allowWrite = $script:ConfigModified -or $Force
        if (-not $allowWrite) {
            $allowWrite = (Get-RequiredFileHash -Path $configPath) -eq [string]$script:StateEntries[$fullConfigPath].sha256
        }
        Restore-MultiAgentFeature -AllowWrite $allowWrite
    }
}

foreach ($parent in ($script:RemovedParents | Sort-Object -Unique)) {
    $current = $parent
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $isCodexRoot = $current.TrimEnd('\') -eq $CodexHome.TrimEnd('\')
        $isAgentsRoot = $current.TrimEnd('\') -eq $AgentsHome.TrimEnd('\')
        if ($isCodexRoot -or $isAgentsRoot -or -not (Test-Path -LiteralPath $current -PathType Container)) {
            break
        }

        if (@(Get-ChildItem -LiteralPath $current -Force).Count -ne 0) {
            break
        }

        $isCodexPath = $current.StartsWith($CodexHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        $parentRoot = if ($isCodexPath) { $CodexHome } else { $AgentsHome }
        Assert-ChildPath -Path $current -Parent $parentRoot | Out-Null
        if (Confirm-UninstallAction -Target $current -Action 'remove empty managed directory') {
            Remove-Item -LiteralPath $current -Force
        }
        $current = Split-Path -Parent $current
    }
}

if (-not $script:Skipped -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    if (Confirm-UninstallAction -Target $statePath -Action 'remove install state') {
        Remove-Item -LiteralPath $statePath -Force
    }
}
elseif ($script:Skipped) {
    Write-Warning 'Install state was preserved because one or more modified managed files were skipped.'
}

Write-Host 'Codex Workflows Kit managed files were removed where their contents were unchanged.'
