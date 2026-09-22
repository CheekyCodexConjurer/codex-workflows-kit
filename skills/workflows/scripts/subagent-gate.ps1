[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('delegation', 'review')][string]$Gate,
    [Parameter(Mandatory)][string]$InputJson,
    [ValidateSet('off', 'shadow', 'on')][string]$Mode = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'subagent-gates.psm1') -Force

$inputData = ConvertFrom-Json -InputObject $InputJson -ErrorAction Stop
$result = if ($Gate -eq 'delegation') {
    Invoke-SubagentDelegationGate -InputData $inputData -Mode $Mode
}
else {
    Invoke-SubagentReviewGate -InputData $inputData -Mode $Mode
}
$result | ConvertTo-Json -Compress -Depth 5
exit 0
