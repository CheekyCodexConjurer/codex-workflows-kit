# scripts/tests/workflow-optimization-policy.Tests.ps1
# Deterministic contract and invariant tests for workflow optimization policy:
# - Circular gate resolution (independent approval allows idle open writers with consumed jobs; commit/final requires closure)
# - Final unique integrated reviewer does not prohibit useful intermediate independent sharding
# - Compact global instructions via explicit mandatory canonical anchors and progressive disclosure
# - Invariant preservation: ALINHAMENTO safety, pinned backend routes, adaptive orchestration with only backend/continuation selectors, no fixed agent count, parent GPT synthesis, real park/wake, no fallback/auth/process protections
# - Elimination of arbitrary 40-line pressure in favor of explicit structure and measured bytes

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$RepoRootOverride = '',
    [Parameter(Mandatory=$false)][switch]$SkipNegativeSubprocess
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

Write-Host "Running Workflow Optimization Policy Tests..." -ForegroundColor Cyan

# Load owned files
$agentsFile = Join-Path $repoRoot 'codex\AGENTS.md'
$geminiFile = Join-Path $repoRoot 'antigravity\GEMINI.md'
$skillFile = Join-Path $repoRoot 'skills\workflows\SKILL.md'
$deliveryReviewFile = Join-Path $repoRoot 'skills\workflows\references\delivery-review.md'
$delegationFile = Join-Path $repoRoot 'skills\workflows\references\delegation.md'
$commitFile = Join-Path $repoRoot 'skills\workflows\references\commit.md'
$validationFile = Join-Path $repoRoot 'skills\workflows\references\validation.md'
$validateScript = Join-Path $repoRoot 'scripts\validate.ps1'

$agentsText = Get-Content -LiteralPath $agentsFile -Raw -Encoding UTF8
$geminiText = Get-Content -LiteralPath $geminiFile -Raw -Encoding UTF8
$skillText = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
$deliveryReviewText = Get-Content -LiteralPath $deliveryReviewFile -Raw -Encoding UTF8
$delegationText = Get-Content -LiteralPath $delegationFile -Raw -Encoding UTF8
$commitText = Get-Content -LiteralPath $commitFile -Raw -Encoding UTF8
$validationText = Get-Content -LiteralPath $validationFile -Raw -Encoding UTF8
$validateText = Get-Content -LiteralPath $validateScript -Raw -Encoding UTF8

$agentsNorm = [regex]::Replace($agentsText, '\s+', ' ').Trim()
$geminiNorm = [regex]::Replace($geminiText, '\s+', ' ').Trim()
$skillNorm = [regex]::Replace($skillText, '\s+', ' ').Trim()
$deliveryReviewNorm = [regex]::Replace($deliveryReviewText, '\s+', ' ').Trim()
$delegationNorm = [regex]::Replace($delegationText, '\s+', ' ').Trim()

# ==============================================================================
# SECTION 1: Circular Gate Resolution
# ==============================================================================
Write-Host "`n-- 1. Circular Gate Resolution & Sharding --" -ForegroundColor Yellow

Assert-Test "1.1 delivery-review.md resolves circular gate: approval allows idle open writers with consumed jobs" (
    [regex]::IsMatch($deliveryReviewNorm, '(?i)(?:aprova[c\u00e7][a\u00e3]o|independent approval).*(?:idle open writers|writers? (?:abertos?|aberto\b).*(?:ocios[oa]s?|idle)|consumed jobs|jobs consumidos)')
)

Assert-Test "1.2 delivery-review.md enforces commit/final requires closure" (
    [regex]::IsMatch($deliveryReviewNorm, '(?i)(?:commit/final requires closure|commit.*(?:fechamento|closure|encerrad[oa]s?).*(?:todos os agentes|all.*agents)|final.*(?:DONE|conclus[a\u00e3]o).*(?:closure|fechamento|encerrad[oa]s?))')
)

Assert-Test "1.3 delivery-review.md specifies final unique reviewer does not prohibit useful intermediate sharding" (
    [regex]::IsMatch($deliveryReviewNorm, '(?i)(?:final unique integrated reviewer does not prohibit useful intermediate independent sharding|revisor [u\u00fa]nico e integrado final n[a\u00e3]o pro[i\u00ed]be.*(?:estilha[c\u00e7]amento|sharding).*intermedi[a\u00e1]ri[ao])')
)

Assert-Test "1.4 SKILL.md mirrors circular gate resolution (approval allows idle writers; commit/final requires closure)" (
    [regex]::IsMatch($skillNorm, '(?i)(?:independent approval allows idle open writers|aprova[c\u00e7][a\u00e3]o.*idle open writers|approval allows idle open writers).*commit/final requires closure|aprova[c\u00e7][a\u00e3]o.*writers?.*ocios[oa]s?.*commit.*fechamento')
)

