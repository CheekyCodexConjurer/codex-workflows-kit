Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\skills\workflows\scripts\adaptive-orchestration.psm1') -Force

function Assert-Equal($Name, $Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "$Name expected '$Expected', got '$Actual'" }
}

function New-Request($Fronts) {
    return [ordered]@{
        mode = 'DELIVER.AUTO'; backend = 'deepseek'; event = 'new_front'
        objective = 'Implement bounded change'; fronts = @($Fronts)
        consumed_dependencies = @(); workers = @(); risks = @()
        available_capacity = 3; estimated_parallel_gain_seconds = 20
        capabilities = @('batch_scheduler'); callable_tools = @('subagents_spawn_batch')
        authoritative_bridge_probe = @{ status='ok'; capabilities=@('batch_scheduler') }
    }
}

$immediate = New-Request @(@{ id='small'; immediate=$true; agent_mode='analyze' })
$d = Get-AdaptiveOrchestrationDecision -Request $immediate -JevMode off
Assert-Equal 'immediate' $d.execution 'direct'
Assert-Equal 'immediate Jev' $d.jev.calls 0
$immediate.fronts[0].ambiguous = $true
$immediate.fronts[0].decision_signals = 'Scope is uncertain'
$d = Get-AdaptiveOrchestrationDecision -Request $immediate -JevMode off
Assert-Equal 'ambiguous immediate front escalates' $d.execution 'parent_decision'
$immediate.fronts[0].ambiguous = $false

$one = New-Request @(@{ id='feature'; agent_mode='edit'; ownership=@('src/a.ts') })
$d = Get-AdaptiveOrchestrationDecision -Request $one -JevMode off
Assert-Equal 'cohesive feature' $d.execution 'delegate_one'
Assert-Equal 'independent review' $d.review.independent_review $true

$two = New-Request @(
    @{ id='a'; agent_mode='edit'; ownership=@('src/a.ts') },
    @{ id='b'; agent_mode='edit'; ownership=@('src/b.ts') }
)
$d = Get-AdaptiveOrchestrationDecision -Request $two -JevMode off
Assert-Equal 'parallel independent' $d.execution 'delegate_parallel'
Assert-Equal 'parallel count' @($d.selected_front_ids).Count 2
$legacyBatch = New-Request @(
    @{ id='legacy-a'; agent_mode='edit'; ownership=@('src/legacy-a.ts') },
    @{ id='legacy-b'; agent_mode='edit'; ownership=@('src/legacy-b.ts') }
)
$legacyBatch.callable_tools = @('deepseek_spawn_batch')
$d = Get-AdaptiveOrchestrationDecision -Request $legacyBatch -JevMode off
Assert-Equal 'legacy batch alias remains callable' $d.execution 'delegate_parallel'
$capacityBounded = New-Request @(
    @{ id='first'; agent_mode='edit'; ownership=@('src/first.ts') },
    @{ id='second'; agent_mode='edit'; ownership=@('src/second.ts') },
    @{ id='third'; agent_mode='edit'; ownership=@('src/third.ts') }
)
$capacityBounded.available_capacity = 2
$d = Get-AdaptiveOrchestrationDecision -Request $capacityBounded -JevMode off
Assert-Equal 'parallel capacity bound' @($d.selected_front_ids).Count 2
Assert-Equal 'parallel defers excess front' (@($d.selected_front_ids) -contains 'third') $false
Assert-Equal 'excess front remains deferred' (@($d.deferred_front_ids) -contains 'third') $true
$native = New-Request @(
    @{ id='native-a'; agent_mode='edit'; ownership=@('src/one.ts') },
    @{ id='native-b'; agent_mode='edit'; ownership=@('src/two.ts') }
)
$native.backend = 'native'
$native.capabilities = @()
$native.callable_tools = @()
$native.authoritative_bridge_probe = $null
$d = Get-AdaptiveOrchestrationDecision -Request $native -JevMode off
Assert-Equal 'native exposed capacity permits independent fronts' $d.execution 'delegate_parallel'
$native.available_capacity = 1
$d = Get-AdaptiveOrchestrationDecision -Request $native -JevMode off
Assert-Equal 'native capacity blocks parallel' $d.execution 'delegate_one'

$two.authoritative_bridge_probe.status = 'error'
$d = Get-AdaptiveOrchestrationDecision -Request $two -JevMode off
Assert-Equal 'unhealthy authoritative probe blocks parallel' $d.execution 'delegate_one'
$two.authoritative_bridge_probe.status = 'ok'
$two.fronts[0].ownership = @('src')
$d = Get-AdaptiveOrchestrationDecision -Request $two -JevMode off
Assert-Equal 'nested ownership blocks parallel' $d.execution 'delegate_one'
$two.fronts[0].ownership = @('src/a.ts')

$two.fronts[1].ownership = @('src/a.ts')
$d = Get-AdaptiveOrchestrationDecision -Request $two -JevMode off
Assert-Equal 'shared ownership serial' $d.execution 'delegate_one'
$two.fronts[1].ownership = @('src/b.ts')
$two.fronts[1].depends_on = @('a')
$d = Get-AdaptiveOrchestrationDecision -Request $two -JevMode off
Assert-Equal 'dependency serial' $d.execution 'delegate_one'
Assert-Equal 'dependency deferred' @($d.deferred_front_ids).Count 1

