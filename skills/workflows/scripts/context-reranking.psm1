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

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $contentSha256 = try {
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanContent)
        $hashBytes = $sha.ComputeHash($contentBytes)
        -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }

    $computedId = if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $Id.Trim()
    }
    else {
        # Seed includes $contentSha256 so contradictory content at same line range gets distinct IDs
        $seed = "$RepositoryScope|$cleanRef|$RevisionOrHash|$LineStart|$LineEnd|$Representation|$contentSha256"
        $shaId = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
            $hashBytes = $shaId.ComputeHash($bytes)
            $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
            "cand:$($hex.Substring(0, 16))"
        }
        finally {
            $shaId.Dispose()
        }
    }

    return [ordered]@{
        schema_version     = 1
        id                 = $computedId
        source             = $Source.Trim()
        source_ref         = $cleanRef
        repository_scope   = $RepositoryScope.Trim()
        revision_or_hash   = $RevisionOrHash.Trim()
        content_sha256     = $contentSha256
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
                $resolvedTarget = $null
                # 1. PowerShell 7+ / .NET 6+ ResolveLinkTarget API
                if ($item.PSObject.Methods['ResolveLinkTarget']) {
                    try {
                        $target = $item.ResolveLinkTarget($true)
                        if ($null -ne $target) {
                            $resolvedTarget = $target.FullName
                        }
                    }
                    catch {
                        $resolvedTarget = $null
                    }
                }
                # 2. Windows PowerShell 5.1 / .NET Framework fallback using FileSystemInfo.Target
                if ([string]::IsNullOrWhiteSpace($resolvedTarget) -and $item.PSObject.Properties['Target']) {
                    try {
                        $rawTarget = $item.Target
                        if ($rawTarget -is [System.Collections.IEnumerable] -and $rawTarget -isnot [string]) {
                            $rawTarget = @($rawTarget)[0]
                        }
                        if (-not [string]::IsNullOrWhiteSpace($rawTarget)) {
                            if ([IO.Path]::IsPathRooted($rawTarget)) {
                                $resolvedTarget = $rawTarget
                            }
                            else {
                                $parentDir = if ($item -is [IO.DirectoryInfo] -and $item.Parent) {
                                    $item.Parent.FullName
                                }
                                elseif ($item.DirectoryName) {
                                    $item.DirectoryName
                                }
                                else {
                                    $current
                                }
                                $resolvedTarget = [IO.Path]::Combine($parentDir, $rawTarget)
                            }
                        }
                    }
                    catch {
                        $resolvedTarget = $null
                    }
                }

                # 3. Fail closed if the reparse point cannot be safely resolved
                if ([string]::IsNullOrWhiteSpace($resolvedTarget)) {
                    throw "Unable to safely resolve reparse point '$next'. Failing closed for security."
                }
                $next = [IO.Path]::GetFullPath($resolvedTarget)
            }
        }
        $current = $next
    }
    return [IO.Path]::GetFullPath($current)
}

function Format-WindowsProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$Arg = ''
    )

    if ([string]::IsNullOrEmpty($Arg)) {
        return [string][char]34 + [string][char]34
    }

    if ($Arg -notmatch '[\s"]') {
        return $Arg
    }

    # Standard Microsoft CRT / CommandLineToArgvW escaping rules
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([char]34)
    $slashCount = 0
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $c = $Arg[$i]
        if ($c -eq [char]92) {
            $slashCount++
        }
        elseif ($c -eq [char]34) {
            if ($slashCount -gt 0) {
                [void]$sb.Append((New-Object string ([char]92, ($slashCount * 2 + 1))))
            }
            else {
                [void]$sb.Append([char]92)
                [void]$sb.Append([char]34)
            }
            $slashCount = 0
        }
        else {
            if ($slashCount -gt 0) {
                [void]$sb.Append((New-Object string ([char]92, $slashCount)))
                $slashCount = 0
            }
            [void]$sb.Append($c)
        }
    }
    if ($slashCount -gt 0) {
        [void]$sb.Append((New-Object string ([char]92, ($slashCount * 2))))
    }
    [void]$sb.Append([char]34)
    return $sb.ToString()
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

