# scripts/tests/evidence-repair-validator.Tests.ps1
# Deterministic RED/GREEN targeted tests for the evidence-based repair validators
# in scripts/validate.ps1 and scripts/test-safe-profile-gate.ps1.

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
# Load AST functions from validate.ps1 and test-safe-profile-gate.ps1
# ---------------------------------------------------------------------------
$validateScript = Join-Path $repoRoot 'scripts\validate.ps1'
$gateScript = Join-Path $repoRoot 'scripts\test-safe-profile-gate.ps1'

$validateAst = [System.Management.Automation.Language.Parser]::ParseFile($validateScript, [ref]$null, [ref]$null)
$gateAst = [System.Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$null, [ref]$null)

function Load-FunctionAst($ast, [string]$functionName) {
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $functionName }, $true)
    if ($fn.Count -eq 0) {
        throw "Could not find function $functionName in AST"
    }
    Invoke-Expression ($fn[0].Extent.Text -replace '(?i)^function\s+', 'function script:')
}

Load-FunctionAst $validateAst 'Assert-DeliveryReviewContract'
Load-FunctionAst $validateAst 'Assert-DeliveryReviewPolicy'
Load-FunctionAst $gateAst 'Test-CorrectionAdequacyGateSemantics'

# Load canonical policy texts
$canonicalDelivery = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\references\delivery-review.md') -Raw -Encoding UTF8
$canonicalQuality  = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\references\quality-ratchet.md') -Raw -Encoding UTF8
$canonicalValid    = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\references\validation.md') -Raw -Encoding UTF8
$canonicalCommit   = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\references\commit.md') -Raw -Encoding UTF8
$canonicalDelega   = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\references\delegation.md') -Raw -Encoding UTF8
$canonicalSkill    = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\SKILL.md') -Raw -Encoding UTF8
$canonicalAgents   = Get-Content -LiteralPath (Join-Path $repoRoot 'codex\AGENTS.md') -Raw -Encoding UTF8
$canonicalGemini   = Get-Content -LiteralPath (Join-Path $repoRoot 'antigravity\GEMINI.md') -Raw -Encoding UTF8
$canonicalReadme   = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw -Encoding UTF8

$nl = [Environment]::NewLine

Write-Host "Running Evidence-Based Repair Validator Tests..." -ForegroundColor Cyan

# ===========================================================================
# GROUP 1: Assert-DeliveryReviewContract (validate.ps1)
# ===========================================================================
Write-Host "`n-- 1. Assert-DeliveryReviewContract (validate.ps1) --" -ForegroundColor Yellow

# 1.1 Valid current policy accepted
$threw = $false
$err = ''
try {
    Assert-DeliveryReviewContract -Label 'canonical delivery-review' -Text $canonicalDelivery
} catch {
    $threw = $true
    $err = $_.Exception.Message
}
Assert-Test "1.1 Canonical delivery-review.md is accepted" (-not $threw) $err

# 1.2 Stale max2 policy rejected (RED)
$threw = $false
try {
    $staleMax2 = $canonicalDelivery + $nl + "$([char]0x00c9) permitido um m$([char]0x00e1)ximo de 2 rodadas de reparo."
    Assert-DeliveryReviewContract -Label 'stale max2' -Text $staleMax2
} catch {
    $threw = $true
}
Assert-Test "1.2 Stale max2 policy rejected (máximo 2 rodadas)" $threw

# 1.3 Stale max2 policy (en) rejected (RED)
$threw = $false
try {
    $staleMax2En = $canonicalDelivery + $nl + 'Consolidated repair cycle has a max 2 rounds limit.'
    Assert-DeliveryReviewContract -Label 'stale max 2 rounds' -Text $staleMax2En
} catch {
    $threw = $true
}
Assert-Test "1.3 Stale max2 policy rejected (max 2 rounds)" $threw

# 1.3b Stale max2 policy (at most 2 rounds) rejected (RED)
$threw = $false
try {
    $staleAtMost2 = $canonicalDelivery + $nl + 'Consolidated repair allows at most 2 rounds.'
    Assert-DeliveryReviewContract -Label 'stale at most 2 rounds' -Text $staleAtMost2
} catch {
    $threw = $true
}
Assert-Test "1.3b Stale max2 policy rejected (at most 2 rounds)" $threw