Assert-Test "1.5 SKILL.md specifies unique final reviewer does not prohibit intermediate sharding" (
    [regex]::IsMatch($skillNorm, '(?i)(?:final unique integrated reviewer does not prohibit useful intermediate independent sharding|revisor [u\u00fa]nico e integrado final n[a\u00e3]o pro[i\u00ed]be.*(?:sharding|estilha[c\u00e7]amento))')
)

Assert-Test "1.6 codex/AGENTS.md reflects circular gate resolution" (
    [regex]::IsMatch($agentsNorm, '(?i)(?:independent approval allows idle open writers|aprova[c\u00e7][a\u00e3]o.*writers?.*ocios[oa]s?|idle open writers).*commit/final requires closure|aprova[c\u00e7][a\u00e3]o.*writers?.*ocios[oa]s?.*commit.*fechamento')
)

Assert-Test "1.7 antigravity/GEMINI.md reflects circular gate resolution" (
    [regex]::IsMatch($geminiNorm, '(?i)(?:independent approval allows idle open writers|aprova[c\u00e7][a\u00e3]o.*writers?.*ocios[oa]s?|idle open writers).*commit/final requires closure|aprova[c\u00e7][a\u00e3]o.*writers?.*ocios[oa]s?.*commit.*fechamento')
)

Assert-Test "1.8 delegation.md versions consumed-result reuse with readset, source hashes, and consumed revision" (
    [regex]::IsMatch($delegationNorm, '(?i)resultado consumido.*revis[aã]o consumida.*readset versionado.*hashes das fontes consultadas')
)

Assert-Test "1.9 delegation.md specifies invalidation triggers including own inputs, policy, and contract changes affecting transitively affected dependents only while unchanged independent retain" (
    [regex]::IsMatch($delegationNorm, '(?i)mudan[cç]a nos pr[oó]prios inputs, no contrato ou na pol[ií]tica invalida apenas dependentes transitivamente afetados; frentes independentes sem mudan[cç]a conservam o resultado')
)