function Sanitize-TaskObjective {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Objective = '',
        [Parameter()][string]$Mode = ''
    )

    if ([string]::IsNullOrWhiteSpace($Objective)) {
        if (-not [string]::IsNullOrWhiteSpace($Mode)) {
            return "Task execution context for $Mode"
        }
        return "Task execution context"
    }

    $clean = $Objective

    # 1. Remove fenced code blocks (```...```)
    $clean = [regex]::Replace($clean, '(?s)```.*?```', ' ')

    # 2. Remove inline backtick code snippets
    $clean = [regex]::Replace($clean, '`[^`\r\n]+`', ' ')

    # 3. Strip git diff hunks and headers
    $clean = [regex]::Replace($clean, '(?m)^(?:diff --git|index [0-9a-f]+\.\.[0-9a-f]+|--- [^\r\n]+|\+\+\+ [^\r\n]+|@@ [^@]+ @@|[+-][^\r\n]*).*$', ' ')

    # 4. Strip stack traces and exceptions
    $clean = [regex]::Replace($clean, '(?i)(?:at\s+[a-zA-Z0-9_.]+(?:\([^)]*\))?\s+in\s+[^\r\n]+|Exception:\s+[^\r\n]+|at\s+[^\r\n]+:line\s+\d+)', ' ')

    # 5. Strip private key blocks
    $clean = [regex]::Replace($clean, '(?si)-----BEGIN[ A-Z0-9_-]+KEY-----.*?-----END[ A-Z0-9_-]+KEY-----', ' ')

    # 6. Strip Authorization and Bearer headers
    $clean = [regex]::Replace($clean, '(?i)(?:Authorization|Proxy-Authorization)\s*:\s*(?:Bearer\s+)?[^\s"'',;]+', ' ')
    $clean = [regex]::Replace($clean, '(?i)\bBearer\s+[a-zA-Z0-9_\-\.]{10,}\b', ' ')

    # 7. Strip secrets, API keys, tokens, and credentials
    $clean = [regex]::Replace($clean, '(?i)\b(?:sk-[a-zA-Z0-9_\-]{15,}|ghp_[a-zA-Z0-9]{20,}|AKIA[0-9A-Z]{16}|apikey_[a-zA-Z0-9_]{20,})\b', ' ')
    $clean = [regex]::Replace($clean, '(?i)(?:api[_-]?key|secret|token|password|auth_token|access_key)\s*[:=]\s*["'']?[^\s"'',;]+["'']?', ' ')

    # 8. Strip env assignments and shell variables
    $clean = [regex]::Replace($clean, '(?m)^\s*[A-Za-z_][A-Za-z0-9_]*=[^\r\n]+', ' ')
    $clean = [regex]::Replace($clean, '\$[A-Za-z_][A-Za-z0-9_]*', ' ')

    # 9. Collapse spaces / newlines
    $clean = [regex]::Replace($clean, '\s+', ' ').Trim()

    # 10. Bounds check: truncate to safe summary (max 300 chars)
    if ($clean.Length -gt 300) {
        $clean = $clean.Substring(0, 300).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($clean) -or $clean.Length -lt 3) {
        if (-not [string]::IsNullOrWhiteSpace($Mode)) {
            return "Task execution context for $Mode"
        }
        return "Task execution context"
    }

    return $clean
}

function Sanitize-MetadataSymbol {
    [CmdletBinding()]
    param([Parameter()][string]$Symbol)

    if ([string]::IsNullOrWhiteSpace($Symbol)) {
        return ''
    }

    $raw = $Symbol.Trim()

    # Reject if containing newlines or control characters
    if ($raw -match '[\r\n\x00-\x1f\x7f]') {
        return ''
    }

    # Reject if containing backticks or code block markers
    if ($raw -match '[`]') {
        return ''
    }

    # Reject prompt-like instructions or injection keywords
    if ($raw -match '(?i)\b(?:ignore|system prompt|previous instructions|assistant|human:|user:|reveal|disregard|you are|instructions)\b') {
        return ''
    }

    # Reject authorization headers, bearer tokens, API keys, secrets
    if ($raw -match '(?i)(?:bearer\s+|authorization|proxy-authorization|sk-|ghp_|AKIA|apikey_|password|secret)') {
        return ''
    }

    # Bound length (structural identifiers: max 120 chars)
    if ($raw.Length -gt 120) {
        return ''
    }

    # Allowlist structural symbol identifier patterns:
    # identifiers, namespace qualifiers (., ::, /), method calls (()), generic syntax (<T>, [T])
    # Reject spaces or prose
    if ($raw -notmatch '^[a-zA-Z0-9_.:\$#\-\(\)]+(?:<[a-zA-Z0-9_.,:\$#\- ]+>|\[[a-zA-Z0-9_.,:\$#\- ]+\])?(?:\(\))?$') {
        return ''
    }

    return $raw
}

