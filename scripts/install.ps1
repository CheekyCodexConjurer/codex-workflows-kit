[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('minimal', 'safe', 'full')]
    [string]$Profile = 'safe',

    [string]$CodexHome,

    [string]$AgentsHome,

    [string]$AntigravityHome,

    [string]$AhkDestination,

    [switch]$InstallAhk,

    [switch]$InstallAntigravity,

    [switch]$ConfigureMcp,

    [switch]$InstallScheduledTask,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-InstallAction {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Action)
    if ($WhatIfPreference) {
        Write-Host ("What if: Performing the operation '{0}' on target '{1}'." -f $Action, $Target)
        return $false
    }
    return $true
}

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))

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

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$defaultAntigravityHome = Join-Path $env:USERPROFILE '.gemini'
$CodexHome = Assert-SafeDestination (Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome)
$AgentsHome = Assert-SafeDestination (Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome)
$AntigravityHome = Assert-SafeDestination (Resolve-HomePath -Requested $AntigravityHome -Fallback $defaultAntigravityHome)
if ($CodexHome -ne [IO.Path]::GetFullPath($defaultCodexHome) -and $env:CODEX_HOME -ne $CodexHome) {
    Write-Warning 'A custom CodexHome was selected without matching CODEX_HOME; set CODEX_HOME for the SessionStart MCP hook to audit this same home.'
}

if ([string]::IsNullOrWhiteSpace($AhkDestination)) {
    $AhkDestination = Join-Path $env:USERPROFILE 'Documents\Codex\PromptPad\codex_prompt_pad.ahk'
}
$AhkDestination = Assert-SafeDestination $AhkDestination

if ($Profile -eq 'minimal' -and ($ConfigureMcp -or $InstallScheduledTask)) {
    throw 'The minimal profile cannot configure MCP maintenance. Use -Profile full.'
}

$includeAllSkills = $Profile -ne 'minimal'
$includeAgents = $Profile -ne 'minimal'
$includeOpenCode = $Profile -eq 'full' -or $ConfigureMcp
$includeMaintenance = $Profile -eq 'full' -or $ConfigureMcp
$installAntigravity = $InstallAntigravity -or $Profile -eq 'full'

$skillsSource = Join-Path $repo 'skills'
$workflowSource = Join-Path $skillsSource 'workflows'
$agentsSource = Join-Path $repo 'agents'
$opencodeAgentsSource = Join-Path $agentsSource 'opencode'
$agentsMdSource = Join-Path $repo 'codex\AGENTS.md'
$ahkSource = Join-Path $repo 'ahk\codex_prompt_pad.ahk'
$maintenanceSource = Join-Path $repo 'plugins\mcp-foundation\scripts\maintain-mcps.ps1'
$workerWrapperSource = Join-Path $repo 'bin\opencode-worker.cmd'

$skillsDest = Join-Path $AgentsHome 'skills'
$antigravitySkillsDest1 = Join-Path $AntigravityHome 'antigravity\skills'
$antigravitySkillsDest2 = Join-Path $AntigravityHome 'config\skills'
$agentsDest = Join-Path $CodexHome 'agents'
$opencodeAgentsDest = Join-Path $CodexHome 'opencode-agents'
$agentsMdDest = Join-Path $CodexHome 'AGENTS.md'
$maintenanceDest = Join-Path $CodexHome 'maintenance\maintain-mcps.ps1'
$workerWrapperDest = Join-Path $CodexHome 'bin\opencode-worker.cmd'
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$agentEfforts = @('low', 'high', 'xhigh', 'max')
$script:BackupRoot = Join-Path $CodexHome ('backups\codex-workflows-kit\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:BackedUp = @{}
$script:ManagedFiles = @{}
$script:DryRunConflicts = New-Object System.Collections.Generic.List[string]

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        if (-not (Get-Item -LiteralPath $Path).PSIsContainer) {
            throw "Destination exists but is not a directory: $Path"
        }
        return
    }

    if (Confirm-InstallAction -Target $Path -Action 'Create installation directory') {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Backup-ExistingFile {
    param([Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        return
    }

    $fullDestination = [IO.Path]::GetFullPath($Destination)
    if ($script:BackedUp.ContainsKey($fullDestination)) {
        return
    }

    $safeName = [regex]::Replace($fullDestination, '[^A-Za-z0-9._-]', '_')
    $backupPath = Join-Path $script:BackupRoot $safeName
    if (Confirm-InstallAction -Target $Destination -Action "Back up existing file to $backupPath") {
        Ensure-Directory -Path $script:BackupRoot
        Copy-Item -LiteralPath $Destination -Destination $backupPath -Force
        $script:BackedUp[$fullDestination] = $backupPath
    }
}

function Install-ManagedContent {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $fullDestination = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Parent $fullDestination
    Ensure-Directory -Path $parent

    $changed = $true
    if (Test-Path -LiteralPath $fullDestination -PathType Leaf) {
        $existing = Get-Content -LiteralPath $fullDestination -Raw -Encoding UTF8
        $changed = $existing -cne $Content
    }

    if ($changed) {
        if ($fullDestination -ne $statePath) {
            Backup-ExistingFile -Destination $fullDestination
        }
        if (Confirm-InstallAction -Target $fullDestination -Action 'Install managed content') {
            Write-Utf8NoBom -Path $fullDestination -Content $Content
        }
    }

    if (Test-Path -LiteralPath $fullDestination -PathType Leaf) {
        $script:ManagedFiles[$fullDestination] = (Get-FileHash -LiteralPath $fullDestination -Algorithm SHA256).Hash
    }
}

function Copy-ManagedTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [scriptblock]$Transform
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Managed source directory is missing: $Source"
    }

    Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        if ($Transform) {
            $content = & $Transform $relative $content
        }
        Install-ManagedContent -Destination $target -Content $content
    }
}

