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

    # ------------------------------------------------------------------------
    # SECTION 13: Baseline Scoping & Preservation (No Invented Sol/Medium)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 13: Baseline Scoping & Preservation" -ForegroundColor Yellow

    $scopedTomlDir = Join-Path $tempTestDir 'scoped_codex'
    [void][IO.Directory]::CreateDirectory($scopedTomlDir)
    $scopedTomlPath = Join-Path $scopedTomlDir 'config.toml'

    # 1. Config with top-level model and effort, plus subtable with different keys
    $sampleToml = @"
# Top level settings
model = "gpt-5.6-luna"
model_reasoning_effort = "high"

[model_providers.probe]
model = "gpt-6-astra"
model_reasoning_effort = "xhigh"
base_url = "http://127.0.0.1:4040/v1"
"@
    [IO.File]::WriteAllText($scopedTomlPath, $sampleToml, [System.Text.Encoding]::UTF8)

    $scopedBaseline = Get-CodexBaselineConfig -CodexHome $scopedTomlDir
    Assert-Test "Baseline extracts top-level model Luna" ($scopedBaseline.Model -eq 'Luna')
    Assert-Test "Baseline extracts top-level effort high" ($scopedBaseline.Effort -eq 'high')

    # 2. Config with ONLY subtable (no top-level model or effort)
    $subtableOnlyToml = @"
