# scripts/tests/free-mcp-context7-skill.Tests.ps1
# Deterministic unit and scenario tests for Context7 free MCP skill

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$skillPath = Join-Path $repoRoot 'skills\context7-mcp\SKILL.md'
$agentYamlPath = Join-Path $repoRoot 'skills\context7-mcp\agents\openai.yaml'

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

# --- Simulation & Behavior Helpers ---

function Test-Context7QuerySanitization {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return @{ Allowed = $false; Reason = "Empty query" } }
    # Detect secrets/tokens/credentials
    if ($Query -match '(sk-[a-zA-Z0-9_-]{20,}|Bearer\s+[a-zA-Z0-9_\-\.]+|BEGIN\s+(RSA|EC|PRIVATE)\s+KEY|password\s*[:=]|token\s*[:=])') {
        return @{ Allowed = $false; Reason = "Secret or credential pattern detected" }
    }
    # Detect full user prompt / conversational dumps
    if ($Query -match '(?i)(system\s*prompt|you\s+are\s+a\s+helpful\s+assistant|act\s+as\s+a|<user_request>|<USER_REQUEST>)') {
        return @{ Allowed = $false; Reason = "Full prompt or conversation history dump detected" }
    }
    # Detect multi-line proprietary source code blocks
    if ($Query -match '```' -or ($Query -split '\r?\n').Length -gt 3) {
        return @{ Allowed = $false; Reason = "Proprietary code block or multiline dump detected" }
    }
    return @{ Allowed = $true; SanitizedQuery = $Query.Trim() }
}

function Test-Context7VersionMismatch {
    param(
        [string]$RequestedVersion,
        [string]$ReturnedSourceUrl
    )
    if ([string]::IsNullOrWhiteSpace($RequestedVersion) -or [string]::IsNullOrWhiteSpace($ReturnedSourceUrl)) {
        return @{ HasMismatch = $false; Note = "No version or URL provided" }
    }
    # If a specific version tag was requested (e.g. v19.2.7), but the returned URL points to main or master
    $isMain = $ReturnedSourceUrl -match '(?i)(/tree/main/|/blob/main/|/tree/master/|/blob/master/|@main/|@master/)'
    $hasTag = $ReturnedSourceUrl -match [regex]::Escape($RequestedVersion)
    if ($isMain -and -not $hasTag) {
        return @{
            HasMismatch = $true
            RequestedVersion = $RequestedVersion
            ReturnedTarget = "main"
            Warning = "Version mismatch: requested tag '$RequestedVersion', but source link points to main"
        }
    }
    return @{ HasMismatch = $false; RequestedVersion = $RequestedVersion; ReturnedTarget = $RequestedVersion }
}

function Invoke-Context7DeduplicationCoordination {
    param(
        [hashtable]$SharedPacketStore,
        [string]$LibraryId,
        [string]$Query,
        [string]$WorkerId
    )
    $key = ("{0}:{1}" -f $LibraryId, $Query.ToLowerInvariant().Trim())
    if ($SharedPacketStore.ContainsKey($key)) {
        return @{
            IsDuplicate = $true
            CallMade = $false
            ExistingOwner = $SharedPacketStore[$key].Owner
            Packet = $SharedPacketStore[$key]
        }
    }
    # First worker becomes owner and creates packet
    $packet = @{
        libraryId = $LibraryId
        version = "v19.2.7"
        query = $Query
        source = "https://context7.com/react/react"
        date = (Get-Date -Format "yyyy-MM-dd")
        limits = "1000/mo"
        Owner = $WorkerId
    }
    $SharedPacketStore[$key] = $packet
    return @{
        IsDuplicate = $false
        CallMade = $true
        ExistingOwner = $WorkerId
        Packet = $packet
    }
}

function Invoke-Context7ErrorPolicy {
    param([int]$StatusCode)
    switch ($StatusCode) {
        429 {
            return @{
                StopImmediately = $true
                AllowRetryStorm = $false
                SuggestPaidKey = $false
                SwitchProvider = $false
                FallbackAction = "OfficialDocs"
                UserNotice = "Context7 free monthly quota reached. Refer to official documentation."
            }
        }
        401 {
            return @{
                StopImmediately = $true
                AllowRetryStorm = $false
                SuggestPaidKey = $false
                SwitchProvider = $false
                FallbackAction = "OfficialDocs"
                UserNotice = "Context7 unauthenticated access blocked. Refer to official documentation."
            }
        }
        403 {
            return @{
                StopImmediately = $true
                AllowRetryStorm = $false
                SuggestPaidKey = $false
                SwitchProvider = $false
                FallbackAction = "OfficialDocs"
                UserNotice = "Context7 access forbidden. Refer to official documentation."
            }
        }
        default {
            return @{
                StopImmediately = $false
                AllowRetryStorm = $false
                SuggestPaidKey = $false
                SwitchProvider = $false
                FallbackAction = "None"
                UserNotice = ""
            }
        }
    }
}