function Install-WorkflowSkill {
    param(
        [Parameter(Mandatory)][string]$TargetBase,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Source
    )

    $target = Join-Path $TargetBase $Alias
    $transform = {
        param($relative, $content)
        if ($Alias -ne 'workflows') {
            if ($relative -eq 'SKILL.md') {
                $content = $content.Replace('name: workflows', "name: $Alias")
            }
            if ($relative -eq 'agents\openai.yaml') {
                $content = $content.Replace('$workflows mode=PLAN.AUTO', "`$$Alias mode=PLAN.AUTO")
            }
        }
        return $content
    }.GetNewClosure()

    Copy-ManagedTree -Source $Source -Destination $target -Transform $transform
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory)][string]$Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-OpenCodePathValue {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        (Join-Path $env:APPDATA 'npm\node_modules\opencode-ai\bin'),
        (Join-Path $env:ProgramFiles 'nodejs'),
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        $env:PATH
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        foreach ($item in $candidate -split ';') {
            if (-not [string]::IsNullOrWhiteSpace($item) -and -not $parts.Contains($item)) {
                $parts.Add($item)
            }
        }
    }
    return ($parts -join ';')
}

function Render-AgentProfile {
    param([Parameter(Mandatory)][string]$Content)

    $workerCommand = ConvertTo-TomlString (Join-Path $CodexHome 'bin\opencode-worker.cmd')
    $opencodeAgents = ConvertTo-TomlString $opencodeAgentsDest
    $openCodePath = ConvertTo-TomlString (Get-OpenCodePathValue)
    return $Content.Replace('__OPENCODE_WORKER_COMMAND__', $workerCommand.Trim('"')).Replace('__OPENCODE_AGENTS_DIR__', $opencodeAgents.Trim('"')).Replace('__OPENCODE_PATH__', $openCodePath.Trim('"'))
}