# 1.3c Stale max2 policy (maximum two) rejected (RED)
$threw = $false
try {
    $staleMaxTwo = $canonicalDelivery + $nl + 'Repair cycle has maximum two rounds.'
    Assert-DeliveryReviewContract -Label 'stale maximum two' -Text $staleMaxTwo
} catch {
    $threw = $true
}
Assert-Test "1.3c Stale max2 policy rejected (maximum two)" $threw

# 1.3d Stale max2 policy (no máximo duas rodadas) rejected (RED)
$threw = $false
try {
    $stalePtMaxDuas = $canonicalDelivery + $nl + "S$([char]0x00e3)o permitidas no m$([char]0x00e1)ximo duas rodadas de reparo."
    Assert-DeliveryReviewContract -Label 'stale no maximo duas rodadas' -Text $stalePtMaxDuas
} catch {
    $threw = $true
}
Assert-Test "1.3d Stale max2 policy rejected (no máximo duas rodadas)" $threw

# 1.4 Disguised numerical stopping rule rejected (RED)
$threw = $false
try {
    $disguised = $canonicalDelivery + $nl + "O reparo possui um limite num$([char]0x00e9)rico fixo de 3 tentativas."
    Assert-DeliveryReviewContract -Label 'disguised counter' -Text $disguised
} catch {
    $threw = $true
}
Assert-Test "1.4 Disguised numerical stopping rule rejected" $threw

# 1.5 Missing anti-loop hypothesis rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)hip[o\u00f3]tes', 'suposic' -replace '(?i)hypothesis', 'guess'
    Assert-DeliveryReviewContract -Label 'missing hypothesis' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.5 Missing anti-loop hypothesis rejected" $threw

# 1.6 Missing anti-loop expected discriminating observation rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)observa[c\u00e7][a\u00e3]o discriminante', 'resultado' -replace '(?i)discriminating observation', 'result'
    Assert-DeliveryReviewContract -Label 'missing expected observation' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.6 Missing anti-loop expected observation rejected" $threw

# 1.6b Missing admission phase delta-pending contract rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)n[a\u00e3]o est[a\u00e1] dispon[i\u00ed]vel|not yet available', 'ja disponivel'
    Assert-DeliveryReviewContract -Label 'missing admission pending delta' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.6b Missing admission phase delta-pending contract rejected" $threw

# 1.7 Missing anti-loop post-result observed delta rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)delta observado', 'mudanca' -replace '(?i)observed delta', 'change'
    Assert-DeliveryReviewContract -Label 'missing observed delta' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.7 Missing anti-loop observed delta rejected" $threw

# 1.8 Missing anti-loop next decision rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)pr[o\u00f3]xima decis[a\u00e3]o', 'passo' -replace '(?i)next decision', 'step'
    Assert-DeliveryReviewContract -Label 'missing next decision' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.8 Missing anti-loop next decision rejected" $threw

# 1.9 Missing different diagnostic direction on no-delta rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente', 'mesma' -replace '(?i)different diagnostic direction', 'same'
    Assert-DeliveryReviewContract -Label 'missing diff direction' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.9 Missing different diagnostic direction on no-delta rejected" $threw

# 1.10 Missing duplicate retry / worker swarm prohibition rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)retentativa id[e\u00ea]ntica|duplicate retry|worker swarm', 'retry livre'
    Assert-DeliveryReviewContract -Label 'missing retry/swarm prohibition' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.10 Missing duplicate retry/swarm prohibition rejected" $threw

# 1.11 Missing useful repair continuation rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)terceira rodada|novas evid[e\u00ea]ncias [u\u00fa]teis', 'apenas turno unico'
    Assert-DeliveryReviewContract -Label 'missing useful repair continuation' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.11 Missing useful repair continuation rejected" $threw

# 1.12 Missing genuine authority safety boundary rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)bloqueio genu[i\u00ed]no de', 'bloqueio arbitrario de'
    Assert-DeliveryReviewContract -Label 'missing authority boundary' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.12 Missing genuine authority safety boundary rejected" $threw

# 1.13 Missing no safe actionable path rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)sem caminho seguro acion[a\u00e1]vel', 'com caminho' -replace '(?i)no safe actionable path', 'with safe path'
    Assert-DeliveryReviewContract -Label 'missing no safe path' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.13 Missing no safe actionable path rejected" $threw

