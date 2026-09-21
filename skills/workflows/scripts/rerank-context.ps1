# skills/workflows/scripts/rerank-context.ps1
# Evaluates, prioritizes, and packages retrieved search candidates via TypeSafe/Jev System One (noul)
# within a strict serialized UTF-8 byte budget and privacy containment boundary.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
    [object]$Candidates = $null,

    [Parameter(Mandatory = $false)]
    [string]$CandidatesJson = '',

    [Parameter(Mandatory = $false)]
    [string]$RoutingObjective = '',

    [Parameter(Mandatory = $false)]
    [string]$TaskObjective = '',

    [Parameter(Mandatory = $false)]
    [string]$Mode = '',

    [Parameter(Mandatory = $false)]
    [string]$WorkingDir = '',

    [Parameter(Mandatory = $false)]
    [string]$RepositoryScope = 'repo',

    [Parameter(Mandatory = $false)]
    [ValidateSet('off', 'advisory')]
    [string]$Policy = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('none', 'metadata_only', 'snippets_allowed')]
    [string]$PrivacyScope = '',

    [Parameter(Mandatory = $false)]
    [switch]$AuthorizeContentTransmission,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0.0, 1.0)]
    [double]$KeepThreshold = 0.70,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0.0, 1.0)]
    [double]$MaybeThreshold = 0.40,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MaxSelectedCandidates = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(512, 10485760)]
    [int]$MaxBudgetBytes = 16384,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MinCandidates = 8,

    [Parameter(Mandatory = $false)]
    [ValidateRange(256, 10485760)]
    [int]$ContextBudgetTriggerBytes = 12000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MaxCandidatesToEvaluate = 100,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$MaxJevCalls = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 10485760)]
    [int]$MaxTotalPayloadBytes = 262144,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$BatchSize = 20,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10,

    [Parameter(Mandatory = $false)]
    [string[]]$PinnedIds = @(),

    [Parameter(Mandatory = $false)]
    [hashtable]$MockResponses = $null,

    [Parameter(Mandatory = $false)]
    [scriptblock]$HttpTransportMock = $null,

    [Parameter(Mandatory = $false)]
    [switch]$AsJson,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Fail-fast validation of thresholds
    if ($MaybeThreshold -gt $KeepThreshold) {
        throw "MaybeThreshold ($MaybeThreshold) must be less than or equal to KeepThreshold ($KeepThreshold)."
    }

    # Policy resolution: Parameter -> Env -> Default ('advisory')
    $resolvedPolicy = if ($PSBoundParameters.ContainsKey('Policy') -and -not [string]::IsNullOrWhiteSpace($Policy)) {
        $Policy.ToLowerInvariant()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_RERANK_POLICY)) {
        $envPolicy = $env:CODEX_CONTEXT_RERANK_POLICY.Trim().ToLowerInvariant()
        if ($envPolicy -notin @('off', 'advisory')) {
            throw "Invalid CODEX_CONTEXT_RERANK_POLICY: '$($env:CODEX_CONTEXT_RERANK_POLICY)'. Valid policies are 'off', 'advisory'."
        }
        $envPolicy
    }
    else {
        'advisory'
    }

    # PrivacyScope resolution: Parameter -> AuthorizeContentTransmission -> Env -> Default ('none')
    $resolvedPrivacyScope = if ($PSBoundParameters.ContainsKey('PrivacyScope') -and -not [string]::IsNullOrWhiteSpace($PrivacyScope)) {
        $PrivacyScope.ToLowerInvariant()
    }
    elseif ($AuthorizeContentTransmission.IsPresent) {
        'snippets_allowed'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_PRIVACY_SCOPE)) {
        $envPrivacy = $env:CODEX_CONTEXT_PRIVACY_SCOPE.Trim().ToLowerInvariant()
        if ($envPrivacy -notin @('none', 'metadata_only', 'snippets_allowed')) {
            throw "Invalid CODEX_CONTEXT_PRIVACY_SCOPE: '$($env:CODEX_CONTEXT_PRIVACY_SCOPE)'. Valid scopes are 'none', 'metadata_only', 'snippets_allowed'."
        }
        $envPrivacy
    }
    else {
        'none'
    }

    # Environment overrides for trigger & cost limits: explicit parameter > env > default
    if (-not $PSBoundParameters.ContainsKey('MinCandidates') -and -not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_RERANK_MIN_CANDIDATES)) {
        $MinCandidates = [int]$env:CODEX_CONTEXT_RERANK_MIN_CANDIDATES
    }
    if (-not $PSBoundParameters.ContainsKey('ContextBudgetTriggerBytes') -and -not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_RERANK_TRIGGER_BYTES)) {
        $ContextBudgetTriggerBytes = [int]$env:CODEX_CONTEXT_RERANK_TRIGGER_BYTES
    }
    if (-not $PSBoundParameters.ContainsKey('MaxCandidatesToEvaluate') -and -not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_MAX_CANDIDATES_EVAL)) {
        $MaxCandidatesToEvaluate = [int]$env:CODEX_CONTEXT_MAX_CANDIDATES_EVAL
    }
    if (-not $PSBoundParameters.ContainsKey('MaxJevCalls') -and -not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_MAX_JEV_CALLS)) {
        $MaxJevCalls = [int]$env:CODEX_CONTEXT_MAX_JEV_CALLS
    }
    if (-not $PSBoundParameters.ContainsKey('MaxTotalPayloadBytes') -and -not [string]::IsNullOrWhiteSpace($env:CODEX_CONTEXT_MAX_PAYLOAD_BYTES)) {
        $MaxTotalPayloadBytes = [int]$env:CODEX_CONTEXT_MAX_PAYLOAD_BYTES
    }

    # WorkingDir resolution
    $resolvedWorkingDir = if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
        [IO.Path]::GetFullPath($PWD.Path)
    }
    else {
        [IO.Path]::GetFullPath($WorkingDir)
    }

    # Import core module
    $modulePath = Join-Path $PSScriptRoot 'context-reranking.psm1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Required module not found at: $modulePath"
    }
    Import-Module -Name $modulePath -Force -DisableNameChecking

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $collectedRaw = [System.Collections.Generic.List[object]]::new()
}

