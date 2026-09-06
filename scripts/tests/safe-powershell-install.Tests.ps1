# scripts/tests/safe-powershell-install.Tests.ps1
# Deterministic contract, installation, and mirror distribution tests for invoke-safe-powershell:
# - Isolated test fixture (no host deploy)
# - Failclosed on invalid or missing canonical source (invalidsource failclosed)
# - Managed distribution into all 3 workflows skill mirrors (install3mirrors)
# - Exact SHA256 helper hash match across source, mirrors, and install-state.json (helperhash)
# - Idempotence on re-install without duplicate backups or state pollution (idempotence)
# - Tamper protection and clean rollback/uninstall (rollback)
# - Canonical path resolution: repo root vs installed mirror
# - Policy contract verification in SKILL.md and validation.md with workflow anchor link

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$canonicalHelperPath = Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1'

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

function Get-FileSha256([string]$path) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
}

function New-IsolatedFixture {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("safe-ps-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $fakeRepo = Join-Path $tempDir 'repo'
    $codexHome = Join-Path $tempDir 'codex'
    $agentsHome = Join-Path $tempDir 'agents'
    $geminiHome = Join-Path $tempDir 'gemini'

    New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    New-Item -ItemType Directory -Path $agentsHome -Force | Out-Null
    New-Item -ItemType Directory -Path $geminiHome -Force | Out-Null

    # Copy minimal scripts
    $fakeScripts = Join-Path $fakeRepo 'scripts'
    New-Item -ItemType Directory -Path $fakeScripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\install.ps1') -Destination (Join-Path $fakeScripts 'install.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\backend-routing.psm1') -Destination (Join-Path $fakeScripts 'backend-routing.psm1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1') -Destination (Join-Path $fakeScripts 'invoke-safe-powershell.ps1')
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\uninstall.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\uninstall.ps1') -Destination (Join-Path $fakeScripts 'uninstall.ps1')
    }

    # Copy minimal templates
    $fakeCodex = Join-Path $fakeRepo 'codex'
    New-Item -ItemType Directory -Path $fakeCodex -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'codex\AGENTS.md') -Destination (Join-Path $fakeCodex 'AGENTS.md')

    $fakeAg = Join-Path $fakeRepo 'antigravity'
    New-Item -ItemType Directory -Path $fakeAg -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'antigravity\GEMINI.md') -Destination (Join-Path $fakeAg 'GEMINI.md')

    # Copy canonical skills
    $fakeSkills = Join-Path $fakeRepo 'skills'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\workflows') -Destination (Join-Path $fakeSkills 'workflows') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\evidence-first') -Destination (Join-Path $fakeSkills 'evidence-first') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\mcp-foundation') -Destination (Join-Path $fakeSkills 'mcp-foundation') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\codebase-memory-mcp') -Destination (Join-Path $fakeSkills 'codebase-memory-mcp') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\context7-mcp') -Destination (Join-Path $fakeSkills 'context7-mcp') -Recurse

    # Minimal config.toml in codexHome
    $configPath = Join-Path $codexHome 'config.toml'
    $initialConfig = "[features]`nmulti_agent = false`n`n[mcp_servers.subagents]`ncommand = `"node`"`nargs = [`"server.js`"]`n"
    [System.IO.File]::WriteAllText($configPath, $initialConfig, [System.Text.UTF8Encoding]::new($false))

    return @{
        Root = $tempDir
        Repo = $fakeRepo
        CodexHome = $codexHome
        AgentsHome = $agentsHome
        GeminiHome = $geminiHome
    }
}

