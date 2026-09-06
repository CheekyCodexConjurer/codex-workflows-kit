<#
.SYNOPSIS
    Migrates legacy conflicting rules from the unmanaged footer of GEMINI.md
    while strictly preserving all personal instructions, tone persona, compact syntax,
    global rules, evidence & uncertainty rules, non-conflicting subagent principles,
    and arbitrary user customizations.

.DESCRIPTION
    The unmanaged footer of GEMINI.md previously preserved 3 proven conflicts:
    1. Native subagents / custom roles (5.6 Sol Medium, scout/reviewer/researcher role restrictions,
       omitting model/fork_context/reasoning_effort), which conflict with the managed subagent_backend
       routing (DeepSeek via SubAgents MCP or native gpt-5.6-luna max reasoning) and Adaptive Swarm.
    2. Delivery review veto (forbidding independent reviewers before all phases are frozen, and
       forbidding reviewers per phase), which directly contradicts the managed rule:
       "revisor final integrado e único não proíbe o estilhaçamento intermediário independente útil".
    3. Unmanaged MCP repair and divergent baseline (maintain-mcps.ps1 -Mode Repair and openaiDeveloperDocs),
       which contradicts the read-only doctor contract and the managed free MCP set (Context7, CBM, Serena, CodeGraph).

    This migration:
    - Analyzes the file and detects only the 3 proven conflicts.
    - Creates a timestamped backup before modifying the file.
    - Idempotent: safe to run repeatedly; no-op if no conflicts are detected.
    - Narrow and explicit: never removes the entire footer or unrelated rules.
    - Supports -WhatIf / -DryRun to preview changes without modifying the file.
    - Supports -Path / -GeminiPath to target a specific file (e.g. for test fixtures).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [Alias('Path', 'FilePath')]
    [string]$GeminiPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$BackupDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backendRoutingModule = Join-Path $PSScriptRoot 'backend-routing.psm1'
if (Test-Path -LiteralPath $backendRoutingModule -PathType Leaf) {
    Import-Module $backendRoutingModule -Force
}

# Resolve target file path
$targetPath = if ([string]::IsNullOrWhiteSpace($GeminiPath)) {
    Join-Path $env:USERPROFILE '.gemini\config\GEMINI.md'
} else {
    [IO.Path]::GetFullPath($GeminiPath)
}

if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Target GEMINI.md file does not exist: $targetPath"
}

$raw = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "Target GEMINI.md file is empty: $targetPath"
    return
}

# Validate managed block markers
$blockInfo = Get-GeminiManagedBlockInfo -Content $raw
if (-not $blockInfo.HasValidMarkers) {
    throw "Target file does not contain valid CODEX-WORKFLOWS-KIT markers ('# BEGIN CODEX-WORKFLOWS-KIT' and '# END CODEX-WORKFLOWS-KIT'). Cannot safely migrate unmanaged footer without valid markers: $targetPath"
}

$head = $blockInfo.Head
$managed = $blockInfo.Managed
$tail = $blockInfo.Tail

$conflicts = @(Get-GeminiLegacyConflicts -Text $tail)
if ($conflicts.Count -eq 0) {
    Write-Host "No conflicting unmanaged rules detected in $targetPath. Nothing to migrate."
    return
}

Write-Host "Detected $($conflicts.Count) legacy conflicting rule(s) in unmanaged footer of $($targetPath):"
foreach ($c in $conflicts) {
    Write-Host "  - $c" -ForegroundColor Yellow
}

if ($DryRun) {
    Write-Host "DryRun: migration preview completed without modifications."
    return
}

if (-not $PSCmdlet.ShouldProcess($targetPath, "Migrate legacy conflicting unmanaged rules")) {
    return
}

# Create timestamped backup with collision avoidance and byte/BOM preservation
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$destDir = if ([string]::IsNullOrWhiteSpace($BackupDir)) { Split-Path -Parent $targetPath } else { [IO.Path]::GetFullPath($BackupDir) }
if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$leafName = Split-Path -Leaf $targetPath
$candidateBackup = Join-Path $destDir "$leafName.bak.$timestamp"
if (Test-Path -LiteralPath $candidateBackup) {
    $counter = 1
    while (Test-Path -LiteralPath "$candidateBackup.$counter") {
        $counter++
    }
    $candidateBackup = "$candidateBackup.$counter"
}
$backupFile = $candidateBackup

Copy-Item -LiteralPath $targetPath -Destination $backupFile
Write-Host "Created backup: $backupFile" -ForegroundColor Cyan

# Perform narrow removal
$cleanedTail = Remove-GeminiLegacyConflicts -Text $tail
$newContent = $head + $managed + $cleanedTail

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($targetPath, $newContent, $utf8NoBom)
Write-Host "Successfully migrated $($targetPath): removed $($conflicts.Count) conflicting rule(s); preserved all non-conflicting rules." -ForegroundColor Green
