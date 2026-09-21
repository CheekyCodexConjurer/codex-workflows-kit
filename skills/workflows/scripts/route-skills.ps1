# skills/workflows/scripts/route-skills.ps1
# Evaluates and routes candidate skills during FRAME stage via TypeSafe/Jev System One (noul).

[CmdletBinding()]
param(
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

# 2. Helper functions for parsing and discovery
function Get-SkillFrontmatter {
    param([Parameter(Mandatory = $true)][string]$SkillMdPath)

    if (-not (Test-Path -LiteralPath $SkillMdPath -PathType Leaf)) {
        return $null
    }

    $rawContent = ''
    try {
        # Read only the first 2KB to minimize I/O and context
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

# 3. Discover Kit Skills
$discoveredSkills = [ordered]@{}

# Check install-state.json
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
        # Fall back to directory scanning if state parsing fails
    }
}

# Fallback for kit skills (e.g. running from repo or ~/.agents/skills)
if (-not $kitSkillsDiscovered) {
    $candidateKitDirs = @()
    $thisRepoSkills = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'skills'
    if (Test-Path -LiteralPath $thisRepoSkills -PathType Container) {
        $candidateKitDirs += $thisRepoSkills
    }
    $globalAgentsSkills = Join-Path (Join-Path $env:USERPROFILE '.agents') 'skills'
    if (Test-Path -LiteralPath $globalAgentsSkills -PathType Container) {
        $candidateKitDirs += $globalAgentsSkills
    }

    foreach ($kitDir in $candidateKitDirs) {
        $subDirs = Get-ChildItem -LiteralPath $kitDir -Directory -ErrorAction SilentlyContinue
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
                            source = 'filesystem'
                        }
                    }
                }
            }
        }
        if ($discoveredSkills.Count -gt 0) {
            break
        }
    }
}

# 4. Discover Repository Skills
if (Test-Path -LiteralPath $resolvedWorkingDir -PathType Container) {
    # Recursively find all .agents/skills in repo hierarchy (monorepos/subpackages)
    $skillFiles = @(
        Get-ChildItem -LiteralPath $resolvedWorkingDir -Recurse -Depth 8 -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '[\\/]\.agents[\\/]skills[\\/]' -and
            -not ($_.FullName -match '[\\/](?:\.git|node_modules|bin|obj|\.venv|\.codex|\.gemini|dist|build)[\\/]')
        }
    )

    foreach ($file in $skillFiles) {
        $skillDir = Split-Path -Parent $file.FullName
        $skillLeaf = Split-Path -Leaf $skillDir
        $relPath = $file.FullName.Substring($resolvedWorkingDir.Length).TrimStart('\', '/')
        $relDir = (Split-Path -Parent $relPath) -replace '\\', '/'
        
        $stableId = "repo:$relDir"
        if (-not $discoveredSkills.Contains($stableId)) {
            $meta = Get-SkillFrontmatter -SkillMdPath $file.FullName
            if ($null -ne $meta) {
                $discoveredSkills[$stableId] = [ordered]@{
                    id = $stableId
                    name = [string]$meta.name
                    description = [string]$meta.description
                    scope = 'repo'
                    path = $file.FullName
                    source = 'repo-agents'
                }
            }
        }
    }
}

# 5. Classify Forced Skills
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
if ($Mode -in @('RESEARCH.DEEP', 'P.DEEP') -or ($TaskObjective -match '(?i)\b(evidence|fact-check|verify external|claim)\b')) {
    $forcedSet.Add('evidence-first') | Out-Null
    $forcedSet.Add('kit:evidence-first') | Out-Null
}

# 6. TypeSafe / Jev Evaluation Function
$jevStatus = 'ok'
$jevError = $null

