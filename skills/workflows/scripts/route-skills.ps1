# skills/workflows/scripts/route-skills.ps1
# Evaluates and routes candidate skills during FRAME stage via TypeSafe/Jev System One (noul).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RoutingObjective = '',

    [Parameter(Mandatory = $false)]
    [string]$TaskObjective = '',

    [Parameter(Mandatory = $false)]
    [string]$Mode = '',

    [Parameter(Mandatory = $false)]
    [string]$WorkingDir = '',

    [Parameter(Mandatory = $false)]
    [string]$CodexHome = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('off', 'advisory', 'enforce')]
    [string]$RoutingPolicy = '',

    [Parameter(Mandatory = $false)]
    [string[]]$ForcedSkills = @(),

    [Parameter(Mandatory = $false)]
    [double]$SelectThreshold = 0.70,

    [Parameter(Mandatory = $false)]
    [double]$ReviewThreshold = 0.45,

    [Parameter(Mandatory = $false)]
    [int]$MaxSelectedSkills = 3,

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 25,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 10,

    [Parameter(Mandatory = $false)]
    [hashtable]$MockResponses = $null,

    [Parameter(Mandatory = $false)]
    [switch]$AsJson,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. Resolve configuration and paths
$policy = if (-not [string]::IsNullOrWhiteSpace($RoutingPolicy)) {
    $RoutingPolicy
}
elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_SKILL_ROUTING_POLICY)) {
    $env:CODEX_SKILL_ROUTING_POLICY.ToLowerInvariant()
}
else {
    'advisory'
}

if ($policy -notin @('off', 'advisory', 'enforce')) {
    $policy = 'advisory'
}

$resolvedWorkingDir = if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
    [IO.Path]::GetFullPath($PWD.Path)
}
else {
    [IO.Path]::GetFullPath($WorkingDir)
}

$resolvedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')) }
}
else {
    [IO.Path]::GetFullPath($CodexHome)
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# 2. Objective Sanitization and Data Minimization
function Get-SanitizedRoutingObjective {
    param(
        [string]$PrimaryObjective,
        [string]$FallbackObjective
    )

    $raw = if (-not [string]::IsNullOrWhiteSpace($PrimaryObjective)) {
        $PrimaryObjective
    }
    elseif (-not [string]::IsNullOrWhiteSpace($FallbackObjective)) {
        $FallbackObjective
    }
    else {
        return ''
    }

    # Remove code blocks (fenced ```...``` and inline `...`)
    $cleaned = [regex]::Replace($raw, '(?s)```.*?```', ' ')
    $cleaned = [regex]::Replace($cleaned, '`[^`]+`', ' ')

    # Remove private keys / certificates
    $cleaned = [regex]::Replace($cleaned, '(?s)-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----', ' ')

    # Remove common secrets / token patterns
    $cleaned = [regex]::Replace($cleaned, '(?i)\b(bearer\s+[A-Za-z0-9_\-\.]+)\b', ' ')
    $cleaned = [regex]::Replace($cleaned, '(?i)\b(?:apikey|api_key|token|password|secret|authorization)\s*[:=]\s*[^\s,;]+', ' ')
    $cleaned = [regex]::Replace($cleaned, '\b(?:sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{20,}|glpat-[a-zA-Z0-9]{20,}|apikey_[a-zA-Z0-9_]{20,})\b', ' ')

    # Remove env assignments
    $cleaned = [regex]::Replace($cleaned, '(?m)^\s*[A-Z0-9_]{3,}\s*=\s*[^\r\n]+$', ' ')

    # Remove diff headers / git patches
    $cleaned = [regex]::Replace($cleaned, '(?m)^\s*(?:diff --git|index [a-f0-9]+|\+\+\+ |--- |@@ -\d+,\d+ \+\d+,\d+ @@).*$', ' ')

    # Remove stack trace lines
    $cleaned = [regex]::Replace($cleaned, '(?m)^\s*at\s+[A-Za-z0-9_.<>]+\(.*?\)\s*$', ' ')

    # Collapse multiple whitespace into single line
    $cleaned = [regex]::Replace($cleaned, '\s+', ' ').Trim()

    # Bound length to 300 characters
    if ($cleaned.Length -gt 300) {
        $cleaned = $cleaned.Substring(0, 300).Trim()
    }

    return $cleaned
}

$cleanObjective = Get-SanitizedRoutingObjective -PrimaryObjective $RoutingObjective -FallbackObjective $TaskObjective

# 3. Helper functions for parsing and discovery
function Get-SkillFrontmatter {
    param([Parameter(Mandatory = $true)][string]$SkillMdPath)

    if (-not (Test-Path -LiteralPath $SkillMdPath -PathType Leaf)) {
        return $null
    }

    $rawContent = ''
    try {
        # Read first 2KB to minimize I/O and memory
        $stream = [IO.File]::OpenRead($SkillMdPath)
        try {
            $buffer = New-Object byte[] 2048
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
            $rawContent = $encoding.GetString($buffer, 0, $bytesRead)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $null
    }

    $rawContent = $rawContent.TrimStart([char]0xFEFF)
    $frontmatterMatch = [regex]::Match($rawContent, '(?s)^\s*---\r?\n(.*?)\r?\n---')
    if (-not $frontmatterMatch.Success) {
        $dirName = Split-Path -Leaf (Split-Path -Parent $SkillMdPath)
        return [ordered]@{
            name = $dirName
            description = ''
        }
    }

    $fmText = $frontmatterMatch.Groups[1].Value
    $nameMatch = [regex]::Match($fmText, '(?m)^name:\s*[''"]?(.*?)[''"]?\s*$')
    $name = if ($nameMatch.Success -and -not [string]::IsNullOrWhiteSpace($nameMatch.Groups[1].Value)) {
        $nameMatch.Groups[1].Value.Trim()
    }
    else {
        Split-Path -Leaf (Split-Path -Parent $SkillMdPath)
    }

    $descMatch = [regex]::Match($fmText, '(?m)^description:\s*([^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*)')
    $description = if ($descMatch.Success) {
        $descMatch.Groups[1].Value.Trim() -replace '\s+', ' '
    }
    else {
        ''
    }

    return [ordered]@{
        name = $name
        description = $description
    }
}

function Get-RepositoryRoot {
    param([string]$StartDir)

    if (-not (Test-Path -LiteralPath $StartDir -PathType Container)) {
        return $StartDir
    }

    try {
        $gitOut = git -C $StartDir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitOut)) {
            $rootPath = $gitOut.Trim()
            if (Test-Path -LiteralPath $rootPath -PathType Container) {
                return [IO.Path]::GetFullPath($rootPath)
            }
        }
    }
    catch {
        # Fall back to upward directory scan
    }

    $curr = [IO.Path]::GetFullPath($StartDir)
    while ($null -ne $curr) {
        $gitDir = Join-Path $curr '.git'
        if (Test-Path -LiteralPath $gitDir) {
            return $curr
        }
        $parent = Split-Path -Parent $curr
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $curr) {
            break
        }
        $curr = $parent
    }

    return [IO.Path]::GetFullPath($StartDir)
}

# 4. Discover Kit Skills (Strict Ownership)
$discoveredSkills = [ordered]@{}

# Check install-state.json (highest authority for kit managed skills)
$statePath = Join-Path $resolvedCodexHome 'codex-workflows-kit\install-state.json'
$kitSkillsDiscovered = $false
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $stateJson = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($stateJson.PSObject.Properties.Name -contains 'files' -and $null -ne $stateJson.files) {
            foreach ($entry in @($stateJson.files)) {
                $filePath = [string]$entry.path
                if ($filePath -match '(?:^|[\\/])SKILL\.md$') {
                    $skillName = Split-Path -Leaf (Split-Path -Parent $filePath)
                    $stableId = "kit:$skillName"
                    if (-not $discoveredSkills.Contains($stableId) -and (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                        $meta = Get-SkillFrontmatter -SkillMdPath $filePath
                        if ($null -ne $meta) {
                            $discoveredSkills[$stableId] = [ordered]@{
                                id = $stableId
                                name = [string]$meta.name
                                description = [string]$meta.description
                                scope = 'kit'
                                path = $filePath
                                source = 'install-state'
                            }
                            $kitSkillsDiscovered = $true
                        }
                    }
                }
            }
        }
    }
    catch {
        # Fall through to checkout check
    }
}

