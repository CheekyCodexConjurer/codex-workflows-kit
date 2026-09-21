# scripts/test-skill-routing.ps1
# Deterministic contract tests for TypeSafe/Jev skill routing gate during FRAME.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$routeSkillsScript = Join-Path $repoRoot 'skills\workflows\scripts\route-skills.ps1'
$workflowSkill = Join-Path $repoRoot 'skills\workflows\SKILL.md'
$skillRoutingRef = Join-Path $repoRoot 'skills\workflows\references\skill-routing.md'

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

Write-Host 'Running TypeSafe/Jev Skill Routing Tests...' -ForegroundColor Cyan

# 1. Existence and contract assertions
Assert-Test 'route-skills.ps1 exists in canonical workflows scripts' (Test-Path -LiteralPath $routeSkillsScript -PathType Leaf)
Assert-Test 'skill-routing.md reference documentation exists' (Test-Path -LiteralPath $skillRoutingRef -PathType Leaf)

$skillText = Get-Content -LiteralPath $workflowSkill -Raw -Encoding UTF8
Assert-Test 'workflows SKILL.md documents skill-routing in FRAME' ($skillText -match '(?i)skill-routing is a deterministic sub-step executed during FRAME')
Assert-Test 'workflows SKILL.md links to references/skill-routing.md' ($skillText -match 'references/skill-routing\.md')
Assert-Test 'workflows SKILL.md preserves parent GPT orchestration authority' ($skillText -match '(?i)parent GPT remains the sole orchestrator and final decider')
Assert-Test 'workflows SKILL.md defines deterministic policy != off execution' ($skillText -match '(?i)if routing policy != off: execute skill-routing before FANOUT')
Assert-Test 'workflows SKILL.md defines deterministic policy == off preservation' ($skillText -match '(?i)if routing policy == off: preserve normal skill resolution')

# Verification: SKILL.md must not use purely optional language for the active gate
$frameLine = ($skillText -split "\r?\n" | Where-Object { $_ -match '^- FRAME:' })
$hasOptionalWording = ($frameLine -match '\b(?:can execute|may execute|optionally execute)\b')
Assert-Test 'workflows SKILL.md does not use optional-only wording for active routing gate' (-not $hasOptionalWording)

# 2. Test Policy: 'off'
$resultOff = & $routeSkillsScript -RoutingPolicy off -WorkingDir $repoRoot -Quiet
Assert-Test "policy 'off' reports policy=off" ($resultOff.policy -eq 'off')
Assert-Test "policy 'off' reports status=ok" ($resultOff.status -eq 'ok')
Assert-Test "policy 'off' makes 0 Jev calls" ($resultOff.jev_calls -eq 0)
Assert-Test "policy 'off' marks workflows as forced with enforced=true" ((($resultOff.results | Where-Object { $_.name -eq 'workflows' }).decision -eq 'forced') -and (($resultOff.results | Where-Object { $_.name -eq 'workflows' }).enforced -eq $true))

$unforcedCandidates = @($resultOff.results | Where-Object { $_.decision -ne 'forced' })
$allUnrouted = ($unforcedCandidates.Count -gt 0)
$noSkipInOff = $true
foreach ($r in $unforcedCandidates) {
    if ($r.decision -ne 'unrouted' -or $r.enforced -ne $false) {
        $allUnrouted = $false
    }
    if ($r.decision -eq 'skip') {
        $noSkipInOff = $false
    }
}
Assert-Test "policy 'off' marks all unforced candidates as unrouted with enforced=false" $allUnrouted
Assert-Test "policy 'off' produces no skip decisions (normal resolution preserved)" $noSkipInOff
Assert-Test "policy 'off' summary contains unrouted list" ($resultOff.summary.unrouted.Count -eq $unforcedCandidates.Count)

