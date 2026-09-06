# scripts/tests/promptpad-optimization.Tests.ps1
# Dedicated tests for PromptPad bindings and Doctor AutoHotkey v2 resolver

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

Write-Host "Running PromptPad Optimization & AHK Resolver Tests..." -ForegroundColor Cyan

# ---------------------------------------------------------
# 1. PromptPad AHK Keybindings & Routing Contract
# ---------------------------------------------------------
Write-Host "`n-- 1. PromptPad AHK Keybindings & Contract --" -ForegroundColor Yellow

$ahkPath = Join-Path $repoRoot 'ahk\codex_prompt_pad.ahk'
Assert-Test "ahk/codex_prompt_pad.ahk exists" (Test-Path -LiteralPath $ahkPath -PathType Leaf)

$ahkContent = Get-Content -LiteralPath $ahkPath -Raw -Encoding UTF8

# Verify existing direct mode bindings intact (Numpad0..9)
$expectedModes = @{
    'Numpad0' = '$workflows mode=PLAN.AUTO'
    'Numpad1' = '$workflows mode=DELIVER.AUTO'
    'Numpad2' = '$workflows mode=REVIEW'
    'Numpad3' = '$workflows mode=COMMIT'
    'Numpad4' = '$workflows mode=BUG.INV'
    'Numpad5' = '$workflows mode=BUG.FIX'
    'Numpad6' = '$workflows mode=DEBUG'
    'Numpad7' = '$workflows mode=R.A.F.V'
    'Numpad8' = '$workflows mode=REWORK'
    'Numpad9' = '$workflows mode=RESEARCH.DEEP'
}

foreach ($key in $expectedModes.Keys) {
    $cmd = [regex]::Escape($expectedModes[$key])
    $pattern = "(?m)^$key::PastePrompt\(`"$cmd`"\)"
    Assert-Test "Preserves direct mode binding $key" ($ahkContent -match $pattern)
}

# Verify existing control bindings intact
$existingCtrlBindings = @{
    '^Numpad0' = '.\scripts\switch-subagent-backend.ps1 -Status'
    '^Numpad1' = '.\scripts\switch-subagent-backend.ps1 -Backend native'
    '^Numpad2' = '.\scripts\switch-subagent-backend.ps1 -Backend deepseek'
    '^Numpad4' = '.\scripts\switch-subagent-policy.ps1 -Policy balanced'
    '^Numpad5' = '.\scripts\switch-subagent-policy.ps1 -Policy aggressive'
    '^Numpad6' = '.\scripts\switch-subagent-policy.ps1 -Policy swarm'
}

foreach ($key in $existingCtrlBindings.Keys) {
    $escapedKey = [regex]::Escape($key)
    $cmd = [regex]::Escape($existingCtrlBindings[$key])
    $pattern = "(?m)^$escapedKey::PastePrompt\(`"$cmd`"\)"
    Assert-Test "Preserves control binding $key" ($ahkContent -match $pattern)
}

# Verify four new strategy/continuation bindings
$newCtrlBindings = @{
    '^Numpad7' = '.\scripts\switch-subagent-strategy.ps1 -Strategy worker'
    '^Numpad8' = '.\scripts\switch-subagent-strategy.ps1 -Strategy critical'
    '^Numpad3' = '.\scripts\switch-subagent-continuation.ps1 -Continuation active_follow'
    '^Numpad9' = '.\scripts\switch-subagent-continuation.ps1 -Continuation park_and_wake'
}

