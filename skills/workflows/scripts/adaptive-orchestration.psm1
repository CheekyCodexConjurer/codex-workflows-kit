# Decision support for the Workflows orchestrator. The parent remains responsible
# for the design, tool call, review verdict, and every workflow permission gate.
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'context-reranking.psm1') -Force -DisableNameChecking

function Get-OrchestrationField {
    param([object]$Value, [string]$Name, [object]$Default = $null)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-OrchestrationHash {
    param([object]$Value, [string]$JevMode)
    $snapshot = [ordered]@{}
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]$key -ne 'previous_decision') { $snapshot[$key] = $Value[$key] }
        }
    }
    else {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -ne 'previous_decision') { $snapshot[$property.Name] = $property.Value }
        }
    }
    $snapshot['jev_mode'] = $JevMode
    $json = ConvertTo-Json -InputObject $snapshot -Depth 12 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Test-DisjointFronts {
    param([object[]]$Fronts)
    $owned = [Collections.Generic.List[string]]::new()
    $resources = @{}
    foreach ($front in $Fronts) {
        foreach ($path in @(Get-OrchestrationField $front 'ownership' @())) {
            $key = ([string]$path).Replace('/', '\').TrimEnd('\').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($key)) { return $false }
            foreach ($existing in $owned) {
                if ($key -eq $existing -or $key.StartsWith($existing + '\') -or $existing.StartsWith($key + '\')) { return $false }
            }
            $owned.Add($key)
        }
        foreach ($resource in @(Get-OrchestrationField $front 'exclusive_resources' @())) {
            $key = ([string]$resource).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($key) -or $resources.ContainsKey($key)) { return $false }
            $resources[$key] = $true
        }
    }
    return $true
}

function Test-WorkerReuse {
    param([object]$Worker, [object]$Front, [string]$Backend)
    if ((Get-OrchestrationField $Worker 'backend' '') -cne $Backend) { return $false }
    if ((Get-OrchestrationField $Worker 'status' '') -cne 'idle_open') { return $false }
    foreach ($name in @('session_confirmed', 'context_relevant', 'scope_compatible', 'sources_fresh')) {
        if ((Get-OrchestrationField $Worker $name $false) -ne $true) { return $false }
    }
    if ((Get-OrchestrationField $Worker 'role' '') -ceq 'reviewer') { return $false }
    $workerScope = @(Get-OrchestrationField $Worker 'ownership' @())
    foreach ($path in @(Get-OrchestrationField $Front 'ownership' @())) {
        if ($workerScope -notcontains $path) { return $false }
    }
    return $true
}

function Get-AdaptiveOrchestrationDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Request,
        [ValidateSet('off', 'advisory', 'shadow')][string]$JevMode = 'advisory',
        [hashtable]$MockJevResponses = $null,
        [scriptblock]$JevTransportMock = $null
    )

    $mode = [string](Get-OrchestrationField $Request 'mode' '')
    $backend = [string](Get-OrchestrationField $Request 'backend' '')
    $event = [string](Get-OrchestrationField $Request 'event' '')
    if ($mode -notin @('PLAN.AUTO','PLAN','P.DEEP','RESEARCH.DEEP','IMPL.AUTO','IMPL','IMPL.PHASE','DELIVER.AUTO','REVIEW','COMMIT','BUG.INV','BUG.FIX','DEBUG','REWORK','R.A.F.V','TN.SKILL','CONSULT')) {
        throw "Unsupported workflow mode: $mode"
    }
    if ($backend -notin @('native','deepseek')) { throw "Unsupported selected backend: $backend" }
    if ($event -notin @('new_front','result','blocker','scope_change','contradiction','pre_review')) {
        throw "Unsupported orchestration event: $event"
    }

    $fingerprint = Get-OrchestrationHash $Request $JevMode
    $previous = Get-OrchestrationField $Request 'previous_decision'

    $fronts = @(Get-OrchestrationField $Request 'fronts' @())
    $completed = @(Get-OrchestrationField $Request 'consumed_dependencies' @())
    $ready = [Collections.Generic.List[object]]::new()
    $waiting = [Collections.Generic.List[string]]::new()
    $noWrite = $mode -in @('PLAN.AUTO','PLAN','P.DEEP','RESEARCH.DEEP','REVIEW','BUG.INV','REWORK','TN.SKILL','CONSULT')
    $seenIds = @{}
    foreach ($front in $fronts) {
        $id = [string](Get-OrchestrationField $front 'id' '')
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'Every front needs a stable id.' }
        if ($seenIds.ContainsKey($id)) { throw "Duplicate front id: $id" }
        $seenIds[$id] = $true
        $frontMode = [string](Get-OrchestrationField $front 'agent_mode' 'analyze')
        if ($frontMode -notin @('analyze','edit','test')) { throw "Invalid agent mode for $id" }
        if (($noWrite -or $mode -eq 'COMMIT') -and $frontMode -in @('edit','test')) {
            throw "Workflow mode $mode forbids $frontMode front $id"
        }
        $frontOwnership = @(Get-OrchestrationField $front 'ownership' @())
        if ($frontMode -in @('edit','test') -and
            ($frontOwnership.Count -eq 0 -or @($frontOwnership | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)) {
            throw "Mutating front $id needs explicit ownership"
        }
        $unmet = @((Get-OrchestrationField $front 'depends_on' @()) | Where-Object { $completed -notcontains $_ })
        if ($unmet.Count -gt 0) { $waiting.Add($id) } else { $ready.Add($front) }
    }

    # Recheck permissions and dependencies before reusing a prior decision.
    if ($null -ne $previous -and
        (Get-OrchestrationField $previous 'version' 0) -eq 1 -and
        (Get-OrchestrationField $previous 'fingerprint' '') -ceq $fingerprint -and
        (Get-OrchestrationField $previous 'backend' '') -ceq $backend -and
        (Get-OrchestrationField $previous 'event' '') -ceq $event) {
        $readyIds = @($ready | ForEach-Object { [string](Get-OrchestrationField $_ 'id') })
        $cachedIds = @(Get-OrchestrationField $previous 'selected_front_ids' @())
        $cachedDecision = [string](Get-OrchestrationField $previous 'execution' '')
        if ($cachedDecision -in @('direct','reuse_worker','delegate_one','delegate_parallel','parent_decision','wait_dependencies') -and
            @($cachedIds | Where-Object { $readyIds -notcontains $_ }).Count -eq 0) {
            return $previous
        }
    }

    $risk = @(Get-OrchestrationField $Request 'risks' @())
    $writeMode = -not $noWrite -and $mode -ne 'COMMIT'
    $review = [ordered]@{
        required_checks = @('permission', 'dependencies', 'ownership', 'validation', 'source_freshness')
        independent_review = $writeMode
        additional_gpt_analysis = @($risk | Where-Object { $_ -in @('security','concurrency','public_contract','ambiguity','contradiction') }).Count -gt 0 -or $event -eq 'contradiction'
    }
    if ($writeMode) { $review.required_checks += @('frozen_target', 'operational_proof_when_triggered') }

    $decision = 'wait_dependencies'
    $selected = @()
    $reuseAgent = $null
    $reason = 'No ready front.'
    $jev = [ordered]@{ status = 'skipped'; calls = 0; scores = @{} }
    if ($ready.Count -gt 0) {
        $immediate = @($ready | Where-Object { (Get-OrchestrationField $_ 'immediate' $false) -eq $true })
        $material = @($ready | Where-Object { (Get-OrchestrationField $_ 'immediate' $false) -ne $true })
        if ($ready.Count -eq 1 -and $immediate.Count -eq 1 -and
            (Get-OrchestrationField $ready[0] 'ambiguous' $false) -eq $true) {
            $decision = 'parent_decision'
            $selected = @([string](Get-OrchestrationField $ready[0] 'id'))
            $reason = 'An ambiguous front needs a GPT scope decision before immediate execution.'
        }
        elseif ($ready.Count -eq 1 -and $immediate.Count -eq 1) {
            $decision = 'direct'
            $selected = @([string](Get-OrchestrationField $ready[0] 'id'))
            $reason = 'Immediate cohesive front.'
        }
        else {
            $candidates = $material
            if ($candidates.Count -eq 0) { $candidates = @($ready) }
            $first = $candidates[0]
            $selected = @([string](Get-OrchestrationField $first 'id'))
            $workers = @(Get-OrchestrationField $Request 'workers' @())
            foreach ($worker in $workers) {
                if (Test-WorkerReuse -Worker $worker -Front $first -Backend $backend) {
                    $reuseAgent = [string](Get-OrchestrationField $worker 'agent_id')
                    break
                }
            }
            if ($reuseAgent) {
                $decision = 'reuse_worker'
                $reason = 'Confirmed compatible session.'
            }
            else {
                $decision = 'delegate_one'
                $reason = 'Material ready front.'
                $gain = [double](Get-OrchestrationField $Request 'estimated_parallel_gain_seconds' 0)
                $capacity = [int](Get-OrchestrationField $Request 'available_capacity' 0)
                $parallel = $candidates.Count -gt 1 -and $gain -gt 0 -and $capacity -ge 2 -and (Test-DisjointFronts $candidates)
                if ($parallel -and $backend -eq 'deepseek') {
                    $caps = @(Get-OrchestrationField $Request 'capabilities' @())
                    $tools = @(Get-OrchestrationField $Request 'callable_tools' @())
                    $probe = Get-OrchestrationField $Request 'authoritative_bridge_probe'
                    $probeCaps = @(Get-OrchestrationField $probe 'capabilities' @())
                    $probeStatus = [string](Get-OrchestrationField $probe 'status' '')
                    $parallel = ($caps -contains 'batch_scheduler') -and
                        (($tools -contains 'subagents_spawn_batch') -or ($tools -contains 'deepseek_spawn_batch')) -and
                        ($probeStatus -in @('ok','ready')) -and
                        ($probeCaps -contains 'batch_scheduler')
                }
                if ($parallel) {
                    $decision = 'delegate_parallel'
                    $selected = @($candidates | Select-Object -First $capacity | ForEach-Object { [string](Get-OrchestrationField $_ 'id') })
                    $reason = 'Independent fronts and positive estimated time gain.'
                }
            }
        }
    }

    # Jev only advises on an ambiguous front. Hard permission, ownership and
    # dependency gates above remain authoritative, including in shadow mode.
    $ambiguous = @($ready | Where-Object { (Get-OrchestrationField $_ 'ambiguous' $false) -eq $true })
    if ($ambiguous.Count -gt 0 -and $JevMode -ne 'off' -and $decision -ne 'direct') {
        $items = @()
        foreach ($front in $ambiguous) {
            $id = [string](Get-OrchestrationField $front 'id')
            $signals = [string](Get-OrchestrationField $front 'decision_signals' '')
            $items += [ordered]@{
                id = $id; source_ref = 'orchestration'; representation = 'metadata'
                content = $signals; line_start = $null; line_end = $null
                metadata = @{ decision_question = 'Is this front sufficiently defined for bounded execution?'; true_criteria = 'The objective, scope and acceptance are clear.'; false_criteria = 'A design or scope decision remains unresolved.' }
            }
        }
        $batch = Invoke-JevRerankBatch -Candidates $items -TaskObjective ([string](Get-OrchestrationField $Request 'objective' '')) -TaskMode $mode -PrivacyScope snippets_allowed -MockResponses $MockJevResponses -HttpTransportMock $JevTransportMock -MaxJevCalls 1 -MaxCandidatesToEvaluate 20 -MaxTotalPayloadBytes 16384
        $jev = [ordered]@{ status = $batch.GlobalStatus; calls = $batch.RequestCount; scores = $batch.Scores }
        if ($JevMode -eq 'advisory' -and $batch.GlobalStatus -eq 'ok') {
            foreach ($front in $ambiguous) {
                $id = [string](Get-OrchestrationField $front 'id')
                $score = Get-OrchestrationField (Get-OrchestrationField $batch.Scores $id) 'Score'
                if ($null -ne $score -and [double]$score -lt 0.45) {
                    $decision = 'parent_decision'
                    $selected = @($id)
                    $reason = 'Ambiguous scope requires a GPT design decision or bounded investigation.'
                    break
                }
            }
        }
    }

    return [ordered]@{
        version = 1; fingerprint = $fingerprint; event = $event; backend = $backend
        execution = $decision; selected_front_ids = @($selected)
        deferred_front_ids = @($waiting) + @($ready | ForEach-Object { [string](Get-OrchestrationField $_ 'id') } | Where-Object { $selected -notcontains $_ })
        reuse_agent_id = $reuseAgent; reason = $reason; review = $review; jev = $jev
    }
}

Export-ModuleMember -Function Get-AdaptiveOrchestrationDecision