function Remove-IsolatedFixture([hashtable]$fixture) {
    if ($fixture -and (Test-Path -LiteralPath $fixture.Root)) {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FixtureInstall([hashtable]$fixture, [string]$Profile = 'safe') {
    $installScript = Join-Path $fixture.Repo 'scripts\install.ps1'
    & $installScript -Profile $Profile `
        -CodexHome $fixture.CodexHome `
        -AgentsHome $fixture.AgentsHome `
        -AntigravityHome $fixture.GeminiHome `
        -Force
}

function Invoke-FixtureUninstall([hashtable]$fixture, [switch]$Force) {
    $uninstallScript = Join-Path $fixture.Repo 'scripts\uninstall.ps1'
    if ($Force) {
        & $uninstallScript `
            -CodexHome $fixture.CodexHome `
            -AgentsHome $fixture.AgentsHome `
            -AntigravityHome $fixture.GeminiHome `
            -Force
    } else {
        & $uninstallScript `
            -CodexHome $fixture.CodexHome `
            -AgentsHome $fixture.AgentsHome `
            -AntigravityHome $fixture.GeminiHome
    }
}

Write-Host "Running Safe PowerShell Installer and Distribution Tests..." -ForegroundColor Cyan

# ==============================================================================
# Suite 1: Preflight & Invalid Source Failclosed
# ==============================================================================
Write-Host "`n[Suite 1] Preflight & Invalid Source Failclosed" -ForegroundColor Yellow

$fix1 = New-IsolatedFixture
try {
    # Test 1.1: Missing canonical helper source throws
    $helperInRepo = Join-Path $fix1.Repo 'scripts\invoke-safe-powershell.ps1'
    Remove-Item -LiteralPath $helperInRepo -Force
    $threwMissing = $false
    try {
        Invoke-FixtureInstall -fixture $fix1
    } catch {
        if ($_.Exception.Message -match 'Canonical safe PowerShell helper is missing') {
            $threwMissing = $true
        }
    }
    Assert-Test -Name "1.1 Missing canonical helper source fails closed in preflight" -Condition $threwMissing

    # Test 1.2: Empty canonical helper source throws
    [System.IO.File]::WriteAllText($helperInRepo, "   `r`n`t", [System.Text.UTF8Encoding]::new($false))
    $threwEmpty = $false
    try {
        Invoke-FixtureInstall -fixture $fix1
    } catch {
        if ($_.Exception.Message -match 'Canonical safe PowerShell helper is empty') {
            $threwEmpty = $true
        }
    }
    Assert-Test -Name "1.2 Empty canonical helper source fails closed in preflight" -Condition $threwEmpty
} finally {
    Remove-IsolatedFixture $fix1
}

# ==============================================================================
# Suite 2 & 3: 3-Mirror Installation & Hash Verification
# ==============================================================================
Write-Host "`n[Suite 2 & 3] 3-Mirror Installation & Hash Consistency" -ForegroundColor Yellow

$fix2 = New-IsolatedFixture
try {
    # Perform fresh safe install
    Invoke-FixtureInstall -fixture $fix2

    $canonicalHash = Get-FileSha256 $canonicalHelperPath

    # Mirror 1: AgentsHome/skills/workflows/scripts/invoke-safe-powershell.ps1
    $mirror1 = Join-Path $fix2.AgentsHome 'skills\workflows\scripts\invoke-safe-powershell.ps1'
    $mirror1Exists = Test-Path -LiteralPath $mirror1 -PathType Leaf
    Assert-Test -Name "2.1 Helper installed to Mirror 1 (AgentsHome/skills/workflows)" -Condition $mirror1Exists
    $mirror1Hash = if ($mirror1Exists) { Get-FileSha256 $mirror1 } else { '' }
    Assert-Test -Name "3.1 Mirror 1 hash matches canonical source hash" -Condition ($mirror1Hash -eq $canonicalHash) -Details "Expected $canonicalHash, got $mirror1Hash"

    # Mirror 2: AntigravityHome/antigravity/skills/workflows/scripts/invoke-safe-powershell.ps1
    $mirror2 = Join-Path $fix2.GeminiHome 'antigravity\skills\workflows\scripts\invoke-safe-powershell.ps1'
    $mirror2Exists = Test-Path -LiteralPath $mirror2 -PathType Leaf
    Assert-Test -Name "2.2 Helper installed to Mirror 2 (AntigravityHome/antigravity/skills/workflows)" -Condition $mirror2Exists
    $mirror2Hash = if ($mirror2Exists) { Get-FileSha256 $mirror2 } else { '' }
    Assert-Test -Name "3.2 Mirror 2 hash matches canonical source hash" -Condition ($mirror2Hash -eq $canonicalHash) -Details "Expected $canonicalHash, got $mirror2Hash"

    # Mirror 3: AntigravityHome/config/skills/workflows/scripts/invoke-safe-powershell.ps1
    $mirror3 = Join-Path $fix2.GeminiHome 'config\skills\workflows\scripts\invoke-safe-powershell.ps1'
    $mirror3Exists = Test-Path -LiteralPath $mirror3 -PathType Leaf
    Assert-Test -Name "2.3 Helper installed to Mirror 3 (AntigravityHome/config/skills/workflows)" -Condition $mirror3Exists
    $mirror3Hash = if ($mirror3Exists) { Get-FileSha256 $mirror3 } else { '' }
    Assert-Test -Name "3.3 Mirror 3 hash matches canonical source hash" -Condition ($mirror3Hash -eq $canonicalHash) -Details "Expected $canonicalHash, got $mirror3Hash"

    # State file check
    $statePath = Join-Path $fix2.CodexHome 'codex-workflows-kit\install-state.json'
    $stateExists = Test-Path -LiteralPath $statePath -PathType Leaf
    Assert-Test -Name "3.4 install-state.json exists" -Condition $stateExists

    if ($stateExists) {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stateMap = @{}
        foreach ($f in $state.files) {
            $stateMap[[string]$f.path] = [string]$f.sha256
        }

        Assert-Test -Name "3.5 State records Mirror 1 with correct SHA256" -Condition ($stateMap.ContainsKey($mirror1) -and $stateMap[$mirror1] -eq $canonicalHash)
        Assert-Test -Name "3.6 State records Mirror 2 with correct SHA256" -Condition ($stateMap.ContainsKey($mirror2) -and $stateMap[$mirror2] -eq $canonicalHash)
        Assert-Test -Name "3.7 State records Mirror 3 with correct SHA256" -Condition ($stateMap.ContainsKey($mirror3) -and $stateMap[$mirror3] -eq $canonicalHash)
    }

    # ==============================================================================
    # Suite 4: Idempotence & Re-run
    # ==============================================================================
    Write-Host "`n[Suite 4] Idempotence & Re-run" -ForegroundColor Yellow

    $backupsDir = Join-Path $fix2.CodexHome 'backups\codex-workflows-kit'

    # Rerun install
    Invoke-FixtureInstall -fixture $fix2

    $afterMirror1Hash = Get-FileSha256 $mirror1
    $afterMirror2Hash = Get-FileSha256 $mirror2
    $afterMirror3Hash = Get-FileSha256 $mirror3
    Assert-Test -Name "4.1 Rerun preserves Mirror 1 hash identically" -Condition ($afterMirror1Hash -eq $canonicalHash)
    Assert-Test -Name "4.2 Rerun preserves Mirror 2 hash identically" -Condition ($afterMirror2Hash -eq $canonicalHash)
    Assert-Test -Name "4.3 Rerun preserves Mirror 3 hash identically" -Condition ($afterMirror3Hash -eq $canonicalHash)

    $helperBackups = @(if (Test-Path -LiteralPath $backupsDir) { Get-ChildItem -LiteralPath $backupsDir -Recurse -File -Filter "*invoke-safe-powershell*" })
    Assert-Test -Name "4.4 Rerun does not create duplicate backups for the helper" -Condition ($helperBackups.Count -eq 0)

    # ==============================================================================
    # Suite 5: Tamper Protection & Clean Uninstall
    # ==============================================================================
    Write-Host "`n[Suite 5] Tamper Protection & Clean Uninstall" -ForegroundColor Yellow

    # Tamper with Mirror 1
    [System.IO.File]::WriteAllText($mirror1, "# tampered helper content", [System.Text.UTF8Encoding]::new($false))

    # Tamper protection on uninstall: uninstaller refuses to delete modified managed file without -Force
    Invoke-FixtureUninstall -fixture $fix2
    $mirror1Preserved = Test-Path -LiteralPath $mirror1 -PathType Leaf
    Assert-Test -Name "5.1 Tampered mirror helper is preserved during uninstall without -Force" -Condition $mirror1Preserved
    $statePreserved = Test-Path -LiteralPath $statePath -PathType Leaf
    Assert-Test -Name "5.1b Install state is preserved when modified file is skipped" -Condition $statePreserved

    # Reinstall repairs tampered helper to canonical content and creates a backup of tampered file
    Invoke-FixtureInstall -fixture $fix2
    $repairedHash = Get-FileSha256 $mirror1
    Assert-Test -Name "5.1c Reinstall repairs tampered mirror helper to canonical hash" -Condition ($repairedHash -eq $canonicalHash)
    $tamperBackup = @(if (Test-Path -LiteralPath $backupsDir) { Get-ChildItem -LiteralPath $backupsDir -Recurse -File -Filter "*invoke-safe-powershell*" })
    Assert-Test -Name "5.1d Tampered helper is quarantined/backed up during reinstall" -Condition ($tamperBackup.Count -gt 0)

    # Clean Uninstall with unmodified canonical files
    Invoke-FixtureUninstall -fixture $fix2
    Assert-Test -Name "5.2 Clean uninstall removes Mirror 1 helper" -Condition (-not (Test-Path -LiteralPath $mirror1))
    Assert-Test -Name "5.3 Clean uninstall removes Mirror 2 helper" -Condition (-not (Test-Path -LiteralPath $mirror2))
    Assert-Test -Name "5.4 Clean uninstall removes Mirror 3 helper" -Condition (-not (Test-Path -LiteralPath $mirror3))

    $mirror1Parent = Split-Path -Parent $mirror1
    Assert-Test -Name "5.5 Clean uninstall removes empty scripts directory in Mirror 1" -Condition (-not (Test-Path -LiteralPath $mirror1Parent))
} finally {
    Remove-IsolatedFixture $fix2
}

# ==============================================================================
# Suite 6: Resolution Contract & Anchors
# ==============================================================================
Write-Host "`n[Suite 6] Resolution Contract & Workflow Anchors" -ForegroundColor Yellow

# Test 6.1: Repo root resolution
$repoResolved = Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1'
Assert-Test -Name "6.1 Repo root resolves scripts/invoke-safe-powershell.ps1" -Condition (Test-Path -LiteralPath $repoResolved -PathType Leaf)

# Test 6.2: Installed skill resolves its own scripts/invoke-safe-powershell.ps1 relative to skill root
$skillRelativeHelperPath = 'scripts\invoke-safe-powershell.ps1'
$fix3 = New-IsolatedFixture
try {
    Invoke-FixtureInstall -fixture $fix3
    $skillRoot = Join-Path $fix3.AgentsHome 'skills\workflows'
    $resolvedInstalledHelper = Join-Path $skillRoot $skillRelativeHelperPath
    Assert-Test -Name "6.2 Installed skill resolves own scripts/invoke-safe-powershell.ps1" -Condition (Test-Path -LiteralPath $resolvedInstalledHelper -PathType Leaf)
} finally {
    Remove-IsolatedFixture $fix3
}

# Test 6.3: SKILL.md contains mandatory routing rules
$skillText = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\SKILL.md') -Raw -Encoding UTF8
Assert-Test -Name "6.3 SKILL.md contains mandatory routing for invoke-safe-powershell.ps1" -Condition ($skillText -match 'invoke-safe-powershell\.ps1' -and $skillText -match '-NoProfile' -and $skillText -match '-NonInteractive')
Assert-Test -Name "6.4 SKILL.md contains failclosed when safe helper unavailable" -Condition ($skillText -match 'safehelper unavailable failclosed')
Assert-Test -Name "6.5 SKILL.md contains suspectedprogresswake instruction" -Condition ($skillText -match 'suspectedprogresswake not completedjob/followblocking')
Assert-Test -Name "6.6 SKILL.md preserves non-mutating / no-write authority boundary" -Condition ($skillText -match 'cannot create new or temporary script files to bypass authority')

# Test 6.7: validation.md contains safe PowerShell routing
$validationText = Get-Content -LiteralPath (Join-Path $repoRoot 'skills\workflows\references\validation.md') -Raw -Encoding UTF8
Assert-Test -Name "6.7 validation.md contains safe PowerShell routing" -Condition ($validationText -match 'invoke-safe-powershell\.ps1' -and $validationText -match 'safehelper unavailable failclosed')

# Test 6.8: Workflow anchor link: AGENTS.md and GEMINI.md link to skills/workflows/SKILL.md without duplication
$agentsText = Get-Content -LiteralPath (Join-Path $repoRoot 'codex\AGENTS.md') -Raw -Encoding UTF8
$geminiText = Get-Content -LiteralPath (Join-Path $repoRoot 'antigravity\GEMINI.md') -Raw -Encoding UTF8
Assert-Test -Name "6.8 AGENTS.md links to skills/workflows/SKILL.md via workflow anchor" -Condition ($agentsText -match 'skills/workflows/SKILL\.md')
Assert-Test -Name "6.9 GEMINI.md links to skills/workflows/SKILL.md via workflow anchor" -Condition ($geminiText -match 'skills/workflows/SKILL\.md')

# ==============================================================================
# Suite 7: Mirror Tree Validation & Negative Fixtures
# ==============================================================================
Write-Host "`n[Suite 7] Mirror Tree Validation & Negative Fixtures" -ForegroundColor Yellow

$validateScript = Join-Path $repoRoot 'scripts\validate.ps1'
$validateAst = [System.Management.Automation.Language.Parser]::ParseFile($validateScript, [ref]$null, [ref]$null)
function Load-ValidateFunctionAst($ast, [string]$functionName) {
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $functionName }, $true)
    if ($fn.Count -eq 0) {
        throw "Could not find function $functionName in AST"
    }
    Invoke-Expression ($fn[0].Extent.Text -replace '(?i)^function\s+', 'function script:')
}
Load-ValidateFunctionAst $validateAst 'Assert-SameFile'
Load-ValidateFunctionAst $validateAst 'Assert-MirrorTree'

$fix7 = New-IsolatedFixture
try {
    Invoke-FixtureInstall -fixture $fix7

    $workflowSrc = Join-Path $repoRoot 'skills\workflows'
    $evidenceSrc = Join-Path $repoRoot 'skills\evidence-first'
    $canonicalHelper = Join-Path $repoRoot 'scripts\invoke-safe-powershell.ps1'

    $m1 = Join-Path $fix7.AgentsHome 'skills\workflows'
    $m2 = Join-Path $fix7.GeminiHome 'antigravity\skills\workflows'
    $m3 = Join-Path $fix7.GeminiHome 'config\skills\workflows'

    # Test 7.1: Mirror 1 (Agents) validates GREEN against canonical source & helper
    $m1Pass = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m1 -Label 'workflows skill (agents)' -CanonicalHelper $canonicalHelper
        $m1Pass = $true
    } catch {
        $m1Pass = $false
    }
    Assert-Test -Name "7.1 Mirror 1 (Agents) tree validates GREEN against canonical source & helper" -Condition $m1Pass

    # Test 7.2: Mirror 2 (Antigravity 1) validates GREEN against canonical source & helper
    $m2Pass = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m2 -Label 'workflows skill (antigravity 1)' -CanonicalHelper $canonicalHelper
        $m2Pass = $true
    } catch {
        $m2Pass = $false
    }
    Assert-Test -Name "7.2 Mirror 2 (Antigravity 1) tree validates GREEN against canonical source & helper" -Condition $m2Pass

    # Test 7.3: Mirror 3 (Antigravity 2) validates GREEN against canonical source & helper
    $m3Pass = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m3 -Label 'workflows skill (antigravity 2)' -CanonicalHelper $canonicalHelper
        $m3Pass = $true
    } catch {
        $m3Pass = $false
    }
    Assert-Test -Name "7.3 Mirror 3 (Antigravity 2) tree validates GREEN against canonical source & helper" -Condition $m3Pass

    # Test 7.4: Full installed validator (validate.ps1 -SkipGateTests) runs GREEN on installed fixture
    $valOutput = & pwsh -NoProfile -NonInteractive -File $validateScript `
        -CodexHome $fix7.CodexHome `
        -AgentsHome $fix7.AgentsHome `
        -AntigravityHome $fix7.GeminiHome `
        -SkipGateTests 2>&1
    $valExit = $LASTEXITCODE
    Assert-Test -Name "7.4 Full installed validator passes GREEN across all 3 intact mirrors" -Condition ($valExit -eq 0)

    # --- Negative Fixtures ---

    # Test 7.5: Missing helper in Mirror 1 throws missing
    $m1Helper = Join-Path $m1 'scripts\invoke-safe-powershell.ps1'
    $helperBackupContent = [System.IO.File]::ReadAllBytes($m1Helper)
    Remove-Item -LiteralPath $m1Helper -Force
    $threwMissing = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m1 -Label 'workflows skill (agents)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'is missing') { $threwMissing = $true }
    }
    [System.IO.File]::WriteAllBytes($m1Helper, $helperBackupContent)
    Assert-Test -Name "7.5 Missing helper in Mirror 1 fails closed (throws is missing)" -Condition $threwMissing

    # Test 7.6: Missing helper in Mirror 2 throws missing
    $m2Helper = Join-Path $m2 'scripts\invoke-safe-powershell.ps1'
    Remove-Item -LiteralPath $m2Helper -Force
    $threwMissing2 = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m2 -Label 'workflows skill (antigravity 1)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'is missing') { $threwMissing2 = $true }
    }
    [System.IO.File]::WriteAllBytes($m2Helper, $helperBackupContent)
    Assert-Test -Name "7.6 Missing helper in Mirror 2 fails closed (throws is missing)" -Condition $threwMissing2

    # Test 7.7: Missing helper in Mirror 3 throws missing
    $m3Helper = Join-Path $m3 'scripts\invoke-safe-powershell.ps1'
    Remove-Item -LiteralPath $m3Helper -Force
    $threwMissing3 = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m3 -Label 'workflows skill (antigravity 2)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'is missing') { $threwMissing3 = $true }
    }
    [System.IO.File]::WriteAllBytes($m3Helper, $helperBackupContent)
    Assert-Test -Name "7.7 Missing helper in Mirror 3 fails closed (throws is missing)" -Condition $threwMissing3

    # Test 7.8: Tampered helper in Mirror 1 throws stale
    [System.IO.File]::WriteAllText($m1Helper, '# tampered helper content', [System.Text.UTF8Encoding]::new($false))
    $threwTampered = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m1 -Label 'workflows skill (agents)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'is stale') { $threwTampered = $true }
    }
    [System.IO.File]::WriteAllBytes($m1Helper, $helperBackupContent)
    Assert-Test -Name "7.8 Tampered helper in Mirror 1 fails closed (throws is stale)" -Condition $threwTampered

    # Test 7.9: Tampered helper in Mirror 2 throws stale
    [System.IO.File]::WriteAllText($m2Helper, '# tampered helper content', [System.Text.UTF8Encoding]::new($false))
    $threwTampered2 = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m2 -Label 'workflows skill (antigravity 1)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'is stale') { $threwTampered2 = $true }
    }
    [System.IO.File]::WriteAllBytes($m2Helper, $helperBackupContent)
    Assert-Test -Name "7.9 Tampered helper in Mirror 2 fails closed (throws is stale)" -Condition $threwTampered2

    # Test 7.10: Tampered helper in Mirror 3 throws stale
    [System.IO.File]::WriteAllText($m3Helper, '# tampered helper content', [System.Text.UTF8Encoding]::new($false))
    $threwTampered3 = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m3 -Label 'workflows skill (antigravity 2)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'is stale') { $threwTampered3 = $true }
    }
    [System.IO.File]::WriteAllBytes($m3Helper, $helperBackupContent)
    Assert-Test -Name "7.10 Tampered helper in Mirror 3 fails closed (throws is stale)" -Condition $threwTampered3

    # Test 7.11: Unexpected file in workflows mirror throws unexpected file
    $unexpectedFile = Join-Path $m1 'unexpected-extra-file.txt'
    [System.IO.File]::WriteAllText($unexpectedFile, 'unexpected', [System.Text.UTF8Encoding]::new($false))
    $threwUnexpected = $false
    try {
        Assert-MirrorTree -Source $workflowSrc -Installed $m1 -Label 'workflows skill (agents)' -CanonicalHelper $canonicalHelper
    } catch {
        if ($_.Exception.Message -match 'unexpected file') { $threwUnexpected = $true }
    }
    Remove-Item -LiteralPath $unexpectedFile -Force
    Assert-Test -Name "7.11 Unexpected file in workflows mirror fails closed (throws unexpected file)" -Condition $threwUnexpected

    # Test 7.12: Unexpected helper in non-workflows mirror (evidence-first) throws unexpected file
    $evidenceDest = Join-Path $fix7.AgentsHome 'skills\evidence-first'
    $evidenceHelperDir = Join-Path $evidenceDest 'scripts'
    New-Item -ItemType Directory -Path $evidenceHelperDir -Force | Out-Null
    $evidenceHelper = Join-Path $evidenceHelperDir 'invoke-safe-powershell.ps1'
    [System.IO.File]::WriteAllBytes($evidenceHelper, $helperBackupContent)
    $threwNonWorkflowUnexpected = $false
    try {
        Assert-MirrorTree -Source $evidenceSrc -Installed $evidenceDest -Label 'evidence skill (agents)'
    } catch {
        if ($_.Exception.Message -match 'unexpected file') { $threwNonWorkflowUnexpected = $true }
    }
    Remove-Item -LiteralPath $evidenceHelper -Force
    Assert-Test -Name "7.12 Unexpected helper in non-workflows mirror fails closed (throws unexpected file)" -Condition $threwNonWorkflowUnexpected

    # Test 7.13: Full validator end-to-end rejects tampered helper in installed mirror
    [System.IO.File]::WriteAllText($m1Helper, '# tampered content', [System.Text.UTF8Encoding]::new($false))
    $negValOutput = & pwsh -NoProfile -NonInteractive -File $validateScript `
        -CodexHome $fix7.CodexHome `
        -AgentsHome $fix7.AgentsHome `
        -AntigravityHome $fix7.GeminiHome `
        -SkipGateTests 2>&1
    $negValExit = $LASTEXITCODE
    [System.IO.File]::WriteAllBytes($m1Helper, $helperBackupContent)
    Assert-Test -Name "7.13 Full validator rejects tampered mirror helper (exit code 1)" -Condition ($negValExit -ne 0)

    # Test 7.14: Full validator end-to-end rejects missing helper in installed mirror
    Remove-Item -LiteralPath $m1Helper -Force
    $negValOutput2 = & pwsh -NoProfile -NonInteractive -File $validateScript `
        -CodexHome $fix7.CodexHome `
        -AgentsHome $fix7.AgentsHome `
        -AntigravityHome $fix7.GeminiHome `
        -SkipGateTests 2>&1
    $negValExit2 = $LASTEXITCODE
    [System.IO.File]::WriteAllBytes($m1Helper, $helperBackupContent)
    Assert-Test -Name "7.14 Full validator rejects missing mirror helper (exit code 1)" -Condition ($negValExit2 -ne 0)

    # Test 7.15: Full validator end-to-end rejects unexpected file in installed mirror
    [System.IO.File]::WriteAllText($unexpectedFile, 'unexpected', [System.Text.UTF8Encoding]::new($false))
    $negValOutput3 = & pwsh -NoProfile -NonInteractive -File $validateScript `
        -CodexHome $fix7.CodexHome `
        -AgentsHome $fix7.AgentsHome `
        -AntigravityHome $fix7.GeminiHome `
        -SkipGateTests 2>&1
    $negValExit3 = $LASTEXITCODE
    Remove-Item -LiteralPath $unexpectedFile -Force
    Assert-Test -Name "7.15 Full validator rejects unexpected file in mirror (exit code 1)" -Condition ($negValExit3 -ne 0)
} finally {
    Remove-IsolatedFixture $fix7
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host ("Total: {0} | Passed: {1} | Failed: {2}" -f $script:TestCount, $script:PassedCount, $script:FailedCount) -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "Failures occurred in Safe PowerShell Installation tests:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
}
exit 0
