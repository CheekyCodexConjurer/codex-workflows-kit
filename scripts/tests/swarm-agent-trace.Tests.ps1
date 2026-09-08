# scripts/tests/swarm-agent-trace.Tests.ps1
# Deterministic regression and contract tests for eval-agent-trace.ps1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$RepoRootOverride = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = if ($RepoRootOverride) { [IO.Path]::GetFullPath($RepoRootOverride) } else { [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..')) }

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

Write-Host "Running Swarm Agent Trace Evaluator Tests..." -ForegroundColor Cyan

$evalScript = Join-Path $repoRoot 'scripts\eval-agent-trace.ps1'
$safeHelper = Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1'
$frontierPath = Join-Path $repoRoot 'tests\fixtures\swarm-ready-frontier.json'
$fixturesDir = Join-Path $repoRoot 'tests\fixtures\swarm-agent-trace'

# Helper function to execute eval-agent-trace via pwsh invoke-safe-powershell
function Invoke-Eval {
    param(
        [string]$TraceFile,
        [string]$ScenarioFile = '',
        [string]$ExpectedThread = '',
        [switch]$AsObject
    )

    $resolvedScenario = if ($ScenarioFile) { $ScenarioFile } else { $frontierPath }
    $params = @{
        TracePath = $TraceFile
        FrontierPath = $resolvedScenario
    }
    if ($ExpectedThread) {
        $params['ExpectedThreadId'] = $ExpectedThread
    }
    $jsonParams = $params | ConvertTo-Json -Compress
    $res = & $safeHelper -ScriptPath $evalScript -ParametersJson $jsonParams -PassThru
    $outCombined = "$($res.StdOut)`n$($res.StdErr)".Trim()

    return [PSCustomObject]@{
        ExitCode = $res.ExitCode
        Output = $outCombined
    }
}

# ==============================================================================
# SECTION 1: Missing and Empty Trace Cases
# ==============================================================================
Write-Host "`n-- 1. Missing and Empty Trace Cases --" -ForegroundColor Yellow

$missingTracePath = Join-Path $fixturesDir 'non-existent-trace.jsonl'
$resMissing = Invoke-Eval -TraceFile $missingTracePath
Assert-Test "1.1 Missing trace file exits non-zero" ($resMissing.ExitCode -ne 0) "ExitCode: $($resMissing.ExitCode)"
Assert-Test "1.2 Missing trace reports missing violation" ($resMissing.Output -match 'MissingTrace|Missing.*trace') "Output: $($resMissing.Output)"

$emptyTracePath = Join-Path $fixturesDir 'temp_empty_trace.jsonl'
[IO.File]::WriteAllText($emptyTracePath, "")
try {
    $resEmpty = Invoke-Eval -TraceFile $emptyTracePath
    Assert-Test "1.3 Empty trace file exits non-zero" ($resEmpty.ExitCode -ne 0) "ExitCode: $($resEmpty.ExitCode)"
    Assert-Test "1.4 Empty trace reports empty violation" ($resEmpty.Output -match 'EmptyTrace|empty') "Output: $($resEmpty.Output)"
} finally {
    if (Test-Path -LiteralPath $emptyTracePath) { Remove-Item -LiteralPath $emptyTracePath -Force -ErrorAction SilentlyContinue }
}

# ==============================================================================
# SECTION 2: Thread & Event Integrity Cases
# ==============================================================================
Write-Host "`n-- 2. Thread & Event Integrity Cases --" -ForegroundColor Yellow

$resWrongThread = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'wrong-thread.jsonl')
Assert-Test "2.1 Wrong thread trace exits non-zero" ($resWrongThread.ExitCode -ne 0) "ExitCode: $($resWrongThread.ExitCode)"
Assert-Test "2.2 Wrong thread reported in violations" ($resWrongThread.Output -match 'WrongThread|thread') "Output: $($resWrongThread.Output)"