# 3. Test Frontmatter Parsing & Disposable Hierarchical Fixture
$tempFixtureDir = Join-Path ([IO.Path]::GetTempPath()) ("skill-routing-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempFixtureDir -Force | Out-Null
try {
    # Initialize fake git repo in fixture to test Get-RepositoryRoot
    $fixtureRepo = Join-Path $tempFixtureDir 'my-repo'
    New-Item -ItemType Directory -Path (Join-Path $fixtureRepo '.git') -Force | Out-Null

    # Hierarchy:
    # my-repo/
    #   .agents/skills/root-skill/SKILL.md (named 'db-helper')
    #   packages/
    #     .agents/skills/package-skill/SKILL.md
    #     api/
    #       .agents/skills/api-skill/SKILL.md (also named 'db-helper' to test name collision)
    #       src/ (WorkingDir for test)
    #     worker-only/
    #       .agents/skills/worker-only/SKILL.md (sibling: MUST NOT be discovered)

    $rootSkillDir = Join-Path $fixtureRepo '.agents\skills\root-skill'
    New-Item -ItemType Directory -Path $rootSkillDir -Force | Out-Null
    $rootSkillContent = @"
---
name: db-helper
description: Root database query utilities.
---
# Root DB
"@
    [IO.File]::WriteAllText((Join-Path $rootSkillDir 'SKILL.md'), $rootSkillContent, [System.Text.Encoding]::UTF8)

    $packageSkillDir = Join-Path $fixtureRepo 'packages\.agents\skills\package-skill'
    New-Item -ItemType Directory -Path $packageSkillDir -Force | Out-Null
    $pkgSkillContent = @"
---
name: package-tool
description: Shared package level utilities.
---
# Package Tool
"@
    [IO.File]::WriteAllText((Join-Path $packageSkillDir 'SKILL.md'), $pkgSkillContent, [System.Text.Encoding]::UTF8)

    $apiSkillDir = Join-Path $fixtureRepo 'packages\api\.agents\skills\api-skill'
    $apiSrcDir = Join-Path $fixtureRepo 'packages\api\src'
    New-Item -ItemType Directory -Path $apiSkillDir -Force | Out-Null
    New-Item -ItemType Directory -Path $apiSrcDir -Force | Out-Null
    $apiSkillContent = @"
---
name: db-helper
description: API-specific query utilities with caching.
---
# API DB Helper
"@
    [IO.File]::WriteAllText((Join-Path $apiSkillDir 'SKILL.md'), $apiSkillContent, [System.Text.Encoding]::UTF8)

    $siblingSkillDir = Join-Path $fixtureRepo 'packages\worker-only\.agents\skills\worker-only'
    New-Item -ItemType Directory -Path $siblingSkillDir -Force | Out-Null
    $siblingSkillContent = @"
---
name: worker-only
description: Worker background task processor.
---
# Worker Only
"@
    [IO.File]::WriteAllText((Join-Path $siblingSkillDir 'SKILL.md'), $siblingSkillContent, [System.Text.Encoding]::UTF8)

    # Create mock codex home with install-state.json
    $mockCodexHome = Join-Path $tempFixtureDir '.codex'
    $mockStateDir = Join-Path $mockCodexHome 'codex-workflows-kit'
    New-Item -ItemType Directory -Path $mockStateDir -Force | Out-Null
    $mockKitSkillDir = Join-Path $tempFixtureDir 'installed-skills\custom-kit-tool'
    New-Item -ItemType Directory -Path $mockKitSkillDir -Force | Out-Null
    $customKitContent = @"
---
name: custom-kit-tool
description: Custom dynamic tool installed via codex-workflows-kit.
---
# Custom Kit Tool
"@
    $customKitSkillPath = Join-Path $mockKitSkillDir 'SKILL.md'
    [IO.File]::WriteAllText($customKitSkillPath, $customKitContent, [System.Text.Encoding]::UTF8)

    $mockStateJson = [ordered]@{
        schemaVersion = 5
        product = 'codex-workflows-kit'
        files = @(
            @{ path = $customKitSkillPath; sha256 = 'abc123' },
            @{ path = (Join-Path $repoRoot 'skills\workflows\SKILL.md'); sha256 = 'def456' }
        )
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $mockStateDir 'install-state.json'), $mockStateJson, [System.Text.Encoding]::UTF8)

    # 4. Test Hierarchical Discovery from CWD (packages/api/src)
    $hierResult = & $routeSkillsScript -RoutingPolicy off -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -Quiet
    $hierIds = @($hierResult.results | ForEach-Object { [string]$_.id })

    Assert-Test 'discovers custom kit skill dynamically from install-state.json' ($hierIds -contains 'kit:custom-kit-tool')
    Assert-Test 'discovers root repo skill traversing upward to repo root' ($hierIds -contains 'repo:.agents/skills/root-skill')
    Assert-Test 'discovers intermediate package repo skill' ($hierIds -contains 'repo:packages/.agents/skills/package-skill')
    Assert-Test 'discovers local api repo skill' ($hierIds -contains 'repo:packages/api/.agents/skills/api-skill')
    Assert-Test 'excludes sibling subproject skill outside CWD ancestor chain' (-not ($hierIds -contains 'repo:packages/worker-only/.agents/skills/worker-only'))

    # 5. Test Duplicate Skill Names Across Scopes
    $dbHelperSkills = @($hierResult.results | Where-Object { $_.name -eq 'db-helper' })
    Assert-Test 'duplicate skill names across different scopes do not collide' ($dbHelperSkills.Count -eq 2)
    $dbHelperIds = @($dbHelperSkills | ForEach-Object { $_.id })
    Assert-Test 'duplicate skill names preserve distinct stable IDs' ($dbHelperIds -contains 'repo:.agents/skills/root-skill' -and $dbHelperIds -contains 'repo:packages/api/.agents/skills/api-skill')

    # 6. Test Kit Ownership Protection (Unmanaged global skill must NOT become kit:*)
    # Create fake unmanaged skill in a mock global directory
    $fakeGlobalSkillsDir = Join-Path $tempFixtureDir 'fake-global\.agents\skills\random-user-skill'
    New-Item -ItemType Directory -Path $fakeGlobalSkillsDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeGlobalSkillsDir 'SKILL.md'), "---\nname: random-user-skill\ndescription: Not a kit skill\n---\n", [System.Text.Encoding]::UTF8)

    $emptyCodexHome = Join-Path $tempFixtureDir 'empty-codex'
    New-Item -ItemType Directory -Path $emptyCodexHome -Force | Out-Null
    $unmanagedTestResult = & $routeSkillsScript -RoutingPolicy off -WorkingDir $apiSrcDir -CodexHome $emptyCodexHome -Quiet
    $unmanagedIds = @($unmanagedTestResult.results | ForEach-Object { [string]$_.id })
    Assert-Test 'unmanaged global skill does not become kit:* without proven ownership' (-not ($unmanagedIds -contains 'kit:random-user-skill'))

    # 7. Test Advisory vs Enforce (Observable Difference)
    $mocks = @{
        'repo:.agents/skills/root-skill' = 0.90
        'repo:packages/.agents/skills/package-skill' = 0.55
        'kit:custom-kit-tool' = 0.20
    }

    # Under advisory:
    $advisoryResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MockResponses $mocks -Quiet
    $advSelect = $advisoryResult.results | Where-Object { $_.id -eq 'repo:.agents/skills/root-skill' }
    $advReview = $advisoryResult.results | Where-Object { $_.id -eq 'repo:packages/.agents/skills/package-skill' }
    $advSkip = $advisoryResult.results | Where-Object { $_.id -eq 'kit:custom-kit-tool' }

    Assert-Test 'advisory selects candidate with enforced=false' ($advSelect.decision -eq 'select' -and $advSelect.enforced -eq $false)
    Assert-Test 'advisory reviews candidate with enforced=false' ($advReview.decision -eq 'review' -and $advReview.enforced -eq $false)
    Assert-Test 'advisory skips candidate with enforced=false' ($advSkip.decision -eq 'skip' -and $advSkip.enforced -eq $false)

    # Under enforce:
    $enforceResult = & $routeSkillsScript -RoutingPolicy enforce -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MockResponses $mocks -Quiet
    $enfSelect = $enforceResult.results | Where-Object { $_.id -eq 'repo:.agents/skills/root-skill' }
    $enfReview = $enforceResult.results | Where-Object { $_.id -eq 'repo:packages/.agents/skills/package-skill' }
    $enfSkip = $enforceResult.results | Where-Object { $_.id -eq 'kit:custom-kit-tool' }

    Assert-Test 'enforce selects candidate with enforced=true' ($enfSelect.decision -eq 'select' -and $enfSelect.enforced -eq $true)
    Assert-Test 'enforce reviews candidate with enforced=false (escalated to parent)' ($enfReview.decision -eq 'review' -and $enfReview.enforced -eq $false)
    Assert-Test 'enforce skips candidate with enforced=true' ($enfSkip.decision -eq 'skip' -and $enfSkip.enforced -eq $true)
    Assert-Test 'advisory and enforce exhibit observably different enforcement flags' ($advSelect.enforced -ne $enfSelect.enforced -and $advSkip.enforced -ne $enfSkip.enforced)

    # 8. Test Jev Parallel Batching & Call Count Metrics
    # In fixture, we have 4 unforced candidates (root-skill, package-skill, api-skill, custom-kit-tool).
    $allMocks = @{
        'repo:.agents/skills/root-skill' = 0.88
        'repo:packages/.agents/skills/package-skill' = 0.50
        'repo:packages/api/.agents/skills/api-skill' = 0.92
        'kit:custom-kit-tool' = 0.35
    }

    # With default batch size (25): 4 candidates evaluated in 1 call
    $batchResult1 = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MockResponses $allMocks -BatchSize 25 -Quiet
    Assert-Test 'evaluates all 4 candidates in a single Jev batch call (batch_size=25)' ($batchResult1.jev_calls -eq 1 -and $batchResult1.candidates_evaluated -eq 4)

    # With batch size 2: 4 candidates evaluated across 2 calls
    $batchResult2 = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MockResponses $allMocks -BatchSize 2 -Quiet
    Assert-Test 'chunks 4 candidates into 2 Jev batch calls when batch_size=2' ($batchResult2.jev_calls -eq 2 -and $batchResult2.candidates_evaluated -eq 4)

    # 9. Test Data Minimization & Privacy Protection
    $dirtyPrompt = @"
