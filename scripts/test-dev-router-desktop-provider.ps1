<#
.SYNOPSIS
Deterministic tests for the GPT-Adaptive Desktop PROVIDER activation.

Covers the original production bug: GPT-Adaptive was visible in the catalog but
`model_provider` still pointed at the default OpenAI/ChatGPT provider, so the
alias was sent to the backend and rejected with
"The 'gpt-adaptive' model is not supported when using Codex with a ChatGPT account."

These tests never contact a model. A local mock upstream and a local mock Jev are
used so the suite is byte-deterministic and consumes no quota.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'scripts\dev-router.psm1') -DisableNameChecking -Force

$script:TestCount = 0
$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = @()

function Assert-Test {
    param([string]$Label, [bool]$Condition, [string]$Detail = '')
    $script:TestCount++
    if ($Condition) {
        $script:PassedCount++
        Write-Host ("  [PASS] " + $Label) -ForegroundColor Green
    }
    else {
        $script:FailedCount++
        $detail = if ($Detail) { " -> $Detail" } else { '' }
        $script:Failures += ($Label + $detail)
        Write-Host ("  [FAIL] " + $Label + $detail) -ForegroundColor Red
    }
}

function Get-FreeTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

Write-Host "`nRunning Dev Router Desktop provider activation tests..." -ForegroundColor Cyan

$script:TempTestDir = Join-Path ([IO.Path]::GetTempPath()) ("dev-router-provider-test-" + [Guid]::NewGuid().ToString('N'))
$keepTemp = ($env:DEV_ROUTER_PROVIDER_TEST_KEEP -eq '1')
[void][IO.Directory]::CreateDirectory($script:TempTestDir)
$script:UpstreamPort = Get-FreeTcpPort
$script:JevPort = Get-FreeTcpPort
$script:UpstreamCapture = Join-Path $script:TempTestDir 'upstream.jsonl'

# Mock upstream that records what the proxy actually forwarded.
$mockScript = Join-Path $script:TempTestDir 'mock-upstream.mjs'
$mockSource = @'
import http from 'node:http';
import fs from 'node:fs';
const capture = process.argv[2];
const port = Number(process.argv[3]);
let count = 0;
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    count++;
    let parsed = null;
    try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch {}
    fs.appendFileSync(capture, JSON.stringify({ url: req.url, model: parsed?.model ?? null, effort: parsed?.reasoning?.effort ?? null, auth: Boolean(req.headers.authorization) }) + '\n', 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write('event: response.completed\n');
    res.write('data: {"response":{"id":"resp_' + count + '"}}\n\n');
    res.end();
  });
});
server.listen(port, '127.0.0.1');
'@
[IO.File]::WriteAllText($mockScript, $mockSource, (New-Object System.Text.UTF8Encoding($false)))

$origUpstream = $env:DEV_ROUTER_UPSTREAM
$origJevEndpoint = $env:DEV_ROUTER_JEV_ENDPOINT
$origJevTimeout = $env:DEV_ROUTER_JEV_TIMEOUT_MS
$origApiKey = $env:TYPESAFE_API_KEY

$mockProc = $null
$proxyProcs = New-Object System.Collections.Generic.List[object]

function Start-TestProxy {
    param([string]$CodexHome, [int]$Port)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command node).Source
    $psi.Arguments = '"' + (Join-Path $repoRoot 'scripts\dev-router-proxy.mjs') + '" --port ' + $Port + ' --upstream "http://127.0.0.1:' + $script:UpstreamPort + '/backend-api/codex" --codex-home "' + $CodexHome + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:proxyProcs.Add($proc) | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 200
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
            if ($r.status -eq 'ok') { return $proc }
        }
        catch {}
    }
    return $proc
}

function Invoke-ProxyModel {
    param([int]$Port, [hashtable]$Body, [switch]$WithAuth)
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/v1/responses")
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Timeout = 10000
    if ($WithAuth) {
        # Synthetic placeholder: the suite only ever asserts header PRESENCE.
        $req.Headers['Authorization'] = 'Bearer test-placeholder'
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8))
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    try {
        $res = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($res.GetResponseStream())
        $null = $reader.ReadToEnd()
        $reader.Close(); $res.Close()
        return [int]200
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return -1
    }
}