# Fallback: verified kit repository checkout only (never generic global directories)
if (-not $kitSkillsDiscovered) {
    $repoRootCandidate = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) ''
    $kitWorkflowsSkill = Join-Path $repoRootCandidate 'skills\workflows\SKILL.md'
    $kitInstaller = Join-Path $repoRootCandidate 'scripts\install.ps1'

    if ((Test-Path -LiteralPath $kitWorkflowsSkill -PathType Leaf) -and (Test-Path -LiteralPath $kitInstaller -PathType Leaf)) {
        $kitSkillsDir = Join-Path $repoRootCandidate 'skills'
        if (Test-Path -LiteralPath $kitSkillsDir -PathType Container) {
            $subDirs = Get-ChildItem -LiteralPath $kitSkillsDir -Directory -ErrorAction SilentlyContinue
            foreach ($dir in $subDirs) {
                $skillMd = Join-Path $dir.FullName 'SKILL.md'
                if (Test-Path -LiteralPath $skillMd -PathType Leaf) {
                    $skillName = $dir.Name
                    $stableId = "kit:$skillName"
                    if (-not $discoveredSkills.Contains($stableId)) {
                        $meta = Get-SkillFrontmatter -SkillMdPath $skillMd
                        if ($null -ne $meta) {
                            $discoveredSkills[$stableId] = [ordered]@{
                                id = $stableId
                                name = [string]$meta.name
                                description = [string]$meta.description
                                scope = 'kit'
                                path = $skillMd
                                source = 'kit-repo'
                            }
                        }
                    }
                }
            }
        }
    }
}

