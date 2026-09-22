param(
    [Parameter(Mandatory)][string]$RequestJson,
    [ValidateSet('off','advisory','shadow')][string]$JevMode = 'advisory'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'adaptive-orchestration.psm1') -Force
$request = ConvertFrom-Json -InputObject $RequestJson
$decision = Get-AdaptiveOrchestrationDecision -Request $request -JevMode $JevMode
ConvertTo-Json -InputObject $decision -Depth 12