function Get-CapturedRequests {
    if (-not (Test-Path -LiteralPath $script:UpstreamCapture)) { return @() }
    return @(Get-Content -LiteralPath $script:UpstreamCapture | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

try {
    $env:TYPESAFE_API_KEY = ''

    # ------------------------------------------------------------------
    # ChatGPT upstream derivation (no model, no network)
    # ------------------------------------------------------------------
    Write-Host "`nSection 1: Upstream derivation for ChatGPT auth" -ForegroundColor Yellow
    $authHome = Join-Path $script:TempTestDir 'auth-home'
    [void][IO.Directory]::CreateDirectory($authHome)
    [IO.File]::WriteAllText((Join-Path $authHome 'config.toml'), "preferred_auth_method = `"chatgpt`"`nmodel_provider = `"openai`"`n", (New-Object System.Text.UTF8Encoding($false)))
    $up = Get-DevRouterUpstream -CodexHome $authHome
    Assert-Test "1a. ChatGPT auth resolves the ChatGPT Codex backend" ($up.Upstream -eq 'https://chatgpt.com/backend-api/codex') ("got=$($up.Upstream)")
    Assert-Test "1b. derivation reports its source" ($up.Source -eq 'auth-method:chatgpt') ("got=$($up.Source)")

    [IO.File]::WriteAllText((Join-Path $authHome 'config.toml'), "preferred_auth_method = `"apikey`"`n", (New-Object System.Text.UTF8Encoding($false)))
    $up = Get-DevRouterUpstream -CodexHome $authHome
    Assert-Test "1c. API-key auth resolves the public OpenAI API" ($up.Upstream -eq 'https://api.openai.com') ("got=$($up.Upstream)")

    [IO.File]::WriteAllText((Join-Path $authHome 'config.toml'), "chatgpt_base_url = `"https://example.invalid/custom`"`npreferred_auth_method = `"chatgpt`"`n", (New-Object System.Text.UTF8Encoding($false)))
    $up = Get-DevRouterUpstream -CodexHome $authHome
    Assert-Test "1d. explicit chatgpt_base_url wins over the built-in default" ($up.Upstream -eq 'https://example.invalid/custom') ("got=$($up.Upstream)")

    # ------------------------------------------------------------------
    # Regression: the ORIGINAL bug configuration must NOT report ready
    # ------------------------------------------------------------------
    Write-Host "`nSection 2: Original broken configuration detection" -ForegroundColor Yellow
    $brokenHome = Join-Path $script:TempTestDir 'broken-home'
    [void][IO.Directory]::CreateDirectory((Join-Path $brokenHome 'codex-workflows-kit'))
    $catalogPath = Join-Path $brokenHome 'codex-workflows-kit\model-catalog.json'
    $null = Export-DevRouterModelCatalog -CodexHome $brokenHome -OutputPath $catalogPath
    [IO.File]::WriteAllText((Join-Path $brokenHome 'config.toml'), @"
model = "gpt-adaptive"
model_provider = "openai"
model_catalog_json = "$($catalogPath -replace '\\','/')"

[model_providers.dev-router]
name = "Dev Router"
base_url = "http://127.0.0.1:4058/v1"
wire_api = "responses"
requires_openai_auth = true
"@, (New-Object System.Text.UTF8Encoding($false)))

    $readiness = Get-DevRouterIntegrationReadiness -CodexHome $brokenHome
    Assert-Test "2a. visible-in-catalog + default provider is NOT ready" ($readiness.integration_status -ne 'ready') ("got=$($readiness.integration_status)")
    Assert-Test "2b. the state is reported as catalog_only" ($readiness.integration_status -eq 'catalog_only') ("got=$($readiness.integration_status)")
    Assert-Test "2c. provider_registered is true but provider_selected is false" ($readiness.provider_registered -and -not $readiness.provider_selected)
    Assert-Test "2d. notes name the real cause" ($readiness.integration_notes -match 'NOT selected')

    $status = Get-DevRouterStatus -CodexHome $brokenHome
    Assert-Test "2e. Get-DevRouterStatus does not claim ready" ($status.integration_status -ne 'ready') ("got=$($status.integration_status)")
    Assert-Test "2f. Get-DevRouterStatus never says 'integration active' without proof" ($status.integration_notes -notmatch 'integration active')

    # ------------------------------------------------------------------
    # Register: proxy offline must fail closed with NO broken config
    # ------------------------------------------------------------------
    Write-Host "`nSection 3: Register fails closed when the proxy cannot start" -ForegroundColor Yellow
    $offlineHome = Join-Path $script:TempTestDir 'offline-home'
    [void][IO.Directory]::CreateDirectory($offlineHome)
    [IO.File]::WriteAllText((Join-Path $offlineHome 'config.toml'), "model = `"gpt-5.6-sol`"`nmodel_provider = `"openai`"`n", (New-Object System.Text.UTF8Encoding($false)))
    # Occupy the port so the proxy cannot bind.
    $squatter = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $squatter.Start()
    $squatPort = $squatter.LocalEndpoint.Port
    $registerFailed = $false
    try {
        $null = Register-DevRouterCodexIntegration -CodexHome $offlineHome -Port $squatPort -SkipCodexValidation
    }
    catch { $registerFailed = $true }
    $squatter.Stop()
    Assert-Test "3a. Register throws when the proxy is not healthy" ($registerFailed)
    $offlineTop = Get-CodexTopLevelConfig -CodexHome $offlineHome
    Assert-Test "3b. previous model_provider restored after rollback" ($offlineTop.ModelProvider -eq 'openai') ("got=$($offlineTop.ModelProvider)")
    Assert-Test "3c. model_catalog_json was not left pointing at a dead integration" ([string]::IsNullOrWhiteSpace($offlineTop.ModelCatalogJson)) ("got=$($offlineTop.ModelCatalogJson)")
    Assert-Test "3d. no dev-router provider block was left behind" (-not (Test-DevRouterProviderBlockDeclared -CodexHome $offlineHome))
    Assert-Test "3e. model was never rewritten" ($offlineTop.Model -eq 'gpt-5.6-sol') ("got=$($offlineTop.Model)")

    # ------------------------------------------------------------------
    # Register: happy path selects the provider
    # ------------------------------------------------------------------
    Write-Host "`nSection 4: Transactional register selects the provider" -ForegroundColor Yellow
    $liveHome = Join-Path $script:TempTestDir 'live-home'
    [void][IO.Directory]::CreateDirectory($liveHome)

    # Local mock upstream: records the forwarded model/effort/path and returns a
    # minimal streaming Responses payload. No real model is ever contacted.
    $mockProc = Start-Process -FilePath (Get-Command node).Source -ArgumentList @($mockScript, $script:UpstreamCapture, $script:UpstreamPort) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500

    [IO.File]::WriteAllText((Join-Path $liveHome 'config.toml'), @"
preferred_auth_method = "chatgpt"
model = "gpt-adaptive"
model_provider = "openai"
model_catalog_json = "C:/user/own-catalog.json"
model_reasoning_effort = "high"

[model_providers.user-custom]
name = "User Custom"
base_url = "https://example.invalid/v1"
wire_api = "responses"
"@, (New-Object System.Text.UTF8Encoding($false)))

    $reg = [ordered]@{}
    $livePort = Get-FreeTcpPort

    # Pure derivation check BEFORE any override is applied (no network).
    $derived = Get-DevRouterUpstream -CodexHome $liveHome
    Assert-Test "4d. derivation selects the ChatGPT backend for this auth mode" ($derived.Upstream -eq 'https://chatgpt.com/backend-api/codex') ("got=$($derived.Upstream)")

    # Point the proxy at the local mock so the suite never contacts a real model.
    $env:DEV_ROUTER_UPSTREAM = "http://127.0.0.1:$script:UpstreamPort/backend-api/codex"
    $reg = Register-DevRouterCodexIntegration -CodexHome $liveHome -Port $livePort -ManualBaseModel 'gpt-5.6-sol' -ManualBaseEffort 'high'
    Assert-Test "4a. Register reports the provider as selected" ($reg.ProviderSelected)
    Assert-Test "4b. provider_selected is true on disk" (Test-DevRouterProviderSelected -CodexHome $liveHome)
    Assert-Test "4c. proxy reported running by Register" ($reg.ProxyRunning)
    Assert-Test "4d2. explicit override is honored and reported" ($reg.UpstreamSource -eq 'env:DEV_ROUTER_UPSTREAM') ("got=$($reg.UpstreamSource)")

    $liveTop = Get-CodexTopLevelConfig -CodexHome $liveHome
    Assert-Test "4e. model_provider == dev-router" ($liveTop.ModelProvider -eq 'dev-router') ("got=$($liveTop.ModelProvider)")
    Assert-Test "4f. model is untouched (still gpt-adaptive)" ($liveTop.Model -eq 'gpt-adaptive') ("got=$($liveTop.Model)")
    Assert-Test "4g. manual effort preserved" ($liveTop.ModelEffort -eq 'high') ("got=$($liveTop.ModelEffort)")
    Assert-Test "4h. user's unrelated provider block preserved" (((Get-Content (Join-Path $liveHome 'config.toml') -Raw) -match '\[model_providers\.user-custom\]'))

    $liveReadiness = Get-DevRouterIntegrationReadiness -CodexHome $liveHome
    Assert-Test "4i. readiness reports ready" ($liveReadiness.integration_status -eq 'ready') ("got=$($liveReadiness.integration_status)")
    # This scenario runs with DEV_ROUTER_UPSTREAM pointed at the local mock; the
    # readiness must reflect what the proxy ACTUALLY resolved, not a wish.
    Assert-Test "4j. readiness exposes the live upstream host/path" ($liveReadiness.upstream_host -match '^127\.0\.0\.1(:\d+)?$' -and $liveReadiness.upstream_path -eq '/backend-api/codex/responses') ("got=$($liveReadiness.upstream_host)$($liveReadiness.upstream_path)")
    Assert-Test "4j2. readiness reports the override source" ($liveReadiness.upstream_source -eq 'env:DEV_ROUTER_UPSTREAM') ("got=$($liveReadiness.upstream_source)")
    Assert-Test "4k. readiness exposes the concrete manual base" ($liveReadiness.manual_base_available -and $liveReadiness.manual_base_model -eq 'Sol')

    # ------------------------------------------------------------------
    # Proxy behaviour under the registered provider
    # ------------------------------------------------------------------
    Write-Host "`nSection 5: Requests through the registered provider" -ForegroundColor Yellow
    $before = (Get-CapturedRequests).Count
    $status = Invoke-ProxyModel -Port $livePort -WithAuth -Body @{ model = 'gpt-adaptive'; input = @(@{ role = 'user'; content = @(@{ type = 'input_text'; text = 'Responda somente ROUTER_OK' }) }); reasoning = @{ effort = 'high' } }
    $after = Get-CapturedRequests
    $last = if (@($after).Count -gt $before) { @($after)[-1] } else { $null }
    Assert-Test "5a. gpt-adaptive request accepted (HTTP 200)" ($status -eq 200) ("http=$status")
    Assert-Test "5b. upstream received a CONCRETE model" ($null -ne $last -and $last.model -eq 'gpt-5.6-sol') ("got=$($last.model)")
    Assert-Test "5c. upstream never received the alias" ($null -ne $last -and $last.model -ne 'gpt-adaptive')
    Assert-Test "5d. upstream path is the ChatGPT backend shape" ($null -ne $last -and $last.url -eq '/backend-api/codex/responses') ("got=$($last.url)")
    Assert-Test "5e. authorization header forwarded (presence only)" ($null -ne $last -and $last.auth -eq $true) ("auth=$($last.auth)")

    $before = (Get-CapturedRequests).Count
    $null = Invoke-ProxyModel -Port $livePort -Body @{ model = 'gpt-5.6-luna'; input = @(@{ role = 'user'; content = @(@{ type = 'input_text'; text = 'hi' }) }); reasoning = @{ effort = 'medium' } }
    $after = Get-CapturedRequests
    $last = @($after)[-1]
    Assert-Test "5f. concrete model passes through unchanged (Luna)" ($last.model -eq 'gpt-5.6-luna') ("got=$($last.model)")

    $before = (Get-CapturedRequests).Count
    $null = Invoke-ProxyModel -Port $livePort -Body @{ model = 'gpt-5.6-sol'; input = @(@{ role = 'user'; content = @(@{ type = 'input_text'; text = 'hi' }) }); reasoning = @{ effort = 'low' } }
    $after = Get-CapturedRequests
    $last = @($after)[-1]
    Assert-Test "5g. concrete model passes through with mode=on effort_only (Sol stays Sol)" ($last.model -eq 'gpt-5.6-sol') ("got=$($last.model)")

    # ------------------------------------------------------------------
    # Unregister restores exactly
    # ------------------------------------------------------------------
    Write-Host "`nSection 6: Unregister restores the previous configuration" -ForegroundColor Yellow
    $unreg = Unregister-DevRouterCodexIntegration -CodexHome $liveHome
    Assert-Test "6a. Unregister returns true" ($unreg -eq $true)
    $restoredTop = Get-CodexTopLevelConfig -CodexHome $liveHome
    Assert-Test "6b. previous model_provider restored exactly" ($restoredTop.ModelProvider -eq 'openai') ("got=$($restoredTop.ModelProvider)")
    Assert-Test "6c. previous model_catalog_json restored exactly" ($restoredTop.ModelCatalogJson -eq 'C:/user/own-catalog.json') ("got=$($restoredTop.ModelCatalogJson)")
    Assert-Test "6d. user's model untouched" ($restoredTop.Model -eq 'gpt-adaptive') ("got=$($restoredTop.Model)")
    Assert-Test "6e. user's custom provider block still present" (((Get-Content (Join-Path $liveHome 'config.toml') -Raw) -match '\[model_providers\.user-custom\]'))
    Assert-Test "6f. dev-router provider block removed" (-not (Test-DevRouterProviderBlockDeclared -CodexHome $liveHome))
    Assert-Test "6g. proxy stopped (pid file gone)" (-not (Test-Path -LiteralPath (Join-Path $liveHome 'codex-workflows-kit\dev-router-proxy.pid')))
    $restoredReadiness = Get-DevRouterIntegrationReadiness -CodexHome $liveHome
    Assert-Test "6h. readiness no longer claims ready" ($restoredReadiness.integration_status -ne 'ready') ("got=$($restoredReadiness.integration_status)")

    # ------------------------------------------------------------------
    # Register again: unregister/register is idempotent
    # ------------------------------------------------------------------
    Write-Host "`nSection 7: Re-register after unregister" -ForegroundColor Yellow
    $reg2 = Register-DevRouterCodexIntegration -CodexHome $liveHome -Port (Get-FreeTcpPort) -ManualBaseModel 'gpt-5.6-luna'
    Assert-Test "7a. re-register selects the provider again" ($reg2.ProviderSelected)
    $unreg2 = Unregister-DevRouterCodexIntegration -CodexHome $liveHome
    $restored2 = Get-CodexTopLevelConfig -CodexHome $liveHome
    Assert-Test "7b. second unregister restores openai again" ($restored2.ModelProvider -eq 'openai' -and $unreg2 -eq $true) ("got=$($restored2.ModelProvider)")
    Assert-Test "7c. catalog line restored again" ($restored2.ModelCatalogJson -eq 'C:/user/own-catalog.json') ("got=$($restored2.ModelCatalogJson)")
}
finally {
    if ($null -ne $mockProc -and -not $mockProc.HasExited) { $mockProc.Kill() }
    if ($script:proxyProcs) {
        foreach ($p in $script:proxyProcs) {
            if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
        }
    }
    $env:DEV_ROUTER_UPSTREAM = $origUpstream
    $env:DEV_ROUTER_JEV_ENDPOINT = $origJevEndpoint
    $env:DEV_ROUTER_JEV_TIMEOUT_MS = $origJevTimeout
    $env:TYPESAFE_API_KEY = $origApiKey
    if ($keepTemp) {
        Write-Host "Keeping artifacts at $script:TempTestDir" -ForegroundColor Yellow
    }
    elseif (Test-Path -LiteralPath $script:TempTestDir) {
        Remove-Item -LiteralPath $script:TempTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "Total: $($script:TestCount) | Passed: $($script:PassedCount) | Failed: $($script:FailedCount)" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "Failures ($($script:FailedCount)):" -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
exit 0