[model_providers.probe]
model = "gpt-6-astra"
model_reasoning_effort = "xhigh"
base_url = "http://127.0.0.1:4040/v1"
"@
    [IO.File]::WriteAllText($scopedTomlPath, $subtableOnlyToml, [System.Text.Encoding]::UTF8)

    $emptyBaseline = Get-CodexBaselineConfig -CodexHome $scopedTomlDir
    Assert-Test "Baseline preserves null model when not set at root (no invented Sol)" ($null -eq $emptyBaseline.Model)
    Assert-Test "Baseline preserves null effort when not set at root (no invented medium)" ($null -eq $emptyBaseline.Effort)

    # ------------------------------------------------------------------------
    # SECTION 14: Incompatible Combinations in model_only
    # ------------------------------------------------------------------------
    Write-Host "`nSection 14: Incompatible Combinations in model_only" -ForegroundColor Yellow

    # When baseline effort is unsupported by any candidate model (e.g. ultra)
    $incompProj = New-DevRouterContextProjection `
        -Objective "Task with ultra effort" `
        -Surface 'alignment' `
        -CurrentModel 'Sol' `
        -CurrentEffort 'ultra' `
        -Target 'model_only'

    $incompJev = Invoke-DevRouterJevChoice `
        -Projection $incompProj `
        -Target 'model_only' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'ultra' `
        -ApiKey 'dummy_key'

    Assert-Test "model_only with unsupported effort returns incompatible status" ($incompJev.status -eq 'incompatible')
    Assert-Test "model_only does NOT re-open all models under incompatible effort" ($incompJev.is_fallback -eq $true)
    Assert-Test "model_only preserves baseline model on incompatible effort" ($incompJev.model -eq 'Sol')

    # ------------------------------------------------------------------------
    # SECTION 15: Terra Pass-Through vs Automatic Disallow
    # ------------------------------------------------------------------------
    Write-Host "`nSection 15: Terra Pass-Through vs Automatic Disallow" -ForegroundColor Yellow

    # Resolve with IncludeDisallowed works for manual baseline
    $resTerraAllowed = Resolve-DevRouterModel -ModelNameOrId 'Terra' -IncludeDisallowed
    Assert-Test "Resolve-DevRouterModel -IncludeDisallowed resolves Terra" ($null -ne $resTerraAllowed -and $resTerraAllowed.Name -eq 'Terra')

    # Automatic routing strictly disallows Terra
    Assert-Test "Test-DevRouterModelAllowed strictly returns false for Terra" (-not (Test-DevRouterModelAllowed -ModelNameOrId 'Terra'))

    # Manual baseline on Terra in effort_only stays strictly on Terra
    $null = Set-DevRouterState -Mode 'on' -Target 'effort_only' -CodexHome $testCodexHome
    $mockTerraEffortTransport = {
        param($req)
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{ choice = 'high' }
            }
        }
    }

    $turnTerraManual = Invoke-DevRouterTurn `
        -ConversationId 'conv-terra-manual' `
        -TurnId 'turn-1' `
        -Objective 'Task on manual Terra' `
        -Surface 'alignment' `
        -BaselineModel 'Terra' `
        -BaselineEffort 'low' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockTerraEffortTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "effort_only preserves manual Terra baseline (pass-through)" ($turnTerraManual.applied_model -eq 'Terra')
    Assert-Test "effort_only updates effort for manual Terra" ($turnTerraManual.applied_effort -eq 'high')

    # ------------------------------------------------------------------------
    # SECTION 16: Criteria Mapping & Confidence in TypeSafe Choice
    # ------------------------------------------------------------------------
    Write-Host "`nSection 16: Criteria Mapping & Confidence in TypeSafe Choice" -ForegroundColor Yellow

    $script:capturedCriteria = $null
    $mockCriteriaTransport = {
        param($req)
        # Verify criteria map in request body
        $body = $req.BodyObject
        $script:capturedCriteria = $body.questions.q_route.criteria

        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{
                    type          = 'choice'
                    choice        = 'Sol'
                    confidence    = 0.92
                    probabilities = [pscustomobject]@{
                        Luna  = 0.05
                        Sol   = 0.92
                        Astra = 0.03
                    }
                }
            }
        }
    }

    $critProj = New-DevRouterContextProjection `
        -Objective 'Refactor database migration scripts' `
        -Surface 'alignment' `
        -CurrentModel 'Luna' `
        -CurrentEffort 'medium' `
        -Target 'model_only'

    $choiceWithCriteria = Invoke-DevRouterJevChoice `
        -Projection $critProj `
        -Target 'model_only' `
        -BaselineModel 'Luna' `
        -BaselineEffort 'medium' `
        -ApiKey 'test_key' `
        -HttpTransportMock $mockCriteriaTransport

    Assert-Test "Request body contains criteria map (not array options)" ($null -ne $script:capturedCriteria)
    Assert-Test "Criteria map includes Sol entry" ($null -ne $script:capturedCriteria.Sol -or $null -ne $script:capturedCriteria['Sol'])
    Assert-Test "Jev choice parses real confidence (0.92)" ($choiceWithCriteria.confidence -eq 0.92)
    Assert-Test "Jev choice preserves probabilities object" ($null -ne $choiceWithCriteria.probabilities)

    # ------------------------------------------------------------------------
    # SECTION 17: Lock Invalidation on State Changes
    # ------------------------------------------------------------------------
    Write-Host "`nSection 17: Lock Invalidation on State Changes" -ForegroundColor Yellow

    Clear-AllDevRouterLocks -CodexHome $testCodexHome
    $null = Set-DevRouterState -Mode 'on' -Target 'effort_only' -CodexHome $testCodexHome

    # Acquire lock with effort_only
    $lockObj = Acquire-DevRouterLock `
        -ConversationId 'conv-lock-inval' `
        -Scope 'turn' `
        -TurnId 'turn-1' `
        -Model 'Sol' `
        -Effort 'high' `
        -Mode 'on' `
        -Target 'effort_only' `
        -CodexHome $testCodexHome

    Assert-Test "Initial lock acquired" ($null -ne (Get-DevRouterLock -ConversationId 'conv-lock-inval' -CodexHome $testCodexHome))

    # Switch target from effort_only to model_only
    $null = Set-DevRouterState -Mode 'on' -Target 'model_only' -CodexHome $testCodexHome

    # Next turn evaluation should detect target mismatch and invalidate the lock
    $script:invalCalled = $false
    $mockInvalTransport = {
        param($req)
        $script:invalCalled = $true
        return [pscustomobject]@{
            answers = [pscustomobject]@{
                q_route = [pscustomobject]@{ choice = 'Luna' }
            }
        }
    }

    $turnInval = Invoke-DevRouterTurn `
        -ConversationId 'conv-lock-inval' `
        -TurnId 'turn-1' `
        -Objective 'New work under model_only' `
        -Surface 'alignment' `
        -BaselineModel 'Sol' `
        -BaselineEffort 'medium' `
        -CodexHome $testCodexHome `
        -HttpTransportMock $mockInvalTransport `
        -AdapterSurface 'cli_harness'

    Assert-Test "Lock invalidated when target changed (Jev called fresh)" ($script:invalCalled -eq $true)
    Assert-Test "Applied model reflects new route Luna" ($turnInval.applied_model -eq 'Luna')

    # ------------------------------------------------------------------------
    # SECTION 18: Concurrency & Synchronization
    # ------------------------------------------------------------------------
    Write-Host "`nSection 18: Concurrency & Synchronization" -ForegroundColor Yellow

    $mutexRun = Invoke-DevRouterSynchronized -LockName 'TestLock' -ScriptBlock {
        return "synchronized_result"
    }
    Assert-Test "Invoke-DevRouterSynchronized returns script block result" ($mutexRun -eq 'synchronized_result')

    # ------------------------------------------------------------------------
    # SECTION 19: Composite Model Catalog Generation (GPT-Adaptive)
    # ------------------------------------------------------------------------
    Write-Host "`nSection 19: Composite Model Catalog Generation" -ForegroundColor Yellow

    $catalogPath = Export-DevRouterModelCatalog -CodexHome $testCodexHome
    Assert-Test "Model catalog file created" (Test-Path -LiteralPath $catalogPath -PathType Leaf)

    # Codex >= 0.145 requires UTF-8 without BOM; a BOM breaks configuration load.
    $catalogBytes = [IO.File]::ReadAllBytes($catalogPath)
    $hasBom = ($catalogBytes.Length -ge 3 -and $catalogBytes[0] -eq 0xEF -and $catalogBytes[1] -eq 0xBB -and $catalogBytes[2] -eq 0xBF)
    Assert-Test "Catalog is written without a UTF-8 BOM" (-not $hasBom)

    # Codex expects a SEQUENCE OF SEQUENCES of ModelInfo, not a flat array.
    $catalogRaw = [IO.File]::ReadAllText($catalogPath)
    $trimmedCatalog = $catalogRaw.TrimStart()
    $firstChar = $trimmedCatalog[0]
    $secondNonWhitespace = ''
    for ($i = 1; $i -lt $trimmedCatalog.Length; $i++) {
        if (-not [char]::IsWhiteSpace($trimmedCatalog[$i])) { $secondNonWhitespace = $trimmedCatalog[$i]; break }
    }
    Assert-Test "Catalog root is a JSON array" ($firstChar -eq '[')
    Assert-Test "Catalog root is a nested model group (Vec<Vec<ModelInfo>>)" ($secondNonWhitespace -eq '[')

    $shape = Test-DevRouterModelCatalogShape -Path $catalogPath
    Assert-Test "Catalog passes strict structural validation" ($shape.valid -eq $true)

    $catJson = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $catEntries = if ($catJson -is [System.Collections.IEnumerable]) { $catJson } else { @($catJson) }

    $foundAdaptive = $null
    $foundSol = $null
    $foundAstra = $null
    foreach ($entry in $catEntries) {
        if ($entry.slug -eq 'gpt-adaptive') { $foundAdaptive = $entry }
        if ($entry.slug -eq 'gpt-5.6-sol') { $foundSol = $entry }
        if ($entry.slug -eq 'gpt-6-astra') { $foundAstra = $entry }
    }

    Assert-Test "Catalog contains gpt-adaptive entry" ($null -ne $foundAdaptive)
    Assert-Test "GPT-Adaptive has exact display_name 'GPT-Adaptive'" ($foundAdaptive.display_name -eq 'GPT-Adaptive')
    Assert-Test "GPT-Adaptive has model_provider_id 'dev-router'" ($foundAdaptive.model_provider_id -eq 'dev-router')
    Assert-Test "Catalog preserves official model Sol" ($null -ne $foundSol)
    Assert-Test "Catalog preserves official model Astra" ($null -ne $foundAstra)

    # Every entry must carry the fields Codex 0.145+ rejects configuration without.
    $requiredCatalogFields = @('slug', 'display_name', 'supported_reasoning_levels', 'shell_type', 'visibility', 'supported_in_api', 'priority', 'base_instructions', 'support_verbosity', 'truncation_policy', 'supports_parallel_tool_calls', 'experimental_supported_tools')
    $missingFieldCount = 0
    $legacyKeyCount = 0
    foreach ($entry in $catEntries) {
        $entryProps = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($field in $requiredCatalogFields) {
            if ($entryProps -notcontains $field) { $missingFieldCount++ }
        }
        if ($entryProps -contains 'id' -or $entryProps -contains 'supported_reasoning_efforts' -or $entryProps -contains 'default_reasoning_effort') { $legacyKeyCount++ }
    }
    Assert-Test "No entry is missing a field required by Codex 0.145+ (missing=$missingFieldCount)" ($missingFieldCount -eq 0)
    Assert-Test "No entry uses the rejected legacy catalog keys (legacy=$legacyKeyCount)" ($legacyKeyCount -eq 0)
    Assert-Test "experimental_supported_tools is an empty array, never null" ($null -ne $foundAdaptive.experimental_supported_tools -and @($foundAdaptive.experimental_supported_tools).Count -eq 0)

    # ------------------------------------------------------------------------
    # SECTION 20: Real Proxy Lifecycle & Integration
    # ------------------------------------------------------------------------
    Write-Host "`nSection 20: Real Proxy Lifecycle & Integration" -ForegroundColor Yellow

    $regResult = Register-DevRouterCodexIntegration -CodexHome $testCodexHome -Port 4049
    Assert-Test "Register integration returns catalog path" ($null -ne $regResult.CatalogPath)
    Assert-Test "config.toml registers model_catalog_json" (Test-DevRouterCatalogRegistered -CodexHome $testCodexHome)

    # Start proxy on port 4049
    $proxyStatus = Start-DevRouterProxy -CodexHome $testCodexHome -Port 4049
    Assert-Test "Proxy started and responds to health check" ($proxyStatus.Running -eq $true)

    # Status reflects integrated
    $statusIntegrated = Get-DevRouterStatus -CodexHome $testCodexHome
    Assert-Test "Dev Router status reports integrated when proxy and catalog are active" ($statusIntegrated.integration_status -eq 'integrated')

    # Stop proxy
    $stopped = Stop-DevRouterProxy -CodexHome $testCodexHome -Port 4049
    Assert-Test "Proxy stopped successfully" ($stopped -eq $true)

    # Verify health check fails when stopped
    Start-Sleep -Milliseconds 300
    $proxyStoppedStatus = Get-DevRouterProxyStatus -CodexHome $testCodexHome -Port 4049 -TimeoutMs 250
    Assert-Test "Proxy status reports Running = false after stop" ($proxyStoppedStatus.Running -eq $false)

    # Unregister integration
    $unreg = Unregister-DevRouterCodexIntegration -CodexHome $testCodexHome
    Assert-Test "Unregister integration succeeds" ($unreg -eq $true)
    Assert-Test "Catalog registration removed from config.toml" (-not (Test-DevRouterCatalogRegistered -CodexHome $testCodexHome))

    # ------------------------------------------------------------------------
    # SECTION 21: End-to-End Proxy Responses Interception & Upstream Streaming
    # ------------------------------------------------------------------------
    Write-Host "`nSection 21: End-to-End Proxy Responses Interception & Streaming" -ForegroundColor Yellow

    $mockUpstreamPort = 4055
    $testProxyPort = 4056

    # Determinism + quota safety: with a live TYPESAFE_API_KEY present and the
    # state left in `on`, the proxy would call the real TypeSafe/Jev service from
    # this end-to-end test and the asserted model would depend on a live answer.
    # Pin the state to `off` and blank the key so the run is byte-deterministic
    # and consumes no provider quota.
    $null = Set-DevRouterState -Mode 'off' -Target 'effort_only' -CodexHome $testCodexHome
    $origZdrKey = $env:TYPESAFE_API_KEY
    $env:TYPESAFE_API_KEY = ''
    $mockUpstreamScript = @"