function Install-AgentProfile {
    param([Parameter(Mandatory)][string]$Source)

    $profile = Get-Content -LiteralPath $Source -Raw -Encoding UTF8
    if ((Split-Path -Leaf $Source) -eq 'relay.toml') {
        $profile = Render-AgentProfile -Content $profile
    }

    $nameMatch = [regex]::Match($profile, '(?m)^name\s*=\s*"(?<name>[^"]+)"\s*$')
    if (-not $nameMatch.Success) {
        throw "Agent profile has no name: $Source"
    }

    $name = $nameMatch.Groups['name'].Value
    $destination = Join-Path $agentsDest "$name.toml"
    Install-ManagedContent -Destination $destination -Content $profile

    foreach ($effort in $agentEfforts) {
        $variantName = "$name-$effort"
        $variant = [regex]::Replace($profile, '(?m)^name\s*=\s*"[^"]+"\s*$', "name = `"$variantName`"")
        $variant = [regex]::Replace($variant, '(?m)^model_reasoning_effort\s*=\s*"[^"]+"\s*$', "model_reasoning_effort = `"$effort`"")
        Install-ManagedContent -Destination (Join-Path $agentsDest "$variantName.toml") -Content $variant
    }
}

function Install-ManagedBlock {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Begin,
        [Parameter(Mandatory)][string]$End,
        [Parameter(Mandatory)][string]$Block
    )

    $existing = if (Test-Path -LiteralPath $Destination -PathType Leaf) { Get-Content -LiteralPath $Destination -Raw -Encoding UTF8 } else { '' }
    $content = $existing
    $start = $existing.IndexOf($Begin, [StringComparison]::Ordinal)
    if ($start -ge 0) {
        $endStart = $existing.IndexOf($End, $start, [StringComparison]::Ordinal)
        if ($endStart -lt 0) {
            throw "Managed block is incomplete in $Destination"
        }
        $content = $existing.Substring(0, $start) + $Block + $existing.Substring($endStart + $End.Length)
    }
    elseif ($existing -match '(?m)^\[mcp_servers\.opencode_worker(?:\]|\.)') {
        if (-not $Force) {
            $message = "An unmanaged opencode_worker configuration already exists in $Destination. Use -Force after reviewing its backup."
            if ($WhatIfPreference) {
                $script:DryRunConflicts.Add($message)
                Write-Warning "$message A execução real falharia sem -Force; o bloco foi apenas ignorado no dry-run."
                return
            }
            throw $message
        }
        $pattern = '(?ms)^\[mcp_servers\.opencode_worker(?:\.[^\]]+)?\].*?(?=^\[(?!mcp_servers\.opencode_worker(?:\]|\.))|\z)'
        $content = [regex]::Replace($existing, $pattern, $Block)
    }
    elseif ([string]::IsNullOrWhiteSpace($existing)) {
        $content = $Block
    }
    else {
        $content = $existing.TrimEnd() + "`r`n`r`n" + $Block
    }

    Install-ManagedContent -Destination $Destination -Content $content
}

function Install-GlobalAgentsFile {
    $raw = Get-Content -LiteralPath $agentsMdSource -Raw -Encoding UTF8
    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $end = '# END CODEX-WORKFLOWS-KIT'
    $managed = "$begin`r`n$raw`r`n$end"
    $existing = if (Test-Path -LiteralPath $agentsMdDest -PathType Leaf) { Get-Content -LiteralPath $agentsMdDest -Raw -Encoding UTF8 } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($existing) -and $existing.IndexOf($begin, [StringComparison]::Ordinal) -lt 0 -and $existing -cne $raw -and -not $Force) {
        $message = "An unmanaged Codex AGENTS.md already exists. Use -Force after reviewing its backup: $agentsMdDest"
        if ($WhatIfPreference) {
            $script:DryRunConflicts.Add($message)
            Write-Warning "$message A execução real falharia sem -Force; o bloco foi apenas ignorado no dry-run."
            return
        }
        throw $message
    }

    if ($existing.IndexOf($begin, [StringComparison]::Ordinal) -ge 0) {
        Install-ManagedBlock -Destination $agentsMdDest -Begin $begin -End $end -Block $managed
    }
    else {
        Install-ManagedContent -Destination $agentsMdDest -Content $managed
    }
}

function Install-OpenCodeConfig {
    $configPath = Join-Path $CodexHome 'config.toml'
    $begin = '# BEGIN CODEX-WORKFLOWS-KIT: opencode_worker'
    $end = '# END CODEX-WORKFLOWS-KIT: opencode_worker'
    $block = @"
$begin
[mcp_servers.opencode_worker]
command = $(ConvertTo-TomlString (Join-Path $CodexHome 'bin\opencode-worker.cmd'))
args = ["-y", "sub-agents-mcp@0.12.0"]
startup_timeout_sec = 30
tool_timeout_sec = 600
enabled = true
enabled_tools = ["run_agent"]

[mcp_servers.opencode_worker.env]
AGENTS_DIR = $(ConvertTo-TomlString $opencodeAgentsDest)
AGENT_TYPE = "opencode"
AGENT_MODEL = "opencode-go/deepseek-v4-flash"
AGENT_EFFORT = "max"
AGENT_PERMISSION = "yolo"
EXECUTION_TIMEOUT_MS = "600000"
SESSION_ENABLED = "false"
PATH = $(ConvertTo-TomlString (Get-OpenCodePathValue))
$end
"@
    Install-ManagedBlock -Destination $configPath -Begin $begin -End $end -Block $block.TrimEnd()
}