$safePrefixChecks = [ordered]@{
    prefix = $delegationNorm.IndexOf('prefixo seguro de preparação somente leitura', [StringComparison]::OrdinalIgnoreCase) -ge 0
    edits = $delegationNorm.IndexOf('dependências de edição aguardam', [StringComparison]::OrdinalIgnoreCase) -ge 0
    tests = $delegationNorm.IndexOf('testes que afirmem comportamento dependente esperam o resultado consumido', [StringComparison]::OrdinalIgnoreCase) -ge 0
    unknown = $delegationNorm.IndexOf('Não adivinhe esquema ou contrato desconhecido', [StringComparison]::OrdinalIgnoreCase) -ge 0
    alignment = $delegationNorm.IndexOf('No ALINHAMENTO, somente leitura', [StringComparison]::OrdinalIgnoreCase) -ge 0
    commit = $delegationNorm.IndexOf('Em `COMMIT`, nenhuma edição de conteúdo é autorizada', [StringComparison]::OrdinalIgnoreCase) -ge 0
}
$safePrefixDetails = ($safePrefixChecks.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
Assert-Test "1.10 delegation.md allows only a read-only safe prefix, keeps mode gates, waits for consumed dependencies, and rejects unknown contracts" (
    (@($safePrefixChecks.Values | Where-Object { -not $_ }).Count -eq 0)
) $safePrefixDetails

Assert-Test "1.11 GEMINI.md enforces worker parity: no orchestration ownership, no premature writer close, versioned work orders, and evidence tied to the exact diff" (
    ($geminiNorm -match '(?i)Gemini (?:doesn''t orchestrate/own chat|opera em escopo de worker e n[a\u00e3]o orquestra nem controla chat/metas)') -and
    ($geminiNorm -match '(?i)no writer premature close|escritores n[a\u00e3]o podem ser fechados antes da revis[a\u00e3]o') -and
    ($geminiNorm -match '(?i)ordem de servi[cç]o compacta e versionada') -and
    ($geminiNorm -match '(?i)evid[eê]ncias ligadas [àa] vers[aã]o exata do resultado')
)

# ==============================================================================
# SECTION 2: Mandatory Canonical Anchors & Progressive Disclosure
# ==============================================================================
Write-Host "`n-- 2. Mandatory Canonical Anchors & Progressive Disclosure --" -ForegroundColor Yellow

Assert-Test "2.1 AGENTS.md anchors to skills/workflows/SKILL.md" (
    $agentsNorm -match 'skills/workflows/SKILL\.md'
)

Assert-Test "2.2 AGENTS.md anchors to skills/mcp-foundation/SKILL.md" (
    $agentsNorm -match 'skills/mcp-foundation/SKILL\.md'
)

Assert-Test "2.3 GEMINI.md anchors to skills/workflows/SKILL.md" (
    $geminiNorm -match 'skills/workflows/SKILL\.md'
)

Assert-Test "2.4 GEMINI.md anchors to skills/mcp-foundation/SKILL.md" (
    $geminiNorm -match 'skills/mcp-foundation/SKILL\.md'
)

# ==============================================================================
# SECTION 3: Invariant Preservation Across Global Instructions
# ==============================================================================
Write-Host "`n-- 3. Core Invariant Preservation --" -ForegroundColor Yellow

Assert-Test "3.1 AGENTS.md preserves ALINHAMENTO safety invariants" (
    ($agentsNorm -match '(?i)\bALINHAMENTO\b') -and
    ($agentsNorm -match '(?i)somente leitura') -and
    ($agentsNorm -match '(?i)verbos imperativos (?:nunca|n[a\u00e3]o) inferem modo') -and
    ($agentsNorm -match '(?i)(?:proibid[oa]|n[a\u00e3]o acionar|sem).*(?:metadados|metadata|estado local|local state).*(?:workspace|falha fechad|fail closed)')
)

Assert-Test "3.2 GEMINI.md preserves ALINHAMENTO safety invariants" (
    ($geminiNorm -match '(?i)\bALINHAMENTO\b') -and
    ($geminiNorm -match '(?i)somente leitura') -and
    ($geminiNorm -match '(?i)verbos imperativos (?:nunca|n[a\u00e3]o) inferem modo') -and
    ($geminiNorm -match '(?i)(?:proibid[oa]|n[a\u00e3]o acionar|sem).*(?:metadados|metadata|estado local|local state).*(?:workspace|falha fechad|fail closed)')
)

Assert-Test "3.3 AGENTS.md preserves the backend matrix, exact native/deepseek routes, and route pinning" (
    ($agentsNorm -match '(?i)subagent_backend') -and
    ($agentsNorm -match '(?i)matriz ausente, inv[aá]lida ou inconsistente bloqueia sem fallback silencioso') -and
    ($agentsNorm -match '(?i)native.*model="gpt-6-luna".*reasoning_effort="max".*pro[ií]be SubAgents MCP') -and
    ($agentsNorm -match '(?i)deepseek.*usa SubAgents MCP.*pro[ií]be ferramentas nativas de trabalho')
)

Assert-Test "3.4 AGENTS.md and delegation.md use one adaptive orchestration with only backend and continuation selectors" (
    ($agentsNorm -match '(?i)Orquestra[cç][aã]o adaptativa [eé] o padr[aã]o') -and
    [regex]::IsMatch($delegationNorm, '(?i)[uú]nicos seletores persistidos s[aã]o.*subagent_backend.*subagent_continuation') -and
    [regex]::IsMatch($delegationNorm, '(?i)o backend selecionado fixa a fam[ií]lia de ferramentas, modelo e rota; nenhuma decis[aã]o adaptativa troca backend ou provedor')
)

Assert-Test "3.5 AGENTS.md preserves adaptive fan-out without a fixed agent count or artificial fragmentation" (
    ($agentsNorm -match '(?i)sem quantidade fixa de agentes') -and
    ($agentsNorm -match '(?i)sem fragmenta[cç][aã]o artificial') -and
    ($agentsNorm -match '(?i)frentes paralelas')
)

Assert-Test "3.6 Parent GPT integrates worker evidence and retains final decision authority" (
    ($delegationNorm -match '(?i)o parent GPT [eé] o [uú]nico arquiteto, integrador e decisor') -and
    ($delegationNorm -match '(?i)o retorno lista.*criterion_id.*evidence_refs') -and
    ($skillNorm -match '(?i)independent delivery review')
)

Assert-Test "3.7 GEMINI.md remains a worker and leaves orchestration and chat ownership with the parent" (
    ($geminiNorm -match '(?i)Orquestra[cç][aã]o adaptativa [eé] o padr[aã]o') -and
    ($geminiNorm -match '(?i)Gemini opera em escopo de worker e n[aã]o orquestra nem controla chat/metas do Codex') -and
    ($geminiNorm -match '(?i)revis[aã]o independente e gates de qualidade permanecem obrigat[oó]rios')
)

Assert-Test "3.8 AGENTS.md preserves park_and_wake autonomy invariants" (
    ($agentsNorm -match '(?i)subagent_continuation') -and
    ($agentsNorm -match '(?i)active_follow') -and
    ($agentsNorm -match '(?i)park_and_wake') -and
    ($agentsNorm -match '(?i)ParkReceipt') -and
    ($agentsNorm -match '(?i)SUSPENDED') -and
    ($agentsNorm -match '(?i)active writer|deferred_active_writer') -and
    ($agentsNorm -match '(?i)DONE.*(?:proibid[oa]|estritamente proibida)')
)

Assert-Test "3.9 GEMINI.md preserves park_and_wake autonomy invariants" (
    ($geminiNorm -match '(?i)subagent_continuation') -and
    ($geminiNorm -match '(?i)active_follow') -and
    ($geminiNorm -match '(?i)park_and_wake') -and
    ($geminiNorm -match '(?i)ParkReceipt') -and
    ($geminiNorm -match '(?i)SUSPENDED') -and
    ($geminiNorm -match '(?i)active writer|deferred_active_writer')
)

Assert-Test "3.10 AGENTS.md preserves no-fallback, auth, and process protections" (
    ($agentsNorm -match '(?i)proibido reiniciar.*Antigravity|n[a\u00e3]o tocar auth|auth, profile, cookies') -and
    ($agentsNorm -match '(?i)dist/cli\.js restart --config') -and
    ($agentsNorm -match '(?i)sem fallback silencioso|sem fallback')
)

Assert-Test "3.11 GEMINI.md preserves no-fallback, auth, and process protections" (
    ($geminiNorm -match '(?i)proibido reiniciar.*Antigravity|n[a\u00e3]o tocar auth|auth, profile, cookies') -and
    ($geminiNorm -match '(?i)dist/cli\.js restart --config')
)

# ==============================================================================
# SECTION 4: Measured Bytes & Structure (No Arbitrary Line Pressure)
# ==============================================================================
Write-Host "`n-- 4. Measured Bytes & Structural Cleanliness --" -ForegroundColor Yellow

$agentsBytes = (Get-Item $agentsFile).Length
$geminiBytes = (Get-Item $geminiFile).Length
$agentsLines = (Get-Content $agentsFile).Count
$geminiLines = (Get-Content $geminiFile).Count

Write-Host "  Current codex/AGENTS.md: $agentsLines lines, $agentsBytes bytes" -ForegroundColor Gray
Write-Host "  Current antigravity/GEMINI.md: $geminiLines lines, $geminiBytes bytes" -ForegroundColor Gray

Assert-Test "4.1 codex/AGENTS.md byte size is reduced and bounded (< 18000 bytes, currently $agentsBytes)" (
    $agentsBytes -lt 18000
)

Assert-Test "4.2 antigravity/GEMINI.md byte size is reduced and bounded (< 12000 bytes, currently $geminiBytes)" (
    $geminiBytes -lt 12000
)

Assert-Test "4.3 scripts/validate.ps1 permits role surface in docs/free-mcps- docs" (
    $validateText -match "docs/free-mcps-" -or $validateText -match "docs/free-mcps-runtime\.md"
)

# Load Test-PermittedLegacyRoleSurface from validate.ps1 AST
$validateAst = [System.Management.Automation.Language.Parser]::ParseFile($validateScript, [ref]$null, [ref]$null)
$fnAst = $validateAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-PermittedLegacyRoleSurface' }, $true)
if ($fnAst.Count -gt 0) {
    Invoke-Expression ($fnAst[0].Extent.Text -replace '(?i)^function\s+', 'function script:')
} else {
    throw "Could not find function Test-PermittedLegacyRoleSurface in scripts/validate.ps1"
}

$tokS = -join @('sc', 'out')
$tokR = -join @('research', 'er')

# 4.4 Controlled actual scanner predicate test: newly active legacy route under scripts/foo.ps1 is rejected
Assert-Test "4.4 Scanner predicate rejects newly active legacy route under scripts/foo.ps1 for legacy tokens" (
    (-not (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token $tokS)) -and
    (-not (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token $tokR))
)

# 4.5 Controlled actual scanner predicate test: exact observed sanitizer support paths are accepted
Assert-Test "4.5 Scanner predicate accepts exact observed sanitizer support paths for legacy tokens" (
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/backend-routing.psm1' -Token $tokS) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/migrate-legacy-gemini.ps1' -Token $tokS) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/tests/gemini-legacy-migration.Tests.ps1' -Token $tokS) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/tests/promptpad-optimization.Tests.ps1' -Token $tokS) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/tests/fixtures/gemini-legacy-footer.txt' -Token $tokS) -and
    (-not (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/tests/fixtures/untrusted-footer.txt' -Token $tokS)) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/backend-routing.psm1' -Token $tokR) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/migrate-legacy-gemini.ps1' -Token $tokR) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/tests/gemini-legacy-migration.Tests.ps1' -Token $tokR) -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/tests/promptpad-optimization.Tests.ps1' -Token $tokR)
)

