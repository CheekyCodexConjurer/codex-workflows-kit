# scripts/test-dev-router-proxy.ps1
# Deterministic conformance tests for the hardened Dev Router loopback proxy policy.
# Starts the real proxy against a local mock upstream and a local mock Jev endpoint.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$proxyScript = Join-Path $repoRoot 'scripts\dev-router-proxy.mjs'
$devRouterModule = Join-Path $repoRoot 'scripts\dev-router.psm1'

Import-Module $devRouterModule -DisableNameChecking -Force

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

function Get-FreeTcpPort {
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $port = Get-Random -Minimum 4200 -Maximum 4900
        $listener = $null
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
            $listener.Start()
            $listener.Stop()
            return $port
        }
        catch {
            if ($null -ne $listener) {
                try { $listener.Stop() } catch {}
            }
        }
    }
    throw 'Could not reserve a free loopback TCP port for the proxy conformance test.'
}

function Read-OpenFileText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.StreamReader($stream)
        return $reader.ReadToEnd()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-CaptureLines {
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-OpenFileText -Path $Path
    return @($text -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
}

function Get-ProxyLogLines {
    return @((Read-OpenFileText -Path $script:ProxyLog) -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
}

function Wait-ProxyLogMatch {
    param(
        [Parameter(Mandatory)][string]$Like,
        [int]$TimeoutMs = 5000
    )
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $matches = @(Get-ProxyLogLines | Where-Object { $_ -like $Like })
        if ($matches.Count -gt 0) { return $matches }
        Start-Sleep -Milliseconds 150
    } while ([datetime]::UtcNow -lt $deadline)
    return @()
}

function Get-UpstreamRequests {
    return @(Get-CaptureLines -Path $script:UpstreamCapture | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-JevRequests {
    return @(Get-CaptureLines -Path $script:JevCapture | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-RequestModel {
    param($Request)
    if ($null -eq $Request -or $null -eq $Request.body) { return $null }
    return [string]$Request.body.model
}

function Get-RequestEffort {
    param($Request)
    if ($null -eq $Request -or $null -eq $Request.body -or $null -eq $Request.body.reasoning) { return $null }
    return [string]$Request.body.reasoning.effort
}

function Set-ProxyState {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Target,
        [string]$BaseModel,
        [string]$BaseEffort
    )

    $state = [ordered]@{
        version   = 1
        product   = 'codex-workflows-kit'
        component = 'dev-router'
        mode      = $Mode
        target    = $Target
        updatedAt = [datetime]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($BaseModel)) { $state['manual_base_model'] = $BaseModel }
    if (-not [string]::IsNullOrWhiteSpace($BaseEffort)) { $state['manual_base_effort'] = $BaseEffort }

    [IO.File]::WriteAllText(
        (Join-Path $script:KitDir 'dev-router-state.json'),
        (($state | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding($false)))
}

function Set-JevControl {
    param(
        [ValidateSet('ok', 'hang', 'error')][string]$Mode,
        [string]$Choice
    )
    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        [IO.File]::WriteAllText($script:JevModeFile, $Mode, (New-Object System.Text.UTF8Encoding($false)))
    }
    if (-not [string]::IsNullOrWhiteSpace($Choice)) {
        [IO.File]::WriteAllText($script:JevChoiceFile, $Choice, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Get-LocksMap {
    $locksFile = Join-Path $script:KitDir 'dev-router-locks.json'
    if (-not (Test-Path -LiteralPath $locksFile -PathType Leaf)) { return @{} }
    $raw = Read-OpenFileText -Path $locksFile
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $parsed = $raw | ConvertFrom-Json
    $map = @{}
    if ($null -ne $parsed) {
        foreach ($property in $parsed.PSObject.Properties) {
            $map[$property.Name] = $property.Value
        }
    }
    return $map
}

function Invoke-ProxyResponse {
    param(
        [Parameter(Mandatory)][hashtable]$Body,
        [hashtable]$Headers = @{},
        [int]$TimeoutMs = 20000,
        [int]$ProxyPort = 0
    )

    $targetPort = if ($ProxyPort -gt 0) { $ProxyPort } else { $script:ProxyPort }
    $json = $Body | ConvertTo-Json -Depth 8
    $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$targetPort/v1/responses")
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $request.Timeout = $TimeoutMs
    $request.ReadWriteTimeout = $TimeoutMs
    foreach ($key in $Headers.Keys) {
        $request.Headers[$key] = [string]$Headers[$key]
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()

    $statusCode = -1
    $responseBody = ''
    try {
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        $response.Close()
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $statusCode = [int]$response.StatusCode
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            $response.Close()
        }
        else {
            $responseBody = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        StatusCode = $statusCode
        Body       = $responseBody
    }
}

Write-Host "Running Dev Router Proxy Conformance Tests..." -ForegroundColor Cyan

$script:KeepTemp = ($env:DEV_ROUTER_PROXY_TEST_KEEP -eq '1')
$script:TempTestDir = Join-Path ([IO.Path]::GetTempPath()) ("dev-router-proxy-test-" + [Guid]::NewGuid().ToString('N'))
$script:CodexHome = Join-Path $script:TempTestDir 'codex'
$script:KitDir = Join-Path $script:CodexHome 'codex-workflows-kit'
[void][IO.Directory]::CreateDirectory($script:KitDir)

$script:UpstreamCapture = Join-Path $script:TempTestDir 'upstream-capture.jsonl'
$script:JevCapture = Join-Path $script:TempTestDir 'jev-capture.jsonl'
$script:JevChoiceFile = Join-Path $script:TempTestDir 'jev-choice.txt'
$script:JevModeFile = Join-Path $script:TempTestDir 'jev-mode.txt'
$script:ProxyLog = Join-Path $script:TempTestDir 'proxy.log'
$proxyErrLog = Join-Path $script:TempTestDir 'proxy.err.log'
$mockLog = Join-Path $script:TempTestDir 'mock.log'
$mockErrLog = Join-Path $script:TempTestDir 'mock.err.log'
$mockScript = Join-Path $script:TempTestDir 'mock-endpoints.mjs'

$script:UpstreamPort = Get-FreeTcpPort
$script:JevPort = Get-FreeTcpPort
$script:ProxyPort = Get-FreeTcpPort
$script:ExpectedJevCalls = 0
$script:SeenJevEndpoint = $null

$mockSource = @'
import http from 'node:http';
import fs from 'node:fs';

const upstreamPort = Number(process.argv[2]);
const jevPort = Number(process.argv[3]);
const upstreamCapture = process.argv[4];
const jevCapture = process.argv[5];
const jevChoiceFile = process.argv[6];
const jevModeFile = process.argv[7];

function readControl(file) {
    try { return fs.readFileSync(file, 'utf8').trim(); } catch { return ''; }
}

let upstreamCount = 0;
const upstream = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
        upstreamCount++;
        let parsed = null;
        try { parsed = JSON.parse(body); } catch { parsed = null; }
        fs.appendFileSync(upstreamCapture, JSON.stringify({ method: req.method, url: req.url, headers: req.headers, body: parsed }) + '\n', 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/event-stream' });
        res.write('event: response.completed\n');
        res.write('data: {"response":{"id":"resp_test_' + upstreamCount + '"}}\n\n');
        res.end();
    });
});

const jev = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
        const mode = readControl(jevModeFile) || 'ok';
        let parsed = null;
        try { parsed = JSON.parse(body); } catch { parsed = null; }
        fs.appendFileSync(jevCapture, JSON.stringify({ mode, body: parsed }) + '\n', 'utf8');
        if (mode === 'hang') { return; }
        if (mode === 'error') {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end('{"error":{"message":"mock jev failure"}}');
            return;
        }
        const choice = readControl(jevChoiceFile);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ answers: { q_route: { type: 'choice', choice } } }));
    });
});