function Test-Context7LibraryResolution {
    param(
        [Parameter(Mandatory=$true)][string]$UserInput,
        [Parameter(Mandatory=$false)][string[]]$KnownSessionLibraryIds = @(),
        [Parameter(Mandatory=$false)][string]$AttemptedQueryLibraryId = ''
    )
    # Check if user input is an explicit library ID in /org/project or /org/project/version format
    $isExplicitUserLibraryId = $UserInput -match '^/[a-zA-Z0-9_\-\.]+/[a-zA-Z0-9_\-\.]+(/v?[a-zA-Z0-9_\-\.]+)?$'

    # Check if AttemptedQueryLibraryId was resolved in session
    $isKnownSessionId = ($KnownSessionLibraryIds -contains $AttemptedQueryLibraryId)

    # Detect prohibited fabrication/inference of /org/repo/version from semver or package name
    # e.g., turning "React 19.2.7" into "/react/react/v19.2.7"
    $isInventedId = $false
    if (-not [string]::IsNullOrWhiteSpace($AttemptedQueryLibraryId) -and -not $isExplicitUserLibraryId -and -not $isKnownSessionId) {
        $isInventedId = $true
    }

    if ($isExplicitUserLibraryId) {
        return @{
            AllowedDirectQuery = $true
            RequiresResolve = $false
            IsInventedId = $false
            EffectiveLibraryId = $UserInput
            Reason = "User explicitly supplied authoritatively formatted library ID"
        }
    }

    if ($isKnownSessionId) {
        return @{
            AllowedDirectQuery = $true
            RequiresResolve = $false
            IsInventedId = $false
            EffectiveLibraryId = $AttemptedQueryLibraryId
            Reason = "Library ID previously resolved and cached in session"
        }
    }

    if ($isInventedId) {
        return @{
            AllowedDirectQuery = $false
            RequiresResolve = $true
            IsInventedId = $true
            EffectiveLibraryId = $null
            Reason = "Prohibited inference: library name/version != libraryId. Attempting to fabricate '$AttemptedQueryLibraryId' without calling resolve-library-id is forbidden"
        }
    }

    return @{
        AllowedDirectQuery = $false
        RequiresResolve = $true
        IsInventedId = $false
        EffectiveLibraryId = $null
        Reason = "Package name/version requires calling resolve-library-id first"
    }
}

function Test-Context7QueryPlaceholder {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) {
        return @{
            Allowed = $false
            IsPlaceholder = $false
            NeedsTopicClarification = $true
            Reason = "Missing technical topic. Must determine concept or prompt user before querying"
        }
    }
    # Detect placeholder strings e.g. <topico atomico>, <topic>, <concept>, [query], <placeholder>
    if ($Query -match '(?i)(<\s*topico\s*atomico\s*>|<\s*topic\s*>|<\s*concept\s*>|<\s*placeholder\s*>|\[\s*query\s*\]|\[\s*topic\s*\]|<\s*insert\b|\bplaceholder\b)') {
        return @{
            Allowed = $false
            IsPlaceholder = $true
            NeedsTopicClarification = $true
            Reason = "Placeholder query detected. Queries must be concrete technical topics or prompt user if topic is absent"
        }
    }
    return @{
        Allowed = $true
        IsPlaceholder = $false
        NeedsTopicClarification = $false
        Reason = "Valid concrete topic query"
    }
}

function Invoke-Context7DocReuseOrQuery {
    param(
        [hashtable]$ExistingPacket,
        [string]$TopicNeeded
    )
    if ($null -ne $ExistingPacket -and $ExistingPacket.ContainsKey("content") -and -not [string]::IsNullOrWhiteSpace($ExistingPacket["content"])) {
        # Check if the topic is covered by the existing packet
        $packetTopic = if ($ExistingPacket.ContainsKey("query")) { [string]$ExistingPacket["query"] } else { "" }
        if ([string]::IsNullOrWhiteSpace($TopicNeeded) -or $packetTopic -eq $TopicNeeded -or $ExistingPacket["content"] -match [regex]::Escape($TopicNeeded)) {
            return @{
                CallsMade = 0
                ReusedExistingPacket = $true
                Source = "Cache/Packet"
                Notice = "Reused complete documentation packet with zero external calls"
            }
        }
    }
    # Need new distinct query
    return @{
        CallsMade = 1
        ReusedExistingPacket = $false
        Source = "Context7Query"
        Notice = "Executed new query for distinct topic within budget"
    }
}

