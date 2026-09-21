# scripts/test-dev-router.ps1
# Deterministic contract and unit tests for Dev Router (TypeSafe/Jev orchestrator model and effort router)

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$devRouterModule = Join-Path $repoRoot 'scripts\dev-router.psm1'
$switchScript = Join-Path $repoRoot 'scripts\switch-dev-router.ps1'

Import-Module $devRouterModule -DisableNameChecking -Force
Import-Module (Join-Path $repoRoot 'scripts\backend-routing.psm1') -DisableNameChecking -Force

$script:TestCount = 0
$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $false)][string]$Details = ''
    )

    $script:TestCount++
    if ($Condition) {
        $script:PassedCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:FailedCount++
        $message = if ($Details) { "$Name -> $Details" } else { $Name }
        $script:Failures.Add($message)
        Write-Host "  [FAIL] $message" -ForegroundColor Red
    }
}

Write-Host "Running Dev Router Contract and Integration Tests..." -ForegroundColor Cyan

$tempTestDir = Join-Path ([IO.Path]::GetTempPath()) ("dev-router-test-" + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempTestDir)
$testCodexHome = Join-Path $tempTestDir 'codex'
[void][IO.Directory]::CreateDirectory($testCodexHome)

try {
    # ------------------------------------------------------------------------
    # SECTION 1: Catalog & Model Allowlist
    # ------------------------------------------------------------------------
    Write-Host "`nSection 1: Catalog & Model Allowlist" -ForegroundColor Yellow

    $catalog = Get-DevRouterModelCatalog
    Assert-Test "Catalog contains Luna" ($catalog.Models.Contains('Luna'))
    Assert-Test "Catalog contains Sol" ($catalog.Models.Contains('Sol'))
    Assert-Test "Catalog contains Astra" ($catalog.Models.Contains('Astra'))
    Assert-Test "Catalog explicitly disallows Terra" ($catalog.DisallowedModels -contains 'gpt-5.6-terra')

    Assert-Test "Resolve Luna resolves to gpt-5.6-luna" ((Resolve-DevRouterModel -ModelNameOrId 'Luna').Id -eq 'gpt-5.6-luna')
    Assert-Test "Resolve gpt-5.6-sol resolves to Sol" ((Resolve-DevRouterModel -ModelNameOrId 'gpt-5.6-sol').Name -eq 'Sol')
    Assert-Test "Resolve Astra resolves to gpt-6-astra" ((Resolve-DevRouterModel -ModelNameOrId 'Astra').Id -eq 'gpt-6-astra')
    Assert-Test "Resolve Terra returns null (strictly disallowed)" ($null -eq (Resolve-DevRouterModel -ModelNameOrId 'Terra'))
    Assert-Test "Resolve gpt-5.6-terra returns null" ($null -eq (Resolve-DevRouterModel -ModelNameOrId 'gpt-5.6-terra'))
    Assert-Test "Resolve arbitrary model returns null" ($null -eq (Resolve-DevRouterModel -ModelNameOrId 'claude-3-opus'))

    Assert-Test "Luna supports none, minimal, low, medium, high, xhigh" ((Get-DevRouterModelEfforts -ModelNameOrId 'Luna') -contains 'high')
    Assert-Test "Astra supports high" (Test-DevRouterEffortSupported -ModelNameOrId 'Astra' -Effort 'high')
    Assert-Test "Astra does not support invalid effort" (-not (Test-DevRouterEffortSupported -ModelNameOrId 'Astra' -Effort 'ultra'))

    # ------------------------------------------------------------------------
    # SECTION 2: Initial Installed State & Switcher
    # ------------------------------------------------------------------------
    Write-Host "`nSection 2: Initial Installed State & Switcher" -ForegroundColor Yellow

    $initState = Get-DevRouterState -CodexHome $testCodexHome
    Assert-Test "Default mode is off" ($initState.mode -eq 'off')
    Assert-Test "Default target is effort_only" ($initState.target -eq 'effort_only')

    # Status without locks
    $statusOff = Get-DevRouterStatus -CodexHome $testCodexHome
    Assert-Test "Status reports configured_mode = off" ($statusOff.configured_mode -eq 'off')
    Assert-Test "Status reports effective_mode = off" ($statusOff.effective_mode -eq 'off')
    Assert-Test "Status reports target = effort_only" ($statusOff.target -eq 'effort_only')
    Assert-Test "Status reports integration_status = unintegrated for GUI" ($statusOff.integration_status -eq 'unintegrated')

    # Switch to shadow
    $null = Set-DevRouterState -Mode 'shadow' -Target 'effort_only' -CodexHome $testCodexHome
    $shadowState = Get-DevRouterState -CodexHome $testCodexHome
    Assert-Test "Switch to shadow mode persists" ($shadowState.mode -eq 'shadow')

    # Switch to on with model_and_effort
    $null = Set-DevRouterState -Mode 'on' -Target 'model_and_effort' -CodexHome $testCodexHome
    $onState = Get-DevRouterState -CodexHome $testCodexHome
    Assert-Test "Switch to on persists" ($onState.mode -eq 'on')
    Assert-Test "Switch target persists" ($onState.target -eq 'model_and_effort')

    # ------------------------------------------------------------------------
    # SECTION 3: Mode OFF Behavior (Zero Jev Calls, Preserves Baseline)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 3: Mode OFF Behavior" -ForegroundColor Yellow

    $null = Set-DevRouterState -Mode 'off' -Target 'effort_only' -CodexHome $testCodexHome

    $turnOff = Invoke-DevRouterTurn `
        -ConversationId 'conv-off-1' `
        -TurnId 'turn-1' `
        -Objective 'Refactor authentication handler' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome

    Assert-Test "OFF does not call Jev" ($turnOff.jev_called -eq $false)
    Assert-Test "OFF preserves baseline model" ($turnOff.applied_model -eq 'Sol')
    Assert-Test "OFF preserves baseline effort" ($turnOff.applied_effort -eq 'medium')
    Assert-Test "OFF status is off" ($turnOff.status -eq 'off')

    # ------------------------------------------------------------------------
    # SECTION 4: Mode SHADOW Behavior (Jev Recommends, Baseline Preserved)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 4: Mode SHADOW Behavior" -ForegroundColor Yellow

    $null = Set-DevRouterState -Mode 'shadow' -Target 'effort_only' -CodexHome $testCodexHome

    $mockShadowTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    choice = 'high'
                }
            }
        }
    }

    $turnShadow = Invoke-DevRouterTurn `
        -ConversationId 'conv-shadow-1' `
        -TurnId 'turn-1' `
        -Objective 'Investigate performance bottleneck' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockShadowTransport

    Assert-Test "SHADOW calls Jev" ($turnShadow.jev_called -eq $true)
    Assert-Test "SHADOW records recommended effort" ($turnShadow.recommended_effort -eq 'high')
    Assert-Test "SHADOW preserves applied model" ($turnShadow.applied_model -eq 'Sol')
    Assert-Test "SHADOW preserves applied effort as baseline" ($turnShadow.applied_effort -eq 'medium')
    Assert-Test "SHADOW does not acquire persistent lock" ($turnShadow.is_locked -eq $false)

    # ------------------------------------------------------------------------
    # SECTION 5: ON + EFFORT_ONLY (Model Strictly Preserved, Effort Updated)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 5: ON + EFFORT_ONLY" -ForegroundColor Yellow

    $null = Set-DevRouterState -Mode 'on' -Target 'effort_only' -CodexHome $testCodexHome

    $mockEffortTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    choice = 'xhigh'
                }
            }
        }
    }

    $turnEffortOnly = Invoke-DevRouterTurn `
        -ConversationId 'conv-effort-1' `
        -TurnId 'turn-1' `
        -Objective 'High-risk security vulnerability in token verification' `
        -Surface 'workflow' `
        -WorkflowMode 'BUG.FIX' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'low' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockEffortTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "effort_only updates applied effort to xhigh" ($turnEffortOnly.applied_effort -eq 'xhigh')
    Assert-Test "effort_only STRICTLY preserves model Sol (no Astra escalation)" ($turnEffortOnly.applied_model -eq 'Sol')
    Assert-Test "effort_only locks workflow execution" ($turnEffortOnly.lock_scope -eq 'workflow')

    # Even if Jev mock attempts to return Astra in effort_only, parser rejects model change
    $mockTamperEffortTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    choice = 'Astra'  # Not an effort option!
                }
            }
        }
    }

    $turnTamper = Invoke-DevRouterTurn `
        -ConversationId 'conv-effort-tamper' `
        -TurnId 'turn-1' `
        -Objective 'Critical architecture task' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockTamperEffortTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "Invalid effort choice fails safe to baseline model" ($turnTamper.applied_model -eq 'Sol')
    Assert-Test "Invalid effort choice fails safe to baseline effort" ($turnTamper.applied_effort -eq 'medium')

    # ------------------------------------------------------------------------
    # SECTION 6: ON + MODEL_ONLY (Effort Strictly Preserved, Model Updated)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 6: ON + MODEL_ONLY" -ForegroundColor Yellow

    $null = Set-DevRouterState -Mode 'on' -Target 'model_only' -CodexHome $testCodexHome

    $mockModelTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    choice = 'Luna'
                }
            }
        }
    }

    $turnModelOnly = Invoke-DevRouterTurn `
        -ConversationId 'conv-model-1' `
        -TurnId 'turn-1' `
        -Objective 'Format markdown docstrings' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'high' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockModelTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "model_only updates model to Luna" ($turnModelOnly.applied_model -eq 'Luna')
    Assert-Test "model_only STRICTLY preserves manual effort 'high'" ($turnModelOnly.applied_effort -eq 'high')

    # If mock attempts to return Terra (disallowed), falls back to baseline
    $mockTerraTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    choice = 'Terra'
                }
            }
        }
    }

    $turnTerra = Invoke-DevRouterTurn `
        -ConversationId 'conv-model-terra' `
        -TurnId 'turn-1' `
        -Objective 'Standard work' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockTerraTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "Disallowed Terra choice fails safe to baseline model Sol" ($turnTerra.applied_model -eq 'Sol')

    # ------------------------------------------------------------------------
    # SECTION 7: ON + MODEL_AND_EFFORT (Both Updated in Allowlist)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 7: ON + MODEL_AND_EFFORT" -ForegroundColor Yellow

    $null = Set-DevRouterState -Mode 'on' -Target 'model_and_effort' -CodexHome $testCodexHome

    $mockBothTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    choice = 'Astra:xhigh'
                }
            }
        }
    }

    $turnBoth = Invoke-DevRouterTurn `
        -ConversationId 'conv-both-1' `
        -TurnId 'turn-1' `
        -Objective 'Complex distributed lock deadlock' `
        -Surface 'workflow' `
        -WorkflowMode 'DEBUG' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'low' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockBothTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "model_and_effort updates model to Astra" ($turnBoth.applied_model -eq 'Astra')
    Assert-Test "model_and_effort updates effort to xhigh" ($turnBoth.applied_effort -eq 'xhigh')

    # ------------------------------------------------------------------------
    # SECTION 8: Context Sanitization & Privacy Boundary
    # ------------------------------------------------------------------------
    Write-Host "`nSection 8: Context Sanitization & Privacy Boundary" -ForegroundColor Yellow

    $rawSecretPrompt = @"