Please help fix auth bug:
TYPESAFE_API_KEY=apikey_fake_secret_1234567890abcdef
Authorization: Bearer my_top_secret_bearer_token
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7
-----END PRIVATE KEY-----
OPENAI_API_KEY=sk-test12345678901234567890abcdef
password=SuperSecretPassword!
```python
def leak_code():
    pass
```
diff --git a/test.py b/test.py
@@ -1,2 +1,2 @@
-old
+new
Fix authentication regression in REST API
"@

    # Run with -TaskObjective dirty prompt (fallback sanitizer)
    $cleanTestResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -TaskObjective $dirtyPrompt -MockResponses $mocks -AsJson -Quiet
    Assert-Test 'dirty TaskObjective strips TYPESAFE_API_KEY pattern' (-not ($cleanTestResult -match 'apikey_fake_secret_1234567890abcdef'))
    Assert-Test 'dirty TaskObjective strips Bearer token' (-not ($cleanTestResult -match 'my_top_secret_bearer_token'))
    Assert-Test 'dirty TaskObjective strips private keys' (-not ($cleanTestResult -match 'BEGIN PRIVATE KEY'))
    Assert-Test 'dirty TaskObjective strips OPENAI_API_KEY' (-not ($cleanTestResult -match 'sk-test12345678901234567890abcdef'))
    Assert-Test 'dirty TaskObjective strips password pattern' (-not ($cleanTestResult -match 'SuperSecretPassword'))
    Assert-Test 'dirty TaskObjective strips fenced code blocks' (-not ($cleanTestResult -match 'def leak_code'))

    # Preferred -RoutingObjective
    $prefObjResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -RoutingObjective 'Clean minimized task summary' -MockResponses $mocks -AsJson -Quiet
    Assert-Test 'preferred RoutingObjective executes cleanly' ($null -ne ($prefObjResult | ConvertFrom-Json))

    # 10. Test Forced Skills (explicit and rule-based)
    $forcedExplicitResult = & $routeSkillsScript -RoutingPolicy off -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -ForcedSkills @('package-tool') -Quiet
    $pkgForced = $forcedExplicitResult.results | Where-Object { $_.name -eq 'package-tool' }
    Assert-Test 'explicit user skill is marked forced with score=null and enforced=true' ($pkgForced.decision -eq 'forced' -and $pkgForced.enforced -eq $true -and $null -eq $pkgForced.score)

    $researchModeResult = & $routeSkillsScript -RoutingPolicy off -Mode 'RESEARCH.DEEP' -WorkingDir $repoRoot -Quiet
    $evidenceForced = $researchModeResult.results | Where-Object { $_.name -eq 'evidence-first' }
    Assert-Test 'workflow policy rule enforces evidence-first under RESEARCH.DEEP' ($evidenceForced.decision -eq 'forced' -and $evidenceForced.enforced -eq $true)

    # 11. Test Capacity Limit (MaxSelectedSkills)
    $mocksMultiSelect = @{
        'repo:packages/api/.agents/skills/api-skill' = 0.95
        'repo:.agents/skills/root-skill' = 0.85
        'kit:custom-kit-tool' = 0.78
    }
    # Set MaxSelectedSkills = 1: only the top score should be selected, others downgraded to review
    $capResult = & $routeSkillsScript -RoutingPolicy enforce -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MaxSelectedSkills 1 -MockResponses $mocksMultiSelect -Quiet
    $selectedSkills = @($capResult.results | Where-Object { $_.decision -eq 'select' })
    Assert-Test 'MaxSelectedSkills caps the number of selected skills' ($selectedSkills.Count -eq 1)
    Assert-Test 'Top-scored skill is selected with enforced=true' ($selectedSkills[0].id -eq 'repo:packages/api/.agents/skills/api-skill' -and $selectedSkills[0].enforced -eq $true)

    $downgradedSkill = $capResult.results | Where-Object { $_.id -eq 'repo:.agents/skills/root-skill' }
    Assert-Test 'Excess select candidate is downgraded to review with capacity notice and enforced=false' ($downgradedSkill.decision -eq 'review' -and $downgradedSkill.enforced -eq $false -and $downgradedSkill.note -eq 'capacity_limit_exceeded')

    # 12. Test Fail-Safe Handling: Missing TYPESAFE_API_KEY
    $oldKey = $env:TYPESAFE_API_KEY
    try {
        $env:TYPESAFE_API_KEY = ''
        $failSafeResult = & $routeSkillsScript -RoutingPolicy enforce -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -Quiet
        Assert-Test 'missing key does not throw exception' ($null -ne $failSafeResult)
        Assert-Test 'missing key reports status=unavailable' ($failSafeResult.status -eq 'unavailable')

        $unforcedResults = @($failSafeResult.results | Where-Object { $_.decision -ne 'forced' })
        $allFallbackToReview = $true
        $noFalseSkipOnMissingKey = $true
        foreach ($unf in $unforcedResults) {
            if ($unf.decision -ne 'review' -or $unf.enforced -ne $false) {
                $allFallbackToReview = $false
            }
            if ($unf.decision -eq 'skip') {
                $noFalseSkipOnMissingKey = $false
            }
        }
        Assert-Test 'missing key safely defaults unforced candidates to review with enforced=false' $allFallbackToReview
        Assert-Test 'missing key never produces false skip' $noFalseSkipOnMissingKey
    }
    finally {
        $env:TYPESAFE_API_KEY = $oldKey
    }

    # 13. Test Fail-Safe Handling: Mock API Error / Network Failure
    $mocksWithError = @{
        'repo:packages/api/.agents/skills/api-skill' = @{ error = 'Simulated 503 Service Unavailable' }
        'kit:custom-kit-tool' = 0.90
    }
    $errorResult = & $routeSkillsScript -RoutingPolicy enforce -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MockResponses $mocksWithError -Quiet
    $errorCand = $errorResult.results | Where-Object { $_.id -eq 'repo:packages/api/.agents/skills/api-skill' }
    Assert-Test 'API error marks candidate as review with jev_unavailable note and enforced=false' ($errorCand.decision -eq 'review' -and $errorCand.enforced -eq $false -and $errorCand.note -eq 'jev_unavailable')
    $healthyCand = $errorResult.results | Where-Object { $_.id -eq 'kit:custom-kit-tool' }
    Assert-Test 'Other candidates evaluate successfully despite partial failure' ($healthyCand.decision -eq 'select' -and $healthyCand.enforced -eq $true)

    # 14. Configuration Hardening & Parameter Range Validations (Fail Fast)

    # BatchSize validations
    Assert-Test 'rejects BatchSize = 0' (Test-ScriptThrows { & $routeSkillsScript -BatchSize 0 -Quiet })
    Assert-Test 'rejects BatchSize < 0 (-1)' (Test-ScriptThrows { & $routeSkillsScript -BatchSize -1 -Quiet })
    Assert-Test 'rejects BatchSize > 100 (101)' (Test-ScriptThrows { & $routeSkillsScript -BatchSize 101 -Quiet })
    Assert-Test 'accepts BatchSize = 1' (-not (Test-ScriptThrows { & $routeSkillsScript -BatchSize 1 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))
    Assert-Test 'accepts BatchSize = 100' (-not (Test-ScriptThrows { & $routeSkillsScript -BatchSize 100 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))

    # MaxSelectedSkills validations
    Assert-Test 'rejects MaxSelectedSkills < 0 (-1)' (Test-ScriptThrows { & $routeSkillsScript -MaxSelectedSkills -1 -Quiet })
    Assert-Test 'rejects MaxSelectedSkills > 100 (101)' (Test-ScriptThrows { & $routeSkillsScript -MaxSelectedSkills 101 -Quiet })
    Assert-Test 'accepts MaxSelectedSkills = 100' (-not (Test-ScriptThrows { & $routeSkillsScript -MaxSelectedSkills 100 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))

    # MaxSelectedSkills = 0 boundary behavior: disables automatic selection of implicit skills
    $mocksZero = @{ 'repo:packages/api/.agents/skills/api-skill' = 0.95 }
    $zeroCapResult = & $routeSkillsScript -RoutingPolicy enforce -WorkingDir $apiSrcDir -CodexHome $mockCodexHome -MaxSelectedSkills 0 -MockResponses $mocksZero -Quiet
    $zeroCapSelects = @($zeroCapResult.results | Where-Object { $_.decision -eq 'select' })
    $zeroCapForced = @($zeroCapResult.results | Where-Object { $_.decision -eq 'forced' })
    $zeroCapReviews = @($zeroCapResult.results | Where-Object { $_.id -eq 'repo:packages/api/.agents/skills/api-skill' })
    Assert-Test 'accepts MaxSelectedSkills = 0 and selects 0 implicit skills' ($zeroCapSelects.Count -eq 0)
    Assert-Test 'MaxSelectedSkills = 0 downgrades qualifying candidate to review with capacity notice' ($zeroCapReviews.Count -eq 1 -and $zeroCapReviews[0].decision -eq 'review' -and $zeroCapReviews[0].note -eq 'capacity_limit_exceeded')
    Assert-Test 'MaxSelectedSkills = 0 does not block forced skills' ($zeroCapForced.Count -ge 1)

    # Threshold range validations
    Assert-Test 'rejects SelectThreshold < 0 (-0.1)' (Test-ScriptThrows { & $routeSkillsScript -SelectThreshold -0.1 -Quiet })
    Assert-Test 'rejects SelectThreshold > 1 (1.1)' (Test-ScriptThrows { & $routeSkillsScript -SelectThreshold 1.1 -Quiet })
    Assert-Test 'rejects ReviewThreshold < 0 (-0.1)' (Test-ScriptThrows { & $routeSkillsScript -ReviewThreshold -0.1 -Quiet })
    Assert-Test 'rejects ReviewThreshold > 1 (1.1)' (Test-ScriptThrows { & $routeSkillsScript -ReviewThreshold 1.1 -Quiet })

    # Threshold relationship: ReviewThreshold must be <= SelectThreshold
    Assert-Test 'rejects ReviewThreshold > SelectThreshold' (Test-ScriptThrows { & $routeSkillsScript -ReviewThreshold 0.80 -SelectThreshold 0.50 -Quiet } 'ReviewThreshold .* must be less than or equal to SelectThreshold')
    Assert-Test 'accepts ReviewThreshold = 0.0 and SelectThreshold = 1.0' (-not (Test-ScriptThrows { & $routeSkillsScript -ReviewThreshold 0.0 -SelectThreshold 1.0 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))
    Assert-Test 'accepts ReviewThreshold == SelectThreshold' (-not (Test-ScriptThrows { & $routeSkillsScript -ReviewThreshold 0.70 -SelectThreshold 0.70 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))

    # TimeoutSeconds validations
    Assert-Test 'rejects TimeoutSeconds = 0' (Test-ScriptThrows { & $routeSkillsScript -TimeoutSeconds 0 -Quiet })
    Assert-Test 'rejects TimeoutSeconds < 0 (-1)' (Test-ScriptThrows { & $routeSkillsScript -TimeoutSeconds -1 -Quiet })
    Assert-Test 'rejects TimeoutSeconds > 120 (121)' (Test-ScriptThrows { & $routeSkillsScript -TimeoutSeconds 121 -Quiet })
    Assert-Test 'accepts TimeoutSeconds = 1' (-not (Test-ScriptThrows { & $routeSkillsScript -TimeoutSeconds 1 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))
    Assert-Test 'accepts TimeoutSeconds = 120' (-not (Test-ScriptThrows { & $routeSkillsScript -TimeoutSeconds 120 -RoutingPolicy off -WorkingDir $repoRoot -Quiet }))

    # CODEX_SKILL_ROUTING_POLICY environment variable validation
    $oldPolicy = $env:CODEX_SKILL_ROUTING_POLICY
    try {
        $env:CODEX_SKILL_ROUTING_POLICY = 'banana'
        Assert-Test 'rejects invalid CODEX_SKILL_ROUTING_POLICY environment variable' (Test-ScriptThrows { & $routeSkillsScript -WorkingDir $repoRoot -Quiet } 'Invalid CODEX_SKILL_ROUTING_POLICY')

        $env:CODEX_SKILL_ROUTING_POLICY = 'ADVISORY'
        $envNormResult = & $routeSkillsScript -WorkingDir $repoRoot -Quiet
        Assert-Test 'normalizes uppercase CODEX_SKILL_ROUTING_POLICY' ($envNormResult.policy -eq 'advisory')

        $env:CODEX_SKILL_ROUTING_POLICY = 'Enforce'
        $envEnforceResult = & $routeSkillsScript -WorkingDir $repoRoot -Quiet
        Assert-Test 'normalizes mixed-case CODEX_SKILL_ROUTING_POLICY' ($envEnforceResult.policy -eq 'enforce')
    }
    finally {
        $env:CODEX_SKILL_ROUTING_POLICY = $oldPolicy
    }
}
finally {
    # Cleanup disposable fixture
    if (Test-Path -LiteralPath $tempFixtureDir) {
        Remove-Item -LiteralPath $tempFixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nAll TypeSafe/Jev skill routing tests passed deterministically." -ForegroundColor Green
exit 0
