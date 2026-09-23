Set-StrictMode -Version Latest

function Get-GateField {
    param([AllowNull()][object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Assert-GateEnum {
    param([object]$Value, [string[]]$Allowed, [string]$Name)
    $text = [string]$Value
    if ($Allowed -cnotcontains $text) { throw "Invalid ${Name}: '$text'." }
    return $text
}

function Get-SubagentJevMode {
    param([string]$Mode = '')
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = $env:CODEX_SUBAGENT_JEV_MODE }
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = 'on' }
    return Assert-GateEnum $Mode.ToLowerInvariant() @('off', 'shadow', 'on') 'Jev mode'
}

function Test-GateUnitNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
    if ($Value -isnot [byte] -and $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [float] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
    $number = [double]$Value
    return (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0 -and $number -le 1)
}

function Get-AllowedDelegationChoices {
    param([object]$InputData)
    $choices = @('PARENT_SOLO', 'DELEGATE_SINGLE')
    $fronts = [int](Get-GateField $InputData 'independent_fronts' 1)
    $worker = [bool](Get-GateField $InputData 'relevant_worker_available' $false)
    $warm = [bool](Get-GateField $InputData 'worker_context_warm' $false)
    $route = [bool](Get-GateField $InputData 'worker_route_matches' $false)
    if ($worker -and $warm -and $route) { $choices += 'REUSE_SUBAGENT' }
    if ($fronts -gt 1 -and [bool](Get-GateField $InputData 'fronts_independent' $false)) {
        $choices += 'DELEGATE_BATCH'
    }
    return ,$choices
}

function Invoke-JevGateChoice {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Criteria,
        [Parameter(Mandatory)][string]$Instructions,
        [string]$QuestionId = 'gate',
        [int]$TimeoutSeconds = 8,
        [scriptblock]$TransportMock
    )
    $body = [ordered]@{
        model = 'jev-latest'
        state = (ConvertTo-Json -InputObject $State -Compress -Depth 6)
        questions = [ordered]@{
            $QuestionId = [ordered]@{ type = 'choice'; instructions = $Instructions; criteria = $Criteria }
        }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($null -ne $TransportMock) {
            $response = & $TransportMock $body
        }
        else {
            $key = $env:TYPESAFE_API_KEY
            if ([string]::IsNullOrWhiteSpace($key)) { throw 'jev_unavailable' }
            $headers = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }
            $response = Invoke-RestMethod -Uri 'https://api.typesafe.ai/v1/systemone' -Method Post -Headers $headers -Body (ConvertTo-Json -InputObject $body -Compress -Depth 8) -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        }
        $answers = Get-GateField $response 'answers'
        $answer = Get-GateField $answers $QuestionId
        $choice = [string](Get-GateField $answer 'choice' '')
        $confidence = Get-GateField $answer 'confidence'
        $probabilities = Get-GateField $answer 'probabilities'
        if ((Get-GateField $answer 'type' '') -cne 'choice' -or -not $Criteria.Contains($choice)) { throw 'jev_invalid_choice' }
        if (-not (Test-GateUnitNumber $confidence)) { throw 'jev_invalid_confidence' }
        if ($null -eq $probabilities) { throw 'jev_missing_probabilities' }
        $probabilitySum = 0.0
        foreach ($option in $Criteria.Keys) {
            $probability = Get-GateField $probabilities $option
            if (-not (Test-GateUnitNumber $probability)) { throw 'jev_invalid_probability' }
            $probabilitySum += [double]$probability
        }
        if ([Math]::Abs($probabilitySum - 1.0) -gt 0.02) { throw 'jev_invalid_probability' }
        $selectedProbability = Get-GateField $probabilities $choice
        if (-not (Test-GateUnitNumber $selectedProbability)) { throw 'jev_invalid_probability' }
        return [pscustomobject]@{ ok = $true; choice = $choice; confidence = [double]$confidence; probability = [double]$selectedProbability; latency_ms = $watch.ElapsedMilliseconds; error_code = $null }
    }
    catch {
        $code = if ($_.Exception.Message -match '^jev_') { $_.Exception.Message } else { 'jev_unavailable' }
        return [pscustomobject]@{ ok = $false; choice = $null; confidence = $null; probability = $null; latency_ms = $watch.ElapsedMilliseconds; error_code = $code }
    }
    finally { $watch.Stop() }
}