function Test-ContextCandidateFreshness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter()][string]$RepoPath = ''
    )

    if (-not (Test-ContextCandidate -Candidate $Candidate)) {
        throw "Invalid candidate passed to Test-ContextCandidateFreshness."
    }

    $ref = [string]$Candidate.source_ref
    $source = if ($Candidate.source) { [string]$Candidate.source } else { '' }
    $representation = if ($Candidate.representation) { [string]$Candidate.representation } else { '' }

    # Check whether freshness is applicable:
    # Applies to local file-backed snippets where RepoPath is present
    $isLocalFile = ($representation -eq 'snippet' -or $source -in @('rg', 'file', 'codebase')) -and ($source -notin @('memory', 'api', 'context7', 'prompt', 'manual', 'synthetic', 'custom'))
    if (-not $isLocalFile -or [string]::IsNullOrWhiteSpace($RepoPath)) {
        return [ordered]@{
            Status      = 'not_applicable'
            Reason      = 'Candidate is not a local file-backed snippet'
            Fresh       = $true
            CurrentHash = $null
        }
    }

    $lineStart = if ($null -ne $Candidate.line_start) { [int]$Candidate.line_start } else { $null }
    $lineEnd = if ($null -ne $Candidate.line_end) { [int]$Candidate.line_end } else { $null }
    $recordedHash = if ($Candidate -is [System.Collections.IDictionary]) {
        if ($Candidate.Contains('content_sha256')) { [string]$Candidate['content_sha256'] } else { $null }
    }
    elseif ($Candidate.PSObject.Properties.Name -contains 'content_sha256') {
        [string]$Candidate.content_sha256
    }
    else {
        $null
    }

    $fullPath = [IO.Path]::Combine([IO.Path]::GetFullPath($RepoPath), ($ref -replace '/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return [ordered]@{
            Status      = 'missing'
            Reason      = "Source file does not exist: $ref"
            Fresh       = $false
            CurrentHash = $null
        }
    }

    $currentContent = $null
    try {
        if ($null -ne $lineStart -and $null -ne $lineEnd -and $lineStart -gt 0 -and $lineEnd -ge $lineStart) {
            $allLines = [IO.File]::ReadAllLines($fullPath, [System.Text.Encoding]::UTF8)
            if ($lineStart -le $allLines.Length) {
                $actualEnd = [Math]::Min($lineEnd, $allLines.Length)
                $sliceLines = $allLines[($lineStart - 1)..($actualEnd - 1)]
                $currentContent = ($sliceLines -join "`n") + "`n"
            }
            else {
                $currentContent = ""
            }
        }
        else {
            $currentContent = [IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
        }
    }
    catch {
        return [ordered]@{
            Status      = 'error'
            Reason      = "Could not read source file: $($_.Exception.Message)"
            Fresh       = $false
            CurrentHash = $null
        }
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $currentHash = try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($currentContent)
        $hBytes = $sha.ComputeHash($bytes)
        -join ($hBytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }

    $candContentClean = ([string]$Candidate.content).Replace("`r`n", "`n")
    $currContentClean = $currentContent.Replace("`r`n", "`n")

    $isMatch = ($currContentClean -eq $candContentClean) -or ($null -ne $recordedHash -and $currentHash -eq $recordedHash)
    if ($isMatch) {
        return [ordered]@{
            Status      = 'fresh'
            Reason      = 'Candidate content matches source file'
            Fresh       = $true
            CurrentHash = $currentHash
        }
    }
    else {
        return [ordered]@{
            Status      = 'drifted'
            Reason      = 'Source file content has drifted since candidate retrieval'
            Fresh       = $false
            CurrentHash = $currentHash
        }
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
            content_sha256   = if ($cand.content_sha256) { [string]$cand.content_sha256 } else { $null }
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
        [Parameter()][ValidateSet('metadata_only', 'snippets_allowed')][string]$PrivacyScope = 'snippets_allowed',
        [Parameter(Mandatory = $false)][ValidateRange(1, 1000)][int]$MaxCandidatesToEvaluate = 100,
        [Parameter(Mandatory = $false)][ValidateRange(1, 50)][int]$MaxJevCalls = 5,
        [Parameter(Mandatory = $false)][ValidateRange(1024, 10485760)][int]$MaxTotalPayloadBytes = 262144,
        [Parameter()][hashtable]$MockResponses = $null,
        [Parameter()][scriptblock]$HttpTransportMock = $null
    )

    $scores = [ordered]@{}
    $requestCount = 0
    $totalPayloadBytes = 0
    $actualModel = $Model
    $batchError = $null
    $costLimitReason = $null
    $totalCandidates = $Candidates.Count

    if ($totalCandidates -eq 0) {
        return [ordered]@{
            Scores                 = $scores
            RequestCount           = 0
            PayloadBytes           = 0
            Model                  = $actualModel
            ServiceUnavailable     = $false
            GlobalStatus           = 'ok'
            ValidCount             = 0
            InvalidCount           = 0
            MissingCount           = 0
            CandidatesConsidered   = 0
            CandidatesEvaluated    = 0
            CandidatesNotEvaluated = 0
            CostLimitReason        = $null
            ErrorMessage           = $null
        }
    }

    # 1. Candidate count circuit breaker
    $candListToProcess = $Candidates
    if ($totalCandidates -gt $MaxCandidatesToEvaluate) {
        $candListToProcess = $Candidates[0..($MaxCandidatesToEvaluate - 1)]
        for ($e = $MaxCandidatesToEvaluate; $e -lt $totalCandidates; $e++) {
            $excessCand = $Candidates[$e]
            $scores[[string]$excessCand.id] = [ordered]@{
                Score   = $null
                Status  = 'unevaluated'
                Message = 'jev_candidate_limit'
            }
        }
        $costLimitReason = 'jev_candidate_limit'
    }

    # Split candidates into batches
    $candList = [System.Collections.Generic.List[object]]@($candListToProcess)
    for ($i = 0; $i -lt $candList.Count; $i += $BatchSize) {
        $count = [Math]::Min($BatchSize, $candList.Count - $i)
        $batch = $candList.GetRange($i, $count)

        # Check call limit circuit breaker
        if ($requestCount -ge $MaxJevCalls) {
            for ($remIdx = $i; $remIdx -lt $candList.Count; $remIdx++) {
                $remCand = $candList[$remIdx]
                $scores[[string]$remCand.id] = [ordered]@{
                    Score   = $null
                    Status  = 'unevaluated'
                    Message = 'jev_call_limit'
                }
            }
            if ($null -eq $costLimitReason) {
                $costLimitReason = 'jev_call_limit'
            }
            break
        }

        # 1. Check direct mock responses
        if ($null -ne $MockResponses) {
            $requestCount++
            foreach ($cand in $batch) {
                $cId = [string]$cand.id
                $cRef = [string]$cand.source_ref
                $refRangeKey = if ($null -ne $cand.line_start -and $null -ne $cand.line_end) { "$cRef`:$($cand.line_start):$($cand.line_end)" } else { $cRef }
                $candRefKey = "cand:$refRangeKey"

                $matchedKey = if ($MockResponses.ContainsKey($cId)) { $cId }
                    elseif ($MockResponses.ContainsKey($candRefKey)) { $candRefKey }
                    elseif ($MockResponses.ContainsKey($refRangeKey)) { $refRangeKey }
                    elseif ($MockResponses.ContainsKey($cRef)) { $cRef }
                    elseif ($MockResponses.ContainsKey('*')) { '*' }
                    else { $null }

                if ($null -ne $matchedKey) {
                    $mVal = $MockResponses[$matchedKey]
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

            $symbolInfo = ""
            if ($cand.metadata) {
                $rawSym = $null
                if ($cand.metadata -is [System.Collections.IDictionary]) {
                    if ($cand.metadata.Contains('symbol')) { $rawSym = [string]$cand.metadata['symbol'] }
                    elseif ($cand.metadata.Contains('symbol_name')) { $rawSym = [string]$cand.metadata['symbol_name'] }
                }
                elseif ($cand.metadata.PSObject.Properties.Name -contains 'symbol') {
                    $rawSym = [string]$cand.metadata.symbol
                }
                if (-not [string]::IsNullOrWhiteSpace($rawSym)) {
                    $cleanSym = Sanitize-MetadataSymbol -Symbol $rawSym
                    if (-not [string]::IsNullOrWhiteSpace($cleanSym)) {
                        $symbolInfo = " (symbol: '$cleanSym')"
                    }
                }
            }

            $inst = $null
            $critTrue = $null
            $critFalse = $null

            # Opaque candidate item label: keeps user-supplied candidate IDs local to avoid prompt injection
            $itemLabel = "Item #$($qIdx + 1)"

            if ($PrivacyScope -eq 'metadata_only') {
                # STRICT PRIVACY: ZERO content or code snippets are transmitted!
                $inst = "$itemLabel from '$ref'$linesInfo$symbolInfo ($rep). [Note: Content omitted under metadata-only privacy scope].`nBased solely on these metadata references and file location, does this candidate appear likely relevant or materially useful for the task?"
                $critTrue = "The file path, symbol, location, or metadata indicates this candidate is likely relevant or materially useful for the task."
                $critFalse = "The file path or metadata indicates this candidate is likely unrelated, tangential, or lacks utility."
            }
            else {
                $contentSnippet = [string]$cand.content
                if ($contentSnippet.Length -gt 1200) {
                    $contentSnippet = $contentSnippet.Substring(0, 1200) + "... [truncated]"
                }

                $inst = "$itemLabel from '$ref'$linesInfo$symbolInfo ($rep):`n`"$contentSnippet`"`nDoes this candidate contain materially useful information to investigate or execute the task, including evidence that contradicts hypotheses?"
                $critTrue = "The candidate contains directly relevant code, contract, configuration, test, or contradictory evidence materially useful for the task."
                $critFalse = "The candidate is merely superficially related, tangential, or lacks actionable utility."
            }

            $questions[$qKey] = [ordered]@{
                type         = 'noul'
                instructions = $inst
                criteria     = [ordered]@{
                    true  = $critTrue
                    false = $critFalse
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

        # Check total payload byte limit circuit breaker
        if (($totalPayloadBytes + $bodyBytes) -gt $MaxTotalPayloadBytes) {
            for ($remIdx = $i; $remIdx -lt $candList.Count; $remIdx++) {
                $remCand = $candList[$remIdx]
                $scores[[string]$remCand.id] = [ordered]@{
                    Score   = $null
                    Status  = 'unevaluated'
                    Message = 'jev_payload_limit'
                }
            }
            if ($null -eq $costLimitReason) {
                $costLimitReason = 'jev_payload_limit'
            }
            break
        }
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

    $validEvalCount = @($scores.Values | Where-Object { $_.Status -eq 'ok' }).Count
    $missingEvalCount = @($scores.Values | Where-Object { $_.Status -eq 'missing_answer' }).Count
    $invalidEvalCount = @($scores.Values | Where-Object { $_.Status -in @('invalid_score', 'out_of_range', 'null_answer', 'error') }).Count
    $serviceErrorCount = @($scores.Values | Where-Object { $_.Status -in @('service_unavailable', 'malformed_response') }).Count
    $unevaluatedCount = @($scores.Values | Where-Object { $_.Status -eq 'unevaluated' }).Count

    $calcGlobalStatus = if ($scores.Count -eq 0) {
        'ok'
    }
    elseif ($serviceErrorCount -gt 0 -and $validEvalCount -eq 0) {
        'unavailable'
    }
    elseif ($validEvalCount -eq $scores.Count) {
        'ok'
    }
    elseif ($validEvalCount -gt 0) {
        'partial'
    }
    else {
        'unavailable'
    }

    return [ordered]@{
        Scores                 = $scores
        RequestCount           = $requestCount
        PayloadBytes           = $totalPayloadBytes
        Model                  = $actualModel
        ServiceUnavailable     = ($serviceErrorCount -gt 0)
        GlobalStatus           = $calcGlobalStatus
        ValidCount             = $validEvalCount
        InvalidCount           = $invalidEvalCount
        MissingCount           = $missingEvalCount
        CandidatesConsidered   = $totalCandidates
        CandidatesEvaluated    = $validEvalCount
        CandidatesNotEvaluated = $unevaluatedCount
        CostLimitReason        = $costLimitReason
        ErrorMessage           = $batchError
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

    function Measure-SelectedPackageBytes {
        param([object[]]$Items)
        if ($null -eq $Items -or $Items.Count -eq 0) { return 0 }
        $json = @($Items) | ConvertTo-Json -Depth 6 -Compress
        return [System.Text.Encoding]::UTF8.GetByteCount($json)
    }

    function New-SelectedCandidateObject {
        param([object]$Item, [string]$DecisionOverride)
        $cand = $Item.Candidate
        $dec = if (-not [string]::IsNullOrWhiteSpace($DecisionOverride)) { $DecisionOverride } else { $Item.Decision }
        return [ordered]@{
            id               = $Item.Id
            source           = $cand.source
            source_ref       = $cand.source_ref
            repository_scope = $cand.repository_scope
            revision_or_hash = $cand.revision_or_hash
            line_start       = $cand.line_start
            line_end         = $cand.line_end
            original_rank    = $cand.original_rank
            representation   = $cand.representation
            content          = $cand.content
            score            = $Item.Score
            decision         = $dec
            provenances      = $cand.provenances
        }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    $manifest = [System.Collections.Generic.List[object]]::new()

    # Pre-check 1: verify if PINNED candidate count alone exceeds MaxSelectedCandidates
    if ($pinnedList.Count -gt $MaxSelectedCandidates) {
        return [ordered]@{
            version         = 1
            status          = 'count_exceeded'
            policy          = $Policy
            message         = "Pinned candidate count ($($pinnedList.Count)) exceeds MaxSelectedCandidates ($MaxSelectedCandidates). Sharding required."
            selected        = @()
            manifest        = @($classified | ForEach-Object {
                [ordered]@{
                    id               = $_.Id
                    source_ref       = $_.Candidate.source_ref
                    line_start       = $_.Candidate.line_start
                    line_end         = $_.Candidate.line_end
                    score            = $_.Score
                    decision         = $_.Decision
                    exclusion_reason = 'count_exceeded_by_pinned'
                }
            })
            delivered_bytes = 0
            selected_count  = 0
            deferred_count  = $classified.Count
        }
    }

    # Pre-check 2: verify if PINNED candidates alone exceed MaxBudgetBytes
    $pinnedObjects = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $pinnedList) {
        $pinnedObjects.Add((New-SelectedCandidateObject -Item $p -DecisionOverride 'PINNED'))
    }

    $pinnedTotalBytes = Measure-SelectedPackageBytes -Items @($pinnedObjects.ToArray())
    if ($pinnedTotalBytes -gt $MaxBudgetBytes) {
        return [ordered]@{
            version      = 1
            status       = 'budget_exceeded'
            policy       = $Policy
            message      = "Pinned candidate package ($pinnedTotalBytes bytes) exceeds MaxBudgetBytes ($MaxBudgetBytes). Sharding required."
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

    # 1. Add Pinned items
    foreach ($po in $pinnedObjects) {
        $selected.Add($po)
    }

    # Helper to measure tentative addition of candidate against MaxBudgetBytes
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

        $selectedObj = New-SelectedCandidateObject -Item $Item
        $tentativeItems = @($selected.ToArray()) + @($selectedObj)
        $tentativeBytes = Measure-SelectedPackageBytes -Items $tentativeItems

        if ($tentativeBytes -gt $MaxBudgetBytes) {
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

        $selected.Add($selectedObj)
        return $true
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

    $deliveredPackageBytes = Measure-SelectedPackageBytes -Items @($selected.ToArray())

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
    Sanitize-TaskObjective, `
    Sanitize-MetadataSymbol, `
    Test-ContextCandidateFreshness, `
    Format-WindowsProcessArgument, `
    Resolve-CanonicalDirectoryRoot, `
    Resolve-CanonicalReparsePath, `
    Optimize-CandidateSet, `
    Invoke-JevRerankBatch, `
    Select-ContextPackage