$one.workers = @(@{ agent_id='worker-a'; backend='deepseek'; status='idle_open'; session_confirmed=$true; context_relevant=$true; scope_compatible=$true; sources_fresh=$true; role='implementer'; ownership=@('src/a.ts') })
$one.fronts[0].ownership = @('src/a.ts')
$d = Get-AdaptiveOrchestrationDecision -Request $one -JevMode off
Assert-Equal 'reuse compatible worker' $d.execution 'reuse_worker'
$one.workers[0].sources_fresh = $false
$d = Get-AdaptiveOrchestrationDecision -Request $one -JevMode off
Assert-Equal 'stale worker excluded' $d.execution 'delegate_one'

$noWrite = New-Request @(@{ id='bad'; agent_mode='edit'; ownership=@('src/a.ts') })
$noWrite.mode = 'PLAN.AUTO'
$rejected = $false
try { Get-AdaptiveOrchestrationDecision -Request $noWrite -JevMode off | Out-Null } catch { $rejected = $true }
Assert-Equal 'no-write blocks edit' $rejected $true
$noWrite.fronts[0].agent_mode = 'test'
$rejected = $false
try { Get-AdaptiveOrchestrationDecision -Request $noWrite -JevMode off | Out-Null } catch { $rejected = $true }
Assert-Equal 'no-write blocks tests' $rejected $true
$unownedTests = New-Request @(
    @{ id='test-a'; agent_mode='test' },
    @{ id='test-b'; agent_mode='test' }
)
$rejected = $false
try { Get-AdaptiveOrchestrationDecision -Request $unownedTests -JevMode off | Out-Null } catch { $rejected = $true }
Assert-Equal 'tests without ownership fail closed before parallel dispatch' $rejected $true
$unownedTests.fronts[0].ownership = @('')
$unownedTests.fronts[1].ownership = @('tests/fixture-b')
$rejected = $false
try { Get-AdaptiveOrchestrationDecision -Request $unownedTests -JevMode off | Out-Null } catch { $rejected = $true }
Assert-Equal 'blank test ownership is rejected' $rejected $true

$ambiguous = New-Request @(@{ id='amb'; agent_mode='edit'; ownership=@('src/a.ts'); ambiguous=$true; decision_signals='Scope and acceptance unclear' })
$mock = @{ amb = 0.20 }
$d = Get-AdaptiveOrchestrationDecision -Request $ambiguous -MockJevResponses $mock
Assert-Equal 'Jev ambiguity escalates' $d.execution 'parent_decision'
$mixedAmbiguity = New-Request @(
    @{ id='clear'; agent_mode='edit'; ownership=@('src/clear.ts'); ambiguous=$true; decision_signals='Ready scope' },
    @{ id='unclear'; agent_mode='edit'; ownership=@('src/unclear.ts'); ambiguous=$true; decision_signals='Scope uncertain' }
)
$d = Get-AdaptiveOrchestrationDecision -Request $mixedAmbiguity -MockJevResponses @{ clear=0.8; unclear=0.2 }
Assert-Equal 'later ambiguous front escalates' $d.execution 'parent_decision'
Assert-Equal 'later ambiguous front selected for parent' @($d.selected_front_ids)[0] 'unclear'
Assert-Equal 'later ambiguous front never dispatched with batch' (@($d.selected_front_ids) -contains 'clear') $false
$shadow = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevMode shadow -MockJevResponses $mock
Assert-Equal 'shadow leaves execution' $shadow.execution 'delegate_one'
$off = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevMode off
Assert-Equal 'Jev off preserves orchestration' $off.execution 'delegate_one'
$transportFailure = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevTransportMock { throw 'service unavailable' }
Assert-Equal 'Jev failure preserves conservative execution' $transportFailure.execution 'delegate_one'
Assert-Equal 'Jev failure reported' $transportFailure.jev.status 'unavailable'
$script:capturedJevBody = $null
$transport = {
    param($request)
    $script:capturedJevBody = $request.BodyObject
    $answers = @{}
    foreach ($key in $request.BodyObject.questions.Keys) { $answers[$key] = @{ noul = 0.8 } }
    return @{ model = 'jev-latest'; answers = $answers; usage = @{} }
}
$ambiguous.fronts[0].decision_signals = 'Scope unclear; token=private-value'
$transportResult = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevTransportMock $transport
Assert-Equal 'Jev transport mock status' $transportResult.jev.status 'ok'
Assert-Equal 'Jev uses noul question' @($script:capturedJevBody.questions.Values | Where-Object { $_.type -eq 'noul' }).Count 1
Assert-Equal 'Jev sanitizes signals' ((ConvertTo-Json $script:capturedJevBody -Depth 8) -notmatch 'private-value') $true

$ambiguous.fronts[0].decision_signals = 'Scope and acceptance unclear'
$off = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevMode off
$ambiguous.previous_decision = $off
$cached = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevMode off
Assert-Equal 'unchanged decision reused' $cached.fingerprint $off.fingerprint
$changedMode = Get-AdaptiveOrchestrationDecision -Request $ambiguous -JevMode shadow -MockJevResponses $mock
Assert-Equal 'Jev mode changes fingerprint' ($changedMode.fingerprint -cne $off.fingerprint) $true

Write-Host 'adaptive-orchestration: PASS'
exit 0
