# scripts/tests/swarm-doctor-contract.Tests.ps1
# Dedicated tests for Doctor installed contract predicate, AST fixture, and obsolete route discrimination

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))

$script:TestCount = 0
$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Test {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$false)][string]$Details = ''
    )
    $script:TestCount++
    if ($Condition) {
        $script:PassedCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailedCount++
        $msg = if ($Details) { "$Name -> $Details" } else { $Name }
        $script:Failures.Add($msg)
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
    }
}

Write-Host "Running Doctor Installed Contract & Swarm Delegation Tests..." -ForegroundColor Cyan

# ---------------------------------------------------------
# 1. AST Fixture & Production Function Extraction
# ---------------------------------------------------------
Write-Host "`n-- 1. AST Fixture & Production Function Extraction --" -ForegroundColor Yellow

$doctorPath = Join-Path $repoRoot 'scripts\doctor.ps1'
Assert-Test "scripts/doctor.ps1 exists" (Test-Path -LiteralPath $doctorPath -PathType Leaf)

$parseErrors = $null
$parseTokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($doctorPath, [ref]$parseTokens, [ref]$parseErrors)
Assert-Test "scripts/doctor.ps1 parsed without AST errors" ($parseErrors.Count -eq 0)

# Verify production functions exist in AST
$fnGetPatterns = $ast.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-InstalledContractPatterns' }, $true)
Assert-Test "AST fixture: Get-InstalledContractPatterns is declared" ($null -ne $fnGetPatterns)

$fnTestContract = $ast.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-InstalledContractText' }, $true)
Assert-Test "AST fixture: Test-InstalledContractText is declared" ($null -ne $fnTestContract)

$fnTestMarker = $ast.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-LegacyContractMarker' }, $true)
Assert-Test "AST fixture: Test-LegacyContractMarker is declared" ($null -ne $fnTestMarker)

# Dot-source doctor to load functions into scope
. $doctorPath

Assert-Test "Runtime: Get-InstalledContractPatterns command is available" ($null -ne (Get-Command 'Get-InstalledContractPatterns' -ErrorAction SilentlyContinue))
Assert-Test "Runtime: Test-InstalledContractText command is available" ($null -ne (Get-Command 'Test-InstalledContractText' -ErrorAction SilentlyContinue))
Assert-Test "Runtime: Test-LegacyContractMarker command is available" ($null -ne (Get-Command 'Test-LegacyContractMarker' -ErrorAction SilentlyContinue))

# ---------------------------------------------------------
# 2. RED Baseline: Legacy Blanket 'read-only' Rejection
# ---------------------------------------------------------
Write-Host "`n-- 2. RED Baseline: Legacy Blanket Rejection Demonstration --" -ForegroundColor Yellow

$legitSafePrefixProse = 'O prefixo seguro deve distinguir explicitamente preparação somente leitura (*read-only preparation*) de edições dependentes e asserções de teste (*dependent edits / test assertions*), preservando rigorosamente os gates de modo'
$legacyBlanketPattern = 'read-only'