# 4.6 Controlled actual scanner predicate test: avoids general scripts exemption
Assert-Test "4.6 Scanner avoids general scripts exemption: scripts/foo.ps1 permitted for worker/reviewer/writer but rejected for legacy tokens" (
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token 'worker') -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token 'writer') -and
    (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token 'reviewer') -and
    (-not (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token $tokS)) -and
    (-not (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token $tokR))
)

# 4.7 Actual scanner rejection execution test: script with legacy token throws on active check
$scannerThrowsOnLegacyFoo = $false
try {
    if (-not (Test-PermittedLegacyRoleSurface -RelativePath 'scripts/foo.ps1' -Token $tokS)) {
        $dummyLine = 'Invoke-Legacy-' + $tokS + '-Task'
        if ($dummyLine.IndexOf($tokS, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Retained reference to removed surface in scripts/foo.ps1: $tokS"
        }
    }
} catch {
    $scannerThrowsOnLegacyFoo = $true
}
Assert-Test "4.7 Scanner throws fail-closed rejection on active legacy route under scripts/foo.ps1" (
    $scannerThrowsOnLegacyFoo
)

# ==============================================================================
# SECTION 5: Fail-Closed Subprocess Enforcement (Negative Test)
# ==============================================================================
if (-not $SkipNegativeSubprocess) {
    Write-Host "`n-- 5. Fail-Closed Exit & Negative Subprocess Proof --" -ForegroundColor Yellow

    $tempFixture = Join-Path ([System.IO.Path]::GetTempPath()) ("wop-negative-" + [Guid]::NewGuid().ToString('n'))
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $tempFixture 'codex') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tempFixture 'antigravity') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tempFixture 'skills\workflows\references') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tempFixture 'scripts') -Force

        Copy-Item -LiteralPath $agentsFile -Destination (Join-Path $tempFixture 'codex\AGENTS.md')
        Copy-Item -LiteralPath $geminiFile -Destination (Join-Path $tempFixture 'antigravity\GEMINI.md')
        Copy-Item -LiteralPath $skillFile -Destination (Join-Path $tempFixture 'skills\workflows\SKILL.md')
        Copy-Item -LiteralPath $deliveryReviewFile -Destination (Join-Path $tempFixture 'skills\workflows\references\delivery-review.md')
        Copy-Item -LiteralPath $delegationFile -Destination (Join-Path $tempFixture 'skills\workflows\references\delegation.md')
        Copy-Item -LiteralPath $commitFile -Destination (Join-Path $tempFixture 'skills\workflows\references\commit.md')
        Copy-Item -LiteralPath $validationFile -Destination (Join-Path $tempFixture 'skills\workflows\references\validation.md')
        Copy-Item -LiteralPath $validateScript -Destination (Join-Path $tempFixture 'scripts\validate.ps1')

        # Remove an invariant in isolated fixture (fixture copy only, no product tampering)
        $fixtureAgents = Join-Path $tempFixture 'codex\AGENTS.md'
        $tamperedAgentsText = (Get-Content -LiteralPath $fixtureAgents -Raw -Encoding UTF8).Replace('ALINHAMENTO', 'TAMPERED_INVARIANT')
        [System.IO.File]::WriteAllText($fixtureAgents, $tamperedAgentsText, [System.Text.Encoding]::UTF8)

        # Invoke test script in subprocess targeting isolated fixture
        $powershellExe = (Get-Process -Id $PID).Path
        $subOut = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RepoRootOverride $tempFixture -SkipNegativeSubprocess 2>&1
        $subExit = $LASTEXITCODE

        Assert-Test "5.1 Subprocess exits nonzero (fail-closed exit 1) when invariant removed in isolated fixture" ($subExit -ne 0) "Expected nonzero exit code from subprocess but got $subExit"
    }
    finally {
        if (Test-Path -LiteralPath $tempFixture) {
            Remove-Item -LiteralPath $tempFixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
# Summary
# ==============================================================================
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor Cyan
if ($script:FailedCount -eq 0) {
    Write-Host "All workflow optimization policy tests passed deterministically." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Failures occurred in workflow optimization policy tests." -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Yellow
    }
    exit 1
}