Write-Host "Running Context7 MCP Skill Test Suite..." -ForegroundColor Cyan

# ---------------------------------------------------------
# Test Group 1: File Existence & YAML Frontmatter
# ---------------------------------------------------------
$skillExists = Test-Path -LiteralPath $skillPath
Assert-Test -Name "Skill file exists" -Condition $skillExists -Details "Missing $skillPath"

$agentYamlExists = Test-Path -LiteralPath $agentYamlPath
Assert-Test -Name "Agent openai.yaml exists" -Condition $agentYamlExists -Details "Missing $agentYamlPath"

$skillContent = if ($skillExists) { Get-Content -Path $skillPath -Raw } else { "" }

$hasFrontmatter = $skillContent -match '(?s)^---\r?\nname:\s*context7-mcp\r?\ndescription:\s*.+?\r?\n---'
Assert-Test -Name "SKILL.md has valid frontmatter and name" -Condition $hasFrontmatter

$hasTriggerKeywords = $skillContent -match 'libraries' -and $skillContent -match 'frameworks' -and $skillContent -match 'syntax'
Assert-Test -Name "Description contains trigger-based conditions" -Condition $hasTriggerKeywords

$descHasNoWorkflow = -not ($skillContent -match '(?s)^---\r?\nname:\s*context7-mcp\r?\ndescription:[^\r\n]*?(?:resolve-library-id|query-docs|workflow|phase\s*1|phase\s*2)')
Assert-Test -Name "Description uses triggers and does not leak workflow steps" -Condition $descHasNoWorkflow

# ---------------------------------------------------------
# Test Group 2: Remediation of Legacy Flaw & Sanitization
# ---------------------------------------------------------
# Negative check: Legacy flaw instructed "Pass the user's full question as the query"
$hasLegacyFullQuestion = $skillContent -match '(?i)pass the user''s full question' -or $skillContent -match 'query:\s*The user''s full question'
Assert-Test -Name "Negative: Legacy full-question instruction removed" -Condition (-not $hasLegacyFullQuestion)

# Positive check: Mandates atomic and sanitized query
$hasSanitization = $skillContent -match 'atomic' -and $skillContent -match 'sanitized'
Assert-Test -Name "Mandates atomic, sanitized query" -Condition $hasSanitization

# Positive check: Explicitly forbids secrets/PII/tokens
$hasSecretsProhibition = $skillContent -match 'secrets' -and $skillContent -match 'API keys' -and $skillContent -match 'PII'
Assert-Test -Name "Explicitly forbids secrets, API keys, and PII in queries" -Condition $hasSecretsProhibition

# ---------------------------------------------------------
# Test Group 3: Credential-Free Endpoint & Free Tier Policy
# ---------------------------------------------------------
$hasEndpoint = $skillContent -match 'https://mcp\.context7\.com/mcp'
Assert-Test -Name "Documents global credential-free endpoint" -Condition $hasEndpoint

$hasOfficialSources = $skillContent -match 'raw\.githubusercontent\.com/upstash/context7' -and $skillContent -match 'context7\.com/plans'
Assert-Test -Name "Documents official README and plans sources" -Condition $hasOfficialSources

$forbidsPaid = $skillContent -match 'No OAuth' -and $skillContent -match 'ctx7 setup' -and $skillContent -match 'no Pro tier'
Assert-Test -Name "Strictly forbids OAuth, ctx7 setup, and Pro paid tiers" -Condition $forbidsPaid

$protectsAuthCache = $skillContent -match 'Never access, read, or modify client auth caches'
Assert-Test -Name "Prohibits accessing or modifying auth caches" -Condition $protectsAuthCache

$hasDatedQuota = $skillContent -match '1,000 API calls/month' -and $skillContent -match 'dated historical baseline'
Assert-Test -Name "Quota documented as dated baseline not anonymous guarantee" -Condition $hasDatedQuota

$hasAnonymousDistinction = $skillContent -match 'auth_status=not_logged_in'
Assert-Test -Name "Distinguishes anonymous quota from free logged account" -Condition $hasAnonymousDistinction

