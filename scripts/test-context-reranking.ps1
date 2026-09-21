# scripts/test-context-reranking.ps1
# Deterministic contract and unit tests for TypeSafe/Jev Context Reranker.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$modulePath = Join-Path $repoRoot 'skills\workflows\scripts\context-reranking.psm1'
$rerankScript = Join-Path $repoRoot 'skills\workflows\scripts\rerank-context.ps1'
$rgAdapterScript = Join-Path $repoRoot 'skills\workflows\scripts\select-context-from-rg.ps1'
$workflowSkill = Join-Path $repoRoot 'skills\workflows\SKILL.md'
$contextRerankRef = Join-Path $repoRoot 'skills\workflows\references\context-reranking.md'

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

function Test-ScriptThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Block,
        [Parameter(Mandatory = $false)][string]$ExpectedMessagePattern = ''
    )

    try {
        $null = & $Block
        return $false
    }
    catch {
        if ($ExpectedMessagePattern) {
            return ($_.Exception.Message -match $ExpectedMessagePattern)
        }
        return $true
    }
}

Write-Host 'Running TypeSafe/Jev Context Reranker Tests...' -ForegroundColor Cyan

# ---------------------------------------------------------
# 1. Existence and Documentation Assertions
# ---------------------------------------------------------
Assert-Test 'context-reranking.psm1 module exists' (Test-Path -LiteralPath $modulePath -PathType Leaf)
Assert-Test 'rerank-context.ps1 exists' (Test-Path -LiteralPath $rerankScript -PathType Leaf)
Assert-Test 'select-context-from-rg.ps1 exists' (Test-Path -LiteralPath $rgAdapterScript -PathType Leaf)
Assert-Test 'context-reranking.md reference documentation exists' (Test-Path -LiteralPath $contextRerankRef -PathType Leaf)

$skillText = Get-Content -LiteralPath $workflowSkill -Raw -Encoding UTF8
Assert-Test 'workflows SKILL.md documents context-reranking' ($skillText -match '(?i)context reranking')
Assert-Test 'workflows SKILL.md links to references/context-reranking.md' ($skillText -match 'references/context-reranking\.md')

# Import module for unit tests
Import-Module -Name $modulePath -Force

# ---------------------------------------------------------
# 2. Candidate Data Model & Schema Validation
# ---------------------------------------------------------
$c1 = New-ContextCandidate -Source 'rg' -SourceRef 'src/auth.js' -Content 'function authenticate() {}' -LineStart 10 -LineEnd 20 -OriginalRank 1
Assert-Test 'New-ContextCandidate computes valid candidate structure' (Test-ContextCandidate -Candidate $c1)
Assert-Test 'New-ContextCandidate generates deterministic sha256 id prefixed with cand:' ($c1.id -match '^cand:[a-f0-9]{16}$')
Assert-Test 'New-ContextCandidate normalizes backslashes in SourceRef' ($c1.source_ref -eq 'src/auth.js')
Assert-Test 'New-ContextCandidate creates initial provenance entry' ($c1.provenances.Count -eq 1 -and $c1.provenances[0].source -eq 'rg')

$customId = New-ContextCandidate -Source 'rg' -SourceRef 'src/auth.js' -Content 'code' -Id 'custom-id-123'
Assert-Test 'New-ContextCandidate preserves explicit ID' ($customId.id -eq 'custom-id-123')

$invalidCand = [ordered]@{ id = 'c1'; source = 'rg' }
Assert-Test 'Test-ContextCandidate rejects candidate missing required fields' (-not (Test-ContextCandidate -Candidate $invalidCand))

$emptyRefCand = [ordered]@{ id = 'c1'; source = 'rg'; source_ref = '  '; repository_scope = 'repo'; representation = 'snippet'; content = 'x' }
Assert-Test 'Test-ContextCandidate rejects empty source_ref' (-not (Test-ContextCandidate -Candidate $emptyRefCand))