# 5. Discover Repository Skills (Hierarchical Ancestor Chain: CWD -> Repo Root)
if (Test-Path -LiteralPath $resolvedWorkingDir -PathType Container) {
    $repoRoot = Get-RepositoryRoot -StartDir $resolvedWorkingDir

    # Build ancestor chain from resolvedWorkingDir up to repoRoot
    $dirChain = New-Object System.Collections.Generic.List[string]
    $scanDir = $resolvedWorkingDir
    while ($true) {
        $dirChain.Add($scanDir)
        if ($scanDir.TrimEnd('\', '/') -ieq $repoRoot.TrimEnd('\', '/')) {
            break
        }
        $parentDir = Split-Path -Parent $scanDir
        if ([string]::IsNullOrWhiteSpace($parentDir) -or $parentDir -eq $scanDir) {
            break
        }
        $scanDir = $parentDir
    }

    # At each level in the ancestor chain, check for .agents/skills (exclude siblings)
    foreach ($dir in $dirChain) {
        $skillsFolder = Join-Path $dir '.agents\skills'
        if (Test-Path -LiteralPath $skillsFolder -PathType Container) {
            $skillDirs = Get-ChildItem -LiteralPath $skillsFolder -Directory -ErrorAction SilentlyContinue
            foreach ($sDir in $skillDirs) {
                $skillMd = Join-Path $sDir.FullName 'SKILL.md'
                if (Test-Path -LiteralPath $skillMd -PathType Leaf) {
                    # Generate stable ID with relative path from repoRoot
                    $relPath = if ($sDir.FullName.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $sDir.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                    }
                    else {
                        $sDir.Name
                    }

                    $stableId = "repo:$relPath"
                    if (-not $discoveredSkills.Contains($stableId)) {
                        $meta = Get-SkillFrontmatter -SkillMdPath $skillMd
                        if ($null -ne $meta) {
                            $discoveredSkills[$stableId] = [ordered]@{
                                id = $stableId
                                name = [string]$meta.name
                                description = [string]$meta.description
                                scope = 'repo'
                                path = $skillMd
                                source = 'repo-agents'
                            }
                        }
                    }
                }
            }
        }
    }
}

# 6. Classify Forced Skills
$forcedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

# Workflows skill is always forced (canonical router)
$forcedSet.Add('workflows') | Out-Null
$forcedSet.Add('kit:workflows') | Out-Null

# Explicit user-requested skills
if ($null -ne $ForcedSkills) {
    foreach ($s in $ForcedSkills) {
        if (-not [string]::IsNullOrWhiteSpace($s)) {
            $forcedSet.Add($s.Trim()) | Out-Null
            $forcedSet.Add("kit:$($s.Trim())") | Out-Null
            $forcedSet.Add("repo:$($s.Trim())") | Out-Null
        }
    }
}

# Workflow policy hard rules:
# Evidence-first is mandatory for claims or specific verification contexts
$objectiveForClaimMatch = "$cleanObjective $TaskObjective"
if ($Mode -in @('RESEARCH.DEEP', 'P.DEEP') -or ($objectiveForClaimMatch -match '(?i)\b(evidence|fact-check|verify external|claim)\b')) {
    $forcedSet.Add('evidence-first') | Out-Null
    $forcedSet.Add('kit:evidence-first') | Out-Null
}

# 7. Process Candidate Skills
$results = New-Object System.Collections.Generic.List[object]
$candidatesToEvaluate = New-Object System.Collections.Generic.List[object]

foreach ($candId in $discoveredSkills.Keys) {
    $cand = $discoveredSkills[$candId]
    $cName = [string]$cand.name

    $isForced = $forcedSet.Contains($candId) -or $forcedSet.Contains($cName)
    if ($isForced) {
        $results.Add([pscustomobject]@{
            id = $candId
            name = $cName
            decision = 'forced'
            enforced = $true
            score = $null
            scope = $cand.scope
            path = $cand.path
            description = $cand.description
        })
        continue
    }

    if ($policy -eq 'off') {
        # Policy 'off': unrouted, no skip, normal parent GPT resolution preserved
        $results.Add([pscustomobject]@{
            id = $candId
            name = $cName
            decision = 'unrouted'
            enforced = $false
            score = $null
            scope = $cand.scope
            path = $cand.path
            description = $cand.description
        })
        continue
    }

    $candidatesToEvaluate.Add($cand)
}

# 8. TypeSafe / Jev Batch Evaluation
$jevStatus = 'ok'
$jevError = $null
$jevCallsCount = 0
$evaluatedSkills = New-Object System.Collections.Generic.List[object]

if ($candidatesToEvaluate.Count -gt 0 -and $policy -ne 'off') {
    # Chunk candidates into batches of size $BatchSize
    $batchList = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $candidatesToEvaluate.Count; $i += $BatchSize) {
        $chunkCount = [Math]::Min($BatchSize, $candidatesToEvaluate.Count - $i)
        $batch = $candidatesToEvaluate.GetRange($i, $chunkCount)
        $batchList.Add($batch)
    }

    foreach ($batch in $batchList) {
        if ($null -ne $MockResponses) {
            # Offline mock evaluation
            $jevCallsCount++
            foreach ($cand in $batch) {
                $candId = [string]$cand.id
                $candName = [string]$cand.name

                $hasMock = $false
                $mockVal = $null
                if ($MockResponses.ContainsKey($candId)) {
                    $hasMock = $true
                    $mockVal = $MockResponses[$candId]
                }
                elseif ($MockResponses.ContainsKey($candName)) {
                    $hasMock = $true
                    $mockVal = $MockResponses[$candName]
                }

                if ($hasMock) {
                    if ($mockVal -is [hashtable] -and $mockVal.ContainsKey('error')) {
                        $results.Add([pscustomobject]@{
                            id = $candId
                            name = $candName
                            decision = 'review'
                            enforced = $false
                            score = $null
                            scope = $cand.scope
                            path = $cand.path
                            description = $cand.description
                            note = 'jev_unavailable'
                        })
                    }
                    else {
                        $evaluatedSkills.Add([pscustomobject]@{
                            id = $candId
                            name = $candName
                            score = [double]$mockVal
                            scope = $cand.scope
                            path = $cand.path
                            description = $cand.description
                        })
                    }
                }
                else {
                    # Mock not provided for this candidate: fail safe to review
                    $results.Add([pscustomobject]@{
                        id = $candId
                        name = $candName
                        decision = 'review'
                        enforced = $false
                        score = $null
                        scope = $cand.scope
                        path = $cand.path
                        description = $cand.description
                        note = 'jev_unavailable'
                    })
                }
            }
        }
        else {
            # Live API batch evaluation
            $apiKey = $env:TYPESAFE_API_KEY
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                $jevStatus = 'unavailable'
                $jevError = 'TYPESAFE_API_KEY is not set.'
                foreach ($cand in $batch) {
                    $results.Add([pscustomobject]@{
                        id = [string]$cand.id
                        name = [string]$cand.name
                        decision = 'review'
                        enforced = $false
                        score = $null
                        scope = $cand.scope
                        path = $cand.path
                        description = $cand.description
                        note = 'jev_unavailable'
                    })
                }
            }
            else {
                $jevCallsCount++
                $statePayload = [ordered]@{
                    task = [ordered]@{
                        mode = $Mode
                        objective = $cleanObjective
                    }
                }

                $questions = [ordered]@{}
                $candKeyMap = @{}
                $qIdx = 0
                foreach ($cand in $batch) {
                    $qKey = "q_$qIdx"
                    $candKeyMap[$qKey] = $cand
                    $descSnippet = if (-not [string]::IsNullOrWhiteSpace($cand.description)) {
                        " Description: '$($cand.description)'."
                    } else { '' }

                    $inst = "Given skill '$($cand.name)' (scope: $($cand.scope)).$descSnippet Would loading this skill materially improve the agent's ability to complete this task correctly, rather than merely being superficially related?"
                    $questions[$qKey] = [ordered]@{
                        type = 'noul'
                        instructions = $inst
                    }
                    $qIdx++
                }

                $body = [ordered]@{
                    model = 'jev-latest'
                    state = ($statePayload | ConvertTo-Json -Compress -Depth 4)
                    questions = $questions
                } | ConvertTo-Json -Depth 6

                $endpoint = 'https://api.typesafe.ai/v1/systemone'
                $headers = @{
                    'Authorization' = "Bearer $apiKey"
                    'Content-Type' = 'application/json'
                }

                $batchFailed = $false
                $response = $null
                try {
                    $response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSeconds
                }
                catch {
                    $batchFailed = $true
                    $jevStatus = 'unavailable'
                    $jevError = $_.Exception.Message
                }

                if ($batchFailed -or $null -eq $response -or -not ($response.PSObject.Properties.Name -contains 'answers')) {
                    foreach ($cand in $batch) {
                        $results.Add([pscustomobject]@{
                            id = [string]$cand.id
                            name = [string]$cand.name
                            decision = 'review'
                            enforced = $false
                            score = $null
                            scope = $cand.scope
                            path = $cand.path
                            description = $cand.description
                            note = 'jev_unavailable'
                        })
                    }
                }
                else {
                    $answers = $response.answers
                    foreach ($qKey in $questions.Keys) {
                        $cand = $candKeyMap[$qKey]
                        $candId = [string]$cand.id
                        $candName = [string]$cand.name

                        $score = $null
                        if ($answers.PSObject.Properties.Name -contains $qKey) {
                            $qAns = $answers.$qKey
                            if ($null -ne $qAns) {
                                if ($qAns.PSObject.Properties.Name -contains 'noul') {
                                    $score = [double]$qAns.noul
                                }
                                elseif ($qAns -is [double] -or $qAns -is [int] -or $qAns -is [decimal]) {
                                    $score = [double]$qAns
                                }
                            }
                        }

                        if ($null -ne $score) {
                            $evaluatedSkills.Add([pscustomobject]@{
                                id = $candId
                                name = $candName
                                score = $score
                                scope = $cand.scope
                                path = $cand.path
                                description = $cand.description
                            })
                        }
                        else {
                            # Safe fallback for candidate missing in answers
                            $results.Add([pscustomobject]@{
                                id = $candId
                                name = $candName
                                decision = 'review'
                                enforced = $false
                                score = $null
                                scope = $cand.scope
                                path = $cand.path
                                description = $cand.description
                                note = 'jev_unavailable'
                            })
                        }
                    }
                }
            }
        }
    }
}