function Invoke-SubagentDelegationGate {
    param([Parameter(Mandatory)][object]$InputData, [string]$Mode = '', [scriptblock]$TransportMock)
    $jevMode = Get-SubagentJevMode $Mode
    $policy = ([string](Get-GateField $InputData 'policy' '')).ToLowerInvariant()
    if ($policy -eq 'standard') { $policy = 'balanced' }
    $policy = Assert-GateEnum $policy @('balanced', 'aggressive', 'swarm') 'policy'
    $workflowMode = [string](Get-GateField $InputData 'workflow_mode' '')
    if ($workflowMode -notmatch '^[A-Z][A-Z.]*$') { throw 'Invalid workflow_mode.' }
    $backend = Assert-GateEnum (([string](Get-GateField $InputData 'backend' '')).ToLowerInvariant()) @('native', 'deepseek') 'backend'
    $allowed = Get-AllowedDelegationChoices $InputData
    $current = Assert-GateEnum (Get-GateField $InputData 'current_decision' '') $allowed 'current_decision'
    $fronts = [int](Get-GateField $InputData 'independent_fronts' 1)
    if ($fronts -lt 1 -or $fronts -gt 100) { throw 'Invalid independent_fronts.' }
    $trivial = [bool](Get-GateField $InputData 'trivial' $false)
    $material = [bool](Get-GateField $InputData 'material' $false)
    $scope = Assert-GateEnum (([string](Get-GateField $InputData 'scope' 'local')).ToLowerInvariant()) @('local', 'multi_file', 'large') 'scope'
    $taskType = Assert-GateEnum (([string](Get-GateField $InputData 'task_type' 'general')).ToLowerInvariant()) @('general', 'read', 'implementation', 'debug', 'review', 'research') 'task_type'
    $contextLoad = Assert-GateEnum (([string](Get-GateField $InputData 'context_load' 'low')).ToLowerInvariant()) @('low', 'medium', 'high') 'context_load'
    $result = [ordered]@{ gate = 'delegation'; policy = $policy; decision = $current; reason_code = 'current_policy'; jev_called = $false; latency_ms = 0; worker_reused = ($current -eq 'REUSE_SUBAGENT'); backend = $backend; review_result = $null; current_decision = $current; jev_recommendation = $null; jev_calls_avoided = 0 }
    if ($jevMode -eq 'off') { $result.reason_code = 'off'; return [pscustomobject]$result }
    if ($trivial -or -not $material) {
        if ($jevMode -eq 'on') { $result.decision = 'PARENT_SOLO'; $result.worker_reused = $false }
        $result.jev_recommendation = 'PARENT_SOLO'
        $result.reason_code = 'deterministic_trivial'; $result.jev_calls_avoided = 1
        return [pscustomobject]$result
    }
    if ($workflowMode -in @('ALINHAMENTO', 'PLAN.AUTO', 'PLAN', 'P.DEEP', 'RESEARCH.DEEP', 'REVIEW', 'COMMIT', 'BUG.INV', 'REWORK', 'TN.SKILL', 'CONSULT') -and [bool](Get-GateField $InputData 'requires_edit' $false)) {
        $result.decision = 'PARENT_SOLO'; $result.reason_code = 'mode_write_forbidden'; $result.jev_calls_avoided = 1
        $result.worker_reused = $false
        return [pscustomobject]$result
    }
    $state = [ordered]@{ policy = $policy; workflow_mode = $workflowMode; task_type = $taskType; scope = $scope; estimated_files = [Math]::Min(100, [Math]::Max(0, [int](Get-GateField $InputData 'estimated_files' 0))); requires_edit = [bool](Get-GateField $InputData 'requires_edit' $false); requires_tests = [bool](Get-GateField $InputData 'requires_tests' $false); requires_architecture = [bool](Get-GateField $InputData 'requires_architecture' $false); independent_fronts = $fronts; fronts_independent = [bool](Get-GateField $InputData 'fronts_independent' $false); context_load = $contextLoad; relevant_worker_available = [bool](Get-GateField $InputData 'relevant_worker_available' $false); worker_context_warm = [bool](Get-GateField $InputData 'worker_context_warm' $false) }
    $clearGain = ($contextLoad -eq 'high' -or $scope -eq 'large' -or $fronts -gt 1 -or ($allowed -contains 'REUSE_SUBAGENT'))
    if ($policy -eq 'balanced' -and -not $clearGain) {
        if ($jevMode -eq 'on') { $result.decision = 'PARENT_SOLO'; $result.worker_reused = $false }
        $result.jev_recommendation = 'PARENT_SOLO'
        $result.reason_code = 'deterministic_no_clear_gain'; $result.jev_calls_avoided = 1
        return [pscustomobject]$result
    }
    $state.delegation_cost_high = [bool](Get-GateField $InputData 'delegation_cost_high' $false)
    $criteria = [ordered]@{}
    foreach ($choice in $allowed) {
        $criteria[$choice] = switch ($choice) {
            'PARENT_SOLO' { 'Parent completes cohesive work when delegation costs more.' }
            'REUSE_SUBAGENT' { 'Continue a proven related, warm worker on the same backend.' }
            'DELEGATE_SINGLE' { 'One bounded material front benefits from delegation.' }
            'DELEGATE_BATCH' { 'Multiple genuinely independent ready fronts benefit from parallel delegation.' }
        }
    }
    $jev = Invoke-JevGateChoice -State $state -Criteria $criteria -Instructions 'Choose the least wasteful permitted delegation route. Balanced prefers parent solo unless gain is clear; aggressive prefers delegation for material work; swarm batches only independent fronts. Reuse a warm related worker when helpful.' -TransportMock $TransportMock
    $result.jev_called = $true; $result.latency_ms = $jev.latency_ms
    if ($jev.ok) { $result.jev_recommendation = $jev.choice }
    if (-not $jev.ok -or $jev.confidence -lt 0.65 -or $jev.probability -lt 0.55) {
        $result.reason_code = if ($jev.ok) { 'jev_uncertain_current_policy' } else { $jev.error_code }
        return [pscustomobject]$result
    }
    if ($jevMode -eq 'shadow') { $result.reason_code = 'shadow'; return [pscustomobject]$result }
    if ($policy -eq 'aggressive' -and $jev.choice -eq 'PARENT_SOLO' -and -not $state.delegation_cost_high) {
        $result.reason_code = 'aggressive_delegation_preferred'
        return [pscustomobject]$result
    }
    $result.decision = $jev.choice
    $result.worker_reused = ($jev.choice -eq 'REUSE_SUBAGENT')
    $result.reason_code = switch ($jev.choice) { 'PARENT_SOLO' { 'jev_parent_efficient' }; 'REUSE_SUBAGENT' { 'jev_warm_worker' }; 'DELEGATE_SINGLE' { 'jev_single_front' }; 'DELEGATE_BATCH' { 'jev_independent_fronts' } }
    return [pscustomobject]$result
}