# ---------------------------------------------------------
# 3. Reparse Path Containment & Path Safety
# ---------------------------------------------------------
Assert-Test 'Assert-CandidatePathContainment accepts valid repo-relative path' (
    (Assert-CandidatePathContainment -RepoPath $repoRoot -RelativePath 'skills/workflows/SKILL.md') -eq 'skills/workflows/SKILL.md'
)

Assert-Test 'Assert-CandidatePathContainment rejects rooted path' (
    Test-ScriptThrows { Assert-CandidatePathContainment -RepoPath $repoRoot -RelativePath 'C:\Windows\System32\calc.exe' } 'rooted'
)

Assert-Test 'Assert-CandidatePathContainment rejects upward traversal ..' (
    Test-ScriptThrows { Assert-CandidatePathContainment -RepoPath $repoRoot -RelativePath 'skills/../../secrets.txt' } 'canonical'
)

Assert-Test 'Assert-CandidatePathContainment rejects path with colon' (
    Test-ScriptThrows { Assert-CandidatePathContainment -RepoPath $repoRoot -RelativePath 'foo:bar.txt' } 'canonical'
)

# ---------------------------------------------------------
# 4. Secret & Token Detection (Test-CandidateSafety)
# ---------------------------------------------------------
$safeCheck = Test-CandidateSafety -SourceRef 'src/service.ts' -Content 'const port = 8080;'
Assert-Test 'Safe source file passes Test-CandidateSafety' ($safeCheck.Safe -eq $true)

$envCheck = Test-CandidateSafety -SourceRef '.env' -Content 'API_KEY=123'
Assert-Test '.env filename is rejected by Test-CandidateSafety' ($envCheck.Safe -eq $false -and $envCheck.Reason -eq 'path_matches_secret_pattern')

$envExampleCheck = Test-CandidateSafety -SourceRef '.env.example' -Content 'API_KEY='
Assert-Test '.env.example filename is permitted by Test-CandidateSafety' ($envExampleCheck.Safe -eq $true)

$pemCheck = Test-CandidateSafety -SourceRef 'certs/server.pem' -Content 'certificate'
Assert-Test '.pem certificate filename is rejected' ($pemCheck.Safe -eq $false)

$rsaCheck = Test-CandidateSafety -SourceRef '.ssh/id_rsa' -Content 'keys'
Assert-Test 'id_rsa filename is rejected' ($rsaCheck.Safe -eq $false)

$privKeyContent = "-----BEGIN RSA PRIVATE KEY-----`nMIIEowIBAAKCAQEA0`n-----END RSA PRIVATE KEY-----"
$keyCheck = Test-CandidateSafety -SourceRef 'safe.txt' -Content $privKeyContent
Assert-Test 'Private key content signature is rejected' ($keyCheck.Safe -eq $false -and $keyCheck.Reason -eq 'content_contains_private_key')

$skCheck = Test-CandidateSafety -SourceRef 'safe.txt' -Content 'const key = "sk-1234567890123456789012";'
Assert-Test 'OpenAI/TypeSafe API token pattern is rejected' ($skCheck.Safe -eq $false -and $skCheck.Reason -eq 'content_contains_secret_token')

$ghpCheck = Test-CandidateSafety -SourceRef 'safe.txt' -Content 'const gh = "ghp_123456789012345678901234567890";'
Assert-Test 'GitHub PAT token pattern is rejected' ($ghpCheck.Safe -eq $false)

$akiaCheck = Test-CandidateSafety -SourceRef 'safe.txt' -Content 'const aws = "AKIAIOSFODNN7EXAMPLE";'
Assert-Test 'AWS Access Key pattern is rejected' ($akiaCheck.Safe -eq $false)

$codexConfigCheck = Test-CandidateSafety -SourceRef '.codex/config.toml' -Content 'setting=1'
Assert-Test '.codex profile path is rejected' ($codexConfigCheck.Safe -eq $false)

