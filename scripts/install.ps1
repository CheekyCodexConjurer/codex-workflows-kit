$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

$skillsSource = Join-Path $repo 'skills'
$workflowSource = Join-Path $skillsSource 'workflows'
$workflowAliases = @('codex-workflows', 'antigravity-workflows', 'opencode-workflows')
$agentsSource = Join-Path $repo 'agents'
$opencodeAgentsSource = Join-Path $agentsSource 'opencode'
$agentsMdSource = Join-Path $repo 'codex\AGENTS.md'
$ahkSource = Join-Path $repo 'ahk\codex_prompt_pad.ahk'
$maintenanceSource = Join-Path $repo 'plugins\mcp-foundation\scripts\maintain-mcps.ps1'

$skillsDest = 'C:\Users\mathe\.agents\skills'
$antigravitySkillsDest1 = 'C:\Users\mathe\.gemini\antigravity\skills'
$antigravitySkillsDest2 = 'C:\Users\mathe\.gemini\config\skills'
$agentsDest = 'C:\Users\mathe\.codex\agents'
$opencodeAgentsDest = 'C:\Users\mathe\.codex\opencode-agents'
$agentsMdDest = 'C:\Users\mathe\.codex\AGENTS.md'
$ahkDest = 'C:\Users\mathe\Documents\Codex\2026-07-01\pod\outputs\codex_prompt_pad.ahk'
$maintenanceDest = 'C:\Users\mathe\.codex\maintenance\maintain-mcps.ps1'
$agentEfforts = @('low', 'high', 'xhigh', 'max')

function Install-AgentEffortVariants {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination
    )

    $profile = Get-Content -Raw -LiteralPath $Source
    $nameMatch = [regex]::Match($profile, '(?m)^name\s*=\s*"(?<name>[^"]+)"\s*$')
    if (!$nameMatch.Success) {
        throw "Agent profile has no name: $Source"
    }

    foreach ($effort in $agentEfforts) {
        $variantName = "$($nameMatch.Groups['name'].Value)-$effort"
        $variant = [regex]::Replace(
            $profile,
            '(?m)^name\s*=\s*"[^"]+"\s*$',
            "name = `"$variantName`""
        )
        $variant = [regex]::Replace(
            $variant,
            '(?m)^model_reasoning_effort\s*=\s*"[^"]+"\s*$',
            "model_reasoning_effort = `"$effort`""
        )
        Set-Content -LiteralPath (Join-Path $Destination "$variantName.toml") -Value $variant -NoNewline
    }
}

function Install-WorkflowAlias {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination,
        [Parameter(Mandatory)]
        [string]$Alias
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    Copy-Item -Recurse -Force $Source $Destination

    $skillPath = Join-Path $Destination 'SKILL.md'
    $skillText = Get-Content -Raw -LiteralPath $skillPath
    $skillText = $skillText.Replace('name: workflows', "name: $Alias")
    Set-Content -LiteralPath $skillPath -Value $skillText -NoNewline

    $interfacePath = Join-Path $Destination 'agents\openai.yaml'
    if (Test-Path -LiteralPath $interfacePath) {
        $interfaceText = Get-Content -Raw -LiteralPath $interfacePath
        $aliasPrompt = '$' + $Alias + ' mode=PLAN.AUTO'
        $interfaceText = $interfaceText.Replace('$workflows mode=PLAN.AUTO', $aliasPrompt)
        Set-Content -LiteralPath $interfacePath -Value $interfaceText -NoNewline
    }
}

New-Item -ItemType Directory -Force $skillsDest, $antigravitySkillsDest1, $antigravitySkillsDest2, $agentsDest, $opencodeAgentsDest, (Split-Path -Parent $ahkDest), (Split-Path -Parent $maintenanceDest) | Out-Null

Get-ChildItem -Directory $skillsSource | ForEach-Object {
    foreach ($targetBase in @($skillsDest, $antigravitySkillsDest1, $antigravitySkillsDest2)) {
        $targetPath = Join-Path $targetBase $_.Name
        if (Test-Path $targetPath) {
            Remove-Item -Recurse -Force $targetPath
        }
        Copy-Item -Recurse -Force $_.FullName $targetPath
    }
}

if (!(Test-Path -LiteralPath $workflowSource)) {
    throw "Canonical workflows skill is missing: $workflowSource"
}

foreach ($targetBase in @($skillsDest, $antigravitySkillsDest1, $antigravitySkillsDest2)) {
    foreach ($alias in $workflowAliases) {
        Install-WorkflowAlias -Source $workflowSource -Destination (Join-Path $targetBase $alias) -Alias $alias
    }
}

Copy-Item -Force (Join-Path $agentsSource '*.toml') $agentsDest
Get-ChildItem -File $agentsSource -Filter '*.toml' | ForEach-Object {
    Install-AgentEffortVariants -Source $_.FullName -Destination $agentsDest
}
Copy-Item -Force (Join-Path $opencodeAgentsSource '*.md') $opencodeAgentsDest
Copy-Item -Force $agentsMdSource $agentsMdDest

$ahkBackup = $null
if (Test-Path $ahkDest) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ahkBackup = Join-Path (Split-Path -Parent $ahkDest) "codex_prompt_pad.$timestamp.ahk.bak"
    Copy-Item -Force $ahkDest $ahkBackup
}

Copy-Item -Force $ahkSource $ahkDest

$maintenanceBackup = $null
if (Test-Path $maintenanceDest) {
    $sourceHash = (Get-FileHash -LiteralPath $maintenanceSource -Algorithm SHA256).Hash
    $destHash = (Get-FileHash -LiteralPath $maintenanceDest -Algorithm SHA256).Hash
    if ($sourceHash -ne $destHash) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $maintenanceBackup = "$maintenanceDest.$timestamp.bak"
        Copy-Item -Force $maintenanceDest $maintenanceBackup
    }
}

Copy-Item -Force $maintenanceSource $maintenanceDest
& $maintenanceDest -Mode Repair -RepositoryRoot $repo -InstallScheduledTask

Write-Host "Installed Codex workflow assets."
Write-Host "Skills: $skillsDest"
Write-Host "Agents: $agentsDest"
Write-Host "OpenCode agents: $opencodeAgentsDest"
Write-Host "AGENTS.md: $agentsMdDest"
Write-Host "AHK: $ahkDest"
Write-Host "MCP maintenance: $maintenanceDest"
if ($ahkBackup) {
    Write-Host "AHK backup: $ahkBackup"
}
if ($maintenanceBackup) {
    Write-Host "MCP maintenance backup: $maintenanceBackup"
}
