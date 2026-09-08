# scripts/tests/swarm-completion-validator.Tests.ps1
# Deterministic RED/GREEN targeted tests for the revised dependency-scoped
# swarm completion policy validator in scripts/validate.ps1.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))

$script:TestCount = 0
$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Test {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$false)][string]$Details = ''
    )
    $script:TestCount++
    if ($Condition) {
        $script:PassedCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailedCount++
        $msg = if ($Details) { "$Name -> $Details" } else { $Name }
        $script:Failures.Add($msg)
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Load AST functions from validate.ps1
# ---------------------------------------------------------------------------
$validateScript = Join-Path $repoRoot 'scripts\validate.ps1'
$validateAst = [System.Management.Automation.Language.Parser]::ParseFile($validateScript, [ref]$null, [ref]$null)

function Load-FunctionAst($ast, [string]$functionName) {
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $functionName }, $true)
    if ($fn.Count -eq 0) {
        throw "Could not find function $functionName in AST"
    }
    Invoke-Expression ($fn[0].Extent.Text -replace '(?i)^function\s+', 'function script:')
}

Load-FunctionAst $validateAst 'Assert-CompletionPolicy'

$nl = [Environment]::NewLine

# ---------------------------------------------------------------------------
# Base Fixtures
# ---------------------------------------------------------------------------
$validDependencyScopedText = @(
    'Completion contract: completion is dependency-scoped; for each dependency or wave, the parent must wait for a `final response` before `dependent synthesis or advancement` (global barrier across independent waves is forbidden). While a job is `running`, do not send an `interruptive follow-up` or `replace` it. `interrupted`, `errored`, `timed out`, or `missing final response` means unavailable: keep the gate `open/BLOCKED`; do not use a `silent fallback`.',
    'Under `park_and_wake`, after all useful parent work ends, the parent dispatches independent fronts and drains useful local work before arming, emits a user-visible suspension message with waking condition, and ending the current run with obligations pending is permitted exclusively in the nonterminal `SUSPENDED` state backed by an armed `ParkReceipt` proving an externally armed continuation (if unarmed or `deliveryMode=none`, the parent must remain active). External wake follows the proven dual CLI wake contract starting a new run in the exact same task: for a loaded Desktop session, enqueue a metadata-only marker with `codex queue` so App automatically starts next run; for an unloaded session, use `codex exec resume`; queue-first deterministic error routing attempts `codex queue` first and routes to `codex exec resume` on unloaded session errors; no in-turn wait, no polling, no raw worker output, no automatic goal resume; a suspected progress wake is not a completed job and not follow-blocking (`suspectedprogresswake not completedjob/followblocking`), with no new goal or provider controls; follow and close obligations occur only after wake to consume ready jobs with `subagents_follow` and close retired agents with `subagents_close`. Exactly-once wake per generation and generation supersession apply; failure states fail closed without silent fallback to active_follow.',
    'Commit/final requires closure: final `DONE` remains strictly forbidden until all required jobs are terminally consumed and all agents closed (incomplete final closure is forbidden).',
    '',
    'Slices are designed to close terminally. Upon missing closure (ausência de fechamento)',
    'or proven terminal error, continue on the same track (mesma trilha): request a minimal',
    'inventory (inventário mínimo) and then execute small closure slices (closure slices pequenos).',
    'Proibido repetir integralmente a frente; proibido abrir novo agente / substituto.',
    '',
    'Normative contract:',
    '`completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`'
) -join $nl

$oldGlobalBarrierText = @(
    'Completion contract: for every required job, the parent must wait for a',
    '`final response` before `synthesis or advancement`. While a job is `running`,',
    'do not send an `interruptive follow-up` or `replace` it. `interrupted`,',
    '`errored`, `timed out`, or `missing final response` means unavailable: keep',
    'the gate `open/BLOCKED`; do not use a `silent fallback`.',
    'Under `park_and_wake`, after all useful parent work ends, the parent dispatches independent fronts and drains useful local work before arming, emits a user-visible suspension message with waking condition, and ending the current run with obligations pending is permitted',
    'exclusively in the nonterminal `SUSPENDED` state backed by an armed `ParkReceipt` proving',
    'an externally armed continuation (if unarmed or `deliveryMode=none`, the parent must remain active). External wake follows the proven dual CLI wake contract starting a new run in the exact same task: for a loaded Desktop session, enqueue a metadata-only marker with `codex queue` so App automatically starts next run; for an unloaded session, use `codex exec resume`; queue-first deterministic error routing attempts `codex queue` first and routes to `codex exec resume` on unloaded session errors; no in-turn wait, no polling, no raw worker output, no automatic goal resume; a suspected progress wake is not a completed job and not follow-blocking (`suspectedprogresswake not completedjob/followblocking`), with no new goal or provider controls; follow and close obligations occur only after wake to consume ready jobs with `subagents_follow` and close retired agents with `subagents_close`. Exactly-once wake per generation and generation supersession apply; failure states fail closed without silent fallback to active_follow.',
    'Final `DONE` remains strictly forbidden until all required jobs are terminally consumed',
    'and all agents closed.',
    '',
    'Slices are designed to close terminally. Upon missing closure (ausência de fechamento)',
    'or proven terminal error, continue on the same track (mesma trilha): request a minimal',
    'inventory (inventário mínimo) and then execute small closure slices (closure slices pequenos).',
    'Proibido repetir integralmente a frente; proibido abrir novo agente / substituto.',
    '',
    'Normative contract:',
    '`completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`'
) -join $nl