foreach ($key in $newCtrlBindings.Keys) {
    $escapedKey = [regex]::Escape($key)
    $cmd = [regex]::Escape($newCtrlBindings[$key])
    $pattern = "(?m)^$escapedKey::PastePrompt\(`"$cmd`"\)"
    Assert-Test "Implements new control binding $key -> $($newCtrlBindings[$key])" ($ahkContent -match $pattern)
}

# Passively paste only (no Enter or automatic command execution)
$hasAutoExecute = ($ahkContent -match '(?i)(?:Send\s*["'']?\{Enter\}|Run\s|Exec\s)')
Assert-Test "PromptPad uses passive PastePrompt only (no auto-execution/Enter)" (-not $hasAutoExecute)

# Document CWD assumption matching existing shortcuts
$hasCwdDoc = ($ahkContent -match '(?i)(?:cwd|working\s+dir(?:ectory)?|repo(?:sitory)?\s+root).*(?:match|script|shortcut)')
Assert-Test "Documents repo root / CWD assumption matching existing shortcuts" $hasCwdDoc

# Budget constraint: < 60 non-comment lines
$nonCommentLines = @(($ahkContent -split "\r?\n") | Where-Object { $_ -match '\S' -and -not ($_ -match '^\s*;') })
Assert-Test "PromptPad remains compact (< 60 non-comment lines, currently $($nonCommentLines.Count))" ($nonCommentLines.Count -lt 60)

# ---------------------------------------------------------
# 2. Doctor AHK v2 Resolver & Detection Logic
# ---------------------------------------------------------
Write-Host "`n-- 2. Doctor AutoHotkey v2 Detection & Resolver --" -ForegroundColor Yellow

$doctorPath = Join-Path $repoRoot 'scripts\doctor.ps1'
Assert-Test "scripts/doctor.ps1 exists" (Test-Path -LiteralPath $doctorPath -PathType Leaf)

# Dot-source doctor to access functions
. $doctorPath

Assert-Test "Test-AutoHotkeyV2Executable function is declared" ($null -ne (Get-Command 'Test-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue))
Assert-Test "Resolve-AutoHotkeyV2Executable function is declared" ($null -ne (Get-Command 'Resolve-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue))
Assert-Test "Test-PromptPadContract function is declared" ($null -ne (Get-Command 'Test-PromptPadContract' -ErrorAction SilentlyContinue))

# Positive test: actual resolver finds real AHK v2 on host
$actualResolved = if ($null -ne (Get-Command 'Resolve-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue)) { Resolve-AutoHotkeyV2Executable } else { $null }
Assert-Test "Resolver successfully detects installed AHK on host" ($null -ne $actualResolved -and $actualResolved.IsValid)
if ($null -ne $actualResolved -and $actualResolved.IsValid) {
    Assert-Test "Resolved AHK path exists" (Test-Path -LiteralPath $actualResolved.Path -PathType Leaf)
    Assert-Test "Resolved AHK version starts with 2." ($actualResolved.Version -match '^2\.')
}

# Negative test 1: missing path
$missingResult = if ($null -ne (Get-Command 'Test-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue)) { Test-AutoHotkeyV2Executable -Path "C:\NonExistent_AHK_Path_12345\AutoHotkey64.exe" } else { [pscustomobject]@{ IsValid = $true } }
Assert-Test "Negative: missing path returns IsValid=false" (-not $missingResult.IsValid)

# Negative test 2: non-AHK binary (e.g. notepad.exe)
$notepadPath = Join-Path ([Environment]::GetFolderPath('System')) 'notepad.exe'
if (Test-Path -LiteralPath $notepadPath -PathType Leaf) {
    $notepadResult = if ($null -ne (Get-Command 'Test-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue)) { Test-AutoHotkeyV2Executable -Path $notepadPath } else { [pscustomobject]@{ IsValid = $true } }
    Assert-Test "Negative: non-AHK executable (notepad) rejected" (-not $notepadResult.IsValid)
}

# Negative test 3: arbitrary filename (text file named AutoHotkey64.exe)
$testTempDir = Join-Path ([IO.Path]::GetTempPath()) ("ahk-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTempDir -Force | Out-Null

try {
    $fakeExe = Join-Path $testTempDir 'AutoHotkey64.exe'
    Set-Content -LiteralPath $fakeExe -Value 'Not a valid PE executable, just arbitrary text claiming to be v2' -Encoding UTF8
    $fakeResult = if ($null -ne (Get-Command 'Test-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue)) { Test-AutoHotkeyV2Executable -Path $fakeExe } else { [pscustomobject]@{ IsValid = $true } }
    Assert-Test "Negative: arbitrary filename claiming v2 rejected without fileexists false-positive" (-not $fakeResult.IsValid)

    # Negative test 4: malformed shortcut (.lnk with corrupted bytes)
    $corruptLnk = Join-Path $testTempDir 'Corrupt.lnk'
    Set-Content -LiteralPath $corruptLnk -Value 'Corrupted shortcut bytes' -Encoding UTF8

    $scInfo = Get-ShortcutInfo -Path $corruptLnk
    Assert-Test "Negative: corrupted shortcut handled safely by Get-ShortcutInfo without crash" ($null -eq $scInfo -or [string]::IsNullOrWhiteSpace($scInfo.TargetPath))

    $resFromCorrupt = if ($null -ne (Get-Command 'Resolve-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue)) { Resolve-AutoHotkeyV2Executable -ShortcutPath $corruptLnk -CandidatePaths @() } else { [pscustomobject]@{ IsValid = $true } }
    Assert-Test "Negative: resolver with corrupt shortcut and empty candidates returns IsValid=false" (-not $resFromCorrupt.IsValid)

    # Negative test 5: shortcut pointing to non-v2 binary
    $nonV2Lnk = Join-Path $testTempDir 'NonV2.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $shortcutObj = $wsh.CreateShortcut($nonV2Lnk)
    $shortcutObj.TargetPath = $fakeExe
    $shortcutObj.Save()

    $resFromNonV2 = if ($null -ne (Get-Command 'Resolve-AutoHotkeyV2Executable' -ErrorAction SilentlyContinue)) { Resolve-AutoHotkeyV2Executable -ShortcutPath $nonV2Lnk -CandidatePaths @() } else { [pscustomobject]@{ IsValid = $true } }
    Assert-Test "Negative: shortcut pointing to fake/non-v2 exe rejected by resolver" (-not $resFromNonV2.IsValid)

    # Positive test with explicit shortcut pointing to actual AHK
    if ($null -ne $actualResolved -and $actualResolved.IsValid) {
        $validLnk = Join-Path $testTempDir 'Valid.lnk'
        $validShortcut = $wsh.CreateShortcut($validLnk)
        $validShortcut.TargetPath = $actualResolved.Path
        $validShortcut.Save()

        $resFromValid = Resolve-AutoHotkeyV2Executable -ShortcutPath $validLnk -CandidatePaths @()
        Assert-Test "Positive: resolver resolves valid shortcut target" ($resFromValid.IsValid -and $resFromValid.Source -eq 'ShortcutTarget')
    }
}
finally {
    if (Test-Path -LiteralPath $testTempDir) {
        Remove-Item -LiteralPath $testTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------
# 2.1 PromptPad Token Scanning & Role Injection Contract
# ---------------------------------------------------------
Write-Host "`n-- 2.1 PromptPad Contract & Token Scanning Tests --" -ForegroundColor Yellow

# Positive tests: canonical commands allowed
Assert-Test "Positive: repo ahk content satisfies PromptPad contract" (Test-PromptPadContract -Text $ahkContent)
Assert-Test "Positive: exact canonical passive switch-subagent-strategy -Strategy worker allowed" (Test-PromptPadContract -Text '^Numpad7::PastePrompt(".\scripts\switch-subagent-strategy.ps1 -Strategy worker")')
Assert-Test "Positive: canonical switch command with slash allowed" (Test-PromptPadContract -Text '^Numpad7::PastePrompt("./scripts/switch-subagent-strategy.ps1 -Strategy worker")')
Assert-Test "Positive: canonical switch command with single quotes allowed" (Test-PromptPadContract -Text "^Numpad7::PastePrompt('.\scripts\switch-subagent-strategy.ps1 -Strategy worker')")

# Negative tests: worker role injection and active execution rejected
Assert-Test "Negative: worker direct prompt rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("worker do this")'))
Assert-Test "Negative: worker role parameter injection rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("$workflows role=worker")'))
Assert-Test "Negative: non-passive worker execution rejected" (-not (Test-PromptPadContract -Text 'Run(".\scripts\switch-subagent-strategy.ps1 -Strategy worker")'))
Assert-Test "Negative: worker comment rejected" (-not (Test-PromptPadContract -Text "; worker comment`n^Numpad7::PastePrompt(`".\scripts\switch-subagent-strategy.ps1 -Strategy worker`")"))
Assert-Test "Negative: multiple worker tokens rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt(".\scripts\switch-subagent-strategy.ps1 -Strategy worker and worker")'))

# Negative tests: other banned prompt tokens rejected
Assert-Test "Negative: writer token rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("writer")'))
Assert-Test "Negative: scout token rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("scout")'))
Assert-Test "Negative: researcher token rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("researcher")'))
Assert-Test "Negative: reviewer token rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("reviewer")'))
Assert-Test "Negative: reader token rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt("reader")'))
Assert-Test "Negative: PromptPadNative rejected" (-not (Test-PromptPadContract -Text 'PromptPadNative = true'))
Assert-Test "Negative: BackendOverrideText rejected" (-not (Test-PromptPadContract -Text 'BackendOverrideText'))
Assert-Test "Negative: WorkflowPrompt rejected" (-not (Test-PromptPadContract -Text 'WorkflowPrompt'))

# ---------------------------------------------------------
# 3. Doctor Output Contract & Read-Only Invariance
# ---------------------------------------------------------
Write-Host "`n-- 3. Doctor Output Contract & Read-Only Invariance --" -ForegroundColor Yellow

$doctorRun = & powershell -NoProfile -ExecutionPolicy Bypass -File $doctorPath 2>&1
$doctorExit = $LASTEXITCODE

Assert-Test "Doctor executes successfully (exit code 0)" ($doctorExit -eq 0)
$doctorCombined = $doctorRun -join "`n"

Assert-Test "Doctor output contains verified AutoHotkey v2 check" ($doctorCombined -match '(?m)\[OK\]\s+AutoHotkey v2:')
Assert-Test "Doctor output does not emit AutoHotkey v2 warning" ($doctorCombined -notmatch '(?m)\[WARN\]\s+AutoHotkey v2:')
Assert-Test "Doctor output does not emit Managed AGENTS template warning" ($doctorCombined -notmatch '(?m)\[WARN\]\s+Managed AGENTS template:')
Assert-Test "Doctor output contains verified Prompt Pad contract check" ($doctorCombined -match '(?m)\[OK\]\s+Prompt Pad contract:')

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
    Write-Host "All PromptPad optimization & AHK resolver tests passed!" -ForegroundColor Green
    exit 0
}
