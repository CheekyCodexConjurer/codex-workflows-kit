$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

$skillSource = Join-Path $repo 'skills\codex-workflows'
$agentsSource = Join-Path $repo 'agents'
$agentsMdSource = Join-Path $repo 'codex\AGENTS.md'
$ahkSource = Join-Path $repo 'ahk\codex_prompt_pad.ahk'

$skillDest = 'C:\Users\mathe\.agents\skills\codex-workflows'
$agentsDest = 'C:\Users\mathe\.codex\agents'
$agentsMdDest = 'C:\Users\mathe\.codex\AGENTS.md'
$ahkDest = 'C:\Users\mathe\Documents\Codex\2026-07-01\pod\outputs\codex_prompt_pad.ahk'

New-Item -ItemType Directory -Force (Split-Path -Parent $skillDest), $agentsDest, (Split-Path -Parent $ahkDest) | Out-Null

if (Test-Path $skillDest) {
    Remove-Item -Recurse -Force $skillDest
}

Copy-Item -Recurse -Force $skillSource $skillDest
Copy-Item -Force (Join-Path $agentsSource '*.toml') $agentsDest
Copy-Item -Force $agentsMdSource $agentsMdDest
Copy-Item -Force $ahkSource $ahkDest

Write-Host "Installed codex workflows."
Write-Host "Skill: $skillDest"
Write-Host "Agents: $agentsDest"
Write-Host "AGENTS.md: $agentsMdDest"
Write-Host "AHK: $ahkDest"
