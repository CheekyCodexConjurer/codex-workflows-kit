# skills/workflows/scripts/context-reranking.psm1
# Reusable core module for TypeSafe/Jev Context Reranking.
# Provides candidate schema validation, exact deduplication, privacy path containment,
# parallel batch evaluation via TypeSafe System One (noul), and budget-bounded context packaging.

Set-StrictMode -Version Latest

function New-ContextCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$SourceRef,
        [Parameter(Mandatory)][string]$Content,
        [Parameter()][string]$Id = '',
        [Parameter()][string]$RepositoryScope = 'repo',
        [Parameter()][string]$RevisionOrHash = 'HEAD',
        [Parameter()][Nullable[int]]$LineStart = $null,
        [Parameter()][Nullable[int]]$LineEnd = $null,
        [Parameter()][int]$OriginalRank = 1,
        [Parameter()][ValidateSet('snippet', 'metadata')][string]$Representation = 'snippet',
        [Parameter()][hashtable]$Metadata = @{}
    )

    $cleanRef = $SourceRef.Trim().Replace('\', '/') -replace '^\./', ''
    $cleanContent = $Content

    $computedId = if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $Id.Trim()
    }
    else {
        $seed = "$RepositoryScope|$cleanRef|$RevisionOrHash|$LineStart|$LineEnd|$Representation"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
            $hashBytes = $sha.ComputeHash($bytes)
            $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
            "cand:$($hex.Substring(0, 16))"
        }
        finally {
            $sha.Dispose()
        }
    }

    return [ordered]@{
        schema_version     = 1
        id                 = $computedId
        source             = $Source.Trim()
        source_ref         = $cleanRef
        repository_scope   = $RepositoryScope.Trim()
        revision_or_hash   = $RevisionOrHash.Trim()
        line_start         = $LineStart
        line_end           = $LineEnd
        original_rank      = $OriginalRank
        representation     = $Representation
        content            = $cleanContent
        provenances        = @(
            [ordered]@{
                source        = $Source.Trim()
                source_ref    = $cleanRef
                original_rank = $OriginalRank
            }
        )
        metadata           = $Metadata
    }
}

function Test-ContextCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Candidate)

    $props = if ($Candidate -is [System.Collections.IDictionary]) { $Candidate.Keys } else { $Candidate.PSObject.Properties.Name }
    $required = @('id', 'source', 'source_ref', 'repository_scope', 'representation', 'content')

    foreach ($req in $required) {
        if ($props -notcontains $req) {
            return $false
        }
    }

    $cId = [string]$Candidate.id
    $cContent = [string]$Candidate.content
    $cRef = [string]$Candidate.source_ref

    if ([string]::IsNullOrWhiteSpace($cId) -or [string]::IsNullOrWhiteSpace($cRef)) {
        return $false
    }

    return $true
}

function Resolve-CanonicalReparsePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string[]]$RelativeSegments
    )

    $current = $BasePath
    foreach ($seg in $RelativeSegments) {
        $next = [IO.Path]::Combine($current, $seg)
        if (Test-Path -LiteralPath $next) {
            $item = Get-Item -LiteralPath $next -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($item -is [IO.DirectoryInfo] -or $item -is [IO.FileInfo]) {
                    $target = $item.ResolveLinkTarget($true)
                    if ($null -ne $target) {
                        $next = [IO.Path]::GetFullPath($target.FullName)
                    }
                }
            }
        }
        $current = $next
    }
    return [IO.Path]::GetFullPath($current)
}

