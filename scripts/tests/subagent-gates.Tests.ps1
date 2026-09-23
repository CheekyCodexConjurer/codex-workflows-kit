Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $repo 'skills\workflows\scripts\subagent-gates.psm1') -Force

$script:Assertions = 0
$script:Calls = 0
$script:MockChoice = 'DELEGATE_SINGLE'
$script:Confidence = 0.99
$script:LastBody = $null
$script:Mock = {
    param($body)
    $script:Calls++
    $script:LastBody = $body
    if ($script:MockChoice -eq 'THROW') { throw 'mock timeout' }
    $keys = @($body.questions.gate.criteria.Keys)
    $probabilities = @{}
    foreach ($key in $keys) { $probabilities[$key] = if ($key -eq $script:MockChoice) { 0.99 } else { 0.01 / [Math]::Max(1, $keys.Count - 1) } }
    return @{ answers = @{ gate = @{ type = 'choice'; choice = $script:MockChoice; confidence = $script:Confidence; probabilities = $probabilities } } }
}

function Assert-Test([string]$Name, [bool]$Condition) {
    $script:Assertions++
    if (-not $Condition) { throw "FAILED: $Name" }
}

function New-DelegationInput {
    param([string]$Policy = 'balanced')
    return [ordered]@{
        policy = $Policy; workflow_mode = 'DELIVER.AUTO'; backend = 'deepseek'; current_decision = 'PARENT_SOLO'
        task_type = 'implementation'; scope = 'multi_file'; estimated_files = 3; material = $true; trivial = $false
        requires_edit = $true; requires_tests = $true; requires_architecture = $false
        independent_fronts = 1; fronts_independent = $false; context_load = 'medium'
        relevant_worker_available = $false; worker_context_warm = $false; worker_route_matches = $false
    }
}

function New-ReviewInput {
    return [ordered]@{
        policy = 'balanced'; backend = 'deepseek'; tests_passed = $true; permissions_clear = $true
        no_blockers = $true; no_unresolved = $true; scope_clean = $true; mandatory_evidence_present = $true
        no_errors = $true; files_expected = $true; small_change = $true; clearly_aligned = $true
        low_risk = $true; changed_files = 1; architecture_change = $false; ambiguous = $false; sensitive = $false
    }
}

$d = New-DelegationInput
$d.trivial = $true
$before = $script:Calls
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'balanced trivial remains parent without Jev' ($r.decision -eq 'PARENT_SOLO' -and $r.jev_calls_avoided -eq 1 -and $script:Calls -eq $before)
$d.current_decision = 'DELEGATE_SINGLE'
$r = Invoke-SubagentDelegationGate $d -Mode shadow -TransportMock $script:Mock
Assert-Test 'shadow leaves even a trivial current decision untouched' ($r.decision -eq 'DELEGATE_SINGLE' -and $r.jev_recommendation -eq 'PARENT_SOLO')
$d = New-DelegationInput
$d.current_decision = 'DELEGATE_SINGLE'; $before = $script:Calls
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'balanced without clear gain returns parent without Jev' ($r.decision -eq 'PARENT_SOLO' -and $script:Calls -eq $before)
$d = New-DelegationInput 'STANDARD'; $d.trivial = $true
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'STANDARD aliases balanced' ($r.policy -eq 'balanced' -and $r.decision -eq 'PARENT_SOLO')

$d = New-DelegationInput
$d.scope = 'large'; $d.context_load = 'high'; $d.task_type = 'read'; $d.requires_edit = $false
$script:MockChoice = 'DELEGATE_SINGLE'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'balanced high-context reading delegates' ($r.decision -eq 'DELEGATE_SINGLE' -and $r.jev_called)

$d = New-DelegationInput
$d.relevant_worker_available = $true; $d.worker_context_warm = $true; $d.worker_route_matches = $true
$script:MockChoice = 'REUSE_SUBAGENT'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'warm same-route worker reused' ($r.decision -eq 'REUSE_SUBAGENT' -and $r.worker_reused)

$d = New-DelegationInput 'aggressive'
$d.current_decision = 'DELEGATE_SINGLE'; $script:MockChoice = 'DELEGATE_SINGLE'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'aggressive material front delegates' ($r.decision -eq 'DELEGATE_SINGLE')
$d.trivial = $true; $before = $script:Calls
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'aggressive trivial front remains parent' ($r.decision -eq 'PARENT_SOLO' -and $script:Calls -eq $before)

$d = New-DelegationInput 'swarm'
$d.current_decision = 'DELEGATE_SINGLE'; $script:MockChoice = 'DELEGATE_SINGLE'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'swarm single front delegates once' ($r.decision -eq 'DELEGATE_SINGLE')
$d.independent_fronts = 3; $d.fronts_independent = $true; $d.current_decision = 'DELEGATE_BATCH'; $script:MockChoice = 'DELEGATE_BATCH'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'swarm three independent fronts batch' ($r.decision -eq 'DELEGATE_BATCH')
$d.fronts_independent = $false; $d.current_decision = 'DELEGATE_SINGLE'; $script:MockChoice = 'DELEGATE_BATCH'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'causal fronts cannot batch' ($r.decision -eq 'DELEGATE_SINGLE' -and $r.reason_code -eq 'jev_invalid_choice')

