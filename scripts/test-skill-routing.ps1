# scripts/test-skill-routing.ps1
# Deterministic contract tests for optional TypeSafe/Jev skill routing gate during FRAME.

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

Write-Host 'Running TypeSafe/Jev Skill Routing Tests...' -ForegroundColor Cyan

# 1. Existence and contract assertions
Assert-Test 'route-skills.ps1 exists in canonical workflows scripts' (Test-Path -LiteralPath $routeSkillsScript -PathType Leaf)
Assert-Test 'skill-routing.md reference documentation exists' (Test-Path -LiteralPath $skillRoutingRef -PathType Leaf)

$skillText = Get-Content -LiteralPath $workflowSkill -Raw -Encoding UTF8
Assert-Test 'workflows SKILL.md documents skill-routing in FRAME' ($skillText -match '(?i)skill-routing gate before FANOUT')
Assert-Test 'workflows SKILL.md links to references/skill-routing.md' ($skillText -match 'references/skill-routing\.md')
Assert-Test 'workflows SKILL.md preserves parent GPT orchestration authority' ($skillText -match '(?i)parent GPT remains the orchestrator and final decider')

# 2. Test Policy: 'off'
$resultOff = & $routeSkillsScript -RoutingPolicy off -WorkingDir $repoRoot -Quiet
Assert-Test "policy 'off' reports policy=off" ($resultOff.policy -eq 'off')
Assert-Test "policy 'off' reports status=ok" ($resultOff.status -eq 'ok')
Assert-Test "policy 'off' marks workflows as forced" (($resultOff.results | Where-Object { $_.name -eq 'workflows' }).decision -eq 'forced')
$allNonForcedSkipped = $true
foreach ($r in @($resultOff.results | Where-Object { $_.decision -ne 'forced' })) {
    if ($r.decision -ne 'skip') {
        $allNonForcedSkipped = $false
        break
    }
}
Assert-Test "policy 'off' marks all unforced candidates as skip" $allNonForcedSkipped