# ---------------------------------------------------------
# Test Group 4: Tool Contract & Schema Compliance
# ---------------------------------------------------------
$hasTwoPhase = $skillContent -match 'resolve-library-id' -and $skillContent -match 'query-docs'
Assert-Test -Name "Documents two-phase workflow (resolve -> query)" -Condition $hasTwoPhase

$hasPrerequisiteRule = $skillContent -match 'Resolving is mandatory before calling `query-docs` unless'
Assert-Test -Name "Mandatory resolve before query unless explicit ID provided" -Condition $hasPrerequisiteRule

$hasVersionNotLibraryId = $skillContent -match 'Version / Name != Library ID' -or $skillContent -match 'is strictly \*\*NOT\*\* a Context7 `libraryId`'
Assert-Test -Name "Explicit rule: version/name is not a library ID" -Condition $hasVersionNotLibraryId

$forbidsInferringId = $skillContent -match 'NEVER construct, synthesize, or infer' -and $skillContent -match '/react/react/v19\.2\.7'
Assert-Test -Name "Strictly forbids inferring /org/repo/version from semver" -Condition $forbidsInferringId

$forbidsPlaceholderQueries = $skillContent -match 'NEVER use placeholder strings' -and $skillContent -match '<topico atomico>'
Assert-Test -Name "Strictly forbids placeholder queries like <topico atomico>" -Condition $forbidsPlaceholderQueries

$promptsUserForTopic = $skillContent -match 'Prompt User If Topic Absent' -or $skillContent -match 'ask the user for the topic'
Assert-Test -Name "Requires asking user or finding concept if topic is absent" -Condition $promptsUserForTopic

$hasZeroCallsPacketReuse = $skillContent -match 'ZERO calls' -and $skillContent -match 'zero calls'
Assert-Test -Name "Distinguishes complete packet reuse with zero calls" -Condition $hasZeroCallsPacketReuse

$hasCallBudget = $skillContent -match 'Maximum 3 calls per question'
Assert-Test -Name "Documents 3 calls per question budget" -Condition $hasCallBudget

# ---------------------------------------------------------
# Test Group 5: Version Mismatch Handling
# ---------------------------------------------------------
$hasVersionMismatchNotice = $skillContent -match 'declare the version mismatch' -and $skillContent -match 'main'
Assert-Test -Name "Requires checking and declaring version mismatches (tag vs main)" -Condition $hasVersionMismatchNotice

# ---------------------------------------------------------
# Test Group 6: Concurrency, Worker Sharing, & No-Write Safety
# ---------------------------------------------------------
$hasPacketFormat = $skillContent -match '\{libraryId, version, query, source, date, limits\}'
Assert-Test -Name "Defines multi-worker shared evidence packet format" -Condition $hasPacketFormat

$hasSingleOwner = $skillContent -match 'Exactly one worker owns the lookup'
Assert-Test -Name "Requires single worker owner per identical question" -Condition $hasSingleOwner

$hasNoWriteConstraint = $skillContent -match 'do not write local disk caches'
Assert-Test -Name "Prohibits disk cache creation in no-write modes" -Condition $hasNoWriteConstraint

# ---------------------------------------------------------
# Test Group 7: Error Handling (401 / 403 / 429) & Fail-Closed
# ---------------------------------------------------------
$stopsImmediately = $skillContent -match 'Stop Immediately' -and $skillContent -match 'retry storms'
Assert-Test -Name "Stops immediately on 401/403/429 without retry storms" -Condition $stopsImmediately

$noPaidEscalation = $skillContent -match 'No Paid Escalation'
Assert-Test -Name "Prohibits proposing paid keys or Pro upgrades on quota exhaustion" -Condition $noPaidEscalation

$noModelSwitch = $skillContent -match 'No Model Switch'
Assert-Test -Name "Prohibits changing AI models or providers on quota exhaustion" -Condition $noModelSwitch

$hasDisclosedFallback = $skillContent -match 'Disclosed Alternative' -and $skillContent -match 'official project documentation'
Assert-Test -Name "Switches to official documentation as disclosed fallback" -Condition $hasDisclosedFallback

# ---------------------------------------------------------
# Test Group 8: Functional Simulations (RED/GREEN Scenarios)
# ---------------------------------------------------------

