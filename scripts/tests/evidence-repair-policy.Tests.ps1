# scripts/tests/evidence-repair-policy.Tests.ps1
# Deterministic contract, behavioral simulation scenarios, and negative tamper tests
# for the evidence-based repair policy replacing arbitrary max2 repair limits across owned workflow files.
# NOTE: These tests verify content and simulation behavior (content/simulation, not live agent proof);
# an independent forward reviewer will later verify actual runtime agent instruction application.

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

Write-Host "Running Evidence-Based Repair Policy Tests (Content/Simulation, Not Live Agent Proof)..." -ForegroundColor Cyan

# ==============================================================================
# SECTION 1: Deterministic Behavioral Simulation Scenarios (Content/Simulation)
# ==============================================================================
Write-Host "`n-- 1. Deterministic Behavioral Simulation Scenarios (Content/Simulation, Not Live Agent Proof) --" -ForegroundColor Yellow

function Evaluate-RepairAttempt {
    param(
        [int]$AttemptNumber,
        [bool]$HasNewHypothesis,
        [string]$ExpectedObservation,
        [string]$ObservedDelta = $null,
        [string]$DiagnosticDirection,
        [array]$PriorAttempts = @(),
        [bool]$RequiresExternalAuthority = $false,
        [bool]$HasSafeActionablePath = $true,
        [bool]$RiskTriggerPresent = $false,
        [bool]$DeterministicTestsPass = $true,
        [bool]$RuntimeProofObserved = $false,
        [bool]$RequiredFixAddressed = $true,
        [ValidateSet('AUTO','ADMISSION','POST_RESULT')][string]$Stage = 'AUTO',
        [bool]$FalsifiedHypothesis = $false,
        [bool]$NarrowedPossibilities = $false
    )

    # 1. Genuine auth / permission / user-decision blocker or no safe path -> HALT/BLOCKED
    if ($RequiresExternalAuthority) {
        return @{ Status = 'STOP'; Decision = 'BLOCKED'; Reason = 'genuine authority/access/user-decision blocker requires user elevation' }
    }
    if (-not $HasSafeActionablePath) {
        return @{ Status = 'STOP'; Decision = 'BLOCKED'; Reason = 'no safe actionable path forward' }
    }

    # 2. Required fix check
    if (-not $RequiredFixAddressed) {
        return @{ Status = 'REJECTED'; Decision = 'BLOCKED'; Reason = 'required_fix was not addressed' }
    }

    # 3. Anti-loop proposal requirements:
    # Must have testable hypothesis and discriminating expected observation
    if (-not $HasNewHypothesis -or [string]::IsNullOrWhiteSpace($ExpectedObservation)) {
        return @{ Status = 'REJECTED_REPLAN'; Decision = 'REPLAN'; Reason = 'missing testable hypothesis or discriminating observation' }
    }

    # Check if this attempt is an identical no-information retry of a prior attempt in the same direction
    foreach ($prev in $PriorAttempts) {
        $prevHadNoInfo = [string]::IsNullOrWhiteSpace($prev.ObservedDelta)
        if ($prev.ContainsKey('ProducedInformation')) {
            $prevHadNoInfo = $prevHadNoInfo -and (-not $prev.ProducedInformation)
        }
        if ($prev.DiagnosticDirection -eq $DiagnosticDirection -and $prevHadNoInfo) {
            return @{ Status = 'REJECTED_REPLAN'; Decision = 'REPLAN'; Reason = 'duplicate no-evidence retry rejected; lack of delta requires different diagnostic direction' }
        }
    }

    # Determine phase: ADMISSION vs POST-RESULT
    $isAdmission = if ($Stage -eq 'ADMISSION') {
        $true
    } elseif ($Stage -eq 'POST_RESULT') {
        $false
    } else {
        [string]::IsNullOrWhiteSpace($ObservedDelta) -and (-not $FalsifiedHypothesis) -and (-not $NarrowedPossibilities) -and (-not $RuntimeProofObserved)
    }

    # 4. ADMISSION PHASE:
    # Observed delta is not yet available before the experiment executes.
    # Distinct testable hypothesis + expected observation + authorized safe experiment -> ADMITTED.
    if ($isAdmission) {
        return @{ Status = 'ADMITTED'; Decision = 'CONTINUE'; Reason = 'proposed repair admitted with distinct testable hypothesis and expected discriminating observation (observed delta not yet available)' }
    }

    # 5. POST-RESULT PHASE:
    # 5a. Risk trigger operational proof check (reject static-only false greens)
    if ($RiskTriggerPresent -and $DeterministicTestsPass -and (-not $RuntimeProofObserved)) {
        return @{ Status = 'NOT_DONE'; Decision = 'BLOCKED'; Reason = 'passing tests without real proof not done (operational proof missing under risk trigger)' }
    }

    # 5b. Evaluate whether useful information was obtained:
    # Falsified hypothesis or narrowed possibilities counts as information even if symptom persists
    $hasUsefulInformation = (-not [string]::IsNullOrWhiteSpace($ObservedDelta)) -or $FalsifiedHypothesis -or $NarrowedPossibilities
    if (-not $hasUsefulInformation) {
        return @{ Status = 'REJECTED_REPLAN'; Decision = 'REPLAN'; Reason = 'lack of delta requires different diagnostic direction, not duplicate retry' }
    }

    # Third and subsequent useful repairs allowed when there is hypothesis + observed delta / information
    return @{ Status = 'ALLOWED'; Decision = 'CONTINUE'; Reason = 'useful repair allowed with testable hypothesis and observed delta/falsification information' }
}