# ---------------------------------------------------------
# 5. Exact Deduplication and Provenance Merging
# ---------------------------------------------------------
$candDup1 = New-ContextCandidate -Source 'rg' -SourceRef 'src/index.ts' -Content 'console.log("hello");' -LineStart 1 -LineEnd 1 -OriginalRank 1 -Id 'cand:exact'
$candDup2 = New-ContextCandidate -Source 'symbol_search' -SourceRef 'src/index.ts' -Content 'console.log("hello");' -LineStart 1 -LineEnd 1 -OriginalRank 3 -Id 'cand:exact'
$opt = Optimize-CandidateSet -Candidates @($candDup1, $candDup2)

Assert-Test 'Optimize-CandidateSet coalesces identical candidates' ($opt.UniqueCandidates.Count -eq 1)
Assert-Test 'Optimize-CandidateSet records duplicate count' ($opt.DuplicatesCount -eq 1)
Assert-Test 'Optimize-CandidateSet merges provenances' ($opt.UniqueCandidates[0].provenances.Count -eq 2)
Assert-Test 'Optimize-CandidateSet preserves all distinct source tools in provenances' (
    ($opt.UniqueCandidates[0].provenances[0].source -eq 'rg') -and
    ($opt.UniqueCandidates[0].provenances[1].source -eq 'symbol_search')
)

# Differing content with same ID triggers collision throw
$candConflict = New-ContextCandidate -Source 'rg' -SourceRef 'src/index.ts' -Content 'console.log("conflicting");' -LineStart 1 -LineEnd 1 -Id 'cand:exact'
Assert-Test 'Optimize-CandidateSet rejects conflicting content with identical ID' (
    Test-ScriptThrows { Optimize-CandidateSet -Candidates @($candDup1, $candConflict) } 'conflicting content'
)

# ---------------------------------------------------------
# 6. TypeSafe / Jev Batch Client Mocking (Invoke-JevRerankBatch)
# ---------------------------------------------------------
$mockCandidates = @(
    (New-ContextCandidate -Source 'rg' -SourceRef 'a.ts' -Content 'line a' -Id 'ca'),
    (New-ContextCandidate -Source 'rg' -SourceRef 'b.ts' -Content 'line b' -Id 'cb')
)

$recordedRequests = [System.Collections.Generic.List[object]]::new()
$mockTransport = {
    param($req)
    $recordedRequests.Add($req)
    return [ordered]@{
        model = 'jev-mock-v1'
        answers = [ordered]@{
            q_0 = [ordered]@{ noul = 0.92 }
            q_1 = [ordered]@{ noul = 0.35 }
        }
    }
}

$evalResult = Invoke-JevRerankBatch `
    -TaskObjective 'Find service implementations' `
    -Candidates $mockCandidates `
    -BatchSize 10 `
    -HttpTransportMock $mockTransport

Assert-Test 'Invoke-JevRerankBatch executes mock transport' ($recordedRequests.Count -eq 1)
Assert-Test 'Invoke-JevRerankBatch formats noul question criteria' (
    $recordedRequests[0].BodyObject.questions.q_0.type -eq 'noul' -and
    $recordedRequests[0].BodyObject.questions.q_0.criteria.true -match 'directly relevant'
)
Assert-Test 'Invoke-JevRerankBatch parses answer scores' (
    $evalResult.Scores['ca'].Score -eq 0.92 -and
    $evalResult.Scores['cb'].Score -eq 0.35
)
Assert-Test 'Invoke-JevRerankBatch records returned model' ($evalResult.Model -eq 'jev-mock-v1')
Assert-Test 'Invoke-JevRerankBatch reports ServiceUnavailable=false on success' ($evalResult.ServiceUnavailable -eq $false)

# Test Batch Chunking
$chunkCandidates = @(
    (New-ContextCandidate -Source 'rg' -SourceRef '1.ts' -Content 'c1' -Id 'c1'),
    (New-ContextCandidate -Source 'rg' -SourceRef '2.ts' -Content 'c2' -Id 'c2'),
    (New-ContextCandidate -Source 'rg' -SourceRef '3.ts' -Content 'c3' -Id 'c3')
)
$chunkRequests = [System.Collections.Generic.List[object]]::new()
$chunkTransport = {
    param($req)
    $chunkRequests.Add($req)
    return [ordered]@{
        model = 'jev-latest'
        answers = [ordered]@{
            q_0 = [ordered]@{ noul = 0.8 }
            q_1 = [ordered]@{ noul = 0.8 }
        }
    }
}

