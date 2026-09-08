# scripts/tests/mcp-maintenance-routing.Tests.ps1
# Deterministic contract tests for automatic allowlisted MCP preflight and maintenance routing.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$routingModule = Join-Path $repoRoot 'scripts\backend-routing.psm1'
$workflowSkill = Join-Path $repoRoot 'skills\workflows\SKILL.md'
$mcpFoundation = Join-Path $repoRoot 'skills\mcp-foundation\SKILL.md'
$agentsFile = Join-Path $repoRoot 'codex\AGENTS.md'
$geminiFile = Join-Path $repoRoot 'antigravity\GEMINI.md'

$script:TestCount = 0
$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $false)][string]$Details = ''
    )

    $script:TestCount++
    if ($Condition) {
        $script:PassedCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:FailedCount++
        $message = if ($Details) { "$Name -> $Details" } else { $Name }
        $script:Failures.Add($message)
        Write-Host "  [FAIL] $message" -ForegroundColor Red
    }
}

Write-Host 'Running MCP Maintenance Routing Tests...' -ForegroundColor Cyan

Import-Module $routingModule -Force
$workflowText = Get-Content -LiteralPath $workflowSkill -Raw -Encoding UTF8
$foundationText = Get-Content -LiteralPath $mcpFoundation -Raw -Encoding UTF8
$agentsText = Get-Content -LiteralPath $agentsFile -Raw -Encoding UTF8
$geminiText = Get-Content -LiteralPath $geminiFile -Raw -Encoding UTF8

$hasDecision = $null -ne (Get-Command -Name Get-CodexMcpMaintenanceDecision -ErrorAction SilentlyContinue)
Assert-Test 'routing module exports the unified MCP maintenance decision' $hasDecision

if ($hasDecision) {
    $freshCodeGraph = Get-CodexMcpMaintenanceDecision -Mcp CodeGraph -Status @{ state = 'fresh' } -Mode DELIVER.AUTO
    $staleCodeGraph = Get-CodexMcpMaintenanceDecision -Mcp CodeGraph -Status @{ state = 'stale' } -Mode DELIVER.AUTO
    $missingCodeGraph = Get-CodexMcpMaintenanceDecision -Mcp CodeGraph -Status @{ state = 'missing' } -Mode DELIVER.AUTO
    $missingCbm = Get-CodexMcpMaintenanceDecision -Mcp CBM -Status @{ state = 'missing' } -Mode DELIVER.AUTO
    $staleCbmReadOnly = Get-CodexMcpMaintenanceDecision -Mcp CBM -Status @{ state = 'stale' } -Mode PLAN
    $missingSerena = Get-CodexMcpMaintenanceDecision -Mcp Serena -Status @{ state = 'missing' } -Mode IMPL
    $availableContext7 = Get-CodexMcpMaintenanceDecision -Mcp Context7 -Status @{ state = 'available' } -Mode DELIVER.AUTO
    $missingContext7 = Get-CodexMcpMaintenanceDecision -Mcp Context7 -Status @{ state = 'missing' } -Mode DELIVER.AUTO
    $missingCbmCommit = Get-CodexMcpMaintenanceDecision -Mcp CBM -Status @{ state = 'missing' } -Mode COMMIT

    Assert-Test 'fresh CodeGraph skips maintenance' ($freshCodeGraph.Action -ceq 'none') ($freshCodeGraph | Out-String)
    Assert-Test 'stale CodeGraph requests incremental sync in write mode' ($staleCodeGraph.Action -ceq 'sync') ($staleCodeGraph | Out-String)
    Assert-Test 'missing CodeGraph remains manual-init gated' ($missingCodeGraph.Action -ceq 'manual_init') ($missingCodeGraph | Out-String)
    Assert-Test 'missing CBM is prepared automatically in authorized write mode' ($missingCbm.Action -ceq 'initialize') ($missingCbm | Out-String)
    Assert-Test 'stale CBM is inspect-only in no-write mode' ($staleCbmReadOnly.Action -ceq 'inspect') ($staleCbmReadOnly | Out-String)
    Assert-Test 'missing Serena requests project activation in write mode' ($missingSerena.Action -ceq 'activate') ($missingSerena | Out-String)
    Assert-Test 'available Context7 is selected for a triggered documentation lookup' ($availableContext7.Action -ceq 'use') ($availableContext7 | Out-String)
    Assert-Test 'missing Context7 fails closed instead of attempting installation' ($missingContext7.Action -ceq 'blocked') ($missingContext7 | Out-String)
    Assert-Test 'COMMIT never initializes a missing CBM index' ($missingCbmCommit.Action -ceq 'inspect') ($missingCbmCommit | Out-String)
}

$normalized = @($workflowText, $foundationText, $agentsText, $geminiText) | ForEach-Object { [regex]::Replace($_, '\s+', ' ').Trim() }
$allText = $normalized -join ' '
Assert-Test 'canonical policy requires automatic MCP preflight before task work' ($allText -match '(?i)preflight MCP.*(?:autom[aá]tico|automatic).*antes') $allText
Assert-Test 'canonical policy requires agents and sub-agents to use the relevant MCP automatically' ($allText -match '(?i)(?:agentes|agents).*sub-agents.*(?:preflight|MCP).*?(?:deve|must|obrigat)') $allText
Assert-Test 'canonical policy permits supported repository preparation only in write modes' ($allText -match '(?i)(?:inicializa|prepara|sincroniza).*(?:modo[s]? de escrita|write mode)') $allText
Assert-Test 'canonical policy keeps unavailable MCPs fail-closed' ($allText -match '(?i)(?:fail.?closed|falha fechad).*MCP') $allText
Assert-Test 'canonical policy distinguishes CodeGraph manual init from CBM preparation' ($allText -match '(?i)CodeGraph.*(?:manual|operator).*CBM.*(?:prepara|index)') $allText

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nAll MCP maintenance routing tests passed deterministically." -ForegroundColor Green
exit 0