function Invoke-SubagentReviewGate {
    param([Parameter(Mandatory)][object]$InputData, [string]$Mode = '', [scriptblock]$TransportMock)
    $jevMode = Get-SubagentJevMode $Mode
    $backend = Assert-GateEnum (([string](Get-GateField $InputData 'backend' '')).ToLowerInvariant()) @('native', 'deepseek') 'backend'
    $policy = ([string](Get-GateField $InputData 'policy' 'balanced')).ToLowerInvariant()
    if ($policy -eq 'standard') { $policy = 'balanced' }
    $policy = Assert-GateEnum $policy @('balanced', 'aggressive', 'swarm') 'policy'
    $result = [ordered]@{ gate = 'review'; policy = $policy; decision = 'GPT_REVIEW'; reason_code = 'current_policy'; jev_called = $false; latency_ms = 0; worker_reused = $false; backend = $backend; review_result = 'GPT_REVIEW'; current_decision = 'GPT_REVIEW'; jev_recommendation = $null; jev_calls_avoided = 0 }
    if ($jevMode -eq 'off') { $result.reason_code = 'off'; return [pscustomobject]$result }
    $checks = @('tests_passed', 'permissions_clear', 'no_blockers', 'no_unresolved', 'scope_clean', 'mandatory_evidence_present', 'no_errors', 'files_expected', 'small_change', 'clearly_aligned', 'low_risk')
    foreach ($check in $checks) {
        if ((Get-GateField $InputData $check $null) -cne $true) {
            $result.reason_code = "deterministic_$check"; $result.jev_calls_avoided = 1
            return [pscustomobject]$result
        }
    }
    if ([bool](Get-GateField $InputData 'architecture_change' $false) -or [bool](Get-GateField $InputData 'ambiguous' $false) -or [bool](Get-GateField $InputData 'sensitive' $false)) {
        $result.reason_code = 'deterministic_complex_change'; $result.jev_calls_avoided = 1
        return [pscustomobject]$result
    }
    $changed = [int](Get-GateField $InputData 'changed_files' 0)
    if ($changed -lt 1 -or $changed -gt 2) { $result.reason_code = 'deterministic_file_count'; $result.jev_calls_avoided = 1; return [pscustomobject]$result }
    $state = [ordered]@{ tests_passed = $true; permissions_clear = $true; no_blockers = $true; no_unresolved = $true; scope_clean = $true; mandatory_evidence_present = $true; no_errors = $true; files_expected = $true; small_change = $true; clearly_aligned = $true; low_risk = $true; changed_files = $changed }
    $criteria = [ordered]@{ ACCEPT_OBVIOUS = 'Clearly safe, small, expected worker result; only extra parent semantic reading may be skipped.'; GPT_REVIEW = 'Any remaining ambiguity or concern requires parent review.' }
    $jev = Invoke-JevGateChoice -State $state -Criteria $criteria -Instructions 'Can an additional parent semantic reading of this small worker result safely be skipped? Choose GPT_REVIEW whenever uncertain. Mandatory independent delivery review is never skipped.' -TransportMock $TransportMock
    $result.jev_called = $true; $result.latency_ms = $jev.latency_ms
    if ($jev.ok) { $result.jev_recommendation = $jev.choice }
    if (-not $jev.ok -or $jev.confidence -lt 0.9 -or $jev.probability -lt 0.9) { $result.reason_code = if ($jev.ok) { 'jev_uncertain' } else { $jev.error_code }; return [pscustomobject]$result }
    if ($jevMode -eq 'shadow') { $result.reason_code = 'shadow'; return [pscustomobject]$result }
    $result.decision = $jev.choice; $result.review_result = $jev.choice
    $result.reason_code = if ($jev.choice -eq 'ACCEPT_OBVIOUS') { 'jev_obvious_safe' } else { 'jev_review_needed' }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Get-SubagentJevMode, Invoke-JevGateChoice, Invoke-SubagentDelegationGate, Invoke-SubagentReviewGate
