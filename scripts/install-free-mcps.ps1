# scripts/install-free-mcps.ps1
# CLI entrypoint for free MCPs installer: codebase-memory-mcp v0.10.8 and Context7
# Pinned version, SHA256 verified, safe zip expansion, delimited rollback, zero billing credentials

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Inspect', 'Install', 'Rollback')]
    [string]$Mode = 'Inspect',

    [Parameter(Mandatory=$false)]
    [string]$CodexHome = '',

    [Parameter(Mandatory=$false)]
    [string]$AntigravityHome = '',

    [Parameter(Mandatory=$false)]
    [string]$InstallRoot = '',

    [Parameter(Mandatory=$false)]
    [string]$StateRoot = '',

    [Parameter(Mandatory=$false)]
    [string]$OfflineArchive = '',

    [Parameter(Mandatory=$false)]
    [string]$ManifestPath = '',

    [Parameter(Mandatory=$false)]
    [switch]$SkipBinaryDownload,

    [Parameter(Mandatory=$false)]
    [string]$ExpectedBinarySha = '',

    [Parameter(Mandatory=$false)]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $scriptDir 'free-mcps.psm1'

if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    Write-Error "Required module not found: $modulePath"
    exit 1
}

Import-Module -Name $modulePath -Force

try {
    switch ($Mode) {
        'Inspect' {
            $result = Invoke-FreeMcpsInspectWorkflow `
                -CodexHome $CodexHome `
                -AntigravityHome $AntigravityHome `
                -InstallRoot $InstallRoot `
                -StateRoot $StateRoot

            if ($Json) {
                $result | ConvertTo-Json -Depth 10
            } else {
                Write-Host "Free MCPs Status (ReadOnly Inspect):" -ForegroundColor Cyan
                Write-Host "  CBM Pinned Version  : $($result.CbmPinnedVersion) ($($result.CbmArchitecture))"
                Write-Host "  CBM Expected Hash   : $($result.CbmExpectedSha)"
                Write-Host "  CBM Binary Path     : $($result.CbmBinaryPath)"
                Write-Host "  CBM Binary Present  : $($result.CbmBinaryPresent)"
                Write-Host "  Context7 Endpoint   : $($result.Context7Endpoint) (Billing: unproven anonymous intent; OAuth unknown; no caches checked)"
                Write-Host "  Codex Config TOML   : $($result.CodexTomlPath) (Present: $($result.CodexTomlPresent), Has CBM: $($result.CodexTomlHasCbm), Has Context7: $($result.CodexTomlHasCtx7))"
                Write-Host "  Gemini Config JSON  : $($result.GeminiJsonPath) (Present: $($result.GeminiJsonPresent), Has CBM: $($result.GeminiJsonHasCbm), Has Context7: $($result.GeminiJsonHasCtx7))"
                Write-Host "  State Root Config   : $($result.ConfiguredStateRoot)"
                Write-Host "  Configured Cache Dir: $($result.ConfiguredCacheDir)"
                Write-Host "  Configured Runtime  : $($result.ConfiguredRuntimeDir)"
                Write-Host "  Observed Codex Env  : Cache=$($result.CodexObservedCacheDir), Runtime=$($result.CodexObservedRuntimeDir)"
                Write-Host "  Observed Gemini Env : Cache=$($result.GeminiObservedCacheDir), Runtime=$($result.GeminiObservedRuntimeDir)"
                Write-Host "  Manifest Present    : $($result.ManifestPresent)"
                Write-Host "  Runtime Assessment  : $($result.RuntimeGuarantee)"
            }
        }

        'Install' {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedBinarySha)) {
                $cbmMeta = Get-CbmMetadata
                if ($ExpectedBinarySha.Trim().ToLowerInvariant() -ne $cbmMeta.BinarySha256.ToLowerInvariant()) {
                    if ($env:FREE_MCPS_TEST_ALLOW_SHA_OVERRIDE -ne '1') {
                        throw "Public CLI pin violation: ExpectedBinarySha override is restricted to internal tests and must match official pinned digest ($($cbmMeta.BinarySha256))."
                    }
                }
            }

            if (-not $Json) {
                Write-Host "Starting controlled installation of free MCPs (CBM v0.10.8 + Context7)..." -ForegroundColor Cyan
            }
            $res = Invoke-FreeMcpsInstallWorkflow `
                -CodexHome $CodexHome `
                -AntigravityHome $AntigravityHome `
                -InstallRoot $InstallRoot `
                -StateRoot $StateRoot `
                -OfflineArchive $OfflineArchive `
                -SkipBinaryDownload ([bool]$SkipBinaryDownload) `
                -ExpectedBinarySha $ExpectedBinarySha

            if ($Json) {
                $res | ConvertTo-Json -Depth 10
            } else {
                Write-Host "Installation completed successfully." -ForegroundColor Green
                Write-Host "  Status: $($res.Status)"
                Write-Host "  Manifest: $($res.ManifestPath)"
                Write-Host "Restart agent sessions to load updated MCP servers."
            }
        }

        'Rollback' {
            if (-not $Json) {
                Write-Host "Starting rollback of free MCPs..." -ForegroundColor Yellow
            }
            $res = Invoke-FreeMcpsRollbackWorkflow `
                -ManifestPath $ManifestPath `
                -InstallRoot $InstallRoot `
                -CodexHome $CodexHome `
                -AntigravityHome $AntigravityHome `
                -StateRoot $StateRoot

            if ($Json) {
                $res | ConvertTo-Json -Depth 10
            } else {
                Write-Host "Rollback completed successfully." -ForegroundColor Green
                Write-Host "  Processed manifest: $($res.ManifestPath)"
            }
        }
    }
} catch {
    Write-Error "Execution failed: $_"
    exit 1
}