# 1.14 Missing numerical stopping rule prohibition rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)limite num[e\u00e9]rico fixo', 'contador' -replace '(?i)contadores? disfar[c\u00e7]ados?', 'flags' -replace '(?i)numerical stopping rule', 'counter'
    Assert-DeliveryReviewContract -Label 'missing numerical prohibition' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.14 Missing prohibition of numerical stopping rule rejected" $threw

# 1.15 Unchanged review requirement: missing operational proof rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)prova operacional', 'sem prova' -replace '(?i)operational proof', 'no proof' -replace '(?i)runtime proof', 'no proof'
    Assert-DeliveryReviewContract -Label 'missing operational proof' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.15 Unchanged review requirement: missing operational proof rejected" $threw

# 1.16 Unchanged review requirement: missing target_id rejected (RED)
$threw = $false
try {
    $tampered = $canonicalDelivery -replace '(?i)target_id', 'git_commit_hash'
    Assert-DeliveryReviewContract -Label 'missing target_id' -Text $tampered
} catch {
    $threw = $true
}
Assert-Test "1.16 Unchanged review requirement: missing target_id rejected" $threw

# ===========================================================================
# ===========================================================================
# GROUP 2: Assert-DeliveryReviewPolicy (validate.ps1)
# ===========================================================================
Write-Host "`n-- 2. Assert-DeliveryReviewPolicy (validate.ps1) --" -ForegroundColor Yellow

# 2.1 Canonical policy set accepted
$threw = $false
$err = ''
try {
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
    $err = $_.Exception.Message
}
Assert-Test "2.1 Canonical policy set accepted" (-not $threw) $err

