# scripts/tests/gemini-legacy-migration.Tests.ps1
# Tests for narrow legacy GEMINI.md footer migration and doctor diagnostic:
# 1. Doctor diagnoses unmanaged footer conflicts (native models, review veto, maintain-mcps repair) without mutation
# 2. Migration strips ONLY the 3 proven conflicts, preserving all personal preferences and arbitrary user content
# 3. Migration creates explicit timestamped backup before modifying
# 4. Idempotence: re-running migration on clean file produces identical bytes without new backups
# 5. Integration with install.ps1: opt-in migration flag (-MigrateLegacyGemini)
# 6. Safety baseline: install.ps1 without opt-in preserves existing footer untouched
# 7. Doctor reports GREEN (no conflicts) after migration

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$RepoRootOverride = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = if ($RepoRootOverride) { [IO.Path]::GetFullPath($RepoRootOverride) } else { [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..')) }
$doctorScript = Join-Path $repoRoot 'scripts\doctor.ps1'
$migratorScript = Join-Path $repoRoot 'scripts\migrate-legacy-gemini.ps1'
$installerScript = Join-Path $repoRoot 'scripts\install.ps1'

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

function New-IsolatedFixture {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gemini-migrate-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $codexHome = Join-Path $tempDir 'codex'
    $agentsHome = Join-Path $tempDir 'agents'
    $antigravityHome = Join-Path $tempDir 'antigravity'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    New-Item -ItemType Directory -Path $agentsHome -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $antigravityHome 'config') -Force | Out-Null

    $configContent = "[features]`nmulti_agent = false`n`n[mcp_servers.deepseek-subagent]`ncommand = `"pwsh`"`n"
    Set-Content -LiteralPath (Join-Path $codexHome 'config.toml') -Value $configContent -Encoding UTF8

    & pwsh -NoProfile -NonInteractive -File $installerScript `
        -CodexHome $codexHome `
        -AgentsHome $agentsHome `
        -AntigravityHome $antigravityHome 2>&1 | Out-Null

    return @{
        Root = $tempDir
        CodexHome = $codexHome
        AgentsHome = $agentsHome
        AntigravityHome = $antigravityHome
        GeminiPath = Join-Path $antigravityHome 'config\GEMINI.md'
    }
}

# Read canonical footer with conflicts from host file
$canonicalSourcePath = 'C:\Users\mathe\.gemini\config\GEMINI.md'
$endMarker = '# END CODEX-WORKFLOWS-KIT'
$canonicalRaw = Get-Content -LiteralPath $canonicalSourcePath -Raw -Encoding UTF8
$endIdx = $canonicalRaw.IndexOf($endMarker, [StringComparison]::Ordinal)
$canonicalFooterWithConflicts = $canonicalRaw.Substring($endIdx + $endMarker.Length).TrimStart([char[]]@([char]13, [char]10))

$managedHeader = (Get-Content -LiteralPath (Join-Path $repoRoot 'antigravity\GEMINI.md') -Raw -Encoding UTF8).Trim()
$nl = [Environment]::NewLine
$managedBlock = "# BEGIN CODEX-WORKFLOWS-KIT$nl$managedHeader$nl# END CODEX-WORKFLOWS-KIT$nl"

Write-Host 'Running Gemini Legacy Footer Migration Tests...' -ForegroundColor Cyan

# -------------------------------------------------------------
# Suite 1: Doctor Diagnoses Unmanaged Conflicts
# -------------------------------------------------------------
Write-Host "`n-- Suite 1: Doctor Diagnoses Unmanaged Conflicts --" -ForegroundColor Yellow
$fixture1 = New-IsolatedFixture
try {
    $fullGemini = $managedBlock + $canonicalFooterWithConflicts
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($fixture1.GeminiPath, $fullGemini, $utf8NoBom)
    $beforeDoctor = [IO.File]::ReadAllText($fixture1.GeminiPath, [System.Text.Encoding]::UTF8)

    $doctorOut = & pwsh -NoProfile -NonInteractive -File $doctorScript `
        -CodexHome $fixture1.CodexHome `
        -AgentsHome $fixture1.AgentsHome `
        -AntigravityHome $fixture1.AntigravityHome 2>&1 | Out-String

    Assert-Test '1.1 Doctor reports unmanaged GEMINI conflicts check' `
        ($doctorOut -match 'GEMINI unmanaged conflicts') `
        "Doctor output did not mention 'GEMINI unmanaged conflicts': $doctorOut"

    Assert-Test '1.2 Doctor identifies native models conflict' `
        ($doctorOut -match 'native subagent models/roles') `
        'Doctor output did not identify native models conflict'

    Assert-Test '1.3 Doctor identifies delivery review veto conflict' `
        ($doctorOut -match 'delivery review veto') `
        'Doctor output did not identify review veto conflict'

    Assert-Test '1.4 Doctor identifies maintain-mcps repair conflict' `
        ($doctorOut -match 'maintain-mcps repair') `
        'Doctor output did not identify maintain-mcps repair conflict'

    $afterDoctor = Get-Content -LiteralPath $fixture1.GeminiPath -Raw -Encoding UTF8
    Assert-Test '1.5 Doctor is strictly non-mutating (file bytes unchanged)' `
        ($afterDoctor -ceq $beforeDoctor) `
        'Doctor mutated GEMINI.md'
} finally {
    Remove-Item -LiteralPath $fixture1.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Suite 2: Migration Helper Execution, Narrow Removal & Backup
# -------------------------------------------------------------
Write-Host "`n-- Suite 2: Migration Helper Execution, Narrow Removal & Backup --" -ForegroundColor Yellow
$fixture2 = New-IsolatedFixture
try {
    $extraUserText = $nl + "# User Personal Notes" + $nl + "- Custom project bookmark: my-project" + $nl + $nl + $nl + $nl + "# Section With Blanklines" + $nl + $nl + $nl + $nl + "Content after blanklines" + $nl
    $fullGemini2 = $managedBlock + $canonicalFooterWithConflicts + $extraUserText
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($fixture2.GeminiPath, $fullGemini2, $utf8NoBom)

    Assert-Test '2.0 Migration helper script exists' `
        (Test-Path -LiteralPath $migratorScript -PathType Leaf) `
        "Missing migrator script: $migratorScript"

    if (Test-Path -LiteralPath $migratorScript -PathType Leaf) {
        $migrateOut = & pwsh -NoProfile -NonInteractive -File $migratorScript `
            -GeminiPath $fixture2.GeminiPath 2>&1 | Out-String

        $migratedContent = Get-Content -LiteralPath $fixture2.GeminiPath -Raw -Encoding UTF8

        Assert-Test '2.1 Conflict 1 removed: 5.6 Sol Medium rule' `
            ($migratedContent -notmatch '5\.6 Sol Medium') `
            '5.6 Sol Medium was not removed'

        Assert-Test '2.2 Conflict 1 removed: custom roles scout/reviewer/researcher restriction' `
            ($migratedContent -notmatch 'Every read-only spawn must select the exact custom role') `
            'Custom role restriction was not removed'

        Assert-Test '2.3 Conflict 1 removed: omit fork_context and model' `
            ($migratedContent -notmatch 'Custom-role spawns must omit') `
            'Omit fork_context rule was not removed'

        Assert-Test '2.4 Conflict 1 removed: transient retry with same explicit role' `
            ($migratedContent -notmatch 'transient launch, stream, or account-availability error') `
            'Transient retry rule was not removed'

        Assert-Test '2.5 Conflict 2 removed: independent reviewers start only after all phases frozen' `
            ($migratedContent -notmatch 'independent reviewers start only after all approved phases are integrated and frozen') `
            'Review veto rule was not removed'

        Assert-Test '2.6 Conflict 2 removed: do not spawn reviewers per phase' `
            ($migratedContent -notmatch 'do not spawn reviewers per phase') `
            'Do not spawn reviewers per phase was not removed'

        Assert-Test '2.7 Conflict 3 removed: openaiDeveloperDocs baseline' `
            ($migratedContent -notmatch '(?m)^\s*-\s*Allowlisted baseline:.*openaiDeveloperDocs') `
            'openaiDeveloperDocs allowlist baseline was not removed'

        Assert-Test '2.8 Conflict 3 removed: maintain-mcps.ps1 -Mode Repair' `
            ($migratedContent -notmatch 'maintain-mcps\.ps1\s+-Mode\s+Repair') `
            'maintain-mcps.ps1 -Mode Repair was not removed'

        Assert-Test '2.9 Preserved: personal persona and tone instructions' `
            ($migratedContent -match 'Responda sempre em texto corrido') `
            'Tone persona was lost'

        Assert-Test '2.10 Preserved: compact syntax definition' `
            ($migratedContent -match 'Compact syntax: `⇢`') `
            'Compact syntax was lost'

        Assert-Test '2.11 Preserved: Global rules block' `
            ($migratedContent -match 'Global rules:' -and $migratedContent -match 'Route by task\+risk\+blast before work') `
            'Global rules were lost'

        Assert-Test '2.12 Preserved: Evidence & uncertainty block' `
            ($migratedContent -match 'Evidence & uncertainty:' -and $migratedContent -match 'evidence-first') `
            'Evidence & uncertainty rules were lost'

        Assert-Test '2.13 Preserved: Subagents non-conflicting core rules' `
            ($migratedContent -match 'Main agent owns critical path' -and `
             $migratedContent -match 'Use subagents only when they improve wall-clock time' -and `
             $migratedContent -match 'Writable workers require claim-map') `
            'Non-conflicting Subagents rules were lost'

        Assert-Test '2.14 Preserved: CodeGraph guidelines' `
            ($migratedContent -match 'CodeGraph:' -and $migratedContent -match 'cg-worthy') `
            'CodeGraph rules were lost'

        Assert-Test '2.15 Preserved: Audit TTL rule' `
            ($migratedContent -match 'Session-start audit uses a 24-hour TTL') `
            'Audit TTL rule was lost'

        Assert-Test '2.16 Preserved: Extra user custom text' `
            ($migratedContent -match 'Custom project bookmark: my-project') `
            'Arbitrary user text was lost'

        Assert-Test '2.17 Preserved: Context7 and OpenAI Developer Docs benign guidance rule' `
            ($migratedContent -match 'Use Context7 for current library.*OpenAI Developer Docs') `
            'Benign docs guidance rule was unexpectedly removed'

        Assert-Test '2.18 Preserved: blank lines in user sections are not collapsed' `
            ($migratedContent -match '(\r?\n){4}# Section With Blanklines(\r?\n){4}Content after blanklines') `
            'Unrelated blank lines were collapsed or modified'

        $backupFiles = @(Get-ChildItem -Path (Split-Path -Parent $fixture2.GeminiPath) -Filter 'GEMINI.md.bak*' -File)
        Assert-Test '2.19 Backup file was created before migration' `
            ($backupFiles.Count -ge 1) `
            'No backup file found matching GEMINI.md.bak*'

        if ($backupFiles.Count -ge 1) {
            $backupContent = Get-Content -LiteralPath $backupFiles[0].FullName -Raw -Encoding UTF8
            Assert-Test '2.20 Backup contains original unmigrated content' `
                ($backupContent -ceq $fullGemini2) `
                'Backup content does not match original pre-migration content'
        }
    }
} finally {
    Remove-Item -LiteralPath $fixture2.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Suite 3: Idempotence & Safe Re-run
# -------------------------------------------------------------
Write-Host "`n-- Suite 3: Idempotence & Safe Re-run --" -ForegroundColor Yellow
$fixture3 = New-IsolatedFixture
try {
    $fullGemini3 = $managedBlock + $canonicalFooterWithConflicts
    Set-Content -LiteralPath $fixture3.GeminiPath -Value $fullGemini3 -Encoding UTF8

    if (Test-Path -LiteralPath $migratorScript -PathType Leaf) {
        & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture3.GeminiPath | Out-Null
        $firstRunContent = Get-Content -LiteralPath $fixture3.GeminiPath -Raw -Encoding UTF8
        $backupsAfterFirst = @(Get-ChildItem -Path (Split-Path -Parent $fixture3.GeminiPath) -Filter 'GEMINI.md.bak*' -File).Count

        & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture3.GeminiPath | Out-Null
        $secondRunContent = Get-Content -LiteralPath $fixture3.GeminiPath -Raw -Encoding UTF8
        $backupsAfterSecond = @(Get-ChildItem -Path (Split-Path -Parent $fixture3.GeminiPath) -Filter 'GEMINI.md.bak*' -File).Count

        Assert-Test '3.1 Idempotence: content identical after second run' `
            ($firstRunContent -ceq $secondRunContent) `
            'Content changed on second migration run'

        Assert-Test '3.2 No-op: no redundant backup created when file already clean' `
            ($backupsAfterFirst -eq $backupsAfterSecond) `
            'Extra backup was created on second run'
    }
} finally {
    Remove-Item -LiteralPath $fixture3.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Suite 4: Doctor GREEN after Migration
# -------------------------------------------------------------
Write-Host "`n-- Suite 4: Doctor GREEN after Migration --" -ForegroundColor Yellow
$fixture4 = New-IsolatedFixture
try {
    $fullGemini4 = $managedBlock + $canonicalFooterWithConflicts
    Set-Content -LiteralPath $fixture4.GeminiPath -Value $fullGemini4 -Encoding UTF8

    if (Test-Path -LiteralPath $migratorScript -PathType Leaf) {
        & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture4.GeminiPath | Out-Null

        $doctorOutAfter = & pwsh -NoProfile -NonInteractive -File $doctorScript `
            -CodexHome $fixture4.CodexHome `
            -AgentsHome $fixture4.AgentsHome `
            -AntigravityHome $fixture4.AntigravityHome 2>&1 | Out-String

        Assert-Test '4.1 Doctor passes GEMINI unmanaged conflicts check after migration' `
            ($doctorOutAfter -match '\[OK\]\s+GEMINI unmanaged conflicts') `
            "Doctor did not report [OK] for GEMINI unmanaged conflicts: $doctorOutAfter"
    }
} finally {
    Remove-Item -LiteralPath $fixture4.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Suite 5: Integration with install.ps1 Opt-in Flag
# -------------------------------------------------------------
Write-Host "`n-- Suite 5: Integration with install.ps1 Opt-in Flag --" -ForegroundColor Yellow
$fixture5 = New-IsolatedFixture
try {
    $initialUnmanaged = $canonicalFooterWithConflicts
    Set-Content -LiteralPath $fixture5.GeminiPath -Value $initialUnmanaged -Encoding UTF8

    & pwsh -NoProfile -NonInteractive -File $installerScript `
        -CodexHome $fixture5.CodexHome `
        -AgentsHome $fixture5.AgentsHome `
        -AntigravityHome $fixture5.AntigravityHome `
        -MigrateLegacyGemini 2>&1 | Out-Null

    $installedWithOptIn = Get-Content -LiteralPath $fixture5.GeminiPath -Raw -Encoding UTF8

    Assert-Test '5.1 install.ps1 with -MigrateLegacyGemini installs managed block' `
        ($installedWithOptIn -match '# BEGIN CODEX-WORKFLOWS-KIT') `
        'Managed block was not installed'

    Assert-Test '5.2 install.ps1 with -MigrateLegacyGemini removes 5.6 Sol Medium' `
        ($installedWithOptIn -notmatch '5\.6 Sol Medium') `
        '5.6 Sol Medium remained after install with opt-in'

    Assert-Test '5.3 install.ps1 with -MigrateLegacyGemini removes review veto' `
        ($installedWithOptIn -notmatch 'independent reviewers start only after all approved phases are integrated and frozen') `
        'Review veto remained after install with opt-in'

    Assert-Test '5.4 install.ps1 with -MigrateLegacyGemini removes maintain-mcps Repair' `
        ($installedWithOptIn -notmatch 'maintain-mcps\.ps1\s+-Mode\s+Repair') `
        'maintain-mcps Repair remained after install with opt-in'

    Assert-Test '5.5 install.ps1 with -MigrateLegacyGemini preserves tone persona' `
        ($installedWithOptIn -match 'Responda sempre em texto corrido') `
        'Tone persona was lost during install'
} finally {
    Remove-Item -LiteralPath $fixture5.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Suite 6: install.ps1 without Opt-in Preserves Footer (Safety Baseline)
# -------------------------------------------------------------
Write-Host "`n-- Suite 6: install.ps1 without Opt-in Preserves Footer --" -ForegroundColor Yellow
$fixture6 = New-IsolatedFixture
try {
    $initialUnmanaged6 = $canonicalFooterWithConflicts
    Set-Content -LiteralPath $fixture6.GeminiPath -Value $initialUnmanaged6 -Encoding UTF8

    & pwsh -NoProfile -NonInteractive -File $installerScript `
        -CodexHome $fixture6.CodexHome `
        -AgentsHome $fixture6.AgentsHome `
        -AntigravityHome $fixture6.AntigravityHome 2>&1 | Out-Null

    $installedWithoutOptIn = Get-Content -LiteralPath $fixture6.GeminiPath -Raw -Encoding UTF8

    Assert-Test '6.1 install.ps1 without -MigrateLegacyGemini preserves unmanaged footer' `
        ($installedWithoutOptIn -match '5\.6 Sol Medium' -and $installedWithoutOptIn -match 'openaiDeveloperDocs') `
        'Unmanaged footer was unexpectedly altered without opt-in'
} finally {
    Remove-Item -LiteralPath $fixture6.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Suite 7: Backup Byte-Exactness, BOM Preservation, Collision Safety, Marker Enforcement, and ShouldProcess
# -------------------------------------------------------------
Write-Host "`n-- Suite 7: Backup Byte-Exactness, BOM Preservation & Safety --" -ForegroundColor Yellow
$fixture7 = New-IsolatedFixture
try {
    # 7.1 Byte-exact and BOM preservation in backup
    $fullGemini7 = $managedBlock + $canonicalFooterWithConflicts
    $utf8EncodingWithBom = New-Object System.Text.UTF8Encoding($true)
    $originalBytesWithBom = $utf8EncodingWithBom.GetPreamble() + $utf8EncodingWithBom.GetBytes($fullGemini7)
    [IO.File]::WriteAllBytes($fixture7.GeminiPath, $originalBytesWithBom)

    & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture7.GeminiPath | Out-Null
    $backupFiles7 = @(Get-ChildItem -Path (Split-Path -Parent $fixture7.GeminiPath) -Filter 'GEMINI.md.bak*' -File)
    Assert-Test '7.1 Backup file created for BOM test' ($backupFiles7.Count -ge 1) 'No backup file created'
    if ($backupFiles7.Count -ge 1) {
        $backupBytes = [IO.File]::ReadAllBytes($backupFiles7[0].FullName)
        $bomPreserved = [System.Linq.Enumerable]::SequenceEqual([byte[]]$originalBytesWithBom, [byte[]]$backupBytes)
        Assert-Test '7.2 Backup preserves exact bytes and BOM' $bomPreserved 'Backup bytes or BOM differed from original'
    }

    # 7.3 Backup collision safety (não sobrescrever)
    $fixture7b = New-IsolatedFixture
    try {
        $fullGemini7b = $managedBlock + $canonicalFooterWithConflicts
        [IO.File]::WriteAllText($fixture7b.GeminiPath, $fullGemini7b, (New-Object System.Text.UTF8Encoding($false)))
        $leafName = Split-Path -Leaf $fixture7b.GeminiPath
        $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $collisionBackupPath = Join-Path (Split-Path -Parent $fixture7b.GeminiPath) "$leafName.bak.$timestamp"
        [IO.File]::WriteAllText($collisionBackupPath, 'SENTINEL_EXISTING_BACKUP_DO_NOT_OVERWRITE', [System.Text.Encoding]::UTF8)

        & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture7b.GeminiPath | Out-Null

        $sentinelAfter = [IO.File]::ReadAllText($collisionBackupPath, [System.Text.Encoding]::UTF8)
        Assert-Test '7.3 Existing backup was not overwritten on collision' `
            ($sentinelAfter -eq 'SENTINEL_EXISTING_BACKUP_DO_NOT_OVERWRITE') `
            'Existing backup was overwritten on timestamp collision'

        $allBackups7b = @(Get-ChildItem -Path (Split-Path -Parent $fixture7b.GeminiPath) -Filter "$leafName.bak.*" -File)
        Assert-Test '7.4 Distinct collision backup file was created' `
            ($allBackups7b.Count -ge 2) `
            "Expected at least 2 backup files (sentinel + new backup), found $($allBackups7b.Count)"
    } finally {
        Remove-Item -LiteralPath $fixture7b.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 7.5 Refusal to remove footer without valid markers (fail-closed)
    $fixture7c = New-IsolatedFixture
    try {
        $unmarkedContent = $canonicalFooterWithConflicts
        [IO.File]::WriteAllText($fixture7c.GeminiPath, $unmarkedContent, (New-Object System.Text.UTF8Encoding($false)))

        $resMissing = & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture7c.GeminiPath 2>&1
        $missingMarkersFailed = ($LASTEXITCODE -ne 0 -or $resMissing -match 'valid CODEX-WORKFLOWS-KIT markers')
        $contentAfterMissing = [IO.File]::ReadAllText($fixture7c.GeminiPath, [System.Text.Encoding]::UTF8)

        Assert-Test '7.5 Migration fails closed when markers are completely missing' `
            $missingMarkersFailed `
            'Migration did not fail when markers were missing'

        Assert-Test '7.6 File without markers is left unmodified' `
            ($contentAfterMissing -ceq $unmarkedContent) `
            'Unmarked file was unexpectedly modified'

        # Broken marker: BEGIN present without END
        $brokenContent = "# BEGIN CODEX-WORKFLOWS-KIT`n" + $canonicalFooterWithConflicts
        [IO.File]::WriteAllText($fixture7c.GeminiPath, $brokenContent, (New-Object System.Text.UTF8Encoding($false)))

        $resBroken = & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture7c.GeminiPath 2>&1
        $brokenMarkersFailed = ($LASTEXITCODE -ne 0 -or $resBroken -match 'valid CODEX-WORKFLOWS-KIT markers')
        $contentAfterBroken = [IO.File]::ReadAllText($fixture7c.GeminiPath, [System.Text.Encoding]::UTF8)

        Assert-Test '7.7 Migration fails closed when markers are broken/incomplete' `
            $brokenMarkersFailed `
            'Migration did not fail when markers were broken'

        Assert-Test '7.8 File with broken markers is left unmodified' `
            ($contentAfterBroken -ceq $brokenContent) `
            'File with broken markers was unexpectedly modified'
    } finally {
        Remove-Item -LiteralPath $fixture7c.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 7.9 Effective SupportsShouldProcess / ShouldProcess support (-WhatIf)
    $fixture7d = New-IsolatedFixture
    try {
        $fullGemini7d = $managedBlock + $canonicalFooterWithConflicts
        [IO.File]::WriteAllText($fixture7d.GeminiPath, $fullGemini7d, (New-Object System.Text.UTF8Encoding($false)))

        & pwsh -NoProfile -NonInteractive -File $migratorScript -GeminiPath $fixture7d.GeminiPath -WhatIf | Out-Null

        $backupsAfterWhatIf = @(Get-ChildItem -Path (Split-Path -Parent $fixture7d.GeminiPath) -Filter 'GEMINI.md.bak*' -File)
        $contentAfterWhatIf = [IO.File]::ReadAllText($fixture7d.GeminiPath, [System.Text.Encoding]::UTF8)

        Assert-Test '7.9 WhatIf creates no backup files' `
            ($backupsAfterWhatIf.Count -eq 0) `
            'Backup file was created during WhatIf'

        Assert-Test '7.10 WhatIf leaves target file unmodified' `
            ($contentAfterWhatIf -ceq $fullGemini7d) `
            'Target file was modified during WhatIf'
    } finally {
        Remove-Item -LiteralPath $fixture7d.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath $fixture7.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# Summary
# -------------------------------------------------------------
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount"
if ($script:FailedCount -gt 0) {
    Write-Host 'Failures occurred in Gemini legacy footer migration tests:' -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host 'All Gemini legacy footer migration tests passed deterministically.' -ForegroundColor Green
    exit 0
}