function Resolve-CanonicalDirectoryRoot {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $segments = if ([string]::IsNullOrEmpty($relative)) { @() } else { $relative.Split([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    return Resolve-CanonicalReparsePath -BasePath $root -RelativeSegments $segments
}

function Assert-CandidatePathContainment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Candidate path cannot be empty or whitespace."
    }

    $raw = $RelativePath.Trim()
    if ([IO.Path]::IsPathRooted($raw)) {
        throw "Candidate path must be repository-relative, got rooted path: '$raw'."
    }

    $norm = $raw.Replace('\', '/') -replace '^\./', ''
    $segments = @($norm -split '/')
    if ([string]::IsNullOrWhiteSpace($norm) -or $norm.Contains(':') -or $segments -contains '.' -or $segments -contains '..') {
        throw "Candidate path is not canonical and repository-contained: '$raw'."
    }

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    $repoPrefix = $fullRepoPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    $candidatePath = [IO.Path]::GetFullPath([IO.Path]::Combine($fullRepoPath, ($norm -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $candidatePath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate path escapes repository scope: '$raw'."
    }

    # Reparse resolution (junctions / symlinks)
    $canonicalRepoRoot = Resolve-CanonicalDirectoryRoot -Path $fullRepoPath
    $canonicalRepoPrefix = $canonicalRepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    $resolvedCandidatePath = Resolve-CanonicalReparsePath -BasePath $canonicalRepoRoot -RelativeSegments $segments
    if (-not $resolvedCandidatePath.StartsWith($canonicalRepoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate path escapes repository scope via reparse traversal: '$raw' resolves to '$resolvedCandidatePath'."
    }

    return $norm
}

function Test-CandidateSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRef,
        [Parameter()][string]$Content = ''
    )

    $norm = $SourceRef.Trim().Replace('\', '/') -replace '^\./', '' -replace '^/', ''

    # 1. Block forbidden secret filenames
    if (($norm -match '(?i)(?:^|/)\.env(?:\.[^/]+)?$' -and $norm -notmatch '(?i)(?:^|/)\.env\.example$') -or
        $norm -match '(?i)\.(?:pem|key|pfx|p12)$' -or
        $norm -match '(?i)(?:^|/)id_(?:rsa|dsa|ecdsa|ed25519)(?:\.pub)?$' -or
        $norm -match '(?i)(?:^|/)(?:credentials|secrets|tokens?)\.json$') {
        return [ordered]@{
            Safe = $false
            Reason = "path_matches_secret_pattern"
        }
    }

    # 2. Block sensitive profile / internal configuration files
    if ($norm -match '(?i)(?:^|/)(?:\.codex|\.gemini|\.serena/project\.local)(?:/|$)' -or
        $norm -match '(?i)(?:^|/)config\.toml$') {
        return [ordered]@{
            Safe = $false
            Reason = "path_references_global_or_profile_config"
        }
    }

    # 3. Content scanning: block private keys, tokens, and credentials
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        if ($Content -match '-----BEGIN (?:[A-Z0-9_-]+ )?PRIVATE KEY-----') {
            return [ordered]@{
                Safe = $false
                Reason = "content_contains_private_key"
            }
        }

        if ($Content -match '\bsk-[a-zA-Z0-9]{20,}\b' -or
            $Content -match '\b(?:sk-ant-|ghp_|gho_|github_pat_|glpat-)[a-zA-Z0-9_\-]{20,}\b' -or
            $Content -match '\bAKIA[0-9A-Z]{16}\b' -or
            $Content -match '\bBearer\s+[A-Za-z0-9_\-]{20,}\b' -or
            $Content -match '(?i)(?:api[_-]?key|secret|password|auth_token)\s*[:=]\s*["\x27][^"\x27]{8,}["\x27]') {
            return [ordered]@{
                Safe = $false
                Reason = "content_contains_secret_token"
            }
        }

        if ($Content -match '(?m)^\[(?:mcp_servers|agents|features)(?:\.[^\]]+)?\]') {
            return [ordered]@{
                Safe = $false
                Reason = "content_contains_raw_global_config_dump"
            }
        }
    }

    return [ordered]@{
        Safe = $true
        Reason = $null
    }
}

function Optimize-CandidateSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Candidates = @(),
        [Parameter()][string]$RepoPath = ''
    )

    $idMap = [ordered]@{}
    $exactContentMap = [ordered]@{}
    $duplicatesCount = 0

    foreach ($cand in $Candidates) {
        if (-not (Test-ContextCandidate -Candidate $cand)) {
            throw "Invalid candidate structure encountered in candidate set."
        }

        $cId = [string]$cand.id
        $cContent = [string]$cand.content
        $cRef = [string]$cand.source_ref
        $cScope = [string]$cand.repository_scope
        $cRev = [string]$cand.revision_or_hash
        $cStart = if ($null -ne $cand.line_start) { [int]$cand.line_start } else { $null }
        $cEnd = if ($null -ne $cand.line_end) { [int]$cand.line_end } else { $null }
        $cRank = if ($null -ne $cand.original_rank) { [int]$cand.original_rank } else { 1 }

        # Path containment validation if RepoPath is provided
        if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
            Assert-CandidatePathContainment -RepoPath $RepoPath -RelativePath $cRef | Out-Null
        }

        # Check for duplicate ID with conflicting content (Input Error)
        if ($idMap.Contains($cId)) {
            $existing = $idMap[$cId]
            if ([string]$existing.content -cne $cContent) {
                throw "Input error: Duplicate candidate ID '$cId' with conflicting content."
            }
        }

        # Exact deduplication key: scope + ref + rev + lines + exact content
        $exactKey = "$cScope|$cRef|$cRev|$cStart|$cEnd|$cContent"
        if ($exactContentMap.Contains($exactKey)) {
            $duplicatesCount++
            $master = $exactContentMap[$exactKey]
            # Merge provenance without losing original rank
            $provList = [System.Collections.Generic.List[object]]@($master.provenances)
            $provList.Add([ordered]@{
                source        = [string]$cand.source
                source_ref    = $cRef
                original_rank = $cRank
            })
            $master.provenances = @($provList.ToArray())
            if ($cRank -lt [int]$master.original_rank) {
                $master.original_rank = $cRank
            }
            continue
        }

        # New unique candidate
        $normalized = [ordered]@{
            schema_version   = 1
            id               = $cId
            source           = [string]$cand.source
            source_ref       = $cRef
            repository_scope = $cScope
            revision_or_hash = $cRev
            line_start       = $cStart
            line_end         = $cEnd
            original_rank    = $cRank
            representation   = [string]$cand.representation
            content          = $cContent
            provenances      = @(
                [ordered]@{
                    source        = [string]$cand.source
                    source_ref    = $cRef
                    original_rank = $cRank
                }
            )
            metadata         = if ($cand.metadata) { $cand.metadata } else { @{} }
        }

        $idMap[$cId] = $normalized
        $exactContentMap[$exactKey] = $normalized
    }

    return [ordered]@{
        UniqueCandidates = @($idMap.Values)
        DuplicatesCount  = $duplicatesCount
    }
}

