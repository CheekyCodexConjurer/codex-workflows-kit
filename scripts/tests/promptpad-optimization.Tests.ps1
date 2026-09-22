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
    'NumpadDot' = '$workflows mode=CONSULT'
}

foreach ($key in $expectedModes.Keys) {
    $cmd = [regex]::Escape($expectedModes[$key])
    $pattern = "(?m)^$key::PastePrompt\(`"$cmd`"\)"
    Assert-Test "Preserves direct mode binding $key" ($ahkContent -match $pattern)
}

# Verify retained backend / continuation controls
$existingCtrlBindings = @{
    '^Numpad0' = '.\scripts\switch-subagent-backend.ps1 -Status'
    '^Numpad1' = '.\scripts\switch-subagent-backend.ps1 -Backend native'
    '^Numpad2' = '.\scripts\switch-subagent-backend.ps1 -Backend deepseek'
    '^Numpad3' = '.\scripts\switch-subagent-continuation.ps1 -Continuation active_follow'
    '^Numpad9' = '.\scripts\switch-subagent-continuation.ps1 -Continuation park_and_wake'
}

foreach ($key in $existingCtrlBindings.Keys) {
    $escapedKey = [regex]::Escape($key)
    $cmd = [regex]::Escape($existingCtrlBindings[$key])
    $pattern = "(?m)^$escapedKey::PastePrompt\(`"$cmd`"\)"
    Assert-Test "Preserves control binding $key" ($ahkContent -match $pattern)
}