$null = Invoke-JevRerankBatch `
    -TaskObjective 'Task' `
    -Candidates $chunkCandidates `
    -BatchSize 2 `
    -HttpTransportMock $chunkTransport

Assert-Test 'Invoke-JevRerankBatch splits 3 candidates into 2 requests when BatchSize=2' ($chunkRequests.Count -eq 2)

# Test Transport Failure Fallback
$failingTransport = {
    param($req)
    throw "HTTP 503 Service Unavailable"
}
$failResult = Invoke-JevRerankBatch `
    -TaskObjective 'Task' `
    -Candidates $mockCandidates `
    -HttpTransportMock $failingTransport

Assert-Test 'Transport failure reports ServiceUnavailable=true' ($failResult.ServiceUnavailable -eq $true)
Assert-Test 'Transport failure marks candidate scores as null with service_unavailable status' (
    $failResult.Scores['ca'].Score -eq $null -and
    $failResult.Scores['ca'].Status -eq 'service_unavailable'
)

# ---------------------------------------------------------
# 7. Threshold Classification & Budget Packaging (Select-ContextPackage)
# ---------------------------------------------------------
$evals = @{
    'c_keep'  = [ordered]@{ Score = 0.85; Status = 'ok' }
    'c_maybe' = [ordered]@{ Score = 0.55; Status = 'ok' }
    'c_drop'  = [ordered]@{ Score = 0.25; Status = 'ok' }
}

$pkgCandidates = @(
    (New-ContextCandidate -Source 'rg' -SourceRef 'keep.ts' -Content 'code keep' -Id 'c_keep' -OriginalRank 1),
    (New-ContextCandidate -Source 'rg' -SourceRef 'maybe.ts' -Content 'code maybe' -Id 'c_maybe' -OriginalRank 2),
    (New-ContextCandidate -Source 'rg' -SourceRef 'drop.ts' -Content 'code drop' -Id 'c_drop' -OriginalRank 3)
)

$pkg = Select-ContextPackage `
    -Candidates $pkgCandidates `
    -Evaluations $evals `
    -KeepThreshold 0.70 `
    -MaybeThreshold 0.40 `
    -MaxBudgetBytes 10000

Assert-Test 'Select-ContextPackage admits KEEP candidate into selected' (
    @($pkg.selected | Where-Object { $_.id -eq 'c_keep' }).Count -eq 1
)
Assert-Test 'Select-ContextPackage admits MAYBE candidate into selected when budget allows' (
    @($pkg.selected | Where-Object { $_.id -eq 'c_maybe' }).Count -eq 1
)
Assert-Test 'Select-ContextPackage excludes DROP candidate from selected' (
    @($pkg.selected | Where-Object { $_.id -eq 'c_drop' }).Count -eq 0
)
Assert-Test 'Select-ContextPackage records DROP candidate in manifest with low_relevance' (
    ($pkg.manifest | Where-Object { $_.id -eq 'c_drop' }).exclusion_reason -eq 'low_relevance'
)