$blanketHit = [regex]::IsMatch($legitSafePrefixProse, $legacyBlanketPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
Assert-Test "RED baseline: Legacy blanket pattern incorrectly rejected legitimate safe prefix prose" $blanketHit

# ---------------------------------------------------------
# 3. GREEN Production Predicate: Legitimate Safety Prose Passes
# ---------------------------------------------------------
Write-Host "`n-- 3. GREEN Production Predicate: Legitimate Safety Prose Passes --" -ForegroundColor Yellow

Assert-Test "Positive: Safe prefix read-only preparation prose passes contract" (Test-InstalledContractText -Text $legitSafePrefixProse)
Assert-Test "Positive: Test-LegacyContractMarker returns false for safe prefix prose" (-not (Test-LegacyContractMarker -Text $legitSafePrefixProse))

# Test with actual delegation.md installed content
$delegationInstalled = Join-Path $env:USERPROFILE '.agents\skills\workflows\references\delegation.md'
if (Test-Path -LiteralPath $delegationInstalled -PathType Leaf) {
    $delegationContent = Get-Content -LiteralPath $delegationInstalled -Raw -Encoding UTF8
    Assert-Test "Positive: Installed delegation.md passes contract predicate" (Test-InstalledContractText -Text $delegationContent -Surface $delegationInstalled)
}

# Test legitimate safety prose from other skills / components
$legitSamples = @(
    'The doctor is read-only: it inspects installed surfaces, MCP registrations, scheduled tasks, and the Startup shortcut without modifying configuration.',
    'Strictly forbidden in read-only modes and ALINHAMENTO: no auto-index, no background watchers, no index_repository.',
    'In read-only modes and ALINHAMENTO, enforce no-onboarding and no-memories.',
    'Inspect existing daemon events and conflicts without modifying state: Read-Only Diagnostics',
    'Inspect index status using read-only query: pwsh -Command Write-Output Testing read-only preflight',
    'Confirm configuration and project state read-only (confirmação read-only de configuração/projeto) before invocation.',
    'Operating policy for the daemon. Maintenance across other MCP servers remains read-only.'
)

foreach ($sample in $legitSamples) {
    Assert-Test "Positive: Legitimate safety prose passes -> $($sample.Substring(0, [Math]::Min(55, $sample.Length)))..." (Test-InstalledContractText -Text $sample)
}

# ---------------------------------------------------------
# 4. Negative Tests: Explicit Removed Route Surfaces Rejected
# ---------------------------------------------------------
Write-Host "`n-- 4. Negative Tests: Explicit Removed Route Surfaces Rejected --" -ForegroundColor Yellow

$explicitRemovedSurfaces = @(
    @{ Name = 'subagents = (with spaces)'; Content = 'subagents = 5' },
    @{ Name = 'subagents= (no spaces)'; Content = 'subagents=5' },
    @{ Name = 'sidecar route keyword'; Content = 'When the OpenCode sidecar route is active' },
    @{ Name = 'PromptPadNative marker'; Content = 'PromptPadNative = true' },
    @{ Name = 'BackendOverrideText marker'; Content = 'BackendOverrideText = "custom"' }
)

foreach ($item in $explicitRemovedSurfaces) {
    $passed = Test-InstalledContractText -Text $item.Content
    $markerDetected = Test-LegacyContractMarker -Text $item.Content
    Assert-Test "Negative: Explicit removed surface rejected ($($item.Name))" (-not $passed -and $markerDetected)
}

# ---------------------------------------------------------
# 5. Negative Tests: Obsolete Read-Only Route Contracts Rejected
# ---------------------------------------------------------
Write-Host "`n-- 5. Negative Tests: Obsolete Read-Only Route Contracts Rejected --" -ForegroundColor Yellow

$obsoleteReadOnlyContracts = @(
    @{ Name = 'read-only reader'; Content = 'One or more read-only readers are required' },
    @{ Name = 'read-only scout'; Content = 'use the quality-first-subA read-only scout fan-out' },
    @{ Name = 'read-only researcher'; Content = 'fan out one read-only researcher per independent front' },
    @{ Name = 'read-only reviewer'; Content = 'use one fresh read-only reviewer on the correction delta' },
    @{ Name = 'read-only worker'; Content = 'delegated read-only worker' },
    @{ Name = 'read-only watcher'; Content = 'each through its own read-only watcher' },
    @{ Name = 'read-only relay'; Content = 'launch read-only relay subagent' },
    @{ Name = 'read-only opencode'; Content = 'a read-only OpenCode reviewer is required' },
    @{ Name = 'read-only subagent'; Content = 'delegate to a read-only subagent' },
    @{ Name = 'read-only subagents'; Content = 'route read-only subagents through OpenCode relay' },
    @{ Name = 'read-only suba'; Content = 'quality-first read-only suba' },
    @{ Name = 'read-only task'; Content = 'must launch one read-only task per front' },
    @{ Name = 'read-only nested task'; Content = 'delegate one read-only nested task per front' },
    @{ Name = 'read-only checkpoint'; Content = 'allow only a targeted read-only checkpoint' },
    @{ Name = 'read-only profile'; Content = 'native gpt-5.6-luna read-only profiles' },
    @{ Name = 'read-only role'; Content = 'Read-only roles must not edit or run shell' },
    @{ Name = 'read-only gate'; Content = 'any required read-only gate stays blocked' },
    @{ Name = 'read-only dispatch'; Content = 'read-only dispatch to subagent' },
    @{ Name = 'read-only lane'; Content = 'assign read-only lane' },
    @{ Name = 'read-only work'; Content = 'Read-only work must use the exact custom role' },
    @{ Name = 'sandbox_mode = "read-only"'; Content = 'sandbox_mode = "read-only"' },
    @{ Name = 'sandbox_mode = ''read-only'''; Content = "sandbox_mode = 'read-only'" },
    @{ Name = 'sandbox = "read-only"'; Content = 'sandbox = "read-only"' },
    @{ Name = 'mode = "read-only"'; Content = 'mode = "read-only"' },
    @{ Name = 'readers are read-only'; Content = 'OpenCode readers are read-only.' },
    @{ Name = 'reader is read-only'; Content = 'Reader OpenCode é read-only.' },
    @{ Name = 'roles are read-only'; Content = 'Reader and reviewer roles are read-only (edit: deny).' },
    @{ Name = 'watcher.toml is read-only'; Content = 'native watcher.toml is read-only' },
    @{ Name = 'read-only diagnosis'; Content = 'VERIFY -> read-only diagnosis -> W3 writer' },
    @{ Name = 'diagnostico read-only'; Content = 'GPT diagnóstico read-only -> W3 writer novo' },
    @{ Name = 'legacy mode matrix read-only'; Content = "| `PLAN.AUTO` | read | read-only | route proven |" }
)

foreach ($item in $obsoleteReadOnlyContracts) {
    $passed = Test-InstalledContractText -Text $item.Content
    $markerDetected = Test-LegacyContractMarker -Text $item.Content
    Assert-Test "Negative: Obsolete route contract rejected ($($item.Name))" (-not $passed -and $markerDetected)
}

# ---------------------------------------------------------
# 6. End-to-End Doctor Execution Verification
# ---------------------------------------------------------
Write-Host "`n-- 6. End-to-End Doctor Execution Verification --" -ForegroundColor Yellow

$doctorRun = & powershell -NoProfile -NonInteractive -File $doctorPath 2>&1
$doctorExit = $LASTEXITCODE
$doctorOutput = $doctorRun -join "`n"

Assert-Test "Doctor executes with exit code 0" ($doctorExit -eq 0)
Assert-Test "Doctor reports Installed contract OK" ($doctorOutput -match '(?m)\[OK\]\s+Installed contract: No legacy contract markers')
Assert-Test "Doctor does not report any legacy contract failure" ($doctorOutput -notmatch '(?m)\[FAIL\]\s+Installed contract:')
Assert-Test "Doctor reports Doctor OK" ($doctorOutput -match 'Doctor OK\.')

# Summary
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor Cyan

if ($script:Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
}
else {
    Write-Host "All swarm doctor contract tests passed successfully!" -ForegroundColor Green
    exit 0
}