$resDupEvents = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'duplicate-events.jsonl')
Assert-Test "2.3 Duplicate event IDs exits non-zero" ($resDupEvents.ExitCode -ne 0) "ExitCode: $($resDupEvents.ExitCode)"
Assert-Test "2.4 Duplicate events reported in violations" ($resDupEvents.Output -match 'DuplicateEvents|duplicate.*event') "Output: $($resDupEvents.Output)"

# ==============================================================================
# SECTION 3: Malformed Results & Unknown Commands
# ==============================================================================
Write-Host "`n-- 3. Malformed Results & Unknown Commands --" -ForegroundColor Yellow

$resMalformed = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'malformed-result.jsonl')
Assert-Test "3.1 Malformed result exits non-zero" ($resMalformed.ExitCode -ne 0) "ExitCode: $($resMalformed.ExitCode)"
Assert-Test "3.2 Malformed result reported in violations" ($resMalformed.Output -match 'MalformedResult|malformed') "Output: $($resMalformed.Output)"

$resUnknownCmd = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'unknown-command.jsonl')
Assert-Test "3.3 Unknown command / unauthorized tool exits non-zero" ($resUnknownCmd.ExitCode -ne 0) "ExitCode: $($resUnknownCmd.ExitCode)"
Assert-Test "3.4 Unknown command rejected by canary allowlist" ($resUnknownCmd.Output -match 'UnknownCommand|canary|allowlist') "Output: $($resUnknownCmd.Output)"

# ==============================================================================
# SECTION 4: Ready Frontier & Dependency Ordering
# ==============================================================================
Write-Host "`n-- 4. Ready Frontier & Dependency Ordering --" -ForegroundColor Yellow

$resPrematureBtail = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'premature-btail.jsonl')
Assert-Test "4.1 Premature Btail admission exits non-zero" ($resPrematureBtail.ExitCode -ne 0) "ExitCode: $($resPrematureBtail.ExitCode)"
Assert-Test "4.2 Premature Btail reported as dependency violation" ($resPrematureBtail.Output -match 'Premature|Dependency') "Output: $($resPrematureBtail.Output)"

$resDepFailed = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'dependency-failed.jsonl')
Assert-Test "4.3 Dependency failure prevents Btail admission" ($resDepFailed.ExitCode -ne 0) "ExitCode: $($resDepFailed.ExitCode)"
Assert-Test "4.4 Non-success dependency status rejected" ($resDepFailed.Output -match 'Premature|Dependency|failed') "Output: $($resDepFailed.Output)"

# ==============================================================================
# SECTION 5: Lifecycle Completion (Follow and Close Obligations)
# ==============================================================================
Write-Host "`n-- 5. Lifecycle Completion Obligations --" -ForegroundColor Yellow

$resPendingFollow = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'pending-follow.jsonl')
Assert-Test "5.1 Pending follow at trace end exits non-zero" ($resPendingFollow.ExitCode -ne 0) "ExitCode: $($resPendingFollow.ExitCode)"
Assert-Test "5.2 Pending follow reported in violations" ($resPendingFollow.Output -match 'PendingFollow|pending.*follow') "Output: $($resPendingFollow.Output)"

$resUnclosed = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'unclosed-agent.jsonl')
Assert-Test "5.3 Unclosed agent at trace end exits non-zero" ($resUnclosed.ExitCode -ne 0) "ExitCode: $($resUnclosed.ExitCode)"
Assert-Test "5.4 Unclosed agent reported in violations" ($resUnclosed.Output -match 'UnclosedAgent|unclosed') "Output: $($resUnclosed.Output)"

# ==============================================================================
# SECTION 6: Idempotent vs Distinct Job Same Operation
# ==============================================================================
Write-Host "`n-- 6. Idempotent vs Distinct Job Same Operation --" -ForegroundColor Yellow

$resDupSameOp = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'duplicate-same-operation.jsonl')
Assert-Test "6.1 Distinct job attempting same operation/revision rejected" ($resDupSameOp.ExitCode -ne 0) "ExitCode: $($resDupSameOp.ExitCode)"
Assert-Test "6.2 Distinct job same operation violation reported" ($resDupSameOp.Output -match 'DuplicateSameOperation|same operation') "Output: $($resDupSameOp.Output)"