import http from 'node:http';
import fs from 'node:fs';

const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
        const received = {
            method: req.method,
            url: req.url,
            headers: req.headers,
            body: JSON.parse(body)
        };
        fs.writeFileSync(process.argv[2], JSON.stringify(received, null, 2), 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/event-stream' });
        res.write('event: response.completed\ndata: {\"id\":\"resp_test_123\",\"status\":\"completed\"}\n\n');
        res.end();
    });
});
server.listen($mockUpstreamPort, '127.0.0.1', () => {});
"@

    $upstreamFile = Join-Path $tempTestDir 'mock-upstream.mjs'
    $capturedReqFile = Join-Path $tempTestDir 'captured-upstream-req.json'
    [IO.File]::WriteAllText($upstreamFile, $mockUpstreamScript, [System.Text.Encoding]::UTF8)

    $upstreamPInfo = New-Object System.Diagnostics.ProcessStartInfo
    $upstreamPInfo.FileName = 'node'
    $upstreamPInfo.Arguments = "`"$upstreamFile`" `"$capturedReqFile`""
    $upstreamPInfo.UseShellExecute = $false
    $upstreamPInfo.CreateNoWindow = $true
    $upstreamPInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $upstreamProc = [System.Diagnostics.Process]::Start($upstreamPInfo)

    # Start dev-router-proxy with upstream set to mockUpstreamPort
    $env:DEV_ROUTER_UPSTREAM = "http://127.0.0.1:$mockUpstreamPort"
    $proxyPInfo = New-Object System.Diagnostics.ProcessStartInfo
    $proxyPInfo.FileName = 'node'
    $proxyScript = Join-Path $repoRoot 'scripts\dev-router-proxy.mjs'
    $proxyPInfo.Arguments = "`"$proxyScript`" --port $testProxyPort --upstream http://127.0.0.1:$mockUpstreamPort --codex-home `"$testCodexHome`""
    $proxyPInfo.UseShellExecute = $false
    $proxyPInfo.CreateNoWindow = $true
    $proxyPInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $proxyProc = [System.Diagnostics.Process]::Start($proxyPInfo)

    # Wait for proxy to listen
    Start-Sleep -Milliseconds 600

    try {
        # Send POST /v1/responses with model: gpt-adaptive
        $clientReqBody = [ordered]@{
            model = 'gpt-adaptive'
            input = @(
                [ordered]@{
                    role = 'user'
                    content = @(
                        [ordered]@{
                            type = 'input_text'
                            text = 'Fix a minor typo in markdown'
                        }
                    )
                }
            )
            reasoning = [ordered]@{
                effort = 'low'
            }
        } | ConvertTo-Json -Depth 5

        $clientHeaders = @{
            'Authorization' = 'Bearer eyJhbGciOiJSUzI1Ni...mockToken'
            'Content-Type'  = 'application/json'
        }

        $res = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$testProxyPort/v1/responses" `
            -Method Post `
            -Headers $clientHeaders `
            -Body $clientReqBody `
            -TimeoutSec 5

        Assert-Test "Proxy responses request returns successfully" ($null -ne $res)
        Assert-Test "Upstream captured request file created" (Test-Path -LiteralPath $capturedReqFile -PathType Leaf)

        if (Test-Path -LiteralPath $capturedReqFile -PathType Leaf) {
            $captured = Get-Content -LiteralPath $capturedReqFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-Test "Upstream received rewritten model (not gpt-adaptive)" ($captured.body.model -ne 'gpt-adaptive')
            Assert-Test "Upstream received concrete model (Sol/gpt-5.6-sol)" ($captured.body.model -match 'sol')
            Assert-Test "Upstream received requested effort low" ($captured.body.reasoning.effort -eq 'low')
            Assert-Test "Upstream received forwarded Authorization header" ($captured.headers.authorization -like '*mockToken*')
        }
        Assert-Test "End-to-end run consumed no live Jev quota (TYPESAFE_API_KEY blanked)" ([string]::IsNullOrEmpty($env:TYPESAFE_API_KEY))
    }
    finally {
        $env:TYPESAFE_API_KEY = $origZdrKey
        Remove-Item env:DEV_ROUTER_UPSTREAM -ErrorAction SilentlyContinue
        if ($null -ne $proxyProc -and -not $proxyProc.HasExited) {
            $proxyProc.Kill()
            [void]$proxyProc.WaitForExit(1000)
        }
        if ($null -ne $upstreamProc -and -not $upstreamProc.HasExited) {
            $upstreamProc.Kill()
            [void]$upstreamProc.WaitForExit(1000)
        }
    }
}
finally {
    # Ensure any test proxy is stopped
    [void](Stop-DevRouterProxy -CodexHome $testCodexHome -Port 4049 -ErrorAction SilentlyContinue)
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