function Save-InstallState {
    foreach ($path in @($script:ManagedFiles.Keys)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $script:ManagedFiles[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }

    $state = [ordered]@{
        schemaVersion = 1
        product = 'codex-workflows-kit'
        profile = $Profile
        installedAtUtc = [datetime]::UtcNow.ToString('o')
        files = @(
            foreach ($entry in $script:ManagedFiles.GetEnumerator()) {
                [ordered]@{ path = $entry.Key; sha256 = $entry.Value }
            }
        )
    }
    $stateText = $state | ConvertTo-Json -Depth 5
    Install-ManagedContent -Destination $statePath -Content $stateText
}

$installationSucceeded = $false
try {
if (-not (Test-Path -LiteralPath $workflowSource -PathType Container)) {
    throw "Canonical workflows skill is missing: $workflowSource"
}

Ensure-Directory -Path $skillsDest
$skillDirectories = if ($includeAllSkills) {
    @(Get-ChildItem -LiteralPath $skillsSource -Directory | Select-Object -ExpandProperty Name)
} else {
    @('workflows', 'evidence-first')
}

foreach ($skillName in $skillDirectories) {
    $source = Join-Path $skillsSource $skillName
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Configured skill source is missing: $source"
    }
    Copy-ManagedTree -Source $source -Destination (Join-Path $skillsDest $skillName)
}

foreach ($alias in @('codex-workflows', 'antigravity-workflows', 'opencode-workflows')) {
    Install-WorkflowSkill -TargetBase $skillsDest -Alias $alias -Source $workflowSource
}

if ($installAntigravity) {
    foreach ($targetBase in @($antigravitySkillsDest1, $antigravitySkillsDest2)) {
        Ensure-Directory -Path $targetBase
        foreach ($skillName in $skillDirectories) {
            Copy-ManagedTree -Source (Join-Path $skillsSource $skillName) -Destination (Join-Path $targetBase $skillName)
        }
        foreach ($alias in @('codex-workflows', 'antigravity-workflows', 'opencode-workflows')) {
            Install-WorkflowSkill -TargetBase $targetBase -Alias $alias -Source $workflowSource
        }
    }
}

if ($includeAgents) {
    Ensure-Directory -Path $agentsDest
    Install-GlobalAgentsFile
    Get-ChildItem -LiteralPath $agentsSource -File -Filter '*.toml' | ForEach-Object {
        Install-AgentProfile -Source $_.FullName
    }
}

if ($includeOpenCode) {
    Ensure-Directory -Path $opencodeAgentsDest
    Copy-ManagedTree -Source $opencodeAgentsSource -Destination $opencodeAgentsDest
    Install-ManagedContent -Destination $workerWrapperDest -Content (Get-Content -LiteralPath $workerWrapperSource -Raw -Encoding UTF8)
}

if ($includeMaintenance) {
    Install-ManagedContent -Destination $maintenanceDest -Content (Get-Content -LiteralPath $maintenanceSource -Raw -Encoding UTF8)
}

if ($InstallAhk) {
    Install-ManagedContent -Destination $AhkDestination -Content (Get-Content -LiteralPath $ahkSource -Raw -Encoding UTF8)
}

if ($ConfigureMcp) {
    Install-OpenCodeConfig
    $maintenanceArgs = @('-Mode', 'Repair', '-RepositoryRoot', $repo, '-CodexHome', $CodexHome)
    if ($InstallScheduledTask) {
        $maintenanceArgs += '-InstallScheduledTask'
    }
    if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $maintenanceDest -PathType Leaf)) {
        throw "MCP maintenance script was not installed: $maintenanceDest"
    }
    if (Confirm-InstallAction -Target $maintenanceDest -Action 'Repair allowlisted MCP foundation') {
        & $maintenanceDest @maintenanceArgs
    }
}
elseif ($InstallScheduledTask) {
    throw '-InstallScheduledTask requires -ConfigureMcp.'
}

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
            Write-Warning "Installation failed before its state could be saved: $($_.Exception.Message)"
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
Write-Host "Skills: $skillsDest"
if ($includeAgents) { Write-Host "Agents: $agentsDest" }
if ($includeOpenCode) { Write-Host "OpenCode agents: $opencodeAgentsDest" }
if ($InstallAhk) { Write-Host "AHK: $AhkDestination" }
if ($ConfigureMcp) { Write-Host "MCP: configured in $(Join-Path $CodexHome 'config.toml')" }
if ($script:BackedUp.Count -gt 0) { Write-Host "Backups: $script:BackupRoot" }
if ($WhatIfPreference -and $script:DryRunConflicts.Count -gt 0) {
    Write-Warning ("Dry-run encontrou {0} conflito(s); use -Force depois de revisar os backups para executar a instalação." -f $script:DryRunConflicts.Count)
}