$resIdempotent = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'idempotent-admission.jsonl')
Assert-Test "6.3 Repeated identical admission receipt for same job has no error (exit code 0)" ($resIdempotent.ExitCode -eq 0) "ExitCode: $($resIdempotent.ExitCode), Output: $($resIdempotent.Output)"
Assert-Test "6.4 Repeated admission recorded as idempotent" ($resIdempotent.Output -match 'idempotent|Idempotent') "Output: $($resIdempotent.Output)"

# ==============================================================================
# SECTION 7: Selective Invalidation
# ==============================================================================
Write-Host "`n-- 7. Selective Invalidation Boundaries --" -ForegroundColor Yellow

$resMissingStimulus = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'missing-stimulus.jsonl')
Assert-Test "7.1 Missing stimulus fails closed (exit code non-zero)" ($resMissingStimulus.ExitCode -ne 0) "ExitCode: $($resMissingStimulus.ExitCode)"
Assert-Test "7.2 Unproven invalidation reported in violations" ($resMissingStimulus.Output -match 'InvalidRevisionStimulus|stimulus|fail-closed') "Output: $($resMissingStimulus.Output)"

$resAllowedRev = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'allowed-new-revision.jsonl')
Assert-Test "7.3 Allowed new revision with observed stimulus passes (exit code 0)" ($resAllowedRev.ExitCode -eq 0) "ExitCode: $($resAllowedRev.ExitCode), Output: $($resAllowedRev.Output)"

# ==============================================================================
# SECTION 8: Concurrency & Physical Timing Proof
# ==============================================================================
Write-Host "`n-- 8. Concurrency & Physical Timing Verification --" -ForegroundColor Yellow

$resValid = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'valid-trace.jsonl')
Assert-Test "8.1 Valid trace passes deterministically (exit code 0)" ($resValid.ExitCode -eq 0) "ExitCode: $($resValid.ExitCode), Output: $($resValid.Output)"
Assert-Test "8.2 startedAt null legitimately marked as unproven physical overlap without fake proof" ($resValid.Output -match 'unproven.*physical|PhysicalOverlap.*unproven') "Output: $($resValid.Output)"
Assert-Test "8.3 Valid trace confirms logical overlap between Btail and C" ($resValid.Output -match 'LogicalOverlap.*True|logical overlap') "Output: $($resValid.Output)"

$resFinished = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'c-already-finished.jsonl')
Assert-Test "8.4 C already finished trace fails closed on missing logical concurrency" ($resFinished.ExitCode -ne 0) "ExitCode: $($resFinished.ExitCode)"
Assert-Test "8.5 MissingLogicalConcurrency violation reported" ($resFinished.Output -match 'MissingLogicalConcurrency|C was already consumed') "Output: $($resFinished.Output)"

# ==============================================================================
# SECTION 9: PassThru Structured Output
# ==============================================================================
Write-Host "`n-- 9. PassThru Object Schema Verification --" -ForegroundColor Yellow

$objRes = & $evalScript -TracePath (Join-Path $fixturesDir 'valid-trace.jsonl') -FrontierPath $frontierPath -PassThru
Assert-Test "9.1 PassThru returns valid object with Pass=true" ($null -ne $objRes -and $objRes.Pass -eq $true)
Assert-Test "9.2 PassThru reports ConcurrencyProof with PhysicalOverlap unproven" ($objRes.ConcurrencyProof.PhysicalOverlap -eq 'unproven')
Assert-Test "9.3 PassThru reports DispatchedCount equals 4" ($objRes.DispatchedCount -eq 4)
Assert-Test "9.4 PassThru reports ConsumedCount equals 4" ($objRes.ConsumedCount -eq 4)
Assert-Test "9.5 PassThru reports ClosedAgentCount equals 4" ($objRes.ClosedAgentCount -eq 4)

# ==============================================================================
# SECTION 10: Negative Regressions & Actual Native Schema
# ==============================================================================
Write-Host "`n-- 10. Negative Regressions & Actual Native Schema --" -ForegroundColor Yellow