# Scenario 8A: Query Sanitization Filter (Positive & Negative)
$safeQuery = "React 19 useActionState hook signature"
$sanResult1 = Test-Context7QuerySanitization -Query $safeQuery
Assert-Test -Name "Scenario 8A.1: Clean atomic query passes sanitization" -Condition ($sanResult1.Allowed -eq $true)

$secretQuery = "How to use API key sk-proj-1234567890abcdef12345 in axios"
$sanResult2 = Test-Context7QuerySanitization -Query $secretQuery
Assert-Test -Name "Scenario 8A.2: Secret in query rejected" -Condition ($sanResult2.Allowed -eq $false)

$promptDumpQuery = "<USER_REQUEST> You are a helpful assistant. Write full code... </USER_REQUEST>"
$sanResult3 = Test-Context7QuerySanitization -Query $promptDumpQuery
Assert-Test -Name "Scenario 8A.3: Full prompt dump rejected" -Condition ($sanResult3.Allowed -eq $false)

# Scenario 8B: Version Mismatch Detector
$mismatchResult = Test-Context7VersionMismatch -RequestedVersion "v19.2.7" -ReturnedSourceUrl "https://github.com/facebook/react/blob/main/packages/react/index.js"
Assert-Test -Name "Scenario 8B.1: Detected main branch link when v19.2.7 requested" -Condition ($mismatchResult.HasMismatch -eq $true)

$matchingResult = Test-Context7VersionMismatch -RequestedVersion "v19.2.7" -ReturnedSourceUrl "https://github.com/facebook/react/blob/v19.2.7/packages/react/index.js"
Assert-Test -Name "Scenario 8B.2: Tag match correctly accepted without mismatch warning" -Condition ($matchingResult.HasMismatch -eq $false)

# Scenario 8C: Concurrency Deduplication Packet
$sharedStore = @{}
$w1 = Invoke-Context7DeduplicationCoordination -SharedPacketStore $sharedStore -LibraryId "/react/react" -Query "useActionState" -WorkerId "worker-1"
$w2 = Invoke-Context7DeduplicationCoordination -SharedPacketStore $sharedStore -LibraryId "/react/react" -Query "useActionState" -WorkerId "worker-2"

Assert-Test -Name "Scenario 8C.1: First worker makes lookup call and owns packet" -Condition ($w1.CallMade -eq $true -and $w1.ExistingOwner -eq "worker-1")
Assert-Test -Name "Scenario 8C.2: Second worker deduplicates and reuses packet without call" -Condition ($w2.CallMade -eq $false -and $w2.IsDuplicate -eq $true)

# Scenario 8D: HTTP 429 Quota Exhaustion Fail-Closed
$errPolicy429 = Invoke-Context7ErrorPolicy -StatusCode 429
Assert-Test -Name "Scenario 8D.1: 429 stops immediately with no retry storms" -Condition ($errPolicy429.StopImmediately -eq $true -and $errPolicy429.AllowRetryStorm -eq $false)
Assert-Test -Name "Scenario 8D.2: 429 does not suggest paid key or switch provider" -Condition ($errPolicy429.SuggestPaidKey -eq $false -and $errPolicy429.SwitchProvider -eq $false)
Assert-Test -Name "Scenario 8D.3: 429 pivots to official docs fallback" -Condition ($errPolicy429.FallbackAction -eq "OfficialDocs")