$d = New-DelegationInput
$d.current_decision = 'PARENT_SOLO'; $d.context_load = 'high'; $script:MockChoice = 'DELEGATE_SINGLE'
$before = $script:Calls
$r = Invoke-SubagentDelegationGate $d -Mode off -TransportMock $script:Mock
Assert-Test 'off makes no Jev call' ($r.decision -eq 'PARENT_SOLO' -and $script:Calls -eq $before)
$r = Invoke-SubagentDelegationGate $d -Mode shadow -TransportMock $script:Mock
Assert-Test 'shadow preserves actual decision and records recommendation' ($r.decision -eq 'PARENT_SOLO' -and $r.jev_recommendation -eq 'DELEGATE_SINGLE')
$script:MockChoice = 'THROW'
$r = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'Jev failure preserves current decision' ($r.decision -eq 'PARENT_SOLO' -and $r.reason_code -eq 'jev_unavailable')

$script:MockChoice = 'DELEGATE_SINGLE'
$native = New-DelegationInput; $native.backend = 'native'; $native.context_load = 'high'
$gemini = New-DelegationInput; $gemini.backend = 'deepseek'; $gemini.context_load = 'high'
$rn = Invoke-SubagentDelegationGate $native -TransportMock $script:Mock
$nativeState = $script:LastBody.state
$rg = Invoke-SubagentDelegationGate $gemini -TransportMock $script:Mock
Assert-Test 'native and Gemini see identical gate state and decision' ($rn.decision -eq $rg.decision -and $nativeState -ceq $script:LastBody.state -and $rn.backend -eq 'native' -and $rg.backend -eq 'deepseek')

$d = New-DelegationInput
$d.context_load = 'high'; $d.prompt = 'SECRET_MARKER'; $d.code = 'SECRET_MARKER'; $d.diff = 'SECRET_MARKER'
$null = Invoke-SubagentDelegationGate $d -TransportMock $script:Mock
Assert-Test 'only whitelisted small projection reaches Jev' ($script:LastBody.state -notmatch 'SECRET_MARKER|backend')

$review = New-ReviewInput
$review.tests_passed = $false; $before = $script:Calls
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'failed tests demand GPT without Jev' ($r.decision -eq 'GPT_REVIEW' -and $script:Calls -eq $before)
$review = New-ReviewInput; $review.no_blockers = $false; $before = $script:Calls
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'blocker demands GPT without Jev' ($r.decision -eq 'GPT_REVIEW' -and $script:Calls -eq $before)
$review = New-ReviewInput; $review.mandatory_evidence_present = $false; $before = $script:Calls
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'missing evidence demands GPT without Jev' ($r.decision -eq 'GPT_REVIEW' -and $script:Calls -eq $before)
$review = New-ReviewInput; $script:MockChoice = 'ACCEPT_OBVIOUS'
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'small green aligned result can be obvious' ($r.decision -eq 'ACCEPT_OBVIOUS')
$review.architecture_change = $true; $before = $script:Calls
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'architecture change demands GPT without Jev' ($r.decision -eq 'GPT_REVIEW' -and $script:Calls -eq $before)
$review = New-ReviewInput; $review.ambiguous = $true; $before = $script:Calls
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'ambiguity demands GPT without Jev' ($r.decision -eq 'GPT_REVIEW' -and $script:Calls -eq $before)
$review = New-ReviewInput; $script:MockChoice = 'ACCEPT_OBVIOUS'; $script:Confidence = 0.5
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'uncertain Jev cannot accept' ($r.decision -eq 'GPT_REVIEW')
$script:Confidence = 0.99; $script:MockChoice = 'THROW'
$r = Invoke-SubagentReviewGate $review -TransportMock $script:Mock
Assert-Test 'review Jev failure demands GPT' ($r.decision -eq 'GPT_REVIEW')
$script:MockChoice = 'ACCEPT_OBVIOUS'; $before = $script:Calls
$r = Invoke-SubagentReviewGate $review -Mode off -TransportMock $script:Mock
Assert-Test 'review off makes no Jev call' ($r.decision -eq 'GPT_REVIEW' -and $script:Calls -eq $before)
$r = Invoke-SubagentReviewGate $review -Mode shadow -TransportMock $script:Mock
Assert-Test 'review shadow preserves GPT decision' ($r.decision -eq 'GPT_REVIEW' -and $r.jev_recommendation -eq 'ACCEPT_OBVIOUS')

Write-Output "PASS: $script:Assertions subagent gate assertions; Jev calls avoided by deterministic filters in this suite: 10"
exit 0