# Scenario 1: Third useful repair allowed (new testable hypothesis + observed delta, POST-RESULT)
$scenario1Prior = @(
    @{ Attempt = 1; DiagnosticDirection = 'dir_A'; ObservedDelta = 'isolated component failure trace' },
    @{ Attempt = 2; DiagnosticDirection = 'dir_B'; ObservedDelta = 'narrowed timing race condition' }
)
$scenario1Result = Evaluate-RepairAttempt `
    -AttemptNumber 3 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'mutex lock acquires before signal' `
    -ObservedDelta 'signal verified with zero race in stress test' `
    -DiagnosticDirection 'dir_C' `
    -PriorAttempts $scenario1Prior `
    -RequiresExternalAuthority $false `
    -HasSafeActionablePath $true `
    -RiskTriggerPresent $true `
    -DeterministicTestsPass $true `
    -RuntimeProofObserved $true `
    -RequiredFixAddressed $true `
    -Stage 'POST_RESULT'

Assert-Test "[CONTENT/SIMULATION] Scenario 1: Third useful repair allowed with new hypothesis and observed delta" `
    ($scenario1Result.Status -eq 'ALLOWED' -and $scenario1Result.Decision -eq 'CONTINUE') `
    "Result: $($scenario1Result.Status) / $($scenario1Result.Decision)"

# Scenario 2: Duplicate no-evidence retry rejected / replan
$scenario2Prior = @(
    @{ Attempt = 1; DiagnosticDirection = 'dir_A'; ObservedDelta = '' }
)
$scenario2Result = Evaluate-RepairAttempt `
    -AttemptNumber 2 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'retrying same fix' `
    -ObservedDelta '' `
    -DiagnosticDirection 'dir_A' `
    -PriorAttempts $scenario2Prior `
    -RequiresExternalAuthority $false `
    -HasSafeActionablePath $true

Assert-Test "[CONTENT/SIMULATION] Scenario 2: Duplicate no-evidence retry rejected / routed to replan" `
    ($scenario2Result.Status -eq 'REJECTED_REPLAN' -and $scenario2Result.Decision -eq 'REPLAN') `
    "Result: $($scenario2Result.Status) / $($scenario2Result.Decision)"

# Scenario 3: Genuine auth blocker stops
$scenario3Result = Evaluate-RepairAttempt `
    -AttemptNumber 2 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'external token check' `
    -ObservedDelta 'requires admin credential' `
    -DiagnosticDirection 'dir_auth' `
    -RequiresExternalAuthority $true

Assert-Test "[CONTENT/SIMULATION] Scenario 3: Genuine auth blocker stops without expanding permissions" `
    ($scenario3Result.Status -eq 'STOP' -and $scenario3Result.Decision -eq 'BLOCKED') `
    "Result: $($scenario3Result.Status) / $($scenario3Result.Decision)"

# Scenario 4: Passing tests without real proof not done (risk trigger active)
$scenario4Result = Evaluate-RepairAttempt `
    -AttemptNumber 1 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'unit test passes' `
    -ObservedDelta 'green mock tests' `
    -DiagnosticDirection 'dir_db' `
    -RiskTriggerPresent $true `
    -DeterministicTestsPass $true `
    -RuntimeProofObserved $false

Assert-Test "[CONTENT/SIMULATION] Scenario 4: Passing tests without real operational proof rejected as not done" `
    ($scenario4Result.Status -eq 'NOT_DONE' -and $scenario4Result.Decision -eq 'BLOCKED') `
    "Result: $($scenario4Result.Status) / $($scenario4Result.Decision)"

# Scenario 5: Regression - Third proposed hypothesis with no result YET admitted (ADMISSION phase)
$scenario5Prior = @(
    @{ Attempt = 1; DiagnosticDirection = 'dir_A'; ObservedDelta = 'isolated trace' },
    @{ Attempt = 2; DiagnosticDirection = 'dir_B'; ObservedDelta = 'narrowed cause' }
)
$scenario5Result = Evaluate-RepairAttempt `
    -AttemptNumber 3 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'drain loop flushes remaining buffer elements' `
    -DiagnosticDirection 'dir_C' `
    -PriorAttempts $scenario5Prior `
    -RequiresExternalAuthority $false `
    -HasSafeActionablePath $true `
    -Stage 'ADMISSION'

Assert-Test "[CONTENT/SIMULATION] Scenario 5: Third proposed hypothesis with no result YET admitted" `
    (($scenario5Result.Status -in @('ADMITTED', 'ALLOWED')) -and $scenario5Result.Decision -eq 'CONTINUE') `
    "Result: $($scenario5Result.Status) / $($scenario5Result.Decision)"

# Scenario 6: Regression - Same no-information retry rejected at admission
$scenario6Prior = @(
    @{ Attempt = 1; DiagnosticDirection = 'dir_A'; ObservedDelta = '' },
    @{ Attempt = 2; DiagnosticDirection = 'dir_B'; ObservedDelta = '' }
)
$scenario6Result = Evaluate-RepairAttempt `
    -AttemptNumber 3 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'retrying dir_B again without new direction' `
    -DiagnosticDirection 'dir_B' `
    -PriorAttempts $scenario6Prior `
    -RequiresExternalAuthority $false `
    -HasSafeActionablePath $true `
    -Stage 'ADMISSION'

Assert-Test "[CONTENT/SIMULATION] Scenario 6: Same no-information retry rejected at admission" `
    ($scenario6Result.Status -eq 'REJECTED_REPLAN' -and $scenario6Result.Decision -eq 'REPLAN') `
    "Result: $($scenario6Result.Status) / $($scenario6Result.Decision)"

# Scenario 7: Falsified hypothesis or narrowed possibilities counts as information post-result even if symptom persists
$scenario7Result = Evaluate-RepairAttempt `
    -AttemptNumber 2 `
    -HasNewHypothesis $true `
    -ExpectedObservation 'failure reproduced with targeted trace' `
    -ObservedDelta 'hypothesis H1 falsified: mutex lock contention absent; narrowed cause to socket write buffer' `
    -DiagnosticDirection 'dir_diag' `
    -FalsifiedHypothesis $true `
    -NarrowedPossibilities $true `
    -Stage 'POST_RESULT'

Assert-Test "[CONTENT/SIMULATION] Scenario 7: Falsified hypothesis/narrowed possibilities counts as information post-result" `
    ($scenario7Result.Status -eq 'ALLOWED' -and $scenario7Result.Decision -eq 'CONTINUE') `
    "Result: $($scenario7Result.Status) / $($scenario7Result.Decision)"

# ==============================================================================
# SECTION 2: Owned Policy Files Content & Contract Verification (Content/Simulation)
# ==============================================================================
Write-Host "`n-- 2. Owned Policy Files Content & Contract Verification (Content/Simulation, Not Live Agent Proof) --" -ForegroundColor Yellow