# 3. Test Frontmatter Parsing & Discovery with Disposable Fixture
$tempFixtureDir = Join-Path ([IO.Path]::GetTempPath()) ("skill-routing-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempFixtureDir -Force | Out-Null
try {
    # Create mock repo with .agents/skills and nested packages/api/.agents/skills
    $repoSkillsDir = Join-Path $tempFixtureDir '.agents\skills\db-query'
    New-Item -ItemType Directory -Path $repoSkillsDir -Force | Out-Null
    $dbSkillContent = @"
---
name: db-query
description: Execute optimized read-only queries against relational databases.
---
# DB Query Skill
"@
    [IO.File]::WriteAllText((Join-Path $repoSkillsDir 'SKILL.md'), $dbSkillContent, [System.Text.Encoding]::UTF8)

    $nestedSkillsDir = Join-Path $tempFixtureDir 'packages\api\.agents\skills\api-client'
    New-Item -ItemType Directory -Path $nestedSkillsDir -Force | Out-Null
    $apiSkillContent = @"
---
name: api-client
description: Specialized client for interacting with upstream REST APIs.
---
# API Client Skill
"@
    [IO.File]::WriteAllText((Join-Path $nestedSkillsDir 'SKILL.md'), $apiSkillContent, [System.Text.Encoding]::UTF8)

    # Create mock install-state.json
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

    # Run discovery against the fixture
    $fixtureResult = & $routeSkillsScript -RoutingPolicy off -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -Quiet
    
    $discoveredIds = @($fixtureResult.results | ForEach-Object { [string]$_.id })
    Assert-Test 'discovers custom kit skill dynamically from install-state.json' ($discoveredIds -contains 'kit:custom-kit-tool')
    Assert-Test 'discovers local repo skill in .agents/skills' ($discoveredIds -contains 'repo:.agents/skills/db-query')
    Assert-Test 'discovers nested repo skill in packages/api/.agents/skills' ($discoveredIds -contains 'repo:packages/api/.agents/skills/api-client')

    $dbSkill = $fixtureResult.results | Where-Object { $_.id -eq 'repo:.agents/skills/db-query' }
    Assert-Test 'lightweight catalog extracts frontmatter name' ($dbSkill.name -eq 'db-query')
    Assert-Test 'lightweight catalog extracts frontmatter description' ($dbSkill.description -match 'relational databases')

    # 4. Test Forced Skills (explicit and rule-based)
    $forcedExplicitResult = & $routeSkillsScript -RoutingPolicy off -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -ForcedSkills @('db-query') -Quiet
    $dbForced = $forcedExplicitResult.results | Where-Object { $_.name -eq 'db-query' }
    Assert-Test 'explicit user skill is marked forced with score=null' ($dbForced.decision -eq 'forced' -and $null -eq $dbForced.score)

    $researchModeResult = & $routeSkillsScript -RoutingPolicy off -Mode 'RESEARCH.DEEP' -WorkingDir $repoRoot -Quiet
    $evidenceForced = $researchModeResult.results | Where-Object { $_.name -eq 'evidence-first' }
    Assert-Test 'workflow policy rule enforces evidence-first under RESEARCH.DEEP' ($evidenceForced.decision -eq 'forced')

    # 5. Test Jev Scoring & Thresholds via Mock Responses
    $mocks = @{
        'repo:.agents/skills/db-query' = 0.92
        'repo:packages/api/.agents/skills/api-client' = 0.58
        'kit:custom-kit-tool' = 0.30
    }
    $evalResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -MockResponses $mocks -Quiet
    Assert-Test 'mock evaluation reports status=mock' ($evalResult.status -eq 'mock')

    $dbEval = $evalResult.results | Where-Object { $_.id -eq 'repo:.agents/skills/db-query' }
    Assert-Test 'score >= 0.70 results in select' ($dbEval.decision -eq 'select' -and $dbEval.score -eq 0.92)

    $apiEval = $evalResult.results | Where-Object { $_.id -eq 'repo:packages/api/.agents/skills/api-client' }
    Assert-Test 'score between 0.45 and 0.70 results in review' ($apiEval.decision -eq 'review' -and $apiEval.score -eq 0.58)

    $kitEval = $evalResult.results | Where-Object { $_.id -eq 'kit:custom-kit-tool' }
    Assert-Test 'score < 0.45 results in skip' ($kitEval.decision -eq 'skip' -and $kitEval.score -eq 0.30)

    # 6. Test Capacity Limit (MaxSelectedSkills)
    $mocksMultiSelect = @{
        'repo:.agents/skills/db-query' = 0.95
        'repo:packages/api/.agents/skills/api-client' = 0.85
        'kit:custom-kit-tool' = 0.78
    }
    # Set MaxSelectedSkills = 1: only the top score should be selected, others downgraded to review
    $capResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -MaxSelectedSkills 1 -MockResponses $mocksMultiSelect -Quiet
    $selectedSkills = @($capResult.results | Where-Object { $_.decision -eq 'select' })
    Assert-Test 'MaxSelectedSkills caps the number of selected skills' ($selectedSkills.Count -eq 1)
    Assert-Test 'Top-scored skill is selected' ($selectedSkills[0].id -eq 'repo:.agents/skills/db-query')

    $downgradedSkill = $capResult.results | Where-Object { $_.id -eq 'repo:packages/api/.agents/skills/api-client' }
    Assert-Test 'Excess select candidate is downgraded to review with capacity notice' ($downgradedSkill.decision -eq 'review' -and $downgradedSkill.note -eq 'capacity_limit_exceeded')

    # Forced skills do not consume capacity
    Assert-Test 'Workflows skill remains forced and does not count towards MaxSelectedSkills' (($capResult.results | Where-Object { $_.name -eq 'workflows' }).decision -eq 'forced')

    # 7. Test Fail-Safe Handling: Missing TYPESAFE_API_KEY
    $oldKey = $env:TYPESAFE_API_KEY
    try {
        $env:TYPESAFE_API_KEY = ''
        $failSafeResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -Quiet
        Assert-Test 'missing key does not throw exception' ($null -ne $failSafeResult)
        Assert-Test 'missing key reports status=unavailable' ($failSafeResult.status -eq 'unavailable')
        
        $unforcedResults = @($failSafeResult.results | Where-Object { $_.decision -ne 'forced' })
        $allFallbackToReview = $true
        foreach ($unf in $unforcedResults) {
            if ($unf.decision -ne 'review') {
                $allFallbackToReview = $false
                break
            }
        }
        Assert-Test 'missing key safely defaults unforced candidates to review' $allFallbackToReview
    }
    finally {
        $env:TYPESAFE_API_KEY = $oldKey
    }

    # 8. Test Fail-Safe Handling: Mock API Error / Network Failure
    $mocksWithError = @{
        'repo:.agents/skills/db-query' = @{ error = 'Simulated 503 Service Unavailable' }
        'kit:custom-kit-tool' = 0.90
    }
    $errorResult = & $routeSkillsScript -RoutingPolicy advisory -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -MockResponses $mocksWithError -Quiet
    $errorCand = $errorResult.results | Where-Object { $_.id -eq 'repo:.agents/skills/db-query' }
    Assert-Test 'API error marks candidate as review with jev_unavailable note' ($errorCand.decision -eq 'review' -and $errorCand.note -eq 'jev_unavailable')
    $healthyCand = $errorResult.results | Where-Object { $_.id -eq 'kit:custom-kit-tool' }
    Assert-Test 'Other candidates evaluate successfully despite partial failure' ($healthyCand.decision -eq 'select')

    # 9. Test JSON Output format
    $jsonOutput = & $routeSkillsScript -RoutingPolicy off -WorkingDir $tempFixtureDir -CodexHome $mockCodexHome -AsJson -Quiet
    Assert-Test 'AsJson outputs valid parseable JSON' ($null -ne ($jsonOutput | ConvertFrom-Json))

    # 10. Test Security: Verify API key is never in result objects
    $hasSecret = ($jsonOutput -match 'Bearer' -or $jsonOutput -match 'TYPESAFE_API_KEY')
    Assert-Test 'No authorization headers or secrets in JSON output' (-not $hasSecret)
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