upstream.listen(upstreamPort, '127.0.0.1');
jev.listen(jevPort, '127.0.0.1');
'@
[IO.File]::WriteAllText($mockScript, $mockSource, (New-Object System.Text.UTF8Encoding($false)))
Set-JevControl -Mode 'ok' -Choice 'high'

$origJevEndpoint = $env:DEV_ROUTER_JEV_ENDPOINT
$origJevTimeout = $env:DEV_ROUTER_JEV_TIMEOUT_MS
$origApiKey = $env:TYPESAFE_API_KEY

$mockProc = $null
$proxyProc = $null
try {
    $mockArgLine = "`"$mockScript`" $script:UpstreamPort $script:JevPort `"$script:UpstreamCapture`" `"$script:JevCapture`" `"$script:JevChoiceFile`" `"$script:JevModeFile`""
    $mockProc = Start-Process -FilePath 'node' -ArgumentList $mockArgLine -PassThru -NoNewWindow -RedirectStandardOutput $mockLog -RedirectStandardError $mockErrLog
    Start-Sleep -Milliseconds 500

    $env:DEV_ROUTER_JEV_ENDPOINT = "http://127.0.0.1:$script:JevPort/v1/systemone"
    $env:DEV_ROUTER_JEV_TIMEOUT_MS = '600'
    $env:TYPESAFE_API_KEY = 'sk-proj-live-lookalike-0000000000000000000000000000'

    $proxyArgLine = "`"$proxyScript`" --port $script:ProxyPort --upstream http://127.0.0.1:$script:UpstreamPort --codex-home `"$script:CodexHome`""
    $proxyProc = Start-Process -FilePath 'node' -ArgumentList $proxyArgLine -PassThru -NoNewWindow -RedirectStandardOutput $script:ProxyLog -RedirectStandardError $proxyErrLog

    $proxyReady = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        try {
            $healthRequest = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$script:ProxyPort/health")
            $healthRequest.Method = 'GET'
            $healthRequest.Timeout = 500
            $healthResponse = $healthRequest.GetResponse()
            $healthResponse.Close()
            $proxyReady = $true
            break
        }
        catch {}
    }
    Assert-Test "Proxy conformance harness started (proxy + mock upstream + mock Jev)" ($proxyReady -eq $true)

    # ------------------------------------------------------------------
    # 1. on + effort_only with a concrete incoming model
    # ------------------------------------------------------------------
    Write-Host "`nSection 1: effort_only with a concrete incoming model" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'effort_only' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    Set-JevControl -Mode 'ok' -Choice 'high'
    $script:ExpectedJevCalls++

    $response1 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-5.6-sol'
        conversation_id = 'conv-1'
        reasoning       = @{ effort = 'low' }
        input           = @(@{ role = 'user'; content = @(@{ type = 'input_text'; text = 'Fix a minor typo in markdown' }) })
    }
    $upstream1 = @(Get-UpstreamRequests)
    $jev1 = @(Get-JevRequests)

    Assert-Test "1a. effort_only adapts the effort of a CONCRETE incoming model" `
        ($response1.StatusCode -eq 200 -and $upstream1.Count -ge 1 -and (Get-RequestModel $upstream1[0]) -eq 'gpt-5.6-sol' -and (Get-RequestEffort $upstream1[0]) -eq 'high')
    Assert-Test "1b. upstream sees the concrete model, never gpt-adaptive" ((Get-RequestModel $upstream1[0]) -ne 'gpt-adaptive')
    Assert-Test "1c. exactly one Jev call was made for the new boundary" ($jev1.Count -eq $script:ExpectedJevCalls)
    $routeLines = @(Wait-ProxyLogMatch -Like '[[]DevRouter] route*')
    Assert-Test "1d. stable single-line route log" `
        (@($routeLines | Where-Object { $_ -eq '[DevRouter] route boundary=conv-1 mode=on target=effort_only incoming=gpt-5.6-sol jev=called final=gpt-5.6-sol/high status=ok' }).Count -eq 1) `
        (@($routeLines) -join ' || ')

    # ------------------------------------------------------------------
    # 2. Same boundary through the response chain: zero extra Jev calls
    # ------------------------------------------------------------------
    Write-Host "`nSection 2: Sticky routing on the same boundary" -ForegroundColor Yellow
    $response2 = Invoke-ProxyResponse -Body @{
        model                = 'gpt-5.6-sol'
        previous_response_id = 'resp_test_1'
        reasoning            = @{ effort = 'low' }
    }
    $upstream2 = @(Get-UpstreamRequests)
    $jev2 = @(Get-JevRequests)

    Assert-Test "2a. a request with a seen previous_response_id inherits the boundary" `
        ($response2.StatusCode -eq 200 -and $upstream2.Count -eq 2 -and (Get-RequestModel $upstream2[1]) -eq 'gpt-5.6-sol' -and (Get-RequestEffort $upstream2[1]) -eq 'high')
    Assert-Test "2b. lock reuse makes ZERO additional Jev calls" ($jev2.Count -eq $script:ExpectedJevCalls)
    $routeLines2 = @(Wait-ProxyLogMatch -Like '*status=locked*')
    Assert-Test "2c. the reused route is logged as jev=skipped status=locked" `
        (@($routeLines2 | Where-Object { $_ -eq '[DevRouter] route boundary=conv-1 mode=on target=effort_only incoming=gpt-5.6-sol jev=skipped final=gpt-5.6-sol/high status=locked' }).Count -eq 1) `
        (@($routeLines2) -join ' || ')

    # ------------------------------------------------------------------
    # 3. New boundary: a new decision is allowed
    # ------------------------------------------------------------------
    Write-Host "`nSection 3: New boundary makes a new decision" -ForegroundColor Yellow
    Set-JevControl -Mode 'ok' -Choice 'xhigh'
    $script:ExpectedJevCalls++
    $response3 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-2'
        reasoning       = @{ effort = 'low' }
    }
    $upstream3 = @(Get-UpstreamRequests)
    $jev3 = @(Get-JevRequests)

    Assert-Test "3a. a new boundary triggers a new Jev decision" `
        ($response3.StatusCode -eq 200 -and $upstream3.Count -eq 3 -and (Get-RequestModel $upstream3[2]) -eq 'gpt-5.6-sol' -and (Get-RequestEffort $upstream3[2]) -eq 'xhigh')
    Assert-Test "3b. the new decision consumed exactly one more Jev call" ($jev3.Count -eq $script:ExpectedJevCalls)

    # ------------------------------------------------------------------
    # 4. on + model_only from gpt-adaptive
    # ------------------------------------------------------------------
    Write-Host "`nSection 4: model_only picks a concrete allowlisted model" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'model_only' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    Set-JevControl -Mode 'ok' -Choice 'Luna'
    $script:ExpectedJevCalls++
    $response4 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-3'
        reasoning       = @{ effort = 'low' }
    }
    $upstream4 = @(Get-UpstreamRequests)

    Assert-Test "4a. model_only resolves gpt-adaptive to a concrete allowed model" `
        ($response4.StatusCode -eq 200 -and $upstream4.Count -eq 4 -and (Get-RequestModel $upstream4[3]) -eq 'gpt-5.6-luna')
    Assert-Test "4b. model_only preserves the requested effort" ((Get-RequestEffort $upstream4[3]) -eq 'low')
    Assert-Test "4c. gpt-adaptive never reaches upstream" ((Get-RequestModel $upstream4[3]) -ne 'gpt-adaptive')

    # ------------------------------------------------------------------
    # 5. on + model_and_effort from gpt-adaptive
    # ------------------------------------------------------------------
    Write-Host "`nSection 5: model_and_effort applies a compatible pair" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'model_and_effort' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    Set-JevControl -Mode 'ok' -Choice 'Astra:high'
    $script:ExpectedJevCalls++
    $response5 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-4'
        reasoning       = @{ effort = 'medium' }
    }
    $upstream5 = @(Get-UpstreamRequests)

    Assert-Test "5a. model_and_effort applies a concrete compatible pair" `
        ($response5.StatusCode -eq 200 -and $upstream5.Count -eq 5 -and (Get-RequestModel $upstream5[4]) -eq 'gpt-6-astra' -and (Get-RequestEffort $upstream5[4]) -eq 'high')

    # ------------------------------------------------------------------
    # 6. Jev timeout / unavailable
    # ------------------------------------------------------------------
    Write-Host "`nSection 6: Jev timeout and unavailable fail closed to the base" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'effort_only' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    Set-JevControl -Mode 'hang' -Choice ''
    $script:ExpectedJevCalls++
    $response6 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-5'
        reasoning       = @{ effort = 'low' }
    }
    $upstream6 = @(Get-UpstreamRequests)

    Assert-Test "6a. Jev timeout falls back to the concrete manual base" `
        ($response6.StatusCode -eq 200 -and $upstream6.Count -eq 6 -and (Get-RequestModel $upstream6[5]) -eq 'gpt-5.6-sol' -and (Get-RequestEffort $upstream6[5]) -eq 'low')
    Assert-Test "6b. the timeout route is logged with status=timeout" `
        (@((Wait-ProxyLogMatch -Like '*boundary=conv-5 *') | Where-Object { $_ -like '*status=timeout*' }).Count -ge 1)

    Set-JevControl -Mode 'error' -Choice ''
    $script:ExpectedJevCalls++
    $response6b = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-5b'
        reasoning       = @{ effort = 'low' }
    }
    $upstream6b = @(Get-UpstreamRequests)

    Assert-Test "6c. Jev unavailable falls back to the concrete manual base" `
        ($response6b.StatusCode -eq 200 -and $upstream6b.Count -eq 7 -and (Get-RequestModel $upstream6b[6]) -eq 'gpt-5.6-sol')
    Assert-Test "6d. no fallback route ever turns into gpt-adaptive" ((Get-RequestModel $upstream6b[6]) -ne 'gpt-adaptive')
    Set-JevControl -Mode 'ok' -Choice 'high'

    # ------------------------------------------------------------------
    # 7. off + gpt-adaptive
    # ------------------------------------------------------------------
    Write-Host "`nSection 7: off keeps the concrete manual base with zero Jev" -ForegroundColor Yellow
    Set-ProxyState -Mode 'off' -Target 'effort_only' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    $jevBeforeOff = @(Get-JevRequests).Count
    $response7 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-6'
        reasoning       = @{ effort = 'low' }
    }
    $upstream7 = @(Get-UpstreamRequests)

    Assert-Test "7a. off rewrites gpt-adaptive to the concrete manual base" `
        ($response7.StatusCode -eq 200 -and $upstream7.Count -eq 8 -and (Get-RequestModel $upstream7[7]) -eq 'gpt-5.6-sol' -and (Get-RequestEffort $upstream7[7]) -eq 'low')
    Assert-Test "7b. off makes zero Jev calls" (@(Get-JevRequests).Count -eq $jevBeforeOff)

    # ------------------------------------------------------------------
    # 8. shadow + gpt-adaptive
    # ------------------------------------------------------------------
    Write-Host "`nSection 8: shadow observes but never applies or locks" -ForegroundColor Yellow
    Set-ProxyState -Mode 'shadow' -Target 'effort_only' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    Set-JevControl -Mode 'ok' -Choice 'high'
    $script:ExpectedJevCalls++
    $response8 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-7'
        reasoning       = @{ effort = 'low' }
    }
    $upstream8 = @(Get-UpstreamRequests)

    Assert-Test "8a. shadow keeps the concrete manual base" `
        ($response8.StatusCode -eq 200 -and $upstream8.Count -eq 9 -and (Get-RequestModel $upstream8[8]) -eq 'gpt-5.6-sol')
    $locksAfterShadow = Get-LocksMap
    Assert-Test "8b. shadow creates no applied lock" (-not $locksAfterShadow.ContainsKey('conv-7'))
    Assert-Test "8c. shadow logs exactly one telemetry recommendation line" `
        (@(Wait-ProxyLogMatch -Like '[[]DevRouter] shadow recommendation=*').Count -eq 1)
    Assert-Test "8d. shadow Jev call reached the mock endpoint" (@(Get-JevRequests).Count -eq $script:ExpectedJevCalls)

    # ------------------------------------------------------------------
    # 9. Missing concrete base fails closed
    # ------------------------------------------------------------------
    Write-Host "`nSection 9: Missing concrete base fails closed" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'effort_only' -BaseModel '' -BaseEffort ''
    $upstreamBeforeMissing = @(Get-UpstreamRequests).Count
    $jevBeforeMissing = @(Get-JevRequests).Count
    $response9 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-8'
        reasoning       = @{ effort = 'low' }
    }
    $missingErrorType = $null
    try { $missingErrorType = [string](($response9.Body | ConvertFrom-Json).error.type) } catch {}

    Assert-Test "9a. missing manual base returns a local 400 dev_router_missing_base" `
        ($response9.StatusCode -eq 400 -and $missingErrorType -eq 'dev_router_missing_base') `
        ("status=$($response9.StatusCode) type=$missingErrorType body=$($response9.Body)")
    Assert-Test "9b. missing base never contacts the upstream" (@(Get-UpstreamRequests).Count -eq $upstreamBeforeMissing)
    Assert-Test "9c. missing base never calls Jev" (@(Get-JevRequests).Count -eq $jevBeforeMissing)

    # ------------------------------------------------------------------
    # 10. Manual Terra baseline
    # ------------------------------------------------------------------
    Write-Host "`nSection 10: Manual Terra baseline stays concrete and is never offered" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'model_only' -BaseModel 'gpt-5.6-terra' -BaseEffort 'ultra'
    $jevBeforeTerra = @(Get-JevRequests).Count
    $response10 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-9'
        reasoning       = @{ effort = 'ultra' }
    }
    $upstream10 = @(Get-UpstreamRequests)

    Assert-Test "10a. a manual Terra baseline is never auto-replaced when no allowed model serves the effort" `
        ($response10.StatusCode -eq 200 -and $upstream10.Count -eq 10 -and (Get-RequestModel $upstream10[9]) -eq 'gpt-5.6-terra' -and (Get-RequestEffort $upstream10[9]) -eq 'ultra')
    Assert-Test "10b. the incompatible Terra route consumed no Jev call" (@(Get-JevRequests).Count -eq $jevBeforeTerra)

    Set-ProxyState -Mode 'on' -Target 'model_only' -BaseModel 'gpt-5.6-terra' -BaseEffort 'medium'
    Set-JevControl -Mode 'ok' -Choice 'Luna'
    $script:ExpectedJevCalls++
    $response10c = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-9b'
        reasoning       = @{ effort = 'medium' }
    }
    $upstream10c = @(Get-UpstreamRequests)
    $jevRequests = @(Get-JevRequests)
    $terraOffered = $false
    $criteriaJson = ''
    $lastJevBody = $jevRequests[$jevRequests.Count - 1].body
    if ($null -ne $lastJevBody -and $null -ne $lastJevBody.questions) {
        $criteriaJson = $lastJevBody.questions.q_route.criteria | ConvertTo-Json -Depth 6 -Compress
        if ($criteriaJson -match '(?i)terra') { $terraOffered = $true }
        $instructionText = [string]$lastJevBody.questions.q_route.instructions
        if ($instructionText -match '(?i)terra') { $terraOffered = $true }
    }

    Assert-Test "10c. Terra is never offered as a Jev option" (-not $terraOffered) ($criteriaJson)
    Assert-Test "10d. an authorized model_only route only selects allowlisted models" `
        ($upstream10c.Count -eq 11 -and (Get-RequestModel $upstream10c[10]) -eq 'gpt-5.6-luna')
    Assert-Test "10e. upstream never receives the gpt-adaptive alias" (@($upstream10c | Where-Object { (Get-RequestModel $_) -eq 'gpt-adaptive' }).Count -eq 0)

    # ------------------------------------------------------------------
    # 11. Invalid model/effort pair is never applied
    # ------------------------------------------------------------------
    Write-Host "`nSection 11: Invalid model/effort pair is never applied" -ForegroundColor Yellow
    Set-ProxyState -Mode 'on' -Target 'model_and_effort' -BaseModel 'gpt-5.6-sol' -BaseEffort 'medium'
    Set-JevControl -Mode 'ok' -Choice 'Astra:ultra'
    $script:ExpectedJevCalls++
    $response11 = Invoke-ProxyResponse -Body @{
        model           = 'gpt-adaptive'
        conversation_id = 'conv-10'
        reasoning       = @{ effort = 'low' }
    }
    $upstream11 = @(Get-UpstreamRequests)

    Assert-Test "11a. an incompatible pair fails closed to the concrete base" `
        ($response11.StatusCode -eq 200 -and $upstream11.Count -eq 12 -and (Get-RequestModel $upstream11[11]) -eq 'gpt-5.6-sol' -and (Get-RequestEffort $upstream11[11]) -eq 'low')
    Assert-Test "11b. the incompatible pair route is logged as status=incompatible" `
        (@((Wait-ProxyLogMatch -Like '*boundary=conv-10 *') | Where-Object { $_ -like '*status=incompatible*' }).Count -eq 1)

    # ------------------------------------------------------------------
    # 12. Live-call safety with a real-looking API key
    # ------------------------------------------------------------------
    Write-Host "`nSection 12: No live Jev calls with a real-looking key" -ForegroundColor Yellow
    Assert-Test "12a. the suite runs with a real-looking TYPESAFE_API_KEY" ($env:TYPESAFE_API_KEY -like 'sk-*')
    Assert-Test "12b. every Jev call landed on the local mock (count=$(@(Get-JevRequests).Count), expected=$script:ExpectedJevCalls)" `
        (@(Get-JevRequests).Count -eq $script:ExpectedJevCalls)
    Assert-Test "12c. the proxy never mentions the live Jev host" ((Read-OpenFileText -Path $script:ProxyLog) -notmatch 'api\.typesafe\.ai')

    $endpointProbeTransport = {
        param($Request)
        $script:SeenJevEndpoint = [string]$Request.Endpoint
        return [pscustomobject]@{ answers = [pscustomobject]@{ q_route = [pscustomobject]@{ choice = 'high' } } }
    }
    $probeProjection = New-DevRouterContextProjection -Objective 'Endpoint probe' -Surface 'alignment' -CurrentModel 'Sol' -CurrentEffort 'medium' -Target 'effort_only'
    $null = Invoke-DevRouterJevChoice -Projection $probeProjection -Target 'effort_only' -BaselineModel 'Sol' -BaselineEffort 'medium' -ApiKey 'probe-key' -HttpTransportMock $endpointProbeTransport
    Assert-Test "12d. the PowerShell Jev transport honors DEV_ROUTER_JEV_ENDPOINT" `
        ($script:SeenJevEndpoint -eq $env:DEV_ROUTER_JEV_ENDPOINT) ("seen=$($script:SeenJevEndpoint) expected=$($env:DEV_ROUTER_JEV_ENDPOINT)")

    # ------------------------------------------------------------------------
    # 13. Upstream URL shape: ChatGPT-auth backends carry a path.
    # ------------------------------------------------------------------------
    $pathProxyPort = Get-FreeTcpPort
    $pathProxyLog = Join-Path $script:TempTestDir 'proxy-path.log'
    $pathProxyErr = Join-Path $script:TempTestDir 'proxy-path.err'
    $pathProxyProc = Start-Process -FilePath 'node' -ArgumentList @(
        $proxyScript, '--port', $pathProxyPort,
        '--upstream', "http://127.0.0.1:$script:UpstreamPort/backend-api/codex",
        '--codex-home', $script:CodexHome
    ) -PassThru -NoNewWindow -RedirectStandardOutput $pathProxyLog -RedirectStandardError $pathProxyErr
    Start-Sleep -Milliseconds 700
    try {
        $before = @(Get-UpstreamRequests).Count
        $null = Invoke-ProxyResponse -ProxyPort $pathProxyPort -Body @{
            model    = 'gpt-adaptive'
            conversation_id = 'proxy-path-boundary'
            input    = @(@{ role = 'user'; content = @(@{ type = 'input_text'; text = 'Responda somente ROUTER_OK' }) })
            reasoning = @{ effort = 'low' }
        }
        $after = @(Get-UpstreamRequests)
        Assert-Test "13a. a path-bearing upstream base is forwarded to (<base>/responses)" `
            ((@($after).Count -gt $before) -and (@($after)[-1].url -eq '/backend-api/codex/responses')) `
            ("lastUrl=" + $(if (@($after).Count -gt 0) { @($after)[-1].url } else { 'none' }))
    }
    finally {
        if ($null -ne $pathProxyProc -and -not $pathProxyProc.HasExited) {
            $pathProxyProc.Kill()
            [void]$pathProxyProc.WaitForExit(2000)
        }
    }
}
finally {
    if ($null -ne $proxyProc -and -not $proxyProc.HasExited) {
        $proxyProc.Kill()
        [void]$proxyProc.WaitForExit(2000)
    }
    if ($null -ne $mockProc -and -not $mockProc.HasExited) {
        $mockProc.Kill()
        [void]$mockProc.WaitForExit(2000)
    }
    $env:DEV_ROUTER_JEV_ENDPOINT = $origJevEndpoint
    $env:DEV_ROUTER_JEV_TIMEOUT_MS = $origJevTimeout
    $env:TYPESAFE_API_KEY = $origApiKey
    if ($script:KeepTemp) {
        Write-Host "Keeping proxy conformance artifacts at $script:TempTestDir" -ForegroundColor Yellow
    }
    elseif (Test-Path -LiteralPath $script:TempTestDir) {
        Remove-Item -LiteralPath $script:TempTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "Total: $($script:TestCount) | Passed: $($script:PassedCount) | Failed: $($script:FailedCount)" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "Failures ($($script:FailedCount)):" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}
exit 0