$delivRefFile   = Join-Path $repoRoot 'skills\workflows\references\delivery-review.md'
$validRefFile   = Join-Path $repoRoot 'skills\workflows\references\validation.md'
$commitRefFile  = Join-Path $repoRoot 'skills\workflows\references\commit.md'
$delegaRefFile  = Join-Path $repoRoot 'skills\workflows\references\delegation.md'
$wfSkillFile    = Join-Path $repoRoot 'skills\workflows\SKILL.md'
$agentsFile     = Join-Path $repoRoot 'codex\AGENTS.md'
$geminiFile     = Join-Path $repoRoot 'antigravity\GEMINI.md'

$delivText  = if (Test-Path -LiteralPath $delivRefFile)  { Get-Content -LiteralPath $delivRefFile  -Raw -Encoding UTF8 } else { '' }
$validText  = if (Test-Path -LiteralPath $validRefFile)  { Get-Content -LiteralPath $validRefFile  -Raw -Encoding UTF8 } else { '' }
$commitText = if (Test-Path -LiteralPath $commitRefFile) { Get-Content -LiteralPath $commitRefFile -Raw -Encoding UTF8 } else { '' }
$delegaText = if (Test-Path -LiteralPath $delegaRefFile) { Get-Content -LiteralPath $delegaRefFile -Raw -Encoding UTF8 } else { '' }
$wfText     = if (Test-Path -LiteralPath $wfSkillFile)    { Get-Content -LiteralPath $wfSkillFile    -Raw -Encoding UTF8 } else { '' }
$agentsText = if (Test-Path -LiteralPath $agentsFile)     { Get-Content -LiteralPath $agentsFile     -Raw -Encoding UTF8 } else { '' }
$geminiText = if (Test-Path -LiteralPath $geminiFile)     { Get-Content -LiteralPath $geminiFile     -Raw -Encoding UTF8 } else { '' }