# 9. Apply Thresholds, Capacity Bounds, and Policy Enforcement
$isEnforce = ($policy -eq 'enforce')

if ($evaluatedSkills.Count -gt 0) {
    $selectCandidates = New-Object System.Collections.Generic.List[object]

    foreach ($item in $evaluatedSkills) {
        $sc = [double]$item.score
        if ($sc -ge $SelectThreshold) {
            $selectCandidates.Add($item)
        }
        elseif ($sc -ge $ReviewThreshold) {
            # Review candidates: escalated to parent GPT under both advisory and enforce
            $results.Add([pscustomobject]@{
                id = $item.id
                name = $item.name
                decision = 'review'
                enforced = $false
                score = [Math]::Round($sc, 4)
                scope = $item.scope
                path = $item.path
                description = $item.description
            })
        }
        else {
            # Skip candidates: in advisory enforced=false; in enforce enforced=true
            $results.Add([pscustomobject]@{
                id = $item.id
                name = $item.name
                decision = 'skip'
                enforced = $isEnforce
                score = [Math]::Round($sc, 4)
                scope = $item.scope
                path = $item.path
                description = $item.description
            })
        }
    }

    # Sort select candidates descending by score
    $sortedSelect = @($selectCandidates | Sort-Object -Property score -Descending)
    $selectedCount = 0

    foreach ($sel in $sortedSelect) {
        $sc = [double]$sel.score
        if ($selectedCount -lt $MaxSelectedSkills) {
            # In advisory enforced=false; in enforce enforced=true
            $results.Add([pscustomobject]@{
                id = $sel.id
                name = $sel.name
                decision = 'select'
                enforced = $isEnforce
                score = [Math]::Round($sc, 4)
                scope = $sel.scope
                path = $sel.path
                description = $sel.description
            })
            $selectedCount++
        }
        else {
            # Excess above max_selected_skills downgraded to review (escalated to parent)
            $results.Add([pscustomobject]@{
                id = $sel.id
                name = $sel.name
                decision = 'review'
                enforced = $false
                score = [Math]::Round($sc, 4)
                scope = $sel.scope
                path = $sel.path
                description = $sel.description
                note = 'capacity_limit_exceeded'
            })
        }
    }
}