# Test PINNED Candidate Behavior
$pinnedPkg = Select-ContextPackage `
    -Candidates $pkgCandidates `
    -Evaluations $evals `
    -PinnedIds @('c_drop') `
    -KeepThreshold 0.70 `
    -MaybeThreshold 0.40

Assert-Test 'PINNED candidate is admitted into selected regardless of low score' (
    @($pinnedPkg.selected | Where-Object { $_.id -eq 'c_drop' -and $_.decision -eq 'PINNED' }).Count -eq 1
)

# Test Pinned Overflow Triggers budget_exceeded
$overflowCand = New-ContextCandidate -Source 'rg' -SourceRef 'big.ts' -Content ('A' * 2000) -Id 'c_big'
$overflowPkg = Select-ContextPackage `
    -Candidates @($overflowCand) `
    -Evaluations @{} `
    -PinnedIds @('c_big') `
    -MaxBudgetBytes 1000

Assert-Test 'Pinned content exceeding MaxBudgetBytes returns status=budget_exceeded' (
    $overflowPkg.status -eq 'budget_exceeded'
)
Assert-Test 'budget_exceeded returns empty selected array' ($overflowPkg.selected.Count -eq 0)
Assert-Test 'budget_exceeded records pinned items in manifest with budget_exceeded_by_pinned' (
    $overflowPkg.manifest[0].exclusion_reason -eq 'budget_exceeded_by_pinned'
)

# Test Budget Deferral for Non-Pinned Candidates
$budgetTestCandidates = @(
    (New-ContextCandidate -Source 'rg' -SourceRef 'b1.ts' -Content ('A' * 400) -Id 'b1' -OriginalRank 1),
    (New-ContextCandidate -Source 'rg' -SourceRef 'b2.ts' -Content ('B' * 400) -Id 'b2' -OriginalRank 2)
)
$budgetEvals = @{
    'b1' = [ordered]@{ Score = 0.90; Status = 'ok' }
    'b2' = [ordered]@{ Score = 0.85; Status = 'ok' }
}

$smallBudgetPkg = Select-ContextPackage `
    -Candidates $budgetTestCandidates `
    -Evaluations $budgetEvals `
    -KeepThreshold 0.70 `
    -MaybeThreshold 0.40 `
    -MaxBudgetBytes 600

Assert-Test 'Candidate exceeding remaining budget is deferred to manifest with budget_deferred' (
    @($smallBudgetPkg.manifest | Where-Object { $_.exclusion_reason -eq 'budget_deferred' }).Count -ge 1
)

# Test Count Cap Enforcement
$countCapPkg = Select-ContextPackage `
    -Candidates $pkgCandidates `
    -Evaluations $evals `
    -KeepThreshold 0.70 `
    -MaybeThreshold 0.40 `
    -MaxSelectedCandidates 1

Assert-Test 'MaxSelectedCandidates caps selected count' ($countCapPkg.selected.Count -eq 1)
Assert-Test 'Excess candidate recorded in manifest with count_limit_exceeded' (
    @($countCapPkg.manifest | Where-Object { $_.exclusion_reason -eq 'count_limit_exceeded' }).Count -eq 1
)

# ---------------------------------------------------------
# 8. Privacy Authorization Boundary in rerank-context.ps1
# ---------------------------------------------------------
$candSecTest = New-ContextCandidate -Source 'rg' -SourceRef 'src/test.js' -Content 'const x = 1;' -Id 'ct1'

# PrivacyScope = 'none' without -AuthorizeContentTransmission
$unauthResult = & $rerankScript `
    -Candidates @($candSecTest) `
    -Policy advisory `
    -PrivacyScope 'none' `
    -WorkingDir $repoRoot

Assert-Test 'Unauthorized transmission returns status=skipped_privacy_unauthorized' (
    $unauthResult.status -eq 'skipped_privacy_unauthorized'
)
Assert-Test 'Unauthorized transmission safely selects candidate locally without external HTTP calls' (
    $unauthResult.selected.Count -eq 1 -and
    $unauthResult.metrics.requests_made -eq 0
)

# Policy = 'off'
$offResult = & $rerankScript `
    -Candidates @($candSecTest) `
    -Policy off `
    -WorkingDir $repoRoot

Assert-Test "policy 'off' returns status=skipped_policy_off" ($offResult.status -eq 'skipped_policy_off')
Assert-Test "policy 'off' marks candidates as UNROUTED" ($offResult.selected[0].decision -eq 'UNROUTED')
Assert-Test "policy 'off' makes 0 requests" ($offResult.metrics.requests_made -eq 0)

# Pipeline Stdin Support
$pipeCand = New-ContextCandidate -Source 'rg' -SourceRef 'src/test.js' -Content 'const y = 2;' -Id 'ct2'
$pipeResult = @($pipeCand) | & $rerankScript -Policy off -WorkingDir $repoRoot
Assert-Test 'rerank-context.ps1 accepts candidates via pipeline stdin' ($pipeResult.metrics.candidates_received -eq 1)