# The retired policy and strategy controls have no hotkeys or switch scripts.
foreach ($key in @('^Numpad4', '^Numpad5', '^Numpad6', '^Numpad7', '^Numpad8')) {
    $pattern = "(?m)^$([regex]::Escape($key))::"
    Assert-Test "Retired selector hotkey $key is absent" ($ahkContent -notmatch $pattern)
}
Assert-Test "PromptPad has no retired policy or strategy command" ($ahkContent -notmatch '(?i)(delegation_policy|subagent_strategy|switch-subagent-(?:policy|strategy))')
Assert-Test "Policy switch script is retired" (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\switch-subagent-policy.ps1') -PathType Leaf))
Assert-Test "Strategy switch script is retired" (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\switch-subagent-strategy.ps1') -PathType Leaf))

# The retained scripts expose only the backend and continuation controls.
$backendSwitchContent = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\switch-subagent-backend.ps1') -Raw -Encoding UTF8
$continuationSwitchContent = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\switch-subagent-continuation.ps1') -Raw -Encoding UTF8
Assert-Test "Backend switcher has no policy or strategy parameter" ($backendSwitchContent -notmatch '(?im)^\s*\[string\]\$(?:Policy|Strategy)\b|-(?:Policy|Strategy)\s+\$')
Assert-Test "Continuation switcher has no policy or strategy parameter" ($continuationSwitchContent -notmatch '(?im)^\s*\[string\]\$(?:Policy|Strategy)\b|-(?:Policy|Strategy)\s+\$')

# Schema 6 is canonical and removes both legacy selector properties.
Assert-Test "Backend switcher writes schema 6 and drops retired state properties" ($backendSwitchContent -match '(?m)\$nextState\.schemaVersion\s*=\s*6' -and $backendSwitchContent -match "codexDelegation.*codexStrategy")
Assert-Test "Continuation switcher writes schema 6 and drops retired state properties" ($continuationSwitchContent -match '(?m)\$nextState\.schemaVersion\s*=\s*6' -and $continuationSwitchContent -match "codexDelegation.*codexStrategy")
Assert-Test "Backend switcher calls the two-selector managed-block contract" ($backendSwitchContent -match 'Set-CodexAgentsManagedBlockText[^\r\n]*-Backend\s+\$Backend\s+-Continuation')
Assert-Test "Continuation switcher calls the two-selector managed-block contract" ($continuationSwitchContent -match 'Set-CodexAgentsManagedBlockText[^\r\n]*-Backend\s+\$currentBackend\s+-Continuation')

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
# Retired public controls and active execution are rejected.
Assert-Test "Negative: retired policy command rejected" (-not (Test-PromptPadContract -Text '^Numpad4::PastePrompt(".\scripts\switch-subagent-policy.ps1 -Policy swarm")'))
Assert-Test "Negative: retired strategy command rejected" (-not (Test-PromptPadContract -Text '^Numpad7::PastePrompt(".\scripts\switch-subagent-strategy.ps1 -Strategy critical")'))
Assert-Test "PromptPad source contains no active command execution" (-not ($ahkContent -match '(?i)(?:\bRun\s*\(|\bExec\s*\()'))

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

$doctorFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-doctor-fixture-" + [Guid]::NewGuid().ToString('N'))
$doctorCodexHome = Join-Path $doctorFixtureRoot 'codex'
$doctorAgentsHome = Join-Path $doctorFixtureRoot 'agents'
$doctorAntigravityHome = Join-Path $doctorFixtureRoot 'antigravity'
$doctorStateDir = Join-Path $doctorCodexHome 'codex-workflows-kit'
$doctorStatePath = Join-Path $doctorStateDir 'install-state.json'
$doctorConfigPath = Join-Path $doctorCodexHome 'config.toml'
$doctorAgentsMdPath = Join-Path $doctorCodexHome 'AGENTS.md'
$doctorGeminiPath = Join-Path $doctorAntigravityHome 'config\GEMINI.md'
$safePowerShellPath = Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1'

try {
    New-Item -ItemType Directory -Path $doctorStateDir, $doctorAgentsHome, (Split-Path -Parent $doctorGeminiPath) -Force | Out-Null
    Import-Module (Join-Path $repoRoot 'scripts\backend-routing.psm1') -Force
    $fixtureSnapshot = Get-BackendConfigSnapshot -Text ''
    $fixtureBackendState = New-CodexBackendState -Snapshot $fixtureSnapshot -ExistingInstallState $null
    $fixtureBackendState.selected = 'native'
    Assert-CodexBackendState -BackendState $fixtureBackendState

    $doctorConfigText = Set-CodexBackendConfigText -Text '' -Backend 'native' -BackendState $fixtureBackendState
    Set-Content -LiteralPath $doctorConfigPath -Value $doctorConfigText -Encoding UTF8
    $agentsTemplateText = Get-Content -LiteralPath (Join-Path $repoRoot 'codex\AGENTS.md') -Raw -Encoding UTF8
    $agentsManagedText = Set-CodexAgentsManagedBlockText -ExistingAgentsText '' -TemplateText $agentsTemplateText -Backend 'native' -Continuation 'active_follow'
    Set-Content -LiteralPath $doctorAgentsMdPath -Value $agentsManagedText -Encoding UTF8
    $geminiTemplateText = Get-Content -LiteralPath (Join-Path $repoRoot 'antigravity\GEMINI.md') -Raw -Encoding UTF8
    $geminiManagedText = '# BEGIN CODEX-WORKFLOWS-KIT' + [Environment]::NewLine + $geminiTemplateText.Trim() + [Environment]::NewLine + '# END CODEX-WORKFLOWS-KIT' + [Environment]::NewLine
    Set-Content -LiteralPath $doctorGeminiPath -Value $geminiManagedText -Encoding UTF8
    foreach ($skillName in @('workflows', 'evidence-first', 'mcp-foundation')) {
        $skillDirectory = Join-Path $doctorAgentsHome ("skills\$skillName")
        New-Item -ItemType Directory -Path $skillDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot ("skills\$skillName\SKILL.md")) -Destination (Join-Path $skillDirectory 'SKILL.md')
    }

    $doctorState = [ordered]@{
        schemaVersion = 6
        product = 'codex-workflows-kit'
        profile = 'safe'
        installedAtUtc = [datetime]::UtcNow.ToString('o')
        files = @([ordered]@{
                path = [IO.Path]::GetFullPath($ahkPath)
                sha256 = (Get-FileHash -LiteralPath $ahkPath -Algorithm SHA256).Hash
            })
        pendingFiles = @()
        codexFeaturesPrior = [ordered]@{
            multi_agent = [ordered]@{ present = $false; value = $null }
        }
        codexBackend = $fixtureBackendState
        codexContinuation = [ordered]@{ version = 1; selected = 'active_follow' }
    }
    Set-Content -LiteralPath $doctorStatePath -Value (($doctorState | ConvertTo-Json -Depth 8) + [Environment]::NewLine) -Encoding UTF8

    $doctorParameters = [ordered]@{
        CodexHome = $doctorCodexHome
        AgentsHome = $doctorAgentsHome
        AntigravityHome = $doctorAntigravityHome
    }
    $doctorResult = & $safePowerShellPath -File $doctorPath -WorkingDirectory $repoRoot -Parameters $doctorParameters -PassThru
    $doctorExit = [int]$doctorResult.ExitCode
    $doctorRun = @($doctorResult.StdOut, $doctorResult.StdErr)
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($doctorFixtureRoot)
    if ($resolvedFixtureRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedFixtureRoot -PathType Container)) {
        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
    }
}

$doctorCombined = $doctorRun -join "`n"
$doctorFailureDetail = if ($doctorExit -eq 0) { '' } else { (($doctorCombined -split "`r?`n" | Select-Object -Last 15) -join ' | ') }
Assert-Test "Doctor executes successfully (exit code 0)" ($doctorExit -eq 0) $doctorFailureDetail

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