Write-Host "Running Swarm Completion Validator Tests..." -ForegroundColor Cyan

# ===========================================================================
# GROUP 1: Valid Contract Acceptance
# ===========================================================================
Write-Host "`n-- 1. Valid Dependency-Scoped Completion Contract Acceptance --" -ForegroundColor Yellow

$threw = $false
$err = ''
try {
    Assert-CompletionPolicy -Label 'valid dependency-scoped completion fixture' -Text $validDependencyScopedText
} catch {
    $threw = $true
    $err = $_.Exception.Message
}
Assert-Test "1.1 Valid dependency-scoped contract accepted" (-not $threw) $err

# ===========================================================================
# GROUP 2: Rejection of Global Barrier
# ===========================================================================
Write-Host "`n-- 2. Rejection of Global Barrier --" -ForegroundColor Yellow

# 2.1 Old global barrier contract rejected (for every required job... wait before synthesis)
$threw = $false
try {
    Assert-CompletionPolicy -Label 'old global barrier fixture' -Text $oldGlobalBarrierText
} catch {
    $threw = $true
}
Assert-Test "2.1 Old global barrier contract rejected" $threw

# 2.2 Explicit global barrier phrase rejected
$explicitGlobalBarrierText = $validDependencyScopedText + $nl + "The parent establishes a global barrier across all DAG branches."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'explicit global barrier fixture' -Text $explicitGlobalBarrierText
} catch {
    $threw = $true
}
Assert-Test "2.2 Explicit global barrier phrase rejected" $threw

# 2.3 Indefinite regex accommodation rejected (missing dependency-scoped scoping)
$unscopedText = [regex]::Replace($validDependencyScopedText, '(?i)completion is dependency-scoped; for each dependency or wave, the parent must wait for a `final response` before `dependent synthesis or advancement` \(global barrier across independent waves is forbidden\)\.', 'The parent waits for workers.')
$threw = $false
try {
    Assert-CompletionPolicy -Label 'unscoped fixture' -Text $unscopedText
} catch {
    $threw = $true
}
Assert-Test "2.3 Unscoped contract lacking dependency-scoped clause rejected" $threw

# 2.4 Innocent 'global barrier forbidden' phrase accepted without false positive
$innocentGlobalBarrierText = [regex]::Replace($validDependencyScopedText, '(?i)global barrier across independent waves is forbidden', 'global barrier forbidden')
$threw = $false
$err = ''
try {
    Assert-CompletionPolicy -Label 'innocent global barrier forbidden fixture' -Text $innocentGlobalBarrierText
} catch {
    $threw = $true
    $err = $_.Exception.Message
}
Assert-Test "2.4 Innocent 'global barrier forbidden' phrasing accepted without false positive" (-not $threw) $err

# ===========================================================================
# GROUP 3: Rejection of Incomplete Final Closure
# ===========================================================================
Write-Host "`n-- 3. Rejection of Incomplete Final Closure --" -ForegroundColor Yellow

# 3.1 Authorization of final DONE with unconsumed jobs rejected
$incompleteDoneText = $validDependencyScopedText + $nl + "The parent may emit final DONE with unconsumed jobs remaining."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'incomplete done fixture' -Text $incompleteDoneText
} catch {
    $threw = $true
}
Assert-Test "3.1 Authorization of final DONE with unconsumed jobs rejected" $threw

# 3.2 Authorization of DONE before closing all agents rejected
$unclosedAgentsText = $validDependencyScopedText + $nl + "The parent is authorized to commit before closing all agents."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'unclosed agents fixture' -Text $unclosedAgentsText
} catch {
    $threw = $true
}
Assert-Test "3.2 Authorization of commit before closing all agents rejected" $threw