function Invoke-JevRerankBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Candidates = @(),
        [Parameter(Mandatory = $false)][string]$TaskObjective = '',
        [Parameter()][string]$TaskMode = '',
        [Parameter()][string]$Model = 'jev-latest',
        [Parameter()][int]$BatchSize = 20,
        [Parameter()][int]$TimeoutSeconds = 15,
        [Parameter()][hashtable]$MockResponses = $null,
        [Parameter()][scriptblock]$HttpTransportMock = $null
    )

    $scores = [ordered]@{}
    $requestCount = 0
    $totalPayloadBytes = 0
    $actualModel = $Model
    $batchError = $null

    if ($Candidates.Count -eq 0) {
        return [ordered]@{
            Scores             = $scores
            RequestCount       = 0
            PayloadBytes       = 0
            Model              = $actualModel
            ServiceUnavailable = $false
            ErrorMessage       = $null
        }
    }

    # Split candidates into batches
    $candList = [System.Collections.Generic.List[object]]@($Candidates)
    for ($i = 0; $i -lt $candList.Count; $i += $BatchSize) {
        $count = [Math]::Min($BatchSize, $candList.Count - $i)
        $batch = $candList.GetRange($i, $count)

        # 1. Check direct mock responses
        if ($null -ne $MockResponses) {
            $requestCount++
            foreach ($cand in $batch) {
                $cId = [string]$cand.id
                if ($MockResponses.ContainsKey($cId)) {
                    $mVal = $MockResponses[$cId]
                    if ($mVal -is [hashtable] -and $mVal.ContainsKey('error')) {
                        $scores[$cId] = [ordered]@{
                            Score = $null
                            Status = 'error'
                            Message = [string]$mVal.error
                        }
                    }
                    elseif ($null -eq $mVal -or $mVal -is [string] -or [double]::IsNaN([double]$mVal) -or [double]::IsInfinity([double]$mVal) -or [double]$mVal -lt 0.0 -or [double]$mVal -gt 1.0) {
                        $scores[$cId] = [ordered]@{
                            Score = $null
                            Status = 'invalid_score'
                            Message = "Invalid score value from mock: '$mVal'"
                        }
                    }
                    else {
                        $scores[$cId] = [ordered]@{
                            Score = [Math]::Round([double]$mVal, 4)
                            Status = 'ok'
                            Message = $null
                        }
                    }
                }
                else {
                    $scores[$cId] = [ordered]@{
                        Score = $null
                        Status = 'unavailable'
                        Message = 'Missing mock value'
                    }
                }
            }
            continue
        }

        # 2. Prepare HTTP payload
        $questions = [ordered]@{}
        $keyMap = @{}

        $qIdx = 0
        foreach ($cand in $batch) {
            $qKey = "q_$qIdx"
            $keyMap[$qKey] = [string]$cand.id

            $ref = [string]$cand.source_ref
            $rep = [string]$cand.representation
            $linesInfo = if ($null -ne $cand.line_start -and $null -ne $cand.line_end) { " (lines $($cand.line_start)-$($cand.line_end))" } else { "" }
            $contentSnippet = [string]$cand.content
            if ($contentSnippet.Length -gt 1200) {
                $contentSnippet = $contentSnippet.Substring(0, 1200) + "... [truncated]"
            }

            $inst = "Candidate ID: '$($cand.id)' from '$ref'$linesInfo ($rep):`n`"$contentSnippet`"`nDoes this candidate contain materially useful information to investigate or execute the task, including evidence that contradicts hypotheses?"

            $questions[$qKey] = [ordered]@{
                type = 'noul'
                instructions = $inst
                criteria = [ordered]@{
                    true  = "The candidate contains directly relevant code, contract, configuration, test, or contradictory evidence materially useful for the task."
                    false = "The candidate is merely superficially related, tangential, or lacks actionable utility."
                }
            }
            $qIdx++
        }

        $stateObj = [ordered]@{
            task = [ordered]@{
                mode      = $TaskMode
                objective = $TaskObjective
            }
        }

        $bodyObj = [ordered]@{
            model     = $Model
            state     = ($stateObj | ConvertTo-Json -Compress -Depth 4)
            questions = $questions
        }

        $bodyJson = $bodyObj | ConvertTo-Json -Depth 6
        $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($bodyJson)
        $totalPayloadBytes += $bodyBytes

        # 3. Execute request via HttpTransportMock or live REST API
        $responseObj = $null
        $callError = $null

        if ($null -ne $HttpTransportMock) {
            $requestCount++
            try {
                $mockReq = [pscustomobject]@{
                    Endpoint   = 'https://api.typesafe.ai/v1/systemone'
                    Method     = 'POST'
                    BodyJson   = $bodyJson
                    BodyObject = $bodyObj
                    BatchCount = $batch.Count
                }
                $mockRes = & $HttpTransportMock $mockReq
                if ($mockRes -is [string]) {
                    $responseObj = $mockRes | ConvertFrom-Json
                }
                else {
                    $responseObj = $mockRes
                }
            }
            catch {
                $callError = $_.Exception.Message
            }
        }
        else {
            $apiKey = $env:TYPESAFE_API_KEY
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                $callError = 'TYPESAFE_API_KEY environment variable is missing.'
            }
            else {
                $requestCount++
                $headers = @{
                    'Authorization' = "Bearer $apiKey"
                    'Content-Type'  = 'application/json'
                }
                try {
                    $responseObj = Invoke-RestMethod -Uri 'https://api.typesafe.ai/v1/systemone' -Method Post -Headers $headers -Body $bodyJson -TimeoutSec $TimeoutSeconds
                }
                catch {
                    $callError = $_.Exception.Message
                }
            }
        }

        # 4. Parse Answers
        if ($null -ne $callError -or $null -eq $responseObj) {
            $batchError = $callError
            foreach ($cand in $batch) {
                $scores[[string]$cand.id] = [ordered]@{
                    Score   = $null
                    Status  = 'service_unavailable'
                    Message = $callError
                }
            }
            continue
        }

        $resKeys = if ($responseObj -is [System.Collections.IDictionary]) { @($responseObj.Keys) } else { @($responseObj.PSObject.Properties.Name) }
        if ($resKeys -contains 'model' -and -not [string]::IsNullOrWhiteSpace([string]$responseObj.model)) {
            $actualModel = [string]$responseObj.model
        }

        $answers = if ($resKeys -contains 'answers') { $responseObj.answers } else { $null }
        if ($null -eq $answers) {
            $batchError = 'Malformed response: missing answers property.'
            foreach ($cand in $batch) {
                $scores[[string]$cand.id] = [ordered]@{
                    Score   = $null
                    Status  = 'malformed_response'
                    Message = 'Missing answers in response'
                }
            }
            continue
        }

        $ansKeys = if ($answers -is [System.Collections.IDictionary]) { @($answers.Keys) } else { @($answers.PSObject.Properties.Name) }

        foreach ($qKey in $questions.Keys) {
            $cId = $keyMap[$qKey]
            $scoreVal = $null
            $status = 'ok'
            $msg = $null

            if ($ansKeys -contains $qKey) {
                $ans = if ($answers -is [System.Collections.IDictionary]) { $answers[$qKey] } else { $answers.$qKey }
                if ($null -ne $ans) {
                    $rawNum = $null
                    $ansProps = if ($ans -is [System.Collections.IDictionary]) { @($ans.Keys) } else { @($ans.PSObject.Properties.Name) }
                    if ($ansProps -contains 'noul') {
                        $rawNum = if ($ans -is [System.Collections.IDictionary]) { $ans['noul'] } else { $ans.noul }
                    }
                    elseif ($ans -is [double] -or $ans -is [int] -or $ans -is [decimal]) {
                        $rawNum = $ans
                    }

                    if ($null -ne $rawNum -and -not ($rawNum -is [string]) -and -not [double]::IsNaN([double]$rawNum) -and -not [double]::IsInfinity([double]$rawNum)) {
                        $dbl = [double]$rawNum
                        if ($dbl -ge 0.0 -and $dbl -le 1.0) {
                            $scoreVal = [Math]::Round($dbl, 4)
                        }
                        else {
                            $status = 'out_of_range'
                            $msg = "Score out of range [0, 1]: $dbl"
                        }
                    }
                    else {
                        $status = 'invalid_score'
                        $msg = "Invalid score format: $rawNum"
                    }
                }
                else {
                    $status = 'null_answer'
                    $msg = 'Answer value was null'
                }
            }
            else {
                $status = 'missing_answer'
                $msg = 'Candidate question omitted in response'
            }

            $scores[$cId] = [ordered]@{
                Score   = $scoreVal
                Status  = $status
                Message = $msg
            }
        }
    }

    $isUnavailable = @($scores.Values | Where-Object { $_.Status -in @('service_unavailable', 'malformed_response') }).Count -gt 0

    return [ordered]@{
        Scores             = $scores
        RequestCount       = $requestCount
        PayloadBytes       = $totalPayloadBytes
        Model              = $actualModel
        ServiceUnavailable = $isUnavailable
        ErrorMessage       = $batchError
    }
}