$resNoEvent = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'no-event-trace.jsonl')
Assert-Test "10.1 No-event trace exits non-zero" ($resNoEvent.ExitCode -ne 0) "ExitCode: $($resNoEvent.ExitCode), Output: $($resNoEvent.Output)"
Assert-Test "10.2 No-event trace reports empty trace or missing mandatory nodes" ($resNoEvent.Output -match 'EmptyTrace|MissingMandatoryNode') "Output: $($resNoEvent.Output)"

$resIgnoredCmd = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'ignored-command-event.jsonl')
Assert-Test "10.3 Ignored CommandExecution event exits non-zero" ($resIgnoredCmd.ExitCode -ne 0) "ExitCode: $($resIgnoredCmd.ExitCode), Output: $($resIgnoredCmd.Output)"
Assert-Test "10.4 Unauthorized CommandExecution rejected by canary allowlist" ($resIgnoredCmd.Output -match 'UnknownCommand|canary|allowlist') "Output: $($resIgnoredCmd.Output)"

$resFailedClose = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'failed-close.jsonl')
Assert-Test "10.5 Failed subagents_close exits non-zero" ($resFailedClose.ExitCode -ne 0) "ExitCode: $($resFailedClose.ExitCode), Output: $($resFailedClose.Output)"
Assert-Test "10.6 Failed close rejected and not marked closed" ($resFailedClose.Output -match 'FailedClose|UnclosedAgent') "Output: $($resFailedClose.Output)"

$resStaleA = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'stale-a-revision.jsonl')
Assert-Test "10.7 Stale A revision exits non-zero" ($resStaleA.ExitCode -ne 0) "ExitCode: $($resStaleA.ExitCode), Output: $($resStaleA.Output)"
Assert-Test "10.8 Stale dependency revision rejected" ($resStaleA.Output -match 'StaleDependencyRevision|PrematureAdmission|stale') "Output: $($resStaleA.Output)"

$resMissingBatch = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'missing-initial-batch.jsonl')
Assert-Test "10.9 Missing initial ready batch exits non-zero" ($resMissingBatch.ExitCode -ne 0) "ExitCode: $($resMissingBatch.ExitCode), Output: $($resMissingBatch.Output)"
Assert-Test "10.10 Missing initial ready batch reported" ($resMissingBatch.Output -match 'InvalidInitialBatch|PrematureFollow|initial ready batch') "Output: $($resMissingBatch.Output)"

$resInvalidStim = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'invalid-stimulus-binding.jsonl')
Assert-Test "10.11 Arbitrary stimulus substring binding exits non-zero" ($resInvalidStim.ExitCode -ne 0) "ExitCode: $($resInvalidStim.ExitCode), Output: $($resInvalidStim.Output)"
Assert-Test "10.12 Arbitrary stimulus rejected" ($resInvalidStim.Output -match 'InvalidRevisionStimulus|stimulus|fail-closed') "Output: $($resInvalidStim.Output)"

$resActualPos = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'actual-schema-positive.jsonl')
Assert-Test "10.13 Actual native schema positive fixture passes (exit code 0)" ($resActualPos.ExitCode -eq 0) "ExitCode: $($resActualPos.ExitCode), Output: $($resActualPos.Output)"

$resUnaccepted = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'unaccepted-admission.jsonl')
Assert-Test "10.14 Unaccepted admission exits non-zero" ($resUnaccepted.ExitCode -ne 0) "ExitCode: $($resUnaccepted.ExitCode), Output: $($resUnaccepted.Output)"
Assert-Test "10.15 Unaccepted admission reported in violations" ($resUnaccepted.Output -match 'UnacceptedAdmission|rejected|accepted=true') "Output: $($resUnaccepted.Output)"

$resMismatchedReq = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'mismatched-request-id.jsonl')
Assert-Test "10.16 Mismatched receipt requestId exits non-zero" ($resMismatchedReq.ExitCode -ne 0) "ExitCode: $($resMismatchedReq.ExitCode), Output: $($resMismatchedReq.Output)"
Assert-Test "10.17 Mismatched receipt requestId reported in violations" ($resMismatchedReq.Output -match 'MismatchedReceiptId|does not match requested requestId') "Output: $($resMismatchedReq.Output)"