process {
    if ($null -ne $Candidates) {
        if ($Candidates -is [System.Collections.IEnumerable] -and -not ($Candidates -is [string])) {
            foreach ($c in $Candidates) {
                if ($null -ne $c) {
                    $collectedRaw.Add($c)
                }
            }
        }
        else {
            $collectedRaw.Add($Candidates)
        }
    }
}

end {
    # 1. Candidate Extraction
    if ($collectedRaw.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($CandidatesJson)) {
        try {
            $parsed = $CandidatesJson | ConvertFrom-Json
            if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
                foreach ($item in $parsed) {
                    $collectedRaw.Add($item)
                }
            }
            else {
                $collectedRaw.Add($parsed)
            }
        }
        catch {
            throw "Failed to parse CandidatesJson: $($_.Exception.Message)"
        }
    }

    $rawCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $collectedRaw) {
        if ($item -is [string]) {
            $trimmed = $item.Trim()
            if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
                try {
                    $deserialized = $trimmed | ConvertFrom-Json
                    if ($deserialized -is [System.Collections.IEnumerable] -and -not ($deserialized -is [string])) {
                        foreach ($d in $deserialized) { $rawCandidates.Add($d) }
                    }
                    else {
                        $rawCandidates.Add($deserialized)
                    }
                }
                catch {
                    # Treat as invalid candidate
                }
            }
        }
        else {
            $rawCandidates.Add($item)
        }
    }

    $totalReceived = $rawCandidates.Count
    $validCandidates = [System.Collections.Generic.List[object]]::new()
    $rejectedSafety = [System.Collections.Generic.List[object]]::new()

    # 2. Schema Validation, Path Safety, and Secret Scanning
    foreach ($c in $rawCandidates) {
        if (-not (Test-ContextCandidate -Candidate $c)) {
            continue
        }

        # Check repository path containment
        $refPath = [string]$c.source_ref
        $normPath = $null
        try {
            $normPath = Assert-CandidatePathContainment -RepoPath $resolvedWorkingDir -RelativePath $refPath
        }
        catch {
            $rejectedSafety.Add([ordered]@{
                id               = [string]$c.id
                source_ref       = $refPath
                exclusion_reason = 'unsafe_path'
            })
            continue
        }

        # Check candidate safety (secrets / credential detection)
        $contentStr = [string]$c.content
        $safety = Test-CandidateSafety -SourceRef $refPath -Content $contentStr
        if (-not $safety.Safe) {
            $rejectedSafety.Add([ordered]@{
                id               = [string]$c.id
                source_ref       = $refPath
                exclusion_reason = $safety.Reason
            })
            continue
        }

        $validCandidates.Add($c)
    }

    # 3. Exact Deduplication and Provenance Merging
    $optResult = Optimize-CandidateSet -Candidates @($validCandidates)
    $optimizedCandidates = @($optResult.UniqueCandidates)
    $duplicatesCount = $optResult.DuplicatesCount

    # 4. Freshness Evaluation
    # Local file-backed snippets are evaluated for on-disk drift or deletion.
    # Stale, drifted, or missing candidates are excluded from Jev evaluation and delivered selection.
    $activeCandidates = [System.Collections.Generic.List[object]]::new()
    $rejectedFreshness = [System.Collections.Generic.List[object]]::new()
    $freshCount = 0
    $driftedCount = 0
    $missingCount = 0
    $freshnessErrorCount = 0
    $notApplicableCount = 0

    foreach ($cand in $optimizedCandidates) {
        $freshResult = Test-ContextCandidateFreshness -Candidate $cand -RepoPath $resolvedWorkingDir
        switch ($freshResult.Status) {
            'fresh' {
                $freshCount++
                $activeCandidates.Add($cand)
            }
            'not_applicable' {
                $notApplicableCount++
                $activeCandidates.Add($cand)
            }
            'drifted' {
                $driftedCount++
                $rejectedFreshness.Add([ordered]@{
                    id               = [string]$cand.id
                    source_ref       = [string]$cand.source_ref
                    line_start       = $cand.line_start
                    line_end         = $cand.line_end
                    exclusion_reason = 'source_drifted'
                })
            }
            'missing' {
                $missingCount++
                $rejectedFreshness.Add([ordered]@{
                    id               = [string]$cand.id
                    source_ref       = [string]$cand.source_ref
                    line_start       = $cand.line_start
                    line_end         = $cand.line_end
                    exclusion_reason = 'source_missing'
                })
            }
            default {
                $freshnessErrorCount++
                $rejectedFreshness.Add([ordered]@{
                    id               = [string]$cand.id
                    source_ref       = [string]$cand.source_ref
                    line_start       = $cand.line_start
                    line_end         = $cand.line_end
                    exclusion_reason = 'freshness_error'
                })
            }
        }
    }

    # 5. Deterministic Activation Gate
    # Reranking runs only when candidates meet MinCandidates OR total raw content bytes exceed ContextBudgetTriggerBytes.
    # Tiny retrieval sets comfortably fitting context budget bypass Jev and select locally.
    $candCount = $activeCandidates.Count
    $rawContentBytes = 0
    foreach ($ac in $activeCandidates) {
        $rawContentBytes += [System.Text.Encoding]::UTF8.GetByteCount([string]$ac.content)
    }

    $gateStatus = 'disabled'
    if ($resolvedPolicy -eq 'off') {
        $gateStatus = 'disabled'
    }
    else {
        if ($candCount -ge $MinCandidates -or $rawContentBytes -ge $ContextBudgetTriggerBytes) {
            $gateStatus = 'triggered'
        }
        else {
            $gateStatus = 'skipped_below_threshold'
        }
    }

    # 6. Routing Decision & Jev Batch Execution
    $evaluations = @{}
    $requestCount = 0
    $payloadBytes = 0
    $modelUsed = 'none'
    $effectiveStatus = 'ok'
    $validEvalCount = 0
    $invalidEvalCount = 0
    $missingEvalCount = 0
    $candidatesEvaluated = 0
    $candidatesNotEvaluated = 0
    $costLimitReason = $null

    # Objective resolution: RoutingObjective (preferred) -> TaskObjective (fallback)
    $rawObjective = if (-not [string]::IsNullOrWhiteSpace($RoutingObjective)) {
        $RoutingObjective
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TaskObjective)) {
        $TaskObjective
    }
    else {
        ''
    }

    $sanitizedObjective = Sanitize-TaskObjective -Objective $rawObjective -Mode $Mode

    if ($resolvedPolicy -eq 'off') {
        $effectiveStatus = 'skipped_policy_off'
    }
    elseif ($activeCandidates.Count -eq 0) {
        $effectiveStatus = 'ok'
    }
    elseif ($resolvedPrivacyScope -eq 'none') {
        # Privacy boundary: no external transmission authorized
        $effectiveStatus = 'skipped_privacy_unauthorized'
    }
    elseif ($resolvedPrivacyScope -eq 'snippets_allowed' -and -not $AuthorizeContentTransmission.IsPresent) {
        # snippets_allowed without explicit authorization switch is rejected
        $effectiveStatus = 'skipped_privacy_unauthorized'
    }
    elseif ($gateStatus -eq 'skipped_below_threshold') {
        $effectiveStatus = 'skipped_below_threshold'
    }
    else {
        # Transmission permitted: metadata_only OR (snippets_allowed with AuthorizeContentTransmission)
        $apiKey = $env:TYPESAFE_API_KEY
        $hasMock = ($null -ne $MockResponses -or $null -ne $HttpTransportMock)

        if ([string]::IsNullOrWhiteSpace($apiKey) -and -not $hasMock) {
            $effectiveStatus = 'skipped_no_api_key'
        }
        else {
            # Execute batch reranking
            $evalResult = Invoke-JevRerankBatch `
                -TaskObjective $sanitizedObjective `
                -TaskMode $Mode `
                -Candidates @($activeCandidates) `
                -PrivacyScope $resolvedPrivacyScope `
                -BatchSize $BatchSize `
                -TimeoutSeconds $TimeoutSeconds `
                -MaxCandidatesToEvaluate $MaxCandidatesToEvaluate `
                -MaxJevCalls $MaxJevCalls `
                -MaxTotalPayloadBytes $MaxTotalPayloadBytes `
                -MockResponses $MockResponses `
                -HttpTransportMock $HttpTransportMock

            $evaluations = $evalResult.Scores
            $requestCount = $evalResult.RequestCount
            $payloadBytes = $evalResult.PayloadBytes
            $modelUsed = $evalResult.Model
            $validEvalCount = $evalResult.ValidCount
            $invalidEvalCount = $evalResult.InvalidCount
            $missingEvalCount = $evalResult.MissingCount
            $candidatesEvaluated = $evalResult.CandidatesEvaluated
            $candidatesNotEvaluated = $evalResult.CandidatesNotEvaluated
            $costLimitReason = $evalResult.CostLimitReason
            $effectiveStatus = $evalResult.GlobalStatus
        }
    }

    # 7. Budget-Bounded Package Selection
    $package = Select-ContextPackage `
        -Candidates @($activeCandidates) `
        -Evaluations $evaluations `
        -PinnedIds $PinnedIds `
        -KeepThreshold $KeepThreshold `
        -MaybeThreshold $MaybeThreshold `
        -MaxSelectedCandidates $MaxSelectedCandidates `
        -MaxBudgetBytes $MaxBudgetBytes `
        -Policy $resolvedPolicy `
        -GlobalStatus $effectiveStatus

    # Merge safety and freshness rejected candidates into manifest
    $finalManifest = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rejectedSafety) {
        $finalManifest.Add([ordered]@{
            id               = $r.id
            source_ref       = $r.source_ref
            line_start       = $null
            line_end         = $null
            score            = $null
            decision         = 'REJECTED'
            exclusion_reason = $r.exclusion_reason
        })
    }
    foreach ($rf in $rejectedFreshness) {
        $finalManifest.Add([ordered]@{
            id               = $rf.id
            source_ref       = $rf.source_ref
            line_start       = $rf.line_start
            line_end         = $rf.line_end
            score            = $null
            decision         = 'EXCLUDED'
            exclusion_reason = $rf.exclusion_reason
        })
    }
    foreach ($m in $package.manifest) {
        $finalManifest.Add($m)
    }

    # Revalidate selected candidates before final delivery to catch drift during Jev evaluation
    $verifiedSelected = [System.Collections.Generic.List[object]]::new()
    $pinnedSetForReval = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $PinnedIds) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $pinnedSetForReval.Add($p.Trim()) | Out-Null
        }
    }

    $pinnedFailedReval = $false
    $failedPinnedId = $null

    foreach ($sel in $package.selected) {
        $cRef = [string]$sel.source_ref
        $cId = [string]$sel.id
        $isPinned = $pinnedSetForReval.Contains($cId)

        # Non-file sources (memory, history, symbol, cbm, test) bypass on-disk freshness
        $fullPath = [IO.Path]::Combine($resolvedWorkingDir, ($cRef -replace '/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            if ([string]$sel.source -in @('memory', 'history', 'symbol', 'cbm', 'test')) {
                $verifiedSelected.Add($sel)
                continue
            }
            # Missing source file
            $missingCount++
            if ($isPinned) {
                $pinnedFailedReval = $true
                $failedPinnedId = $cId
            }
            $finalManifest.Add([ordered]@{
                id               = $cId
                source_ref       = $cRef
                line_start       = $sel.line_start
                line_end         = $sel.line_end
                score            = $sel.score
                decision         = 'EXCLUDED'
                exclusion_reason = 'source_missing'
            })
            continue
        }

        $freshResult = Test-ContextCandidateFreshness -Candidate $sel -RepoPath $resolvedWorkingDir
        if ($freshResult.Fresh) {
            $verifiedSelected.Add($sel)
        }
        else {
            $reason = if ($freshResult.Status -eq 'drifted') {
                $driftedCount++
                'source_drifted'
            }
            else {
                $missingCount++
                'source_missing'
            }

            if ($isPinned) {
                $pinnedFailedReval = $true
                $failedPinnedId = $cId
            }

            $finalManifest.Add([ordered]@{
                id               = $cId
                source_ref       = $cRef
                line_start       = $sel.line_start
                line_end         = $sel.line_end
                score            = $sel.score
                decision         = 'EXCLUDED'
                exclusion_reason = $reason
            })
        }
    }

    $finalStatus = $package.status
    if ($pinnedFailedReval) {
        $finalStatus = 'pinned_unavailable'
        $finalSelected = @()
        $finalDeliveredBytes = 0
    }
    else {
        $finalSelected = @($verifiedSelected.ToArray())
        $finalDeliveredBytes = if ($finalSelected.Count -eq 0) {
            0
        }
        elseif ($finalSelected.Count -eq 1) {
            [System.Text.Encoding]::UTF8.GetByteCount('[' + ($finalSelected[0] | ConvertTo-Json -Depth 6 -Compress) + ']')
        }
        else {
            [System.Text.Encoding]::UTF8.GetByteCount((@($finalSelected) | ConvertTo-Json -Depth 6 -Compress))
        }
    }

    $stopwatch.Stop()

    $result = [ordered]@{
        version           = 1
        status            = $finalStatus
        gate_status       = $gateStatus
        policy            = $resolvedPolicy
        privacy_scope     = $resolvedPrivacyScope
        routing_objective = $sanitizedObjective
        selected          = $finalSelected
        manifest          = @($finalManifest)
        metrics           = [ordered]@{
            candidates_received      = $totalReceived
            candidates_valid         = $validCandidates.Count
            candidates_deduped       = $optimizedCandidates.Count
            duplicates_coalesced     = $duplicatesCount
            rejected_safety          = $rejectedSafety.Count
            fresh_candidates         = $freshCount
            drifted_candidates       = $driftedCount
            missing_candidates       = $missingCount
            freshness_errors         = $freshnessErrorCount
            gate_status              = $gateStatus
            evaluated_count          = if ($evaluations.Count -gt 0) { $evaluations.Count } else { 0 }
            candidates_considered    = $activeCandidates.Count
            candidates_evaluated     = $candidatesEvaluated
            candidates_not_evaluated = $candidatesNotEvaluated
            cost_limit_reason        = $costLimitReason
            valid_evaluations        = $validEvalCount
            invalid_evaluations      = $invalidEvalCount
            missing_evaluations      = $missingEvalCount
            selected_count           = $finalSelected.Count
            deferred_count           = $finalManifest.Count
            delivered_bytes          = $finalDeliveredBytes
            budget_bytes             = $MaxBudgetBytes
            latency_ms               = $stopwatch.ElapsedMilliseconds
            requests_made            = $requestCount
            model                    = $modelUsed
        }
    }

    if ($AsJson) {
        return ($result | ConvertTo-Json -Depth 8)
    }
    else {
        return $result
    }
}
