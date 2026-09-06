# scripts/tests/safe-powershell.Tests.ps1
# Deterministic contract and invariant tests for invoke-safe-powershell:
# - Bounded -File based invocation with explicit argument array, -NoProfile, -NonInteractive
# - ErrorStop wrapper ensuring terminating, non-terminating, and native nonzero exit code propagation
# - Stdin closed preventing interactive prompt hangs (Read-Host, Console.ReadLine, missing mandatory params)
# - Exact preservation of literal dollars, quotes, spaces, unicode, and switch-like arguments
# - Neutral authority and script path validation (.ps1 leaf only)
# - No default job execution timeout / no forced kill on healthy jobs
# - Regression test reproducing former disappearing variable bug as safe no-hang fixture
# - Multi-engine testing on both PowerShell 7 (pwsh) and Windows PowerShell 5.1 (powershell.exe)

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$RepoRootOverride = '',
    [Parameter(Mandatory=$false)][switch]$SkipPS51
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = if ($RepoRootOverride) { [IO.Path]::GetFullPath($RepoRootOverride) } else { [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..')) }
$helperPath = Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1'

if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    Write-Error "invoke-safe-powershell.ps1 not found at '$helperPath'"
    exit 1
}

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

function Write-Utf8File([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Running Safe PowerShell Contract and Regression Tests..." -ForegroundColor Cyan

$tempFixtureDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "safe_ps_tests_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempFixtureDir -Force | Out-Null

try {
    # Fixture: Echo arguments to stdout
    $fixtureEchoArgs = Join-Path $tempFixtureDir 'echo_args.ps1'
    $codeEchoArgs = "param([Parameter(Mandatory=`$false, Position=0)][string]`$P1, [Parameter(Mandatory=`$false, ValueFromRemainingArguments=`$true)][string[]]`$Remaining)`n" +
        "Write-Host `"P1: <`$P1>`"`n" +
        "Write-Host `"RemainingCount: `$(`$Remaining.Count)`"`n" +
        "if (`$null -ne `$Remaining) { foreach (`$item in `$Remaining) { Write-Host `"Item: <`$item>`" } }"
    Write-Utf8File $fixtureEchoArgs $codeEchoArgs

    # Fixture: Read-Host prompt (hang check)
    $fixtureReadHost = Join-Path $tempFixtureDir 'hang_readhost.ps1'
    $codeReadHost = "Write-Host `"About to prompt`"`n`$input = Read-Host `"Enter interactive input`"`nWrite-Host `"Received: <`$input>`""
    Write-Utf8File $fixtureReadHost $codeReadHost

    # Fixture: Console.ReadLine
    $fixtureConsoleRead = Join-Path $tempFixtureDir 'hang_console_read.ps1'
    $codeConsoleRead = "Write-Host `"Calling Console ReadLine`"`n`$line = [Console]::ReadLine()`nWrite-Host `"Line read: <`$line>`""
    Write-Utf8File $fixtureConsoleRead $codeConsoleRead

    # Fixture: Mandatory parameter missing
    $fixtureMandatory = Join-Path $tempFixtureDir 'mandatory_param.ps1'
    $codeMandatory = "[CmdletBinding()]`nparam([Parameter(Mandatory=`$true)][string]`$RequiredField)`nWrite-Host `"Field: `$RequiredField`""
    Write-Utf8File $fixtureMandatory $codeMandatory

    # Fixture: Terminating exception
    $fixtureTerminating = Join-Path $tempFixtureDir 'throw_error.ps1'
    $codeTerminating = "Write-Host `"Before throw`"`nthrow `"terminating failure message`""
    Write-Utf8File $fixtureTerminating $codeTerminating

    # Fixture: Non-terminating error (Write-Error) with child continue preference
    $fixtureNonTerminating = Join-Path $tempFixtureDir 'non_terminating.ps1'
    $codeNonTerminating = "`$ErrorActionPreference = 'Continue'`nWrite-Error `"non-terminating error occurred`"`nWrite-Host `"continued after write-error`""
    Write-Utf8File $fixtureNonTerminating $codeNonTerminating

    # Fixture: Native command failure ($LASTEXITCODE 42)
    $fixtureNativeFail = Join-Path $tempFixtureDir 'native_fail.ps1'
    $codeNativeFail = "Write-Host `"Running native failure command`"`ncmd.exe /c exit 42`nWrite-Host `"After native command`""
    Write-Utf8File $fixtureNativeFail $codeNativeFail

    # Fixture: Child explicit exit 7
    $fixtureChildExit7 = Join-Path $tempFixtureDir 'child_exit7.ps1'
    $codeChildExit7 = "Write-Host `"Child exiting with code 7`"`nexit 7"
    Write-Utf8File $fixtureChildExit7 $codeChildExit7

    # Fixture: Child explicit exit 0
    $fixtureChildExit0 = Join-Path $tempFixtureDir 'child_exit0.ps1'
    $codeChildExit0 = "Write-Host `"Child exiting with code 0`"`nexit 0"
    Write-Utf8File $fixtureChildExit0 $codeChildExit0

    # Fixture: Native stderr output with exit 0
    $fixtureNativeStderrSuccess = Join-Path $tempFixtureDir 'native_stderr_success.ps1'
    $codeNativeStderrSuccess = "cmd.exe /c `"echo diagnostic warning to stderr >&2`"`nWrite-Host `"Native command finished cleanly`"`nexit 0"
    Write-Utf8File $fixtureNativeStderrSuccess $codeNativeStderrSuccess

    # Fixture: Disappearing variable reproduction fixture
    $fixtureDisappearingVar = Join-Path $tempFixtureDir 'disappearing_var.ps1'
    $codeDisappearingVar = "param([string]`$InjectedVar)`nWrite-Host `"InjectedVar: <`$InjectedVar>`""
    Write-Utf8File $fixtureDisappearingVar $codeDisappearingVar

    # Fixture: Console.ReadLine with explicit non-null validation
    $fixtureConsoleReadRequire = Join-Path $tempFixtureDir 'console_read_require.ps1'
    $codeConsoleReadRequire = "Write-Host `"Calling Console ReadLine`"`n`$line = [Console]::ReadLine()`nif (`$null -eq `$line) { throw `"Unexpected EOF on stdin`" }"
    Write-Utf8File $fixtureConsoleReadRequire $codeConsoleReadRequire

    # Fixture: Write-Error halt verification (inert marker must NOT be executed)
    $fixtureWriteErrorStop = Join-Path $tempFixtureDir 'write_error_stop.ps1'
    $markerPath = Join-Path $tempFixtureDir 'inert_marker.txt'
    $codeWriteErrorStop = "param([string]`$Marker)`nWrite-Host `"Before write-error`"`nWrite-Error `"halting error occurred`"`nSet-Content -LiteralPath `$Marker -Value 'INERT_MARKER_EXECUTED'"
    Write-Utf8File $fixtureWriteErrorStop $codeWriteErrorStop

    # Fixture: Child script invokes helper PassThru on expected negative test then explicitly exits 0
    $fixtureHelperNegativeThenExit0 = Join-Path $tempFixtureDir 'helper_negative_then_exit0.ps1'
    $codeHelperNegativeThenExit0 = "param([string]`$Helper, [string]`$TargetMissing)`n`$res = & `$Helper -ScriptPath `$TargetMissing -PassThru`nexit 0"
    Write-Utf8File $fixtureHelperNegativeThenExit0 $codeHelperNegativeThenExit0

    # Fixture: Child script handles internal error via try/catch then explicitly exits 0
    $fixtureHandleErrorThenExit0 = Join-Path $tempFixtureDir 'handle_error_then_exit0.ps1'
    $codeHandleErrorThenExit0 = "try { throw 'intentional caught failure' } catch {}`nexit 0"
    Write-Utf8File $fixtureHandleErrorThenExit0 $codeHandleErrorThenExit0

    # Fixture: Long-inert script with two outputs separated by sleep
    $fixtureStreamTwoOutputs = Join-Path $tempFixtureDir 'stream_two_outputs.ps1'
    $codeStreamTwoOutputs = "Write-Host `"FIRST_STREAM_OUTPUT`"`nStart-Sleep -Milliseconds 1500`nWrite-Host `"SECOND_STREAM_OUTPUT`""
    Write-Utf8File $fixtureStreamTwoOutputs $codeStreamTwoOutputs

    # Fixture: Healthy job completing cleanly
    $fixtureHealthyQuick = Join-Path $tempFixtureDir 'healthy_job.ps1'
    $codeHealthy = "Start-Sleep -Milliseconds 100`nWrite-Host `"Healthy job complete`"`nexit 0"
    Write-Utf8File $fixtureHealthyQuick $codeHealthy

    # Fixture: Named parameter & switch binding probe
    $fixtureNamedParams = Join-Path $tempFixtureDir 'named_params.ps1'
    $codeNamedParams = "param([string]`$Profile = 'DEFAULT', [switch]`$Enabled)`n" +
        "[pscustomobject]@{ Profile = `$Profile; Enabled = [bool]`$Enabled; Extra = @(`$args) } | ConvertTo-Json -Compress"
    Write-Utf8File $fixtureNamedParams $codeNamedParams

    # Fixture: Marker side-effect script for fail-closed pre-launch negative tests
    $fixtureMarkerNegative = Join-Path $tempFixtureDir 'marker_negative.ps1'
    $negMarkerPath = Join-Path $tempFixtureDir 'negative_marker.txt'
    $escapedNegMarkerPath = $negMarkerPath.Replace('\', '/')
    $codeMarkerNegative = "Set-Content -LiteralPath '$escapedNegMarkerPath' -Value 'INERT_MARKER_EXECUTED'"
    Write-Utf8File $fixtureMarkerNegative $codeMarkerNegative

    # ==========================================================================
    # Group 1: Path Validation & Neutral Authority
    # ==========================================================================
    Write-Host "`n[Suite 1] Path Validation & Neutral Authority" -ForegroundColor Yellow

    $res11 = $null
    $exit11 = 0
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $res11 = & pwsh -NoProfile -NonInteractive -File $helperPath 2>&1
        $exit11 = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    Assert-Test "1.1 Missing -ScriptPath fails quickly with exit 1" ($exit11 -eq 1) "ExitCode: $exit11"

    $res12 = & $helperPath -ScriptPath (Join-Path $tempFixtureDir 'nonexistent.ps1') -PassThru
    Assert-Test "1.2 Non-existent script path fails with exit 1" ($res12.ExitCode -eq 1 -and $res12.Success -eq $false) "ExitCode: $($res12.ExitCode)"

    $res13 = & $helperPath -ScriptPath $tempFixtureDir -PassThru
    Assert-Test "1.3 Directory passed as -ScriptPath fails with exit 1" ($res13.ExitCode -eq 1) "ExitCode: $($res13.ExitCode)"

    $dummyTxt = Join-Path $tempFixtureDir 'test.txt'
    Set-Content -LiteralPath $dummyTxt -Value 'text'
    $res14 = & $helperPath -ScriptPath $dummyTxt -PassThru
    Assert-Test "1.4 Non-.ps1 file passed as -ScriptPath fails with exit 1" ($res14.ExitCode -eq 1) "ExitCode: $($res14.ExitCode)"

    $res15 = & $helperPath -ScriptPath $fixtureEchoArgs -WorkingDirectory (Join-Path $tempFixtureDir 'missing_dir') -PassThru
    Assert-Test "1.5 Invalid WorkingDirectory fails with exit 1" ($res15.ExitCode -eq 1) "ExitCode: $($res15.ExitCode)"

    # ==========================================================================
    # Group 2: Literal Argument Preservation
    # ==========================================================================
    Write-Host "`n[Suite 2] Argument Preservation (Dollars, Quotes, Spaces, Unicode, Switches)" -ForegroundColor Yellow

    $testArgs = @(
        'first_param',
        '$dollarVar',
        '$100',
        '$env:PATH',
        'argument with spaces',
        '"double quoted"',
        "'single quoted'",
        'nested "quotes" inside ''string''',
        'unicøde 🚀 Café 日本語 äöü',
        '-Verbose',
        '-Debug',
        '-WhatIf',
        '--custom-flag'
    )

    $res2 = & $helperPath -ScriptPath $fixtureEchoArgs -ArgumentList $testArgs -PassThru
    Assert-Test "2.1 Execution with complex arguments succeeds (ExitCode 0)" ($res2.ExitCode -eq 0 -and $res2.Success -eq $true) "ExitCode: $($res2.ExitCode)"
    Assert-Test "2.2 Literal `$dollarVar preserved" ($res2.StdOut -match '<\$dollarVar>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.3 Literal `$100 preserved" ($res2.StdOut -match '<\$100>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.4 Literal `$env:PATH preserved" ($res2.StdOut -match '<\$env:PATH>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.5 Spaces preserved as single argument" ($res2.StdOut -match '<argument with spaces>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.6 Double quotes preserved verbatim" ($res2.StdOut -match '<"double quoted">') "StdOut: $($res2.StdOut)"
    Assert-Test "2.7 Single quotes preserved verbatim" ($res2.StdOut -match "<'single quoted'>") "StdOut: $($res2.StdOut)"
    Assert-Test "2.8 Unicode emoji and characters preserved" ($res2.StdOut -match '<unicøde 🚀 Café 日本語 äöü>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.9 Switch -Verbose passed verbatim without interception" ($res2.StdOut -match '<-Verbose>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.10 Switch -Debug passed verbatim without interception" ($res2.StdOut -match '<-Debug>') "StdOut: $($res2.StdOut)"
    Assert-Test "2.11 Flag --custom-flag passed verbatim" ($res2.StdOut -match '<--custom-flag>') "StdOut: $($res2.StdOut)"

    # ==========================================================================
    # Group 3: Hang Prevention & Closed Child Stdin
    # ==========================================================================
    Write-Host "`n[Suite 3] Hang Prevention & Closed Child Stdin" -ForegroundColor Yellow

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res31 = & $helperPath -ScriptPath $fixtureReadHost -PassThru
    $sw.Stop()
    Assert-Test "3.1 Read-Host fails fast non-zero (ExitCode 1)" ($res31.ExitCode -eq 1) "ExitCode: $($res31.ExitCode)"
    Assert-Test "3.2 Read-Host completes rapidly (< 5000ms, no interactive hang)" ($sw.ElapsedMilliseconds -lt 5000) "ElapsedMs: $($sw.ElapsedMilliseconds)"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res32 = & $helperPath -ScriptPath $fixtureConsoleRead -PassThru
    $sw.Stop()
    Assert-Test "3.3 Console.ReadLine returns EOF/null without hanging and exits 0" ($res32.ExitCode -eq 0 -and $res32.StdOut -match 'Line read: <>' -and $sw.ElapsedMilliseconds -lt 5000) "ExitCode: $($res32.ExitCode), StdOut: $($res32.StdOut)"

    $res33b = & $helperPath -ScriptPath $fixtureConsoleReadRequire -PassThru
    Assert-Test "3.4 Script requiring non-null Console.ReadLine fails fast non-zero on EOF" ($res33b.ExitCode -ne 0) "ExitCode: $($res33b.ExitCode)"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res33 = & $helperPath -ScriptPath $fixtureMandatory -PassThru
    $sw.Stop()
    Assert-Test "3.5 Missing mandatory target param fails non-zero (ExitCode 1)" ($res33.ExitCode -eq 1) "ExitCode: $($res33.ExitCode)"
    Assert-Test "3.6 Missing mandatory parameter completes rapidly (< 5000ms)" ($sw.ElapsedMilliseconds -lt 5000) "ElapsedMs: $($sw.ElapsedMilliseconds)"

    # ==========================================================================
    # Group 4: ErrorStop Wrapper & Exit Code Propagation
    # ==========================================================================
    Write-Host "`n[Suite 4] ErrorStop Wrapper & Exit Code Propagation" -ForegroundColor Yellow

    $res41 = & $helperPath -ScriptPath $fixtureTerminating -PassThru
    Assert-Test "4.1 Terminating error propagates non-zero exit code (1)" ($res41.ExitCode -eq 1) "ExitCode: $($res41.ExitCode)"

    $res42 = & $helperPath -ScriptPath $fixtureNonTerminating -PassThru
    Assert-Test "4.2 Non-terminating Write-Error with Continue override propagates non-zero exit code (1)" ($res42.ExitCode -eq 1) "ExitCode: $($res42.ExitCode)"

    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force }
    $res42b = & $helperPath -ScriptPath $fixtureWriteErrorStop -ArgumentList @($markerPath) -PassThru
    $markerCreated = Test-Path -LiteralPath $markerPath
    Assert-Test "4.2b Write-Error halts execution; inert marker NOT executed" ($res42b.ExitCode -ne 0 -and -not $markerCreated) "ExitCode: $($res42b.ExitCode), MarkerCreated: $markerCreated"
    if ($markerCreated) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }

    $res43 = & $helperPath -ScriptPath $fixtureNativeFail -PassThru
    Assert-Test "4.3 Native executable failure propagates exact exit code (42)" ($res43.ExitCode -eq 42) "ExitCode: $($res43.ExitCode)"

    $res44 = & $helperPath -ScriptPath $fixtureChildExit7 -PassThru
    Assert-Test "4.4 Explicit child script exit 7 propagates exact exit code (7)" ($res44.ExitCode -eq 7) "ExitCode: $($res44.ExitCode)"

    $res45 = & $helperPath -ScriptPath $fixtureChildExit0 -PassThru
    Assert-Test "4.5 Explicit child script exit 0 succeeds with exit code 0" ($res45.ExitCode -eq 0) "ExitCode: $($res45.ExitCode)"

    $res46 = & $helperPath -ScriptPath $fixtureNativeStderrSuccess -PassThru
    Assert-Test "4.6 Native stderr diagnostic with exit code 0 succeeds" ($res46.ExitCode -eq 0) "ExitCode: $($res46.ExitCode)"

    # 4.7 Child invokes helper PassThru on expected negative test then explicitly exits 0 (wrapper 0)
    $res47 = & $helperPath -ScriptPath $fixtureHelperNegativeThenExit0 -ArgumentList @($helperPath, (Join-Path $tempFixtureDir 'missing_nested.ps1')) -PassThru
    Assert-Test "4.7 Child invokes helper PassThru on expected negative test then explicitly exits 0 (wrapper 0)" ($res47.ExitCode -eq 0 -and $res47.Success -eq $true) "ExitCode: $($res47.ExitCode)"

    # 4.8 Child handles internal error via try/catch then explicitly exits 0 (wrapper 0)
    $res48 = & $helperPath -ScriptPath $fixtureHandleErrorThenExit0 -PassThru
    Assert-Test "4.8 Child handles internal error via try/catch then explicitly exits 0 (wrapper 0)" ($res48.ExitCode -eq 0 -and $res48.Success -eq $true) "ExitCode: $($res48.ExitCode)"

    # ==========================================================================
    # Group 5: Disappearing Variable Bug Regression & Safe Fixture
    # ==========================================================================
    Write-Host "`n[Suite 5] Disappearing Variable Regression Fixture" -ForegroundColor Yellow

    # 5.1 Former bug: nested string-built -Command interpolates and loses variable
    $buggyCommandOutput = & pwsh -NoProfile -Command "pwsh -NoProfile -Command `"`$testVal = 'disappearing_test'; Write-Host `"Result: `$testVal`"`""
    $isMatch = [bool](($buggyCommandOutput -join "`n") -match 'Result:\s*$')
    Assert-Test "5.1 Nested string-built -Command exhibits disappearing variable defect" $isMatch "Output: $buggyCommandOutput"

    # 5.2 Safe helper preserves literal variable
    $res52 = & $helperPath -ScriptPath $fixtureDisappearingVar -ArgumentList @('$targetVariableValue') -PassThru
    Assert-Test "5.2 invoke-safe-powershell preserves literal `$targetVariableValue intact" ($res52.StdOut -match '<\$targetVariableValue>') "StdOut: $($res52.StdOut)"

    # ==========================================================================
    # Group 6: Real-Time Streaming & Liveness Contract
    # ==========================================================================
    Write-Host "`n[Suite 6] Real-Time Streaming & Liveness Contract" -ForegroundColor Yellow

    $psiStream = New-Object System.Diagnostics.ProcessStartInfo
    $psiStream.FileName = 'pwsh.exe'
    $psiStream.Arguments = "-NoProfile -NonInteractive -File `"$helperPath`" -ScriptPath `"$fixtureStreamTwoOutputs`""
    $psiStream.RedirectStandardOutput = $true
    $psiStream.UseShellExecute = $false
    $psiStream.CreateNoWindow = $true

    $swStream = [System.Diagnostics.Stopwatch]::StartNew()
    $procStream = [System.Diagnostics.Process]::Start($psiStream)

    $firstLine = $procStream.StandardOutput.ReadLine()
    $firstElapsedMs = $swStream.ElapsedMilliseconds
    $runningAtFirst = (-not $procStream.HasExited)

    $secondLine = $procStream.StandardOutput.ReadLine()
    $procStream.WaitForExit()
    $totalStreamMs = $swStream.ElapsedMilliseconds

    Assert-Test "6.1 Streaming: First output observed while child running (< 1400ms)" ($firstLine -match 'FIRST_STREAM_OUTPUT' -and $runningAtFirst -and $firstElapsedMs -lt 1400) "FirstLine: $firstLine, RunningAtFirst: $runningAtFirst, ElapsedMs: $firstElapsedMs"
    Assert-Test "6.2 Streaming: Second output observed after inert delay (>= 1400ms)" ($secondLine -match 'SECOND_STREAM_OUTPUT' -and $totalStreamMs -ge 1400) "TotalMs: $totalStreamMs"
    Assert-Test "6.3 Streaming: Child exits cleanly with code 0" ($procStream.ExitCode -eq 0) "ExitCode: $($procStream.ExitCode)"

    $res64 = & $helperPath -ScriptPath $fixtureHealthyQuick -PassThru
    Assert-Test "6.4 Healthy job completes cleanly without execution deadline" ($res64.ExitCode -eq 0 -and $res64.Success -eq $true) "ExitCode: $($res64.ExitCode)"

    # ==========================================================================
    # Group 7: Multi-Engine & Documented CLI Invocation Validation (PS 7 & PS 5.1)
    # ==========================================================================
    Write-Host "`n[Suite 7] Multi-Engine & Documented CLI Invocation (PS 7 and PS 5.1)" -ForegroundColor Yellow

    # 7.1 PowerShell 7 in-script invocation
    $res71 = & $helperPath -PowerShellExe 'pwsh.exe' -ScriptPath $fixtureEchoArgs -ArgumentList @('engine_ps7', '$var7', 'unicøde 🚀') -PassThru
    Assert-Test "7.1 PowerShell 7 (pwsh) script invocation executes cleanly" ($res71.ExitCode -eq 0 -and $res71.StdOut -match '<engine_ps7>') "ExitCode: $($res71.ExitCode)"

    # 7.2 Documented CLI positional invocation via pwsh -File
    $cliOut72 = & pwsh -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureEchoArgs "cli_pos1" '$literalVar' "spaced arg" "unicøde 🚀"
    Assert-Test "7.2 Documented CLI positional invocation binds all arguments verbatim" ($LASTEXITCODE -eq 0 -and $cliOut72 -match '<cli_pos1>' -and $cliOut72 -match '<\$literalVar>' -and $cliOut72 -match '<spaced arg>' -and $cliOut72 -match '<unicøde 🚀>') "Output: $cliOut72"

    # 7.3 Documented CLI structured -ArgsJson invocation via pwsh -File
    $cliOut73 = & pwsh -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureEchoArgs -ArgsJson '["json_arg1", "$jsonVar", "spaced json"]'
    Assert-Test "7.3 Documented CLI structured -ArgsJson invocation binds all arguments verbatim" ($LASTEXITCODE -eq 0 -and $cliOut73 -match '<json_arg1>' -and $cliOut73 -match '<\$jsonVar>' -and $cliOut73 -match '<spaced json>') "Output: $cliOut73"

    $ps51Path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    if ((-not $SkipPS51) -and (Test-Path -LiteralPath $ps51Path -PathType Leaf)) {
        # 7.4 PS 5.1 in-script invocation
        $res74 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureEchoArgs -ArgumentList @('engine_ps51', '$var51', 'unicøde 🚀') -PassThru
        Assert-Test "7.4 Windows PowerShell 5.1 script invocation executes cleanly" ($res74.ExitCode -eq 0 -and $res74.StdOut -match '<engine_ps51>') "ExitCode: $($res74.ExitCode)"

        # 7.5 PS 5.1 Documented CLI positional invocation via powershell.exe -File
        $cliOut75 = & $ps51Path -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureEchoArgs "cli_ps51" '$literalVar51' "spaced arg ps51"
        Assert-Test "7.5 PS 5.1 Documented CLI positional invocation binds all arguments verbatim" ($LASTEXITCODE -eq 0 -and $cliOut75 -match '<cli_ps51>' -and $cliOut75 -match '<\$literalVar51>' -and $cliOut75 -match '<spaced arg ps51>') "Output: $cliOut75"

        # 7.6 PS 5.1 Documented CLI -ArgsJson invocation
        $cliOut76 = & $ps51Path -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureEchoArgs -ArgsJson '[\"json_ps51\", \"$ps51Var\"]'
        Assert-Test "7.6 PS 5.1 Documented CLI -ArgsJson invocation binds all arguments verbatim" ($LASTEXITCODE -eq 0 -and $cliOut76 -match '<json_ps51>' -and $cliOut76 -match '<\$ps51Var>') "Output: $cliOut76"

        $res77 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureNativeFail -PassThru
        Assert-Test "7.7 PS 5.1 propagates native failure code 42" ($res77.ExitCode -eq 42) "ExitCode: $($res77.ExitCode)"

        $res78 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureReadHost -PassThru
        Assert-Test "7.8 PS 5.1 fails fast on Read-Host with exit 1" ($res78.ExitCode -eq 1) "ExitCode: $($res78.ExitCode)"
    }

    # ==========================================================================
    # Group 8: Structured Named Parameters & Safe Splatting (PS 7 & PS 5.1)
    # ==========================================================================
    Write-Host "`n[Suite 8] Structured Named Parameters & Safe Splatting (PS 7 & PS 5.1)" -ForegroundColor Yellow

    # 8.1 In-script execution with -Parameters binding Profile and switch Enabled=$true
    $res81 = & $helperPath -ScriptPath $fixtureNamedParams -Parameters @{ Profile = 'safe'; Enabled = $true } -PassThru
    $out81 = if ($res81.StdOut) { $res81.StdOut | ConvertFrom-Json } else { $null }
    Assert-Test "8.1 In-script -Parameters binds Profile and switch Enabled=true" ($res81.ExitCode -eq 0 -and $null -ne $out81 -and $out81.Profile -eq 'safe' -and $out81.Enabled -eq $true) "Output: $($res81.StdOut)"

    # 8.2 In-script execution with -Parameters binding Profile and switch Enabled=$false
    $res82 = & $helperPath -ScriptPath $fixtureNamedParams -Parameters @{ Profile = 'safe'; Enabled = $false } -PassThru
    $out82 = if ($res82.StdOut) { $res82.StdOut | ConvertFrom-Json } else { $null }
    Assert-Test "8.2 In-script -Parameters binds Profile and switch Enabled=false" ($res82.ExitCode -eq 0 -and $null -ne $out82 -and $out82.Profile -eq 'safe' -and $out82.Enabled -eq $false) "Output: $($res82.StdOut)"

    # 8.3 In-script execution with partial parameters uses script default for omitted parameters
    $res83 = & $helperPath -ScriptPath $fixtureNamedParams -Parameters @{ Enabled = $true } -PassThru
    $out83 = if ($res83.StdOut) { $res83.StdOut | ConvertFrom-Json } else { $null }
    Assert-Test "8.3 In-script -Parameters preserves default value for omitted Profile" ($res83.ExitCode -eq 0 -and $null -ne $out83 -and $out83.Profile -eq 'DEFAULT' -and $out83.Enabled -eq $true) "Output: $($res83.StdOut)"

    # 8.4 CLI pwsh invocation with -ParametersJson binding Profile and Enabled=true
    $cliOut84 = & pwsh -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureNamedParams -ParametersJson '{"Profile":"safe","Enabled":true}'
    $out84 = if ($cliOut84) { $cliOut84 | ConvertFrom-Json } else { $null }
    Assert-Test "8.4 CLI pwsh -ParametersJson binds Profile and Enabled=true" ($LASTEXITCODE -eq 0 -and $null -ne $out84 -and $out84.Profile -eq 'safe' -and $out84.Enabled -eq $true) "Output: $cliOut84"

    # 8.5 CLI pwsh invocation with -ParametersJson binding Profile and Enabled=false
    $cliOut85 = & pwsh -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureNamedParams -ParametersJson '{"Profile":"safe","Enabled":false}'
    $out85 = if ($cliOut85) { $cliOut85 | ConvertFrom-Json } else { $null }
    Assert-Test "8.5 CLI pwsh -ParametersJson binds Profile and Enabled=false" ($LASTEXITCODE -eq 0 -and $null -ne $out85 -and $out85.Profile -eq 'safe' -and $out85.Enabled -eq $false) "Output: $cliOut85"

    # 8.6 Complex string preservation in named parameter: dollars, quotes, spaces, unicode
    $complexVal = '$my$var "double" ''single'' spaces unicøde 🚀'
    $res86 = & $helperPath -ScriptPath $fixtureNamedParams -Parameters @{ Profile = $complexVal; Enabled = $true } -PassThru
    $out86 = if ($res86.StdOut) { $res86.StdOut | ConvertFrom-Json } else { $null }
    Assert-Test "8.6 Named parameters preserve complex strings (dollars, quotes, unicode)" ($res86.ExitCode -eq 0 -and $null -ne $out86 -and $out86.Profile -eq $complexVal) "Output: $($res86.StdOut)"

    # 8.7 Positional literal semantics preservation (do NOT reinterpret '-foo' positional as named param)
    $res87 = & $helperPath -ScriptPath $fixtureNamedParams -ArgsJson '["-Profile","safe","-Enabled"]' -PassThru
    $out87 = if ($res87.StdOut) { $res87.StdOut | ConvertFrom-Json } else { $null }
    Assert-Test "8.7 Positional array splatting does not convert '-Profile' to named param" ($res87.ExitCode -eq 0 -and $null -ne $out87 -and $out87.Profile -eq '-Profile' -and $out87.Enabled -eq $false) "Output: $($res87.StdOut)"

    # 8.8 Combined named parameters (-ParametersJson) alongside positional arguments via CLI
    $cliOut88 = & pwsh -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureNamedParams -ParametersJson '{"Profile":"safe","Enabled":true}' "extra1" "extra2"
    $out88 = if ($cliOut88) { $cliOut88 | ConvertFrom-Json } else { $null }
    Assert-Test "8.8 CLI combined -ParametersJson and positional arguments bind correctly" ($LASTEXITCODE -eq 0 -and $null -ne $out88 -and $out88.Profile -eq 'safe' -and $out88.Enabled -eq $true -and $out88.Extra.Count -eq 2 -and $out88.Extra[0] -eq 'extra1') "Output: $cliOut88"

    # 8.9 Combined in-script -Parameters alongside -ArgumentList
    $res89 = & $helperPath -ScriptPath $fixtureNamedParams -Parameters @{ Profile = 'safe'; Enabled = $true } -ArgumentList @('pos1', 'pos2') -PassThru
    $out89 = if ($res89.StdOut) { $res89.StdOut | ConvertFrom-Json } else { $null }
    Assert-Test "8.9 In-script combined -Parameters and -ArgumentList bind correctly" ($res89.ExitCode -eq 0 -and $null -ne $out89 -and $out89.Profile -eq 'safe' -and $out89.Enabled -eq $true -and $out89.Extra.Count -eq 2 -and $out89.Extra[1] -eq 'pos2') "Output: $($res89.StdOut)"

    if ((-not $SkipPS51) -and (Test-Path -LiteralPath $ps51Path -PathType Leaf)) {
        # 8.10 PS 5.1 in-script -Parameters binding
        $res810 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureNamedParams -Parameters @{ Profile = 'ps51_safe'; Enabled = $true } -PassThru
        $out810 = if ($res810.StdOut) { $res810.StdOut | ConvertFrom-Json } else { $null }
        Assert-Test "8.10 PS 5.1 in-script -Parameters binds Profile and switch Enabled=true" ($res810.ExitCode -eq 0 -and $null -ne $out810 -and $out810.Profile -eq 'ps51_safe' -and $out810.Enabled -eq $true) "Output: $($res810.StdOut)"

        # 8.11 PS 5.1 in-script -Parameters switch Enabled=false
        $res811 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureNamedParams -Parameters @{ Profile = 'ps51_safe'; Enabled = $false } -PassThru
        $out811 = if ($res811.StdOut) { $res811.StdOut | ConvertFrom-Json } else { $null }
        Assert-Test "8.11 PS 5.1 in-script -Parameters binds Profile and switch Enabled=false" ($res811.ExitCode -eq 0 -and $null -ne $out811 -and $out811.Profile -eq 'ps51_safe' -and $out811.Enabled -eq $false) "Output: $($res811.StdOut)"

        # 8.12 PS 5.1 CLI invocation with -ParametersJson
        $cliOut812 = & $ps51Path -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureNamedParams -ParametersJson '{"Profile":"ps51_cli","Enabled":true}'
        $out812 = if ($cliOut812) { $cliOut812 | ConvertFrom-Json } else { $null }
        Assert-Test "8.12 PS 5.1 CLI -ParametersJson binds Profile and Enabled=true" ($LASTEXITCODE -eq 0 -and $null -ne $out812 -and $out812.Profile -eq 'ps51_cli' -and $out812.Enabled -eq $true) "Output: $cliOut812"

        # 8.13 PS 5.1 complex string preservation
        $res813 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureNamedParams -Parameters @{ Profile = $complexVal; Enabled = $true } -PassThru
        $out813 = if ($res813.StdOut) { $res813.StdOut | ConvertFrom-Json } else { $null }
        Assert-Test "8.13 PS 5.1 preserves complex strings in named parameters" ($res813.ExitCode -eq 0 -and $null -ne $out813 -and $out813.Profile -eq $complexVal) "Output: $($res813.StdOut)"

        # 8.14 PS 5.1 combined named parameters and positional arguments
        $cliOut814 = & $ps51Path -NoProfile -NonInteractive -File $helperPath -ScriptPath $fixtureNamedParams -ParametersJson '{"Profile":"ps51_comb","Enabled":true}' "extra51"
        $out814 = if ($cliOut814) { $cliOut814 | ConvertFrom-Json } else { $null }
        Assert-Test "8.14 PS 5.1 CLI combined -ParametersJson and positional args bind correctly" ($LASTEXITCODE -eq 0 -and $null -ne $out814 -and $out814.Profile -eq 'ps51_comb' -and $out814.Enabled -eq $true -and $out814.Extra.Count -eq 1) "Output: $cliOut814"
    }

    # ==========================================================================
    # Group 9: Fail-Closed Pre-Launch Validation & Marker-Absent Invariants
    # ==========================================================================
    Write-Host "`n[Suite 9] Fail-Closed Pre-Launch Validation & Marker-Absent Invariants" -ForegroundColor Yellow

    # 9.1 Malformed ArgsJson fails closed before target marker
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res91 = & $helperPath -ScriptPath $fixtureMarkerNegative -ArgsJson 'not-json' -PassThru
    $marker91 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.1 Malformed -ArgsJson ('not-json') fails closed with marker absent" ($res91.ExitCode -ne 0 -and -not $marker91) "ExitCode: $($res91.ExitCode), Marker: $marker91"
    if ($marker91) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.2 Wrong container in ArgsJson (object instead of array) fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res92 = & $helperPath -ScriptPath $fixtureMarkerNegative -ArgsJson '{"foo":"bar"}' -PassThru
    $marker92 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.2 Wrong container in -ArgsJson (object) fails closed with marker absent" ($res92.ExitCode -ne 0 -and -not $marker92) "ExitCode: $($res92.ExitCode), Marker: $marker92"
    if ($marker92) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.3 Null element in ArgsJson array fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res93 = & $helperPath -ScriptPath $fixtureMarkerNegative -ArgsJson '["valid", null]' -PassThru
    $marker93 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.3 Null element in -ArgsJson array fails closed with marker absent" ($res93.ExitCode -ne 0 -and -not $marker93) "ExitCode: $($res93.ExitCode), Marker: $marker93"
    if ($marker93) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.4 Nested array in ArgsJson fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res94 = & $helperPath -ScriptPath $fixtureMarkerNegative -ArgsJson '[[1, 2]]' -PassThru
    $marker94 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.4 Nested array in -ArgsJson fails closed with marker absent" ($res94.ExitCode -ne 0 -and -not $marker94) "ExitCode: $($res94.ExitCode), Marker: $marker94"
    if ($marker94) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.5 Malformed ParametersJson fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res95 = & $helperPath -ScriptPath $fixtureMarkerNegative -ParametersJson 'not-json' -PassThru
    $marker95 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.5 Malformed -ParametersJson ('not-json') fails closed with marker absent" ($res95.ExitCode -ne 0 -and -not $marker95) "ExitCode: $($res95.ExitCode), Marker: $marker95"
    if ($marker95) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.6 Wrong container in ParametersJson (array instead of object) fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res96 = & $helperPath -ScriptPath $fixtureMarkerNegative -ParametersJson '["array_container"]' -PassThru
    $marker96 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.6 Wrong container in -ParametersJson (array) fails closed with marker absent" ($res96.ExitCode -ne 0 -and -not $marker96) "ExitCode: $($res96.ExitCode), Marker: $marker96"
    if ($marker96) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.7 Invalid parameter key in ParametersJson fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res97 = & $helperPath -ScriptPath $fixtureMarkerNegative -ParametersJson '{"123invalid":"val"}' -PassThru
    $marker97 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.7 Invalid parameter key in -ParametersJson fails closed with marker absent" ($res97.ExitCode -ne 0 -and -not $marker97) "ExitCode: $($res97.ExitCode), Marker: $marker97"
    if ($marker97) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.8 Null parameter value in ParametersJson fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res98 = & $helperPath -ScriptPath $fixtureMarkerNegative -ParametersJson '{"Profile":null}' -PassThru
    $marker98 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.8 Null parameter value in -ParametersJson fails closed with marker absent" ($res98.ExitCode -ne 0 -and -not $marker98) "ExitCode: $($res98.ExitCode), Marker: $marker98"
    if ($marker98) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.9 Nested object parameter value in ParametersJson fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res99 = & $helperPath -ScriptPath $fixtureMarkerNegative -ParametersJson '{"Profile":{"nested":"obj"}}' -PassThru
    $marker99 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.9 Nested object value in -ParametersJson fails closed with marker absent" ($res99.ExitCode -ne 0 -and -not $marker99) "ExitCode: $($res99.ExitCode), Marker: $marker99"
    if ($marker99) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.10 Conflicting parameters: both -Parameters and -ParametersJson specified
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res910 = & $helperPath -ScriptPath $fixtureMarkerNegative -Parameters @{ Profile = 'a' } -ParametersJson '{"Profile":"b"}' -PassThru
    $marker910 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.10 Specifying both -Parameters and -ParametersJson fails closed" ($res910.ExitCode -ne 0 -and -not $marker910) "ExitCode: $($res910.ExitCode), Marker: $marker910"
    if ($marker910) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.11 Conflicting positional args: both -ArgumentList and -ArgsJson specified
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res911 = & $helperPath -ScriptPath $fixtureMarkerNegative -ArgumentList @('a') -ArgsJson '["b"]' -PassThru
    $marker911 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.11 Specifying both -ArgumentList and -ArgsJson fails closed" ($res911.ExitCode -ne 0 -and -not $marker911) "ExitCode: $($res911.ExitCode), Marker: $marker911"
    if ($marker911) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    # 9.12 Null argument in ArgumentList fails closed
    if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
    $res912 = & $helperPath -ScriptPath $fixtureMarkerNegative -ArgumentList @('valid', $null) -PassThru
    $marker912 = Test-Path -LiteralPath $negMarkerPath
    Assert-Test "9.12 Null argument in -ArgumentList fails closed with marker absent" ($res912.ExitCode -ne 0 -and -not $marker912) "ExitCode: $($res912.ExitCode), Marker: $marker912"
    if ($marker912) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }

    if ((-not $SkipPS51) -and (Test-Path -LiteralPath $ps51Path -PathType Leaf)) {
        # 9.13 PS 5.1 CLI negative test on malformed ParametersJson
        if (Test-Path -LiteralPath $negMarkerPath) { Remove-Item -LiteralPath $negMarkerPath -Force }
        $res913 = & $helperPath -PowerShellExe $ps51Path -ScriptPath $fixtureMarkerNegative -ParametersJson 'not-json' -PassThru
        $marker913 = Test-Path -LiteralPath $negMarkerPath
        Assert-Test "9.13 PS 5.1 malformed -ParametersJson fails closed with marker absent" ($res913.ExitCode -ne 0 -and -not $marker913) "ExitCode: $($res913.ExitCode), Marker: $marker913"
        if ($marker913) { Remove-Item -LiteralPath $negMarkerPath -Force -ErrorAction SilentlyContinue }
    }
}
finally {
    if (Test-Path -LiteralPath $tempFixtureDir) {
        Remove-Item -LiteralPath $tempFixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# Summary
# ==============================================================================
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor Cyan
if ($script:FailedCount -eq 0) {
    Write-Host "All Safe PowerShell contract and regression tests passed deterministically." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Failures occurred in Safe PowerShell tests." -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Yellow
    }
    exit 1
}