# 2.2 Stale max2 policy in delivery-review.md rejected (RED)
$threw = $false
try {
    $staleDeliv = $canonicalDelivery + $nl + "$([char]0x00c9) permitido um m$([char]0x00e1)ximo de duas rodadas de reparo."
    Assert-DeliveryReviewPolicy -DeliveryReviewText $staleDeliv -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.2 Stale max2 in delivery-review.md rejected" $threw

# 2.3 Stale max2 policy in AGENTS.md rejected (RED)
$threw = $false
try {
    $staleAgents = $canonicalAgents + $nl + "com m$([char]0x00e1)x 2 rodadas"
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $staleAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.3 Stale max2 in AGENTS.md rejected" $threw

# 2.4 Stale max2 policy in GEMINI.md rejected (RED)
$threw = $false
try {
    $staleGemini = $canonicalGemini + $nl + "com m$([char]0x00e1)x 2 rodadas"
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $staleGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4 Stale max2 in GEMINI.md rejected" $threw

# 2.4b Stale max2 policy ('at most 2 rounds') in SKILL.md rejected (RED)
$threw = $false
try {
    $staleSkill = $canonicalSkill + $nl + 'Repair cycle allows at most 2 rounds.'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $staleSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4b Stale 'at most 2 rounds' in SKILL.md rejected" $threw

# 2.4c Stale max2 policy ('maximum two') in SKILL.md rejected (RED)
$threw = $false
try {
    $staleSkillTwo = $canonicalSkill + $nl + 'Repair cycle allows maximum two rounds.'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $staleSkillTwo -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4c Stale 'maximum two' in SKILL.md rejected" $threw

# 2.4d Stale max2 policy (Portuguese 'no máximo duas rodadas') in SKILL.md rejected (RED)
$threw = $false
try {
    $staleSkillPt = $canonicalSkill + $nl + "no m$([char]0x00e1)ximo duas rodadas de reparo"
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $staleSkillPt -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4d Stale Portuguese 'no máximo duas rodadas' in SKILL.md rejected" $threw

# 2.4e Stale max2 policy in validation.md rejected (RED)
$threw = $false
try {
    $staleValid = $canonicalValid + $nl + 'at most 2 rounds'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $staleValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4e Stale max2 in validation.md rejected" $threw

# 2.4f Stale max2 policy in commit.md rejected (RED)
$threw = $false
try {
    $staleCommit = $canonicalCommit + $nl + 'at most 2 rounds'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $staleCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4f Stale max2 in commit.md rejected" $threw

# 2.4g Stale max2 policy in quality-ratchet.md rejected (RED)
$threw = $false
try {
    $staleQuality = $canonicalQuality + $nl + 'at most 2 rounds'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $staleQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4g Stale max2 in quality-ratchet.md rejected" $threw

# 2.4h Stale max2 policy in delegation.md rejected (RED)
$threw = $false
try {
    $staleDelega = $canonicalDelega + $nl + 'at most 2 rounds'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $staleDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.4h Stale max2 in delegation.md rejected" $threw

# 2.4i Stale max2 policy in README.md rejected (RED)
$threw = $false
try {
    $staleReadme = $canonicalReadme + $nl + 'at most 2 rounds'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $staleReadme
} catch {
    $threw = $true
}
Assert-Test "2.4i Stale max2 in README.md rejected" $threw

# 2.5 Missing evidence repair / debug ledger in SKILL.md rejected (RED)
$threw = $false
try {
    $tamperedSkill = $canonicalSkill -replace '(?i)debug_ledger\.md', 'notas.txt' -replace '(?i)debug ledger', 'notas' -replace '(?i)reparo orientad[ao] a evid[e\u00ea]ncia', 'reparo comum' -replace '(?i)evidence-based repair', 'standard repair'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $tamperedSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.5 Missing evidence repair in SKILL.md rejected" $threw

# 2.6 Missing evidence repair / debug ledger in AGENTS.md rejected (RED)
$threw = $false
try {
    $tamperedAgents = $canonicalAgents -replace '(?i)debug_ledger\.md', 'notas.txt' -replace '(?i)debug ledger', 'notas' -replace '(?i)reparo orientad[ao] a evid[e\u00ea]ncia', 'reparo comum' -replace '(?i)evidence-based repair', 'standard repair'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $tamperedAgents -GeminiText $canonicalGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.6 Missing evidence repair in AGENTS.md rejected" $threw

# 2.7 Missing evidence repair / debug ledger in GEMINI.md rejected (RED)
$threw = $false
try {
    $tamperedGemini = $canonicalGemini -replace '(?i)debug_ledger\.md', 'notas.txt' -replace '(?i)debug ledger', 'notas' -replace '(?i)reparo orientad[ao] a evid[e\u00ea]ncia', 'reparo comum' -replace '(?i)evidence-based repair', 'standard repair'
    Assert-DeliveryReviewPolicy -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $tamperedGemini -ValidationText $canonicalValid -CommitText $canonicalCommit -QualityRatchetText $canonicalQuality -DelegationText $canonicalDelega -ReadmeText $canonicalReadme
} catch {
    $threw = $true
}
Assert-Test "2.7 Missing evidence repair in GEMINI.md rejected" $threw

# ===========================================================================
# GROUP 3: Test-CorrectionAdequacyGateSemantics (test-safe-profile-gate.ps1)
# ===========================================================================
Write-Host "`n-- 3. Test-CorrectionAdequacyGateSemantics (test-safe-profile-gate.ps1) --" -ForegroundColor Yellow

# 3.1 Canonical policies satisfy semantics
$result31 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.1 Canonical policies satisfy correction adequacy semantics" $result31

# 3.2 Stale max2 policy rejected (RED)
$staleDeliv32 = $canonicalDelivery + $nl + "$([char]0x00c9) permitido um m$([char]0x00e1)ximo de 2 rodadas de reparo."
$result32 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $staleDeliv32 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.2 Stale max2 policy rejected in adequacy gate semantics" (-not $result32)

# 3.3 Disguised numerical stopping rule rejected (RED)
$disguised33 = $canonicalDelivery + $nl + "O reparo possui um limite num$([char]0x00e9)rico fixo de 3 tentativas."
$result33 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $disguised33 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3 Disguised numerical stopping rule rejected in adequacy gate semantics" (-not $result33)

# 3.3b 'at most 2 rounds' in SKILL.md rejected (RED)
$staleSkill33b = $canonicalSkill + $nl + 'Repair allows at most 2 rounds.'
$result33b = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $staleSkill33b -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3b 'at most 2 rounds' in SKILL.md rejected in adequacy gate semantics" (-not $result33b)

# 3.3c 'maximum two' in SKILL.md rejected (RED)
$staleSkill33c = $canonicalSkill + $nl + 'Repair allows maximum two rounds.'
$result33c = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $staleSkill33c -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3c 'maximum two' in SKILL.md rejected in adequacy gate semantics" (-not $result33c)

# 3.3d Portuguese 'no máximo duas rodadas' in SKILL.md rejected (RED)
$staleSkill33d = $canonicalSkill + $nl + "no m$([char]0x00e1)ximo duas rodadas de reparo"
$result33d = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $staleSkill33d -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3d Portuguese 'no máximo duas rodadas' in SKILL.md rejected in adequacy gate semantics" (-not $result33d)

# 3.3e Stale max2 in validation.md rejected (RED)
$staleValid33e = $canonicalValid + $nl + 'at most 2 rounds'
$result33e = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $staleValid33e -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3e Stale max2 in validation.md rejected in adequacy gate semantics" (-not $result33e)

# 3.3f Stale max2 in commit.md rejected (RED)
$staleCommit33f = $canonicalCommit + $nl + 'at most 2 rounds'
$result33f = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $staleCommit33f -DelegationText $canonicalDelega
Assert-Test "3.3f Stale max2 in commit.md rejected in adequacy gate semantics" (-not $result33f)

# 3.3g Stale max2 in quality-ratchet.md rejected (RED)
$staleQuality33g = $canonicalQuality + $nl + 'at most 2 rounds'
$result33g = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $staleQuality33g -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3g Stale max2 in quality-ratchet.md rejected in adequacy gate semantics" (-not $result33g)

# 3.3h Stale max2 in delegation.md rejected (RED)
$staleDelega33h = $canonicalDelega + $nl + 'at most 2 rounds'
$result33h = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $staleDelega33h
Assert-Test "3.3h Stale max2 in delegation.md rejected in adequacy gate semantics" (-not $result33h)

# 3.3i Stale max2 in README.md rejected (RED)
$staleReadme33i = $canonicalReadme + $nl + 'at most 2 rounds'
$result33i = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $staleReadme33i -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.3i Stale max2 in README.md rejected in adequacy gate semantics" (-not $result33i)

# 3.4 Missing anti-loop hypothesis rejected (RED)
$tampered34 = $canonicalDelivery -replace '(?i)hip[o\u00f3]tes', 'suposic' -replace '(?i)hypothesis', 'guess'
$result34 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered34 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.4 Missing hypothesis rejected in adequacy gate semantics" (-not $result34)

# 3.5 Missing expected observation rejected (RED)
$tampered35 = $canonicalDelivery -replace '(?i)observa[c\u00e7][a\u00e3]o discriminante', 'resultado' -replace '(?i)discriminating observation', 'result'
$result35 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered35 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.5 Missing expected observation rejected in adequacy gate semantics" (-not $result35)

# 3.6 Missing observed delta rejected (RED)
$tampered36 = $canonicalDelivery -replace '(?i)delta observado', 'mudanca' -replace '(?i)observed delta', 'change'
$result36 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered36 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.6 Missing observed delta rejected in adequacy gate semantics" (-not $result36)

# 3.7 Missing next decision rejected (RED)
$tampered37 = $canonicalDelivery -replace '(?i)pr[o\u00f3]xima decis[a\u00e3]o', 'passo' -replace '(?i)next decision', 'step'
$result37 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered37 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.7 Missing next decision rejected in adequacy gate semantics" (-not $result37)

# 3.8 Missing different diagnostic direction rejected (RED)
$tampered38 = $canonicalDelivery -replace '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente', 'mesma' -replace '(?i)different diagnostic direction', 'same'
$result38 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered38 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.8 Missing different diagnostic direction rejected in adequacy gate semantics" (-not $result38)

# 3.9 Missing genuine authority boundary rejected (RED)
$tampered39 = $canonicalDelivery -replace '(?i)bloqueio genu[i\u00ed]no de', 'bloqueio arbitrario de'
$result39 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered39 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.9 Missing genuine authority boundary rejected in adequacy gate semantics" (-not $result39)

# 3.10 Minimum fix tamper rejected (preserves sufficient fix) (RED)
$minFixStr = 'corre' + [char]0x00e7 + [char]0x00e3 + 'o m' + [char]0x00ed + 'nima'
$tampered310 = $canonicalDelivery -replace '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel(?:/delimitada)?', $minFixStr
$result310 = Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tampered310 -QualityRatchetText $canonicalQuality -ValidationText $canonicalValid -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini -ReadmeText $canonicalReadme -CommitText $canonicalCommit -DelegationText $canonicalDelega
Assert-Test "3.10 Minimum fix tamper rejected (preserves sufficient fix)" (-not $result310)

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
    Write-Host "`nAll evidence-based repair validator tests passed deterministically." -ForegroundColor Green
    exit 0
}