$resOrphan = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'orphan-follow-close.jsonl')
Assert-Test "10.18 Orphan follow or close exits non-zero" ($resOrphan.ExitCode -ne 0) "ExitCode: $($resOrphan.ExitCode), Output: $($resOrphan.Output)"
Assert-Test "10.19 Orphan follow/close reported in violations" ($resOrphan.Output -match 'UnknownJobFollow|UnknownAgentClose') "Output: $($resOrphan.Output)"

$resMissingThread = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'missing-thread-provenance.jsonl')
Assert-Test "10.20 Missing thread provenance exits non-zero" ($resMissingThread.ExitCode -ne 0) "ExitCode: $($resMissingThread.ExitCode), Output: $($resMissingThread.Output)"
Assert-Test "10.21 Missing thread provenance reported in violations" ($resMissingThread.Output -match 'MissingThreadProvenance|missing thread_id') "Output: $($resMissingThread.Output)"

$resMissingQuiescent = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'close-missing-quiescence.jsonl')
Assert-Test "10.22 Close missing quiescence exits non-zero" ($resMissingQuiescent.ExitCode -ne 0) "ExitCode: $($resMissingQuiescent.ExitCode)"
Assert-Test "10.23 Absent quiescence rejected in violations" ($resMissingQuiescent.Output -match 'FailedClose|quiescent') "Output: $($resMissingQuiescent.Output)"

$resMissingExit = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'stimulus-missing-exit-code.jsonl')
Assert-Test "10.24 Stimulus missing exit code exits non-zero" ($resMissingExit.ExitCode -ne 0) "ExitCode: $($resMissingExit.ExitCode), Output: $($resMissingExit.Output)"
Assert-Test "10.25 Stimulus missing exit code fails closed on invalid revision" ($resMissingExit.Output -match 'InvalidRevisionStimulus|stimulus|fail-closed') "Output: $($resMissingExit.Output)"

$resNullExit = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'stimulus-null-exit-code.jsonl')
Assert-Test "10.26 Stimulus null exit code exits non-zero" ($resNullExit.ExitCode -ne 0) "ExitCode: $($resNullExit.ExitCode), Output: $($resNullExit.Output)"
Assert-Test "10.27 Stimulus null exit code fails closed on invalid revision" ($resNullExit.Output -match 'InvalidRevisionStimulus|stimulus|fail-closed') "Output: $($resNullExit.Output)"

$resMalformedExit = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'stimulus-malformed-exit-code.jsonl')
Assert-Test "10.28 Stimulus malformed/boolean exit code exits non-zero" ($resMalformedExit.ExitCode -ne 0) "ExitCode: $($resMalformedExit.ExitCode), Output: $($resMalformedExit.Output)"
Assert-Test "10.29 Stimulus malformed/boolean exit code fails closed on invalid revision" ($resMalformedExit.Output -match 'InvalidRevisionStimulus|stimulus|fail-closed') "Output: $($resMalformedExit.Output)"

$resFailedStatus = Invoke-Eval -TraceFile (Join-Path $fixturesDir 'stimulus-failed-status.jsonl')
Assert-Test "10.30 Stimulus failed status exits non-zero" ($resFailedStatus.ExitCode -ne 0) "ExitCode: $($resFailedStatus.ExitCode), Output: $($resFailedStatus.Output)"
Assert-Test "10.31 Stimulus failed status fails closed on invalid revision" ($resFailedStatus.Output -match 'InvalidRevisionStimulus|stimulus|fail-closed') "Output: $($resFailedStatus.Output)"

Write-Host "`n=========================================="
Write-Host "Total: $($script:TestCount) | Passed: $($script:PassedCount) | Failed: $($script:FailedCount)"

if ($script:FailedCount -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host " - $f" -ForegroundColor Red
    }
    exit 1
}

Write-Host "All swarm agent trace evaluator tests passed deterministically." -ForegroundColor Green
exit 0