function Get-Normalized([string]$t) {
    return [regex]::Replace($t, '\s+', ' ').Trim()
}

$delivNorm  = Get-Normalized $delivText
$validNorm  = Get-Normalized $validText
$commitNorm = Get-Normalized $commitText
$delegaNorm = Get-Normalized $delegaText
$wfNorm     = Get-Normalized $wfText
$agentsNorm = Get-Normalized $agentsText
$geminiNorm = Get-Normalized $geminiText

# Regex matching normative max2 / maximum 2 rounds and paraphrases ('at most 2 rounds', 'maximum two', Portuguese synonyms)
$normativeMax2Pattern = '(?i)(?:(?:at\s+most|max(?:imum)?(?:\s+of)?|up\s+to)\s+(?:\d+|two)\s+(?:(?:consolidated\s+)?repair\s+)?rounds?|max(?:imum)?\s+two\b|(?:(?:no\s+)?m(?:[a\u00e1]|\u00c3\u00a1)x(?:imo|\u00c3\u00admo)?\.?(?:\s+de)?|at(?:[e\u00e9]|\u00c3\u00a9)|limite\s+(?:fixo\s+)?de)\s+(?:\d+|duas?|dois)\s+(?:rodadas?(?:\s+de\s+reparo)?|tentativas?)|m(?:[a\u00e1]|\u00c3\u00a1)x\.?\s*2(?:\s+rodadas?)?|\blimite\s+num(?:[e\u00e9]|\u00c3\u00a9)rico\s+fixo\s+de\s+\d+)'