$stopwatch.Stop()
$elapsedMs = $stopwatch.ElapsedMilliseconds

# 10. Format Summary and Output
$forcedCount = @($results | Where-Object { $_.decision -eq 'forced' }).Count
$selectedCount = @($results | Where-Object { $_.decision -eq 'select' }).Count
$reviewCount = @($results | Where-Object { $_.decision -eq 'review' }).Count
$skippedCount = @($results | Where-Object { $_.decision -eq 'skip' }).Count
$unroutedCount = @($results | Where-Object { $_.decision -eq 'unrouted' }).Count

$forcedList = @(($results | Where-Object { $_.decision -eq 'forced' }) | ForEach-Object { [string]$_.name })
$selectedList = @(($results | Where-Object { $_.decision -eq 'select' }) | ForEach-Object { [string]$_.name })
$reviewList = @(($results | Where-Object { $_.decision -eq 'review' }) | ForEach-Object { [string]$_.name })
$unroutedList = @(($results | Where-Object { $_.decision -eq 'unrouted' }) | ForEach-Object { [string]$_.name })

if (-not $Quiet) {
    $statusText = if ($null -ne $MockResponses) { 'mock' } elseif ($jevStatus -eq 'unavailable') { 'unavailable' } else { 'ok' }
    Write-Host ("[SKILL-ROUTING] policy={0} status={1} calls={2} latency={3}ms | discovered={4} forced={5} evaluated={6} selected={7} review={8} skipped={9} unrouted={10}" -f `
        $policy, $statusText, $jevCallsCount, $elapsedMs, $discoveredSkills.Count, $forcedCount, $evaluatedSkills.Count, $selectedCount, $reviewCount, $skippedCount, $unroutedCount) -ForegroundColor $(if ($jevStatus -eq 'unavailable' -and $policy -ne 'off') { 'Yellow' } else { 'Cyan' })
    if ($jevStatus -eq 'unavailable' -and $policy -ne 'off' -and -not [string]::IsNullOrWhiteSpace($jevError)) {
        Write-Warning "TypeSafe Jev unavailable: $jevError. Falling back safely to parent guidance."
    }
}

$finalStatus = if ($null -ne $MockResponses) { 'mock' } else { $jevStatus }
$outputData = [ordered]@{
    policy = $policy
    status = $finalStatus
    latencyMs = $elapsedMs
    jev_calls = $jevCallsCount
    candidates_evaluated = $evaluatedSkills.Count
    summary = [ordered]@{
        discovered = $discoveredSkills.Count
        forced = $forcedList
        unrouted = $unroutedList
        evaluated = $evaluatedSkills.Count
        selected = $selectedList
        review = $reviewList
        skipped = $skippedCount
    }
    results = @($results.ToArray())
}

if ($AsJson) {
    return ($outputData | ConvertTo-Json -Depth 5)
}

return $outputData