function Invoke-JevEvaluation {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$TaskObj = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$TaskMode = '',
        [Parameter(Mandatory = $false)][System.Collections.IDictionary]$Mocks = $null
    )

    $candId = [string]$Candidate.id
    $candName = [string]$Candidate.name

    # Check mock responses first (offline testing)
    if ($null -ne $Mocks) {
        if ($Mocks.ContainsKey($candId)) {
            $mockVal = $Mocks[$candId]
            if ($mockVal -is [hashtable] -and $mockVal.ContainsKey('error')) {
                throw $mockVal.error
            }
            return [double]$mockVal
        }
        if ($Mocks.ContainsKey($candName)) {
            $mockVal = $Mocks[$candName]
            if ($mockVal -is [hashtable] -and $mockVal.ContainsKey('error')) {
                throw $mockVal.error
            }
            return [double]$mockVal
        }
    }

    $apiKey = $env:TYPESAFE_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'TYPESAFE_API_KEY is not set.'
    }

    $endpoint = 'https://api.typesafe.ai/v1/systemone'
    $headers = @{
        'Authorization' = "Bearer $apiKey"
        'Content-Type' = 'application/json'
    }

    # Minimal state payload: task metadata and skill metadata only.
    # No source code, secrets, env vars, git diffs or file contents.
    $statePayload = [ordered]@{
        task = [ordered]@{
            mode = $TaskMode
            objective = $TaskObj
        }
        skill = [ordered]@{
            name = $candName
            description = [string]$Candidate.description
            scope = [string]$Candidate.scope
        }
    }

    $questionText = "Given the current task, workflow mode, and skill description, would loading this skill materially improve the agent's ability to complete the task correctly, rather than merely being superficially related to the topic?"

    $body = [ordered]@{
        model = 'jev-latest'
        state = ($statePayload | ConvertTo-Json -Compress -Depth 4)
        questions = [ordered]@{
            materially_improves_task = [ordered]@{
                type = 'noul'
                instructions = $questionText
            }
        }
    } | ConvertTo-Json -Depth 6

    $response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSeconds
    if ($null -eq $response -or -not ($response.PSObject.Properties.Name -contains 'answers')) {
        throw 'Invalid or empty response from TypeSafe Jev API.'
    }

    $answers = $response.answers
    if (-not ($answers.PSObject.Properties.Name -contains 'materially_improves_task')) {
        throw 'Response answers missing materially_improves_task noul output.'
    }

    $noulObj = $answers.materially_improves_task
    $score = $null
    if ($noulObj.PSObject.Properties.Name -contains 'noul') {
        $score = [double]$noulObj.noul
    }
    elseif ($noulObj -is [double] -or $noulObj -is [int] -or $noulObj -is [decimal]) {
        $score = [double]$noulObj
    }
    else {
        throw 'Unable to parse noul score from TypeSafe Jev response.'
    }

    return $score
}

# 7. Process candidate skills
$results = New-Object System.Collections.Generic.List[object]
$evaluatedSkills = New-Object System.Collections.Generic.List[object]

foreach ($candId in $discoveredSkills.Keys) {
    $cand = $discoveredSkills[$candId]
    $cName = [string]$cand.name

    $isForced = $forcedSet.Contains($candId) -or $forcedSet.Contains($cName)
    if ($isForced) {
        $results.Add([pscustomobject]@{
            id = $candId
            name = $cName
            decision = 'forced'
            score = $null
            scope = $cand.scope
            path = $cand.path
            description = $cand.description
        })
        continue
    }

    if ($policy -eq 'off') {
        $results.Add([pscustomobject]@{
            id = $candId
            name = $cName
            decision = 'skip'
            score = $null
            scope = $cand.scope
            path = $cand.path
            description = $cand.description
        })
        continue
    }

    # Evaluate via Jev (advisory or enforce)
    $score = $null
    $evalFailed = $false
    try {
        $score = Invoke-JevEvaluation -Candidate $cand -TaskObj $TaskObjective -TaskMode $Mode -Mocks $MockResponses
    }
    catch {
        $evalFailed = $true
        $jevStatus = 'unavailable'
        $jevError = $_.Exception.Message
    }

    if ($evalFailed) {
        # Fail-safe: In advisory or enforce, do not crash; mark as review for parent GPT consideration
        $results.Add([pscustomobject]@{
            id = $candId
            name = $cName
            decision = 'review'
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
            name = $cName
            score = $score
            scope = $cand.scope
            path = $cand.path
            description = $cand.description
        })
    }
}