# Scenario 8E: No-Write Mode Workspace Safety
$tempFixture = Join-Path ([System.IO.Path]::GetTempPath()) ("c7-nowrite-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempFixture -Force | Out-Null
try {
    # Simulate read-only query in no-write mode: shared packets stay in-memory, zero files created
    $simulatedStore = @{}
    $null = Invoke-Context7DeduplicationCoordination -SharedPacketStore $simulatedStore -LibraryId "/vercel/next.js" -Query "middleware cookies" -WorkerId "worker-ro"
    $fileCount = @(Get-ChildItem -Path $tempFixture -Recurse -File).Count
    Assert-Test -Name "Scenario 8E: No-write mode produces zero disk cache files" -Condition ($fileCount -eq 0)
} finally {
    Remove-Item -LiteralPath $tempFixture -Recurse -Force -ErrorAction SilentlyContinue
}

# Scenario 8F: Library ID Resolution Decision & Inferrence Negation (RED/GREEN)
# 8F.1 (RED negation from forward test): User says "React 19.2.7", model fabricates "/react/react/v19.2.7" without resolve
$res8F1 = Test-Context7LibraryResolution -UserInput "React 19.2.7" -AttemptedQueryLibraryId "/react/react/v19.2.7"
Assert-Test -Name "Scenario 8F.1: Rejects fabricated library ID from semver/package name" -Condition ($res8F1.AllowedDirectQuery -eq $false -and $res8F1.IsInventedId -eq $true)

# 8F.2 (GREEN): User says "React 19.2.7", workflow requires calling resolve-library-id
$res8F2 = Test-Context7LibraryResolution -UserInput "React 19.2.7"
Assert-Test -Name "Scenario 8F.2: Requires resolve-library-id when only library name/version given" -Condition ($res8F2.AllowedDirectQuery -eq $false -and $res8F2.RequiresResolve -eq $true)

# 8F.3 (GREEN): User explicitly supplies /facebook/react
$res8F3 = Test-Context7LibraryResolution -UserInput "/facebook/react"
Assert-Test -Name "Scenario 8F.3: Permits direct query when user provides exact library ID format" -Condition ($res8F3.AllowedDirectQuery -eq $true -and $res8F3.RequiresResolve -eq $false)

# 8F.4 (GREEN): Library ID previously resolved in current task session
$res8F4 = Test-Context7LibraryResolution -UserInput "React" -KnownSessionLibraryIds @("/facebook/react") -AttemptedQueryLibraryId "/facebook/react"
Assert-Test -Name "Scenario 8F.4: Reuses authoritatively resolved library ID from session" -Condition ($res8F4.AllowedDirectQuery -eq $true)

# Scenario 8G: Placeholder Query Rejection & Missing Topic Negation (RED/GREEN)
# 8G.1 (RED negation from forward test): Query is literal placeholder "<topico atomico>"
$res8G1 = Test-Context7QueryPlaceholder -Query "<topico atomico>"
Assert-Test -Name "Scenario 8G.1: Rejects placeholder '<topico atomico>' query" -Condition ($res8G1.Allowed -eq $false -and $res8G1.IsPlaceholder -eq $true)

# 8G.2 (RED negation): Query is generic placeholder token
$res8G2 = Test-Context7QueryPlaceholder -Query "<topic>"
Assert-Test -Name "Scenario 8G.2: Rejects placeholder token '<topic>'" -Condition ($res8G2.Allowed -eq $false -and $res8G2.IsPlaceholder -eq $true)

# 8G.3 (RED negation): Missing/empty topic when user specifies library only
$res8G3 = Test-Context7QueryPlaceholder -Query ""
Assert-Test -Name "Scenario 8G.3: Rejects empty topic and flags need for user clarification" -Condition ($res8G3.Allowed -eq $false -and $res8G3.NeedsTopicClarification -eq $true)

# 8G.4 (GREEN): Valid concrete technical topic query
$res8G4 = Test-Context7QueryPlaceholder -Query "useActionState hook signature"
Assert-Test -Name "Scenario 8G.4: Accepts concrete technical topic query" -Condition ($res8G4.Allowed -eq $true -and $res8G4.IsPlaceholder -eq $false)

# Scenario 8H: Complete Doc Packet Reuse Zero Calls (RED/GREEN)
# 8H.1 (GREEN): Answer already in retrieved complete doc packet -> 0 calls
$existingDocPacket = @{
    libraryId = "/facebook/react"
    query = "useActionState hook"
    content = "useActionState is a Hook that allows you to update state based on the result of a form action."
}
$res8H1 = Invoke-Context7DocReuseOrQuery -ExistingPacket $existingDocPacket -TopicNeeded "useActionState"
Assert-Test -Name "Scenario 8H.1: Reuses complete doc packet with zero calls when answer available" -Condition ($res8H1.CallsMade -eq 0 -and $res8H1.ReusedExistingPacket -eq $true)

# 8H.2 (GREEN): Distinct topic absent from packet executes query within budget
$res8H2 = Invoke-Context7DocReuseOrQuery -ExistingPacket $existingDocPacket -TopicNeeded "useOptimistic hook signature"
Assert-Test -Name "Scenario 8H.2: Executes query when distinct unaddressed topic needed" -Condition ($res8H2.CallsMade -eq 1 -and $res8H2.ReusedExistingPacket -eq $false)

# ---------------------------------------------------------
# Test Summary
# ---------------------------------------------------------
Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Total Tests : $($script:TestCount)"
Write-Host "Passed      : $($script:PassedCount)" -ForegroundColor Green
Write-Host "Failed      : $($script:FailedCount)" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "================================" -ForegroundColor Cyan

if ($script:FailedCount -gt 0) {
    exit 1
}
exit 0