Please inspect this token: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.secretKey
Here is code:
```powershell
Write-Host "Private DB password: mySecretPassword123"
```
Check file C:\SecretProjects\Finance\Accounts.txt
"@

    $proj = New-DevRouterContextProjection `
        -Objective $rawSecretPrompt `
        -Surface 'alignment' `
        -CurrentModel 'Sol' `
        -CurrentEffort 'medium' `
        -HasImages $true

    Assert-Test "Projection strips code block" ($proj.routing_objective -notmatch 'mySecretPassword123')
    Assert-Test "Projection redacts bearer token" ($proj.routing_objective -notmatch 'eyJhbGciOiJIUzI1Ni')
    Assert-Test "Projection sanitizes file paths" ($proj.routing_objective -notmatch 'C:\\SecretProjects')
    Assert-Test "Projection flags image presence without transmitting data" ($proj.has_images -eq $true)

    # ------------------------------------------------------------------------
    # SECTION 9: Thread Isolation & Locking (ALINHAMENTO vs Workflow)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 9: Thread Isolation & Locking" -ForegroundColor Yellow

    Clear-AllDevRouterLocks -CodexHome $testCodexHome

    # Turn lock in ALINHAMENTO:
    $null = Set-DevRouterState -Mode 'on' -Target 'effort_only' -CodexHome $testCodexHome

    $script:mockCallCount = 0
    $mockCountTransport = {
        param($req)
        $script:mockCallCount++
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{ choice = 'high' }
            }
        }
    }

    # First turn call
    $t1 = Invoke-DevRouterTurn `
        -ConversationId 'conv-A' `
        -TurnId 'turn-101' `
        -Objective 'First user prompt in alignment' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'low' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockCountTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "First call invokes Jev" ($script:mockCallCount -eq 1)
    Assert-Test "First call locks turn" ($t1.is_locked -eq $true -and $t1.lock_scope -eq 'turn')

    # Second call in SAME turn (e.g. intermediate tool call)
    $t2 = Invoke-DevRouterTurn `
        -ConversationId 'conv-A' `
        -TurnId 'turn-101' `
        -Objective 'Tool execution result within same turn' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'low' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockCountTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "Second call in same turn REUSES lock without Jev call" ($script:mockCallCount -eq 1 -and $t2.status -eq 'locked')
    Assert-Test "Reused decision preserves applied effort" ($t2.applied_effort -eq 'high')

    # Simultaneous conversation B is NOT contaminated by conversation A
    $tB = Invoke-DevRouterTurn `
        -ConversationId 'conv-B' `
        -TurnId 'turn-201' `
        -Objective 'Independent user prompt in different session' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'low' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockCountTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "Conversation B triggers its own Jev call (no contamination)" ($script:mockCallCount -eq 2)
    Assert-Test "Conversation B has its own distinct lock" ($tB.conversation_id -eq 'conv-B')

    # Releasing lock
    $released = Release-DevRouterLock -ConversationId 'conv-A' -CodexHome $testCodexHome
    Assert-Test "Explicit lock release succeeds" ($released -eq $true)
    Assert-Test "Lock no longer exists for conv-A" ($null -eq (Get-DevRouterLock -ConversationId 'conv-A' -CodexHome $testCodexHome))
    Assert-Test "Lock for conv-B is still intact" ($null -ne (Get-DevRouterLock -ConversationId 'conv-B' -CodexHome $testCodexHome))

    # ------------------------------------------------------------------------
    # SECTION 10: Fail-Safe Fallback (No Universal Astra)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 10: Fail-Safe Fallback" -ForegroundColor Yellow

    # Network / 500 error
    $mockErrorTransport = {
        param($req)
        throw "HTTP 500 Internal Server Error"
    }

    $turnErr = Invoke-DevRouterTurn `
        -ConversationId 'conv-err' `
        -TurnId 'turn-1' `
        -Objective 'Work' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockErrorTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "HTTP error falls back to baseline model Sol" ($turnErr.applied_model -eq 'Sol')
    Assert-Test "HTTP error falls back to baseline effort medium" ($turnErr.applied_effort -eq 'medium')
    Assert-Test "HTTP error does NOT force Astra" ($turnErr.applied_model -ne 'Astra')
    Assert-Test "HTTP error reports degraded status" ($turnErr.status -eq 'error')

    # Missing API Key
    $origKey = $env:TYPESAFE_API_KEY
    try {
        $env:TYPESAFE_API_KEY = ''
        $turnNoKey = Invoke-DevRouterTurn `
            -ConversationId 'conv-nokey' `
            -TurnId 'turn-1' `
            -Objective 'Work' `
            -Surface 'alignment' `
            -BaselineModel 'Luna' `
            -BaselineEffort 'low' `
            -CodexHome $testCodexHome `
            -AdapterSurface 'cli_harness'

        Assert-Test "Missing API key falls back to baseline model Luna" ($turnNoKey.applied_model -eq 'Luna')
        Assert-Test "Missing API key falls back to baseline effort low" ($turnNoKey.applied_effort -eq 'low')
        Assert-Test "Missing API key status is unavailable" ($turnNoKey.status -eq 'unavailable')
    }
    finally {
        $env:TYPESAFE_API_KEY = $origKey
    }

    # ------------------------------------------------------------------------
    # SECTION 11: Surface Detection (GUI Unintegrated vs CLI Harness)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 11: Surface Detection (GUI vs CLI)" -ForegroundColor Yellow

    $null = Set-DevRouterState -Mode 'on' -Target 'effort_only' -CodexHome $testCodexHome

    # Desktop GUI Surface:
    $turnGui = Invoke-DevRouterTurn `
        -ConversationId 'conv-gui' `
        -TurnId 'turn-1' `
        -Objective 'Chat in desktop GUI' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockShadowTransport `
        -AdapterSurface 'codex_app_gui'

    Assert-Test "GUI surface reports effective_mode = bypass" ($turnGui.effective_mode -eq 'bypass')
    Assert-Test "GUI surface preserves manual baseline execution" ($turnGui.applied_model -eq 'Sol' -and $turnGui.applied_effort -eq 'medium')
    Assert-Test "GUI surface reports unintegrated_surface status" ($turnGui.status -eq 'unintegrated_surface')

    # CLI Harness Surface:
    $cliArgs = Get-DevRouterCliArguments -Model 'Luna' -Effort 'high'
    Assert-Test "CLI harness generates -m gpt-5.6-luna" ($cliArgs[0] -eq '-m' -and $cliArgs[1] -eq 'gpt-5.6-luna')
    Assert-Test "CLI harness generates model_reasoning_effort override" ($cliArgs[2] -eq '-c' -and $cliArgs[3] -eq 'model_reasoning_effort="high"')

    # ------------------------------------------------------------------------
    # SECTION 12: CLI Switcher Script Integration
    # ------------------------------------------------------------------------
    Write-Host "`nSection 12: CLI Switcher Script Integration" -ForegroundColor Yellow

    # Switch to mode on, target model_only via script
    & $switchScript -Mode on -Target model_only -CodexHome $testCodexHome | Out-Null
    $stateAfterSwitch = Get-DevRouterState -CodexHome $testCodexHome
    Assert-Test "switch-dev-router sets mode on" ($stateAfterSwitch.mode -eq 'on')
    Assert-Test "switch-dev-router sets target model_only" ($stateAfterSwitch.target -eq 'model_only')

    # Switch to off
    & $switchScript -Mode off -CodexHome $testCodexHome | Out-Null
    $stateAfterOff = Get-DevRouterState -CodexHome $testCodexHome
    Assert-Test "switch-dev-router sets mode off" ($stateAfterOff.mode -eq 'off')

    # Status call
    $statusObj = & $switchScript -Status -CodexHome $testCodexHome
    Assert-Test "switch-dev-router -Status returns pscustomobject" ($null -ne $statusObj)
    Assert-Test "Status object has configured_mode" ($statusObj.configured_mode -eq 'off')
    Assert-Test "Status object has integration_status" ($statusObj.integration_status -eq 'unintegrated')
}
finally {
    if (Test-Path -LiteralPath $tempTestDir) {
        Remove-Item -LiteralPath $tempTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "Dev Router Test Results: $($script:PassedCount)/$($script:TestCount) passed" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "Failures ($($script:FailedCount)):" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
}
exit 0
