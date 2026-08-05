[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-UninstallAction {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Action)
    if ($WhatIfPreference) {
        Write-Host ("What if: Performing the operation '{0}' on target '{1}'." -f $Action, $Target)
        return $false
    }
    return $true
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Resolve-HomePath {
    param([string]$Requested, [string]$Fallback)
    $value = if ([string]::IsNullOrWhiteSpace($Requested)) { $Fallback } else { $Requested }
    return [IO.Path]::GetFullPath($value)
}

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$CodexHome = Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome
$AgentsHome = Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "No Codex Workflows Kit install state was found: $statePath"
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (
    -not ($state.PSObject.Properties.Name -contains 'schemaVersion') -or
    -not ($state.PSObject.Properties.Name -contains 'product') -or
    [int]$state.schemaVersion -ne 1 -or
    [string]$state.product -ne 'codex-workflows-kit'
) {
    throw "Install state is not a Codex Workflows Kit state file: $statePath"
}
$configPath = Join-Path $CodexHome 'config.toml'
$agentsMdPath = Join-Path $CodexHome 'AGENTS.md'
$beginConfig = '# BEGIN CODEX-WORKFLOWS-KIT: opencode_worker'
$endConfig = '# END CODEX-WORKFLOWS-KIT: opencode_worker'
$beginAgents = '# BEGIN CODEX-WORKFLOWS-KIT'
$endAgents = '# END CODEX-WORKFLOWS-KIT'
$script:Skipped = $false

function Remove-ManagedFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedHash)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash -and -not $Force) {
        $script:Skipped = $true
        Write-Warning "Skipping modified managed file; use -Force after review: $Path"
        return
    }

    if (Confirm-UninstallAction -Target $Path -Action 'Remove managed file') {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Remove-ManagedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Begin,
        [Parameter(Mandatory)][string]$End
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $start = $content.IndexOf($Begin, [StringComparison]::Ordinal)
    if ($start -lt 0) {
        return
    }
    $endStart = $content.IndexOf($End, $start, [StringComparison]::Ordinal)
    if ($endStart -lt 0) {
        throw "Managed block is incomplete in $Path"
    }

    $result = ($content.Substring(0, $start) + $content.Substring($endStart + $End.Length)).Trim()
    if (Confirm-UninstallAction -Target $Path -Action 'Remove managed configuration block') {
        if ([string]::IsNullOrWhiteSpace($result)) {
            Remove-Item -LiteralPath $Path -Force
        }
        else {
            Write-Utf8NoBom -Path $Path -Content ($result + "`r`n")
        }
    }
}

foreach ($file in @($state.files)) {
    $path = [string]$file.path
    if ($path -eq $configPath -or $path -eq $agentsMdPath -or $path -eq $statePath) {
        continue
    }
    Remove-ManagedFile -Path $path -ExpectedHash ([string]$file.sha256)
}

Remove-ManagedBlock -Path $configPath -Begin $beginConfig -End $endConfig
Remove-ManagedBlock -Path $agentsMdPath -Begin $beginAgents -End $endAgents

if (-not $script:Skipped -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    if (Confirm-UninstallAction -Target $statePath -Action 'Remove install state') {
        Remove-Item -LiteralPath $statePath -Force
    }
}
elseif ($script:Skipped) {
    Write-Warning "Install state preserved because one or more modified managed files were skipped. Review them, then rerun uninstall with -Force."
}

$stateDirectory = Split-Path -Parent $statePath
if (Test-Path -LiteralPath $stateDirectory -PathType Container) {
    $remaining = @(Get-ChildItem -LiteralPath $stateDirectory -Force)
    if ($remaining.Count -eq 0 -and (Confirm-UninstallAction -Target $stateDirectory -Action 'Remove empty managed state directory')) {
        Remove-Item -LiteralPath $stateDirectory -Force
    }
}

Write-Host 'Codex Workflows Kit managed files removed where their contents were unchanged.'
Write-Host 'MCP registrations, scheduled tasks, backups, external packages, and maintenance logs/state are preserved.'
Write-Host 'If a scheduled task remains, it may reference the removed maintenance script; review docs/security.md before removing or repairing it.'
