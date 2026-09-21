[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Switch')]
    [ValidateSet('off', 'shadow', 'on')]
    [string]$Mode,

    [Parameter(ParameterSetName = 'Switch')]
    [ValidateSet('effort_only', 'model_only', 'model_and_effort')]
    [string]$Target,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'ProxyAction')]
    [switch]$StartProxy,

    [Parameter(ParameterSetName = 'ProxyAction')]
    [switch]$StopProxy,

    [Parameter(ParameterSetName = 'IntegrationAction')]
    [switch]$RegisterIntegration,

    [Parameter(ParameterSetName = 'IntegrationAction')]
    [switch]$UnregisterIntegration,

    [string]$CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
Import-Module (Join-Path $repo 'scripts\dev-router.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $repo 'scripts\backend-routing.psm1') -DisableNameChecking -Force

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$requestedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) { $defaultCodexHome } else { $CodexHome }
$CodexHome = [IO.Path]::GetFullPath($requestedCodexHome)
$root = [IO.Path]::GetPathRoot($CodexHome)
if ($CodexHome.TrimEnd('\') -eq $root.TrimEnd('\')) {
    throw "Refusing to use a filesystem root as a Codex home: $CodexHome"
}

# Handle explicit Integration Actions
if ($RegisterIntegration) {
    Write-Host "Registering GPT-Adaptive integration in Codex config.toml..." -ForegroundColor Cyan
    [void](Export-DevRouterModelCatalog -CodexHome $CodexHome)
    $reg = Register-DevRouterCodexIntegration -CodexHome $CodexHome
    Write-Host "Registered model catalog: $($reg.CatalogPath)" -ForegroundColor Green
    $currentStatus = Get-DevRouterStatus -CodexHome $CodexHome
    return [pscustomobject]$currentStatus
}

if ($UnregisterIntegration) {
    Write-Host "Unregistering GPT-Adaptive integration from Codex config.toml..." -ForegroundColor Cyan
    [void](Unregister-DevRouterCodexIntegration -CodexHome $CodexHome)
    Write-Host "GPT-Adaptive integration unregistered." -ForegroundColor Green
    $currentStatus = Get-DevRouterStatus -CodexHome $CodexHome
    return [pscustomobject]$currentStatus
}

# Handle explicit Proxy Actions
if ($StartProxy) {
    if (-not (Test-DevRouterCatalogRegistered -CodexHome $CodexHome)) {
        [void](Export-DevRouterModelCatalog -CodexHome $CodexHome)
        [void](Register-DevRouterCodexIntegration -CodexHome $CodexHome)
    }
    Write-Host "Starting Dev Router loopback proxy..." -ForegroundColor Cyan
    $pStatus = Start-DevRouterProxy -CodexHome $CodexHome
    if ($pStatus.Running) {
        Write-Host "Dev Router proxy running on http://127.0.0.1:$($pStatus.Port)" -ForegroundColor Green
    }
    else {
        Write-Host "Warning: Dev Router proxy failed to start." -ForegroundColor Yellow
    }
    $currentStatus = Get-DevRouterStatus -CodexHome $CodexHome
    return [pscustomobject]$currentStatus
}

if ($StopProxy) {
    Write-Host "Stopping Dev Router loopback proxy..." -ForegroundColor Cyan
    [void](Stop-DevRouterProxy -CodexHome $CodexHome)
    Write-Host "Dev Router proxy stopped." -ForegroundColor Green
    $currentStatus = Get-DevRouterStatus -CodexHome $CodexHome
    return [pscustomobject]$currentStatus
}

# If no switch parameters provided, treat as -Status
if ($PSCmdlet.ParameterSetName -eq 'Status' -or ([string]::IsNullOrWhiteSpace($Mode) -and [string]::IsNullOrWhiteSpace($Target))) {
    $currentStatus = Get-DevRouterStatus -CodexHome $CodexHome

    Write-Host "=== Dev Router Status ===" -ForegroundColor Cyan
    Write-Host "Configured Mode:     $($currentStatus.configured_mode)"
    Write-Host "Effective Mode:      $($currentStatus.effective_mode)"
    Write-Host "Target:              $($currentStatus.target)"
    Write-Host "Integration Status:  $($currentStatus.integration_status)"
    Write-Host "Baseline Model:      $($currentStatus.baseline_model)"
    Write-Host "Baseline Effort:     $($currentStatus.baseline_effort)"
    Write-Host "Effective Model:     $($currentStatus.effective_model)"
    Write-Host "Effective Effort:    $($currentStatus.effective_effort)"
    Write-Host "Pending Change:      $($currentStatus.pending_change)"
    Write-Host "Route Lock Scope:    $($currentStatus.route_lock_scope)"
    Write-Host "Scope:               parent orchestrator in alignment and workflow"
    Write-Host ""
    Write-Host "Notes: $($currentStatus.integration_notes)" -ForegroundColor Gray

    return [pscustomobject]$currentStatus
}

# Reading current state
$currentState = Get-DevRouterState -CodexHome $CodexHome

$nextMode = if (-not [string]::IsNullOrWhiteSpace($Mode)) { $Mode } else { [string]$currentState.mode }
$nextTarget = if (-not [string]::IsNullOrWhiteSpace($Target)) { $Target } else { [string]$currentState.target }

$modeChanged = ($nextMode -ne [string]$currentState.mode)
$targetChanged = ($nextTarget -ne [string]$currentState.target)

if (-not $modeChanged -and -not $targetChanged) {
    Write-Host "Dev Router already set to Mode '$nextMode' and Target '$nextTarget'. No changes made." -ForegroundColor Yellow
    $currentStatus = Get-DevRouterStatus -CodexHome $CodexHome
    return [pscustomobject]$currentStatus
}

# If switching to OFF, also release any existing locks
if ($nextMode -eq 'off') {
    Clear-AllDevRouterLocks -CodexHome $CodexHome
}

$newState = Set-DevRouterState -Mode $nextMode -Target $nextTarget -CodexHome $CodexHome

# When enabling shadow or on, ensure proxy is started if integration is configured
if ($nextMode -in @('shadow', 'on') -and (Test-DevRouterCatalogRegistered -CodexHome $CodexHome)) {
    try {
        [void](Start-DevRouterProxy -CodexHome $CodexHome)
    }
    catch {
        Write-Warning "Could not start Dev Router proxy: $($_.Exception.Message)"
    }
}

Write-Host "Dev Router updated successfully:" -ForegroundColor Green
Write-Host "  Mode:   $nextMode"
Write-Host "  Target: $nextTarget"
Write-Host "Scope: parent orchestrator in new turns and sessions."
Write-Host "Config file: $(Join-Path $CodexHome 'codex-workflows-kit\dev-router-state.json')"

$updatedStatus = Get-DevRouterStatus -CodexHome $CodexHome
return [pscustomobject]$updatedStatus