function Select-ContextPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Candidates = @(),
        [Parameter(Mandatory = $false)][hashtable]$Evaluations = @{},
        [Parameter()][string[]]$PinnedIds = @(),
        [Parameter()][ValidateRange(0.0, 1.0)][double]$KeepThreshold = 0.75,
        [Parameter()][ValidateRange(0.0, 1.0)][double]$MaybeThreshold = 0.45,
        [Parameter()][ValidateRange(1, 100)][int]$MaxSelectedCandidates = 10,
        [Parameter()][ValidateRange(512, 1048576)][int]$MaxBudgetBytes = 16384,
        [Parameter()][string]$Policy = 'advisory',
        [Parameter()][string]$GlobalStatus = 'ok'
    )

    $pinnedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $PinnedIds) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $pinnedSet.Add($p.Trim()) | Out-Null
        }
    }

    $classified = [System.Collections.Generic.List[object]]::new()

    foreach ($cand in $Candidates) {
        $cId = [string]$cand.id
        $isPinned = $pinnedSet.Contains($cId)

        $eval = if ($Evaluations.ContainsKey($cId)) { $Evaluations[$cId] } else { $null }
        $score = $null
        $evalStatus = 'unrouted'
        $evalMessage = $null

        if ($null -ne $eval) {
            $evalKeys = if ($eval -is [System.Collections.IDictionary]) { @($eval.Keys) } else { @($eval.PSObject.Properties.Name) }
            if ($evalKeys -contains 'Score') {
                $rawScore = if ($eval -is [System.Collections.IDictionary]) { $eval['Score'] } else { $eval.Score }
                if ($null -ne $rawScore) {
                    $score = [double]$rawScore
                }
            }
            if ($evalKeys -contains 'Status') {
                $evalStatus = if ($eval -is [System.Collections.IDictionary]) { [string]$eval['Status'] } else { [string]$eval.Status }
            }
            if ($evalKeys -contains 'Message') {
                $evalMessage = if ($eval -is [System.Collections.IDictionary]) { [string]$eval['Message'] } else { [string]$eval.Message }
            }
        }

        $decision = if ($isPinned) {
            'PINNED'
        }
        elseif ($Policy -eq 'off') {
            'UNROUTED'
        }
        elseif ($null -eq $score) {
            'MAYBE'
        }
        elseif ($score -ge $KeepThreshold) {
            'KEEP'
        }
        elseif ($score -ge $MaybeThreshold) {
            'MAYBE'
        }
        else {
            'DROP'
        }

        $classified.Add([pscustomobject]@{
            Candidate   = $cand
            Id          = $cId
            Score       = $score
            Decision    = $decision
            IsPinned    = $isPinned
            EvalStatus  = $evalStatus
            EvalMessage = $evalMessage
        })
    }

    # Sorting priority for selection:
    # 1. PINNED (sorted by original_rank asc, then id asc)
    # 2. KEEP (sorted by score desc, original_rank asc, id asc)
    # 3. MAYBE or UNROUTED (sorted by score desc, original_rank asc, id asc)
    # 4. DROP (excluded from selection, recorded in manifest)

    $pinnedList = @($classified | Where-Object { $_.IsPinned } | Sort-Object -Property @{ Expression = { $_.Candidate.original_rank }; Ascending = $true }, @{ Expression = { $_.Id }; Ascending = $true })
    $keepList   = @($classified | Where-Object { -not $_.IsPinned -and $_.Decision -eq 'KEEP' } | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Candidate.original_rank }; Ascending = $true }, @{ Expression = { $_.Id }; Ascending = $true })
    $maybeList  = @($classified | Where-Object { -not $_.IsPinned -and ($_.Decision -in @('MAYBE', 'UNROUTED')) } | Sort-Object -Property @{ Expression = { if ($null -ne $_.Score) { $_.Score } else { -1.0 } }; Descending = $true }, @{ Expression = { $_.Candidate.original_rank }; Ascending = $true }, @{ Expression = { $_.Id }; Ascending = $true })
    $dropList   = @($classified | Where-Object { -not $_.IsPinned -and $_.Decision -eq 'DROP' })

    $selected = [System.Collections.Generic.List[object]]::new()
    $manifest = [System.Collections.Generic.List[object]]::new()

    # Pre-check: verify if PINNED alone exceed MaxBudgetBytes
    $pinnedTotalBytes = 0
    foreach ($p in $pinnedList) {
        $pinnedTotalBytes += [System.Text.Encoding]::UTF8.GetByteCount([string]$p.Candidate.content)
    }
    if ($pinnedTotalBytes -gt $MaxBudgetBytes) {
        return [ordered]@{
            version      = 1
            status       = 'budget_exceeded'
            policy       = $Policy
            message      = "Pinned candidate content ($pinnedTotalBytes bytes) exceeds MaxBudgetBytes ($MaxBudgetBytes). Sharding required."
            selected     = @()
            manifest     = @($classified | ForEach-Object {
                [ordered]@{
                    id               = $_.Id
                    source_ref       = $_.Candidate.source_ref
                    line_start       = $_.Candidate.line_start
                    line_end         = $_.Candidate.line_end
                    score            = $_.Score
                    decision         = $_.Decision
                    exclusion_reason = 'budget_exceeded_by_pinned'
                }
            })
            delivered_bytes = 0
            selected_count  = 0
            deferred_count  = $classified.Count
        }
    }

    $tracker = [ordered]@{
        DeliveredBytes = 0
    }

    # Helper to measure addition of candidate
    function Try-AddCandidate {
        param([object]$Item, [string]$ExclusionDefaultReason)

        if ($selected.Count -ge $MaxSelectedCandidates) {
            $manifest.Add([ordered]@{
                id               = $Item.Id
                source_ref       = $Item.Candidate.source_ref
                line_start       = $Item.Candidate.line_start
                line_end         = $Item.Candidate.line_end
                score            = $Item.Score
                decision         = $Item.Decision
                exclusion_reason = 'count_limit_exceeded'
            })
            return $false
        }

        $candBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$Item.Candidate.content)
        if (($tracker.DeliveredBytes + $candBytes) -gt $MaxBudgetBytes) {
            $manifest.Add([ordered]@{
                id               = $Item.Id
                source_ref       = $Item.Candidate.source_ref
                line_start       = $Item.Candidate.line_start
                line_end         = $Item.Candidate.line_end
                score            = $Item.Score
                decision         = $Item.Decision
                exclusion_reason = 'budget_deferred'
            })
            return $false
        }

        # Add to selected
        $selectedObj = [ordered]@{
            id               = $Item.Id
            source           = $Item.Candidate.source
            source_ref       = $Item.Candidate.source_ref
            repository_scope = $Item.Candidate.repository_scope
            revision_or_hash = $Item.Candidate.revision_or_hash
            line_start       = $Item.Candidate.line_start
            line_end         = $Item.Candidate.line_end
            original_rank    = $Item.Candidate.original_rank
            representation   = $Item.Candidate.representation
            content          = $Item.Candidate.content
            score            = $Item.Score
            decision         = $Item.Decision
            provenances      = $Item.Candidate.provenances
        }

        $selected.Add($selectedObj)
        $tracker.DeliveredBytes += $candBytes
        return $true
    }

    # 1. Add Pinned
    foreach ($p in $pinnedList) {
        $candBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$p.Candidate.content)
        $selectedObj = [ordered]@{
            id               = $p.Id
            source           = $p.Candidate.source
            source_ref       = $p.Candidate.source_ref
            repository_scope = $p.Candidate.repository_scope
            revision_or_hash = $p.Candidate.revision_or_hash
            line_start       = $p.Candidate.line_start
            line_end         = $p.Candidate.line_end
            original_rank    = $p.Candidate.original_rank
            representation   = $p.Candidate.representation
            content          = $p.Candidate.content
            score            = $p.Score
            decision         = 'PINNED'
            provenances      = $p.Candidate.provenances
        }
        $selected.Add($selectedObj)
        $tracker.DeliveredBytes += $candBytes
    }

    # 2. Add KEEP
    foreach ($k in $keepList) {
        $null = Try-AddCandidate -Item $k -ExclusionDefaultReason 'budget_deferred'
    }

    # 3. Add MAYBE / UNROUTED
    foreach ($m in $maybeList) {
        $null = Try-AddCandidate -Item $m -ExclusionDefaultReason 'budget_deferred'
    }

    # 4. Record DROP in manifest
    foreach ($d in $dropList) {
        $manifest.Add([ordered]@{
            id               = $d.Id
            source_ref       = $d.Candidate.source_ref
            line_start       = $d.Candidate.line_start
            line_end         = $d.Candidate.line_end
            score            = $d.Score
            decision         = 'DROP'
            exclusion_reason = 'low_relevance'
        })
    }

    $deliveredPackageBytes = if ($selected.Count -gt 0) {
        $jsonStr = $selected | ConvertTo-Json -Depth 6 -Compress
        [System.Text.Encoding]::UTF8.GetByteCount($jsonStr)
    }
    else {
        0
    }

    return [ordered]@{
        version         = 1
        status          = $GlobalStatus
        policy          = $Policy
        selected        = @($selected.ToArray())
        manifest        = @($manifest.ToArray())
        delivered_bytes = $deliveredPackageBytes
        selected_count  = $selected.Count
        deferred_count  = $manifest.Count
    }
}

Export-ModuleMember -Function `
    New-ContextCandidate, `
    Test-ContextCandidate, `
    Assert-CandidatePathContainment, `
    Test-CandidateSafety, `
    Optimize-CandidateSet, `
    Invoke-JevRerankBatch, `
    Select-ContextPackage