# 3.3 Explicit authorization of incomplete final closure rejected
$explicitIncompleteText = $validDependencyScopedText + $nl + "This workflow permits incomplete final closure during delivery."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'explicit incomplete closure fixture' -Text $explicitIncompleteText
} catch {
    $threw = $true
}
Assert-Test "3.3 Explicit permit of incomplete final closure rejected" $threw

# 3.4 Missing mandatory final closure requirement rejected
$missingClosureReqText = [regex]::Replace($validDependencyScopedText, '(?i)Commit/final requires closure: final `DONE` remains strictly forbidden until all required jobs are terminally consumed and all agents closed \(incomplete final closure is forbidden\)\.', '')
$threw = $false
try {
    Assert-CompletionPolicy -Label 'missing closure requirement fixture' -Text $missingClosureReqText
} catch {
    $threw = $true
}
Assert-Test "3.4 Missing mandatory final closure requirement rejected" $threw

# 3.5 Causal frontier advancement while unrelated front unconsumed accepted
$causalFrontierText = $validDependencyScopedText + $nl + "On the global-ready frontier, consuming A and Bprep allows Btail to launch while C is unconsumed; independent approval allows idle open writers with consumed jobs, but idle open writers cannot close before delivery review."
$threw = $false
$err = ''
try {
    Assert-CompletionPolicy -Label 'causal frontier valid fixture' -Text $causalFrontierText
} catch {
    $threw = $true
    $err = $_.Exception.Message
}
Assert-Test "3.5 Causal frontier advancement while unrelated front unconsumed accepted" (-not $threw) $err

# 3.6 Causal non-final safety: final DONE or commit while C unconsumed is rejected
$causalPrematureDoneText = $causalFrontierText + $nl + "The parent may emit final DONE while C is unconsumed."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'causal premature done fixture' -Text $causalPrematureDoneText
} catch {
    $threw = $true
}
Assert-Test "3.6 Final DONE with unconsumed dependency rejected under causal frontier" $threw

# ===========================================================================
# GROUP 4: Core Safety Invariants Preservation
# ===========================================================================
Write-Host "`n-- 4. Core Safety Invariants Preservation --" -ForegroundColor Yellow

# 4.1 Rejection of interruptive follow-up on running jobs
$interruptText = $validDependencyScopedText + $nl + "The parent may interrupt running jobs when needed."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'interrupt running fixture' -Text $interruptText
} catch {
    $threw = $true
}
Assert-Test "4.1 Permission to interrupt running jobs rejected" $threw

# 4.2 Rejection of replacing running jobs
$replaceText = $validDependencyScopedText + $nl + "The parent can replace running jobs on lag."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'replace running fixture' -Text $replaceText
} catch {
    $threw = $true
}
Assert-Test "4.2 Permission to replace running jobs rejected" $threw

# 4.3 Rejection of silent fallback
$fallbackText = $validDependencyScopedText + $nl + "The parent may fall back to alternate worker upon timeout."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'fallback fixture' -Text $fallbackText
} catch {
    $threw = $true
}
Assert-Test "4.3 Permission to use fallback worker rejected" $threw

# 4.4 Rejection of repeat integrally
$repeatIntegrallyText = $validDependencyScopedText + $nl + "O parent deve repetir integralmente a frente."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'repeat integrally fixture' -Text $repeatIntegrallyText
} catch {
    $threw = $true
}
Assert-Test "4.4 Permission to repeat integrally rejected" $threw

# 4.5 Rejection of opening new agent on timeout
$newAgentTimeoutText = $validDependencyScopedText + $nl + "O parent pode abrir novo agente após timeout."
$threw = $false
try {
    Assert-CompletionPolicy -Label 'new agent timeout fixture' -Text $newAgentTimeoutText
} catch {
    $threw = $true
}
Assert-Test "4.5 Permission to open new agent on timeout rejected" $threw

# 4.6 Missing normative policy declaration rejected
$missingNormativeText = [regex]::Replace($validDependencyScopedText, '(?i)completion_policy\s*=\s*\{[^}]*\}', '')
$threw = $false
try {
    Assert-CompletionPolicy -Label 'missing normative fixture' -Text $missingNormativeText
} catch {
    $threw = $true
}
Assert-Test "4.6 Missing normative declaration rejected" $threw

# ---------------------------------------------------------------------------
# Summary and Exit
# ---------------------------------------------------------------------------
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor Cyan
if ($script:FailedCount -gt 0) {
    Write-Host "Failures occurred in swarm completion validator tests (RED phase expected before validator update):" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "All swarm completion validator tests passed deterministically." -ForegroundColor Green
    exit 0
}