# Test: Normative max2 and 'at most 2 rounds' must be absent from all owned files (including SKILL.md line 240)
Assert-Test "[CONTENT/SIMULATION] delivery-review.md has no normative max2 or 'at most 2 rounds' rule" (-not [regex]::IsMatch($delivNorm, $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] validation.md has no normative max2 or 'at most 2 rounds' rule" (-not [regex]::IsMatch($validNorm, $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] commit.md has no normative max2 or 'at most 2 rounds' rule" (-not [regex]::IsMatch($commitNorm, $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] SKILL.md (incl line 240) has no normative max2 or 'at most 2 rounds' rule" (-not [regex]::IsMatch($wfNorm, $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] AGENTS.md has no normative max2 or 'at most 2 rounds' rule" (-not [regex]::IsMatch($agentsNorm, $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] GEMINI.md has no normative max2 or 'at most 2 rounds' rule" (-not [regex]::IsMatch($geminiNorm, $normativeMax2Pattern))

# Tamper tests: 'at most 2 rounds', 'maximum two', and Portuguese synonyms injected anywhere normative is rejected
Assert-Test "[CONTENT/SIMULATION] Tamper test: 'at most 2 rounds' injected in SKILL.md is detected and rejected" `
    ([regex]::IsMatch(($wfNorm + ' at most 2 rounds'), $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] Tamper test: 'maximum two' injected in SKILL.md is detected and rejected" `
    ([regex]::IsMatch(($wfNorm + ' maximum two rounds of repair'), $normativeMax2Pattern))
$ptTamper = "no m$([char]0x00e1)ximo duas rodadas de reparo"
Assert-Test "[CONTENT/SIMULATION] Tamper test: Portuguese 'no m$([char]0x00e1)ximo duas rodadas' injected in SKILL.md is detected and rejected" `
    ([regex]::IsMatch(($wfNorm + " $ptTamper"), $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] Tamper test: 'at most 2 rounds' injected in delivery-review.md is detected and rejected" `
    ([regex]::IsMatch(($delivNorm + ' at most 2 rounds'), $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] Tamper test: 'at most 2 rounds' injected in AGENTS.md is detected and rejected" `
    ([regex]::IsMatch(($agentsNorm + ' at most 2 rounds'), $normativeMax2Pattern))
Assert-Test "[CONTENT/SIMULATION] Tamper test: 'at most 2 rounds' injected in GEMINI.md is detected and rejected" `
    ([regex]::IsMatch(($geminiNorm + ' at most 2 rounds'), $normativeMax2Pattern))

# Canonical rule verification in delivery-review.md
Assert-Test "[CONTENT/SIMULATION] delivery-review.md defines evidence-based repair policy" `
    ([regex]::IsMatch($delivNorm, '(?i)(?:pol[i\u00ed]tica de reparo orientada a evid[e\u00ea]ncia|evidence-based repair)'))

Assert-Test "[CONTENT/SIMULATION] delivery-review.md distinguishes admission (hypothesis+observation) from post-result (delta/falsification)" `
    ([regex]::IsMatch($delivNorm, '(?i)(?:admiss[a\u00e3]o|admission)') -and
     [regex]::IsMatch($delivNorm, '(?i)(?:p[o\u00f3]s-resultado|post-result)') -and
     [regex]::IsMatch($delivNorm, '(?i)falsif') -and
     [regex]::IsMatch($delivNorm, '(?i)(?:n[a\u00e3]o est[a\u00e1] dispon[i\u00ed]vel|not yet available)'))

Assert-Test "[CONTENT/SIMULATION] delivery-review.md mandates anti-loop debug ledger with required fields" `
    ([regex]::IsMatch($delivNorm, '(?i)debug_ledger\.md') -and
     [regex]::IsMatch($delivNorm, '(?i)hip[o\u00f3]tese') -and
     [regex]::IsMatch($delivNorm, '(?i)observa[c\u00e7][a\u00e3]o discriminante') -and
     [regex]::IsMatch($delivNorm, '(?i)delta observado') -and
     [regex]::IsMatch($delivNorm, '(?i)pr[o\u00f3]xima decis[a\u00e3]o'))

Assert-Test "[CONTENT/SIMULATION] delivery-review.md requires different diagnostic direction on lack of delta (no duplicate retry/swarm)" `
    ([regex]::IsMatch($delivNorm, '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente') -and
     [regex]::IsMatch($delivNorm, '(?i)(?:sem|proibid[oa]).{0,50}(?:retentativa id[e\u00ea]ntica|duplicate retry|worker swarm)'))

Assert-Test "[CONTENT/SIMULATION] delivery-review.md allows third and subsequent useful repairs with new hypothesis and delta" `
    ([regex]::IsMatch($delivNorm, '(?i)(?:terceir[ao]|subsequente).{0,50}(?:reparo|tentativa).{0,50}(?:permitid[ao]|avalan|avan[c\u00e7]a)'))

Assert-Test "[CONTENT/SIMULATION] delivery-review.md stops only on genuine authority/access/user-decision or no safe actionable path" `
    ([regex]::IsMatch($delivNorm, '(?i)bloqueio genu[i\u00ed]no de autoridade|acesso|decis[a\u00e3]o do usu[a\u00e1]rio') -and
     [regex]::IsMatch($delivNorm, '(?i)sem caminho seguro acion[a\u00e1]vel'))

Assert-Test "[CONTENT/SIMULATION] delivery-review.md prohibits fixed numerical stopping rules or disguised counters" `
    ([regex]::IsMatch($delivNorm, '(?i)(?:sem|proibid[oa]).{0,50}(?:limite num[e\u00e9]rico fixo|contador disfar[c\u00e7]ado)'))

# Aligned mirrors verification
Assert-Test "[CONTENT/SIMULATION] SKILL.md mirrors evidence-based repair and anti-loop ledger" `
    ([regex]::IsMatch($wfNorm, '(?i)(?:reparo orientado a evid[e\u00ea]ncia|evidence-based repair)') -and
     [regex]::IsMatch($wfNorm, '(?i)debug_ledger\.md'))

Assert-Test "[CONTENT/SIMULATION] AGENTS.md mirrors evidence-based repair and anti-loop ledger" `
    ([regex]::IsMatch($agentsNorm, '(?i)(?:reparo orientad[oa] a evid[e\u00ea]ncia|evidence-based repair)') -and
     [regex]::IsMatch($agentsNorm, '(?i)debug_ledger\.md'))

Assert-Test "[CONTENT/SIMULATION] GEMINI.md mirrors evidence-based repair and anti-loop ledger" `
    ([regex]::IsMatch($geminiNorm, '(?i)(?:reparo orientado a evid[e\u00ea]ncia|evidence-based repair)') -and
     [regex]::IsMatch($geminiNorm, '(?i)debug_ledger\.md'))

Assert-Test "[CONTENT/SIMULATION] validation.md references evidence-based repair cycle" `
    ([regex]::IsMatch($validNorm, '(?i)(?:reparo orientado a evid[e\u00ea]ncia|evidence-based repair)'))

Assert-Test "[CONTENT/SIMULATION] commit.md references evidence-based repair cycle" `
    ([regex]::IsMatch($commitNorm, '(?i)(?:reparo orientado a evid[e\u00ea]ncia|evidence-based repair)'))

Assert-Test "[CONTENT/SIMULATION] delegation.md forbids duplicate retry or worker swarm duplication on lack of delta" `
    ([regex]::IsMatch($delegaNorm, '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente|worker swarm'))

# Invariants preservation
Assert-Test "[CONTENT/SIMULATION] delivery-review.md preserves required_fix invariant" ([regex]::IsMatch($delivNorm, '(?i)required_fix'))
Assert-Test "[CONTENT/SIMULATION] delivery-review.md preserves operational runtime proof gate" ([regex]::IsMatch($delivNorm, '(?i)prova operacional'))
Assert-Test "[CONTENT/SIMULATION] delivery-review.md preserves independent review verdict requirement" ([regex]::IsMatch($delivNorm, '(?i)APPROVED') -and [regex]::IsMatch($delivNorm, '(?i)BLOCKED'))
Assert-Test "[CONTENT/SIMULATION] delivery-review.md preserves staging invariant target_id" ([regex]::IsMatch($delivNorm, '(?i)target_id'))

# Line budget checks
$agentsLines = ($agentsText -split "`r?`n").Count
$geminiLines = ($geminiText -split "`r?`n").Count
Assert-Test "[CONTENT/SIMULATION] codex/AGENTS.md remains compact (<= 45 lines, currently $agentsLines)" ($agentsLines -le 45)
Assert-Test "[CONTENT/SIMULATION] antigravity/GEMINI.md remains compact (<= 35 lines, currently $geminiLines)" ($geminiLines -le 35)

# Summary
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "`nAll evidence-based repair policy tests passed deterministically." -ForegroundColor Green
    exit 0
}
