[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

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
        $script:Warnings.Add("${Name}: $Detail")
        Write-Host ("[WARN] {0}: {1}" -f $Name, $Detail) -ForegroundColor Yellow
    }
    else {
        $script:Failures.Add("${Name}: $Detail")
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Host "Codex Workflows Kit doctor`nCodex home: $CodexHome`nAgents home: $AgentsHome"
Write-Check -Name 'Install state' -Passed (Test-Path -LiteralPath $statePath -PathType Leaf) -Detail $statePath

$installedProfile = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $installedProfile = [string]((Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json).profile)
    }
    catch {
        $installedProfile = $null
    }
}

$coreFiles = @(
    (Join-Path $AgentsHome 'skills\workflows\SKILL.md'),
    (Join-Path $AgentsHome 'skills\evidence-first\SKILL.md')
)
if ($installedProfile -ne 'minimal') {
    $coreFiles += (Join-Path $CodexHome 'AGENTS.md')
    $coreFiles += (Join-Path $CodexHome 'agents\relay.toml')
}
foreach ($path in $coreFiles) {
    Write-Check -Name 'Core artifact' -Passed (Test-Path -LiteralPath $path -PathType Leaf) -Detail $path
}

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($file in @($state.files)) {
            $path = [string]$file.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Check -Name 'Managed artifact' -Passed $false -Detail "Missing: $path"
                continue
            }
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $matches = $actual -eq [string]$file.sha256
            Write-Check -Name 'Managed artifact' -Passed $matches -Detail $path
        }
    }
    catch {
        Write-Check -Name 'Install state' -Passed $false -Detail $_.Exception.Message
    }
}

Write-Check -Name 'Git' -Passed (Test-Command -Name 'git') -Detail 'Required for worktrees and repository operations'
Write-Check -Name 'PowerShell' -Passed ($PSVersionTable.PSVersion.Major -ge 5) -Detail $PSVersionTable.PSVersion
Write-Check -Name 'Codex CLI' -Passed (Test-Command -Name 'codex') -Detail 'Optional for MCP foundation repair' -Optional
Write-Check -Name 'Node/npm' -Passed (Test-Command -Name 'npx') -Detail 'Required by the OpenCode worker' -Optional
Write-Check -Name 'OpenCode CLI' -Passed (Test-Command -Name 'opencode') -Detail 'Required by the OpenCode worker' -Optional
Write-Check -Name 'AutoHotkey v2' -Passed (Test-Command -Name 'AutoHotkey64.exe') -Detail 'Required only for the prompt pad' -Optional
Write-Check -Name 'CodeGraph' -Passed (Test-Command -Name 'codegraph') -Detail 'Optional until MCP foundation repair' -Optional

$opencodeConfig = Join-Path $CodexHome 'config.toml'
$hasOpenCodeBlock = $false
if (Test-Path -LiteralPath $opencodeConfig -PathType Leaf) {
    $configText = Get-Content -LiteralPath $opencodeConfig -Raw -Encoding UTF8
    $hasOpenCodeBlock = $configText.Contains('# BEGIN CODEX-WORKFLOWS-KIT: opencode_worker')
}
Write-Check -Name 'OpenCode MCP config' -Passed $hasOpenCodeBlock -Detail $opencodeConfig -Optional

if ($Detailed) {
    Write-Host "`nInstalled paths are recorded in: $statePath"
    Write-Host 'The doctor does not change files, install packages, authenticate MCPs, or start tasks.'
}

if ($script:Failures.Count -gt 0) {
    exit 1
}

Write-Host "`nDoctor OK. Optional warnings: $($script:Warnings.Count)."