# JSON Input Support
$jsonStr = @($pipeCand) | ConvertTo-Json -Depth 5
$jsonResult = & $rerankScript -CandidatesJson $jsonStr -Policy off -WorkingDir $repoRoot
Assert-Test 'rerank-context.ps1 accepts candidates via -CandidatesJson' ($jsonResult.metrics.candidates_received -eq 1)

# Parameter Validation
Assert-Test 'rerank-context.ps1 rejects MaybeThreshold > KeepThreshold' (
    Test-ScriptThrows { & $rerankScript -KeepThreshold 0.40 -MaybeThreshold 0.70 } 'less than or equal'
)
Assert-Test 'rerank-context.ps1 rejects BatchSize = 0' (
    Test-ScriptThrows { & $rerankScript -BatchSize 0 }
)
Assert-Test 'rerank-context.ps1 rejects MaxBudgetBytes < 512' (
    Test-ScriptThrows { & $rerankScript -MaxBudgetBytes 200 }
)

# ---------------------------------------------------------
# 9. End-to-End Ripgrep Adapter (select-context-from-rg.ps1)
# ---------------------------------------------------------
$mockRgJsonLines = @(
    '{"type":"begin","data":{"path":{"text":"src/app.py"}}}',
    '{"type":"match","data":{"path":{"text":"src/app.py"},"lines":{"text":"def handle_request():\n"},"line_number":10,"absolute_offset":100,"submatches":[{"match":{"text":"handle_request"},"start":4,"end":18}]}}',
    '{"type":"context","data":{"path":{"text":"src/app.py"},"lines":{"text":"    validate_session()\n"},"line_number":11}}',
    '{"type":"end","data":{"path":{"text":"src/app.py"},"stats":{"elapsed":{"secs":0,"nanos":10000},"matched_lines":1,"matches":1}}}',
    '{"type":"summary","data":{"stats":{"matched_lines":1,"matches":1}}}'
)

$rgMockResult = & $rgAdapterScript `
    -Query 'handle_request' `
    -MockRgOutput $mockRgJsonLines `
    -Policy advisory `
    -AuthorizeContentTransmission `
    -MockResponses @{ 'cand:src/app.py:10:11' = 0.91 } `
    -WorkingDir $repoRoot

Assert-Test 'select-context-from-rg parses mock rg JSON output into candidate chunks' (
    $rgMockResult.metrics.candidates_received -eq 1
)
Assert-Test 'select-context-from-rg groups match and context lines into contiguous chunk' (
    $rgMockResult.selected[0].content -match 'def handle_request' -and
    $rgMockResult.selected[0].content -match 'validate_session'
)
Assert-Test 'select-context-from-rg routes candidates through reranker successfully' (
    $rgMockResult.selected.Count -eq 1 -and
    $rgMockResult.status -eq 'ok'
)

# Real synthetic file test in temporary directory
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("rg-rerank-test-" + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $tempDir 'src') -Force
    $testFile = Join-Path $tempDir 'src\service.py'
    Set-Content -LiteralPath $testFile -Value @"
class DatabasePool:
    def __init__(self, size=10):
        self.size = size
        self.connections = []

    def acquire(self):
        return "conn"
"@ -Encoding UTF8

    $liveRgResult = & $rgAdapterScript `
        -Query 'DatabasePool' `
        -Path 'src' `
        -WorkingDir $tempDir `
        -Policy off

    Assert-Test 'select-context-from-rg executes real ripgrep against synthetic repo' (
        $liveRgResult.selected.Count -eq 1
    )
    Assert-Test 'Real ripgrep candidate contains accurate line numbers' (
        $liveRgResult.selected[0].line_start -eq 1 -and
        $liveRgResult.selected[0].line_end -ge 1
    )
    Assert-Test 'Real ripgrep candidate contains source content' (
        $liveRgResult.selected[0].content -match 'class DatabasePool'
    )
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    throw "$script:FailedCount context reranking tests failed."
}
else {
    Write-Host 'All TypeSafe/Jev context reranking tests passed deterministically.' -ForegroundColor Green
}