# 8. Apply Thresholds and Capacity Bounds (MaxSelectedSkills)
# Bootstrap thresholds: >= SelectThreshold -> select; ReviewThreshold to SelectThreshold -> review; < ReviewThreshold -> skip
if ($evaluatedSkills.Count -gt 0) {
    $selectCandidates = New-Object System.Collections.Generic.List[object]
    $otherCandidates = New-Object System.Collections.Generic.List[object]

    foreach ($item in $evaluatedSkills) {
        $sc = [double]$item.score
        if ($sc -ge $SelectThreshold) {
            $selectCandidates.Add($item)
        }
        elseif ($sc -ge $ReviewThreshold) {
            $results.Add([pscustomobject]@{
                id = $item.id
                name = $item.name
                decision = 'review'
                score = [Math]::Round($sc, 4)
                scope = $item.scope
                path = $item.path
                description = $item.description
            })
        }
        else {
            $results.Add([pscustomobject]@{
                id = $item.id
                name = $item.name
                decision = 'skip'
                score = [Math]::Round($sc, 4)
                scope = $item.scope
                path = $item.path
                description = $item.description
            })
        }
    }

    # Sort select candidates by score descending
    $sortedSelect = @($selectCandidates | Sort-Object -Property score -Descending)
    $selectedCount = 0

    foreach ($sel in $sortedSelect) {
        $sc = [double]$sel.score
        if ($selectedCount -lt $MaxSelectedSkills) {
            $results.Add([pscustomobject]@{
                id = $sel.id
                name = $sel.name
                decision = 'select'
                score = [Math]::Round($sc, 4)
                scope = $sel.scope
                path = $sel.path
                description = $sel.description
            })
            $selectedCount++
        }
        else {
            # Excess above max_selected_skills downgraded to review
            $results.Add([pscustomobject]@{
                id = $sel.id
                name = $sel.name
                decision = 'review'
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

# 9. Format Summary and Output
$forcedCount = @($results | Where-Object { $_.decision -eq 'forced' }).Count
$selectedCount = @($results | Where-Object { $_.decision -eq 'select' }).Count
$reviewCount = @($results | Where-Object { $_.decision -eq 'review' }).Count
$skippedCount = @($results | Where-Object { $_.decision -eq 'skip' }).Count

$forcedList = @(($results | Where-Object { $_.decision -eq 'forced' }) | ForEach-Object { [string]$_.name })
$selectedList = @(($results | Where-Object { $_.decision -eq 'select' }) | ForEach-Object { [string]$_.name })
$reviewList = @(($results | Where-Object { $_.decision -eq 'review' }) | ForEach-Object { [string]$_.name })

if (-not $Quiet) {
    $statusText = if ($null -ne $MockResponses) { 'mock' } elseif ($jevStatus -eq 'unavailable') { 'unavailable' } else { 'ok' }
    Write-Host ("[SKILL-ROUTING] policy={0} status={1} latency={2}ms | discovered={3} forced={4} evaluated={5} selected={6} review={7} skipped={8}" -f `
        $policy, $statusText, $elapsedMs, $discoveredSkills.Count, $forcedCount, $evaluatedSkills.Count, $selectedCount, $reviewCount, $skippedCount) -ForegroundColor $(if ($jevStatus -eq 'unavailable' -and $policy -ne 'off') { 'Yellow' } else { 'Cyan' })
    if ($jevStatus -eq 'unavailable' -and $policy -ne 'off' -and -not [string]::IsNullOrWhiteSpace($jevError)) {
        Write-Warning "TypeSafe Jev unavailable: $jevError. Falling back safely to parent guidance."
    }
}

$finalStatus = if ($null -ne $MockResponses) { 'mock' } else { $jevStatus }
$outputData = [ordered]@{
    policy = $policy
    status = $finalStatus
    latencyMs = $elapsedMs
    summary = [ordered]@{
        discovered = $discoveredSkills.Count
        forced = $forcedList
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
