# scripts/tests/free-mcp-mirrors.Tests.ps1
# Deterministic unit and integration tests for codebase-memory-mcp and context7-mcp managed mirrors

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

function New-MirrorFixture {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-mirror-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $fakeRepo = Join-Path $tempDir 'repo'
    $codexHome = Join-Path $tempDir 'codex'
    $agentsHome = Join-Path $tempDir 'agents'
    $geminiHome = Join-Path $tempDir 'gemini'

    New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    New-Item -ItemType Directory -Path $agentsHome -Force | Out-Null
    New-Item -ItemType Directory -Path $geminiHome -Force | Out-Null

    $configPath = Join-Path $codexHome 'config.toml'
    $initialConfig = "[features]`nmulti_agent = false`n`n[mcp_servers.subagents]`ncommand = `"node`"`nargs = [`"server.js`"]`n"
    [IO.File]::WriteAllText($configPath, $initialConfig, (New-Object System.Text.UTF8Encoding $false))

    # Copy real scripts to fake repo
    $fakeScripts = Join-Path $fakeRepo 'scripts'
    New-Item -ItemType Directory -Path $fakeScripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\install.ps1') -Destination (Join-Path $fakeScripts 'install.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\doctor.ps1') -Destination (Join-Path $fakeScripts 'doctor.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\validate.ps1') -Destination (Join-Path $fakeScripts 'validate.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\uninstall.ps1') -Destination (Join-Path $fakeScripts 'uninstall.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\backend-routing.psm1') -Destination (Join-Path $fakeScripts 'backend-routing.psm1')

    # Copy templates and docs
    $fakeCodex = Join-Path $fakeRepo 'codex'
    New-Item -ItemType Directory -Path $fakeCodex -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'codex\AGENTS.md') -Destination (Join-Path $fakeCodex 'AGENTS.md')

    $fakeAg = Join-Path $fakeRepo 'antigravity'
    New-Item -ItemType Directory -Path $fakeAg -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'antigravity\GEMINI.md') -Destination (Join-Path $fakeAg 'GEMINI.md')

    Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination (Join-Path $fakeRepo 'docs') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'ahk') -Destination (Join-Path $fakeRepo 'ahk') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $fakeRepo 'README.md')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'CHANGELOG.md') -Destination (Join-Path $fakeRepo 'CHANGELOG.md')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md') -Destination (Join-Path $fakeRepo 'CONTRIBUTING.md')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'SECURITY.md') -Destination (Join-Path $fakeRepo 'SECURITY.md')

    # Copy existing canonical skills
    $fakeSkills = Join-Path $fakeRepo 'skills'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\workflows') -Destination (Join-Path $fakeSkills 'workflows') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\evidence-first') -Destination (Join-Path $fakeSkills 'evidence-first') -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\mcp-foundation') -Destination (Join-Path $fakeSkills 'mcp-foundation') -Recurse

    # Copy canonical sources for free MCP skills
    $cbmSource = Join-Path $fakeSkills 'codebase-memory-mcp'
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'skills\codebase-memory-mcp') -PathType Container) {
        Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\codebase-memory-mcp') -Destination $cbmSource -Recurse
    } else {
        New-Item -ItemType Directory -Path $cbmSource -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $cbmSource 'SKILL.md'), "---\nname: codebase-memory-mcp\ndescription: Semantic codebase memory MCP skill\n---\n# Codebase Memory MCP\nFree tier memory indexing.", (New-Object System.Text.UTF8Encoding $false))
    }

    $ctxSource = Join-Path $fakeSkills 'context7-mcp'
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'skills\context7-mcp') -PathType Container) {
        Copy-Item -LiteralPath (Join-Path $repoRoot 'skills\context7-mcp') -Destination $ctxSource -Recurse
    } else {
        New-Item -ItemType Directory -Path $ctxSource -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $ctxSource 'SKILL.md'), "---\nname: context7-mcp\ndescription: Live documentation lookup\n---\n# Context7 MCP\nFree documentation query.", (New-Object System.Text.UTF8Encoding $false))
    }

    return @{
        Root = $tempDir
        Repo = $fakeRepo
        CodexHome = $codexHome
        AgentsHome = $agentsHome
        AntigravityHome = $geminiHome
        CbmSource = $cbmSource
        CtxSource = $ctxSource
    }
}

function Remove-MirrorFixture {
    param([hashtable]$Fixture)
    if ($Fixture -and (Test-Path -LiteralPath $Fixture.Root)) {
        Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "=== Running free MCP mirrors test suite ===" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Test Group 1: Installation & Mirror Copying
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 1: Fresh Installation of Free MCP Mirrors ---" -ForegroundColor Yellow
$fix1 = New-MirrorFixture
try {
    $installScript = Join-Path $fix1.Repo 'scripts\install.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix1.CodexHome)' -AgentsHome '$($fix1.AgentsHome)' -AntigravityHome '$($fix1.AntigravityHome)' -Force" | Out-Null

    # Check codebase-memory-mcp in all 3 mirror destinations
    $cbmMirrorAgents = Join-Path $fix1.AgentsHome 'skills\codebase-memory-mcp\SKILL.md'
    $cbmMirrorAg1 = Join-Path $fix1.AntigravityHome 'antigravity\skills\codebase-memory-mcp\SKILL.md'
    $cbmMirrorAg2 = Join-Path $fix1.AntigravityHome 'config\skills\codebase-memory-mcp\SKILL.md'

    Assert-Test -Name "CBM mirror copied to shared agents skills" -Condition (Test-Path -LiteralPath $cbmMirrorAgents -PathType Leaf)
    Assert-Test -Name "CBM mirror copied to Antigravity skills 1" -Condition (Test-Path -LiteralPath $cbmMirrorAg1 -PathType Leaf)
    Assert-Test -Name "CBM mirror copied to Antigravity skills 2" -Condition (Test-Path -LiteralPath $cbmMirrorAg2 -PathType Leaf)

    # Check context7-mcp in all 3 mirror destinations
    $ctxMirrorAgents = Join-Path $fix1.AgentsHome 'skills\context7-mcp\SKILL.md'
    $ctxMirrorAg1 = Join-Path $fix1.AntigravityHome 'antigravity\skills\context7-mcp\SKILL.md'
    $ctxMirrorAg2 = Join-Path $fix1.AntigravityHome 'config\skills\context7-mcp\SKILL.md'

    Assert-Test -Name "Context7 mirror copied to shared agents skills" -Condition (Test-Path -LiteralPath $ctxMirrorAgents -PathType Leaf)
    Assert-Test -Name "Context7 mirror copied to Antigravity skills 1" -Condition (Test-Path -LiteralPath $ctxMirrorAg1 -PathType Leaf)
    Assert-Test -Name "Context7 mirror copied to Antigravity skills 2" -Condition (Test-Path -LiteralPath $ctxMirrorAg2 -PathType Leaf)

    # Check file contents match source
    $cbmSourceHash = (Get-FileHash (Join-Path $fix1.CbmSource 'SKILL.md') -Algorithm SHA256).Hash
    $cbmInstalledHash = if (Test-Path -LiteralPath $cbmMirrorAgents) { (Get-FileHash $cbmMirrorAgents -Algorithm SHA256).Hash } else { '' }
    Assert-Test -Name "CBM mirror content matches source SHA256" -Condition ($cbmSourceHash -eq $cbmInstalledHash)

    $ctxSourceHash = (Get-FileHash (Join-Path $fix1.CtxSource 'SKILL.md') -Algorithm SHA256).Hash
    $ctxInstalledHash = if (Test-Path -LiteralPath $ctxMirrorAgents) { (Get-FileHash $ctxMirrorAgents -Algorithm SHA256).Hash } else { '' }
    Assert-Test -Name "Context7 mirror content matches source SHA256" -Condition ($ctxSourceHash -eq $ctxInstalledHash)

    # Check install-state.json records all mirrors
    $statePath = Join-Path $fix1.CodexHome 'codex-workflows-kit\install-state.json'
    Assert-Test -Name "Install state manifest exists" -Condition (Test-Path -LiteralPath $statePath -PathType Leaf)

    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestPaths = @($state.files | ForEach-Object { [string]$_.path })

    Assert-Test -Name "Manifest contains CBM agents mirror" -Condition ($manifestPaths -contains $cbmMirrorAgents)
    Assert-Test -Name "Manifest contains CBM Antigravity 1 mirror" -Condition ($manifestPaths -contains $cbmMirrorAg1)
    Assert-Test -Name "Manifest contains CBM Antigravity 2 mirror" -Condition ($manifestPaths -contains $cbmMirrorAg2)
    Assert-Test -Name "Manifest contains Context7 agents mirror" -Condition ($manifestPaths -contains $ctxMirrorAgents)
    Assert-Test -Name "Manifest contains Context7 Antigravity 1 mirror" -Condition ($manifestPaths -contains $ctxMirrorAg1)
    Assert-Test -Name "Manifest contains Context7 Antigravity 2 mirror" -Condition ($manifestPaths -contains $ctxMirrorAg2)
}
finally {
    Remove-MirrorFixture $fix1
}

# -------------------------------------------------------------------------
# Test Group 2: Unmanaged Pre-Existing Context7 Migration & Backup Preservation
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 2: Unmanaged Pre-Existing Context7 Migration & Backup ---" -ForegroundColor Yellow
$fix2 = New-MirrorFixture
try {
    # Place unmanaged pre-existing context7-mcp in agents/skills before installation
    $unmanagedDir = Join-Path $fix2.AgentsHome 'skills\context7-mcp'
    New-Item -ItemType Directory -Path $unmanagedDir -Force | Out-Null
    $unmanagedSkillPath = Join-Path $unmanagedDir 'SKILL.md'
    $unmanagedExtraPath = Join-Path $unmanagedDir 'legacy-notes.txt'
    [IO.File]::WriteAllText($unmanagedSkillPath, "UNMANAGED PRE-EXISTING CONTEXT7 SKILL", (New-Object System.Text.UTF8Encoding $false))
    [IO.File]::WriteAllText($unmanagedExtraPath, "EXTRA UNMANAGED FILE THAT MUST NOT LEAK INTO MANAGED MIRROR", (New-Object System.Text.UTF8Encoding $false))

    $unmanagedSkillHash = (Get-FileHash $unmanagedSkillPath -Algorithm SHA256).Hash
    $unmanagedExtraHash = (Get-FileHash $unmanagedExtraPath -Algorithm SHA256).Hash

    $installScript = Join-Path $fix2.Repo 'scripts\install.ps1'
    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix2.CodexHome)' -AgentsHome '$($fix2.AgentsHome)' -AntigravityHome '$($fix2.AntigravityHome)' -Force" 2>&1 | Out-String

    # Verify migration message was emitted (not silent!)
    $emittedMigrationNotice = $output -match 'Migrat(?:ing|ed) unmanaged pre-existing Context7 skill'
    Assert-Test -Name "Explicit non-silent notice emitted for unmanaged context7 migration" -Condition $emittedMigrationNotice -Details $output

    # Verify backups were created under CodexHome/backups
    $backupRoot = Join-Path $fix2.CodexHome 'backups\codex-workflows-kit'
    Assert-Test -Name "Backup root directory created" -Condition (Test-Path -LiteralPath $backupRoot -PathType Container)

    $backupFiles = if (Test-Path -LiteralPath $backupRoot) { @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File) } else { @() }
    $backedUpHashes = @($backupFiles | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash })

    Assert-Test -Name "Pre-existing unmanaged SKILL.md preserved in backup" -Condition ($backedUpHashes -contains $unmanagedSkillHash)
    Assert-Test -Name "Pre-existing unmanaged extra file preserved in backup" -Condition ($backedUpHashes -contains $unmanagedExtraHash)

    # Verify the installed mirror is now clean and matches canonical source
    $installedSkillHash = if (Test-Path -LiteralPath $unmanagedSkillPath) { (Get-FileHash $unmanagedSkillPath -Algorithm SHA256).Hash } else { '' }
    $canonicalHash = (Get-FileHash (Join-Path $fix2.CtxSource 'SKILL.md') -Algorithm SHA256).Hash
    Assert-Test -Name "Installed context7-mcp SKILL.md replaced with canonical source" -Condition ($installedSkillHash -eq $canonicalHash)
    Assert-Test -Name "Extra unmanaged file removed from clean mirror tree" -Condition (-not (Test-Path -LiteralPath $unmanagedExtraPath))

    # Verify extra custom file preserved in recoverable quarantine directory outside skill discovery
    $quarantineFiles = if (Test-Path -LiteralPath $backupRoot) { [IO.FileInfo[]]@(Get-ChildItem -LiteralPath $backupRoot -Recurse -File | Where-Object { $_.DirectoryName -match 'quarantine' }) } else { [IO.FileInfo[]]@() }
    Assert-Test -Name "Extra custom file preserved in recoverable quarantine directory outside skill discovery" -Condition ($quarantineFiles.Length -gt 0)

    # Verify backup-manifest.json exists and verifies restore integrity
    $manifestFiles = [IO.FileInfo[]]@(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Filter 'backup-manifest.json')
    Assert-Test -Name "Backup manifest exists in backup root" -Condition ($manifestFiles.Length -gt 0)

    $manifestValid = $false
    if ($manifestFiles.Length -gt 0) {
        $manifest = Get-Content -LiteralPath $manifestFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = [object[]]@($manifest)
        $matchedEntries = 0
        foreach ($entry in $entries) {
            if (Test-Path -LiteralPath $entry.backup) {
                $checkSha = (Get-FileHash $entry.backup -Algorithm SHA256).Hash
                if ($checkSha -eq $entry.sha256) {
                    $matchedEntries++
                }
            }
        }
        $manifestValid = ($matchedEntries -eq $entries.Length -and $matchedEntries -ge 2)
    }
    Assert-Test -Name "Restore backup integrity verified byte-for-byte from manifest" -Condition $manifestValid
}
finally {
    Remove-MirrorFixture $fix2
}

# -------------------------------------------------------------------------
# Test Group 3: Doctor Read-Only Verification, No Mutations, & Optional Rollout
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 3: Doctor Read-Only & Tamper Detection ---" -ForegroundColor Yellow
$fix3 = New-MirrorFixture
try {
    $installScript = Join-Path $fix3.Repo 'scripts\install.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix3.CodexHome)' -AgentsHome '$($fix3.AgentsHome)' -AntigravityHome '$($fix3.AntigravityHome)' -Force" | Out-Null

    # Take snapshot of all files before doctor
    $filesBefore = @{}
    Get-ChildItem -LiteralPath $fix3.Root -Recurse -File | ForEach-Object {
        $filesBefore[$_.FullName] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }

    # Run doctor
    $doctorScript = Join-Path $fix3.Repo 'scripts\doctor.ps1'
    $docOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$doctorScript' -CodexHome '$($fix3.CodexHome)' -AgentsHome '$($fix3.AgentsHome)' -AntigravityHome '$($fix3.AntigravityHome)' -Detailed" 2>&1
    $docExit = $LASTEXITCODE

    Assert-Test -Name "Doctor passes on cleanly installed mirrors" -Condition ($docExit -eq 0) -Details ($docOutput -join "`n")

    # Verify no files were mutated by doctor (strict read-only)
    $filesAfter = @{}
    Get-ChildItem -LiteralPath $fix3.Root -Recurse -File | ForEach-Object {
        $filesAfter[$_.FullName] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }

    $mutated = $false
    if ($filesBefore.Count -ne $filesAfter.Count) {
        $mutated = $true
    } else {
        foreach ($k in $filesBefore.Keys) {
            if (-not $filesAfter.ContainsKey($k) -or $filesBefore[$k] -ne $filesAfter[$k]) {
                $mutated = $true
                break
            }
        }
    }
    Assert-Test -Name "Doctor performed zero mutations on filesystem" -Condition (-not $mutated)

    # Tamper with a codebase-memory mirror file and verify doctor detects it
    $targetMirror = Join-Path $fix3.AgentsHome 'skills\codebase-memory-mcp\SKILL.md'
    if (Test-Path -LiteralPath $targetMirror) {
        [IO.File]::AppendAllText($targetMirror, "`n# Tampered content", (New-Object System.Text.UTF8Encoding $false))
    }

    $tamperOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$doctorScript' -CodexHome '$($fix3.CodexHome)' -AgentsHome '$($fix3.AgentsHome)' -AntigravityHome '$($fix3.AntigravityHome)'" 2>&1
    $tamperExit = $LASTEXITCODE

    # If mirror existed and was tampered, doctor must fail. If mirror wasn't even installed, fail the test.
    Assert-Test -Name "Doctor fails closed when mirror hash is tampered" -Condition ($tamperExit -ne 0 -and (Test-Path -LiteralPath $targetMirror))
}
finally {
    Remove-MirrorFixture $fix3
}

# -------------------------------------------------------------------------
# Test Group 4: Validate Script Mirror Integrity
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 4: Validate Script Mirror Integrity ---" -ForegroundColor Yellow
$fix4 = New-MirrorFixture
try {
    $installScript = Join-Path $fix4.Repo 'scripts\install.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix4.CodexHome)' -AgentsHome '$($fix4.AgentsHome)' -AntigravityHome '$($fix4.AntigravityHome)' -Force" | Out-Null

    # Run validate.ps1 on installed fixture
    $validateScript = Join-Path $fix4.Repo 'scripts\validate.ps1'
    $valOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$validateScript' -CodexHome '$($fix4.CodexHome)' -AgentsHome '$($fix4.AgentsHome)' -AntigravityHome '$($fix4.AntigravityHome)' -SkipGateTests" 2>&1
    $valExit = $LASTEXITCODE

    Assert-Test -Name "Validate passes when free MCP mirrors are intact" -Condition ($valExit -eq 0) -Details ($valOutput -join "`n")

    # Add an unexpected extra file into installed context7 mirror
    $extraFile = Join-Path $fix4.AntigravityHome 'antigravity\skills\context7-mcp\extra.md'
    if (Test-Path -LiteralPath (Split-Path -Parent $extraFile)) {
        [IO.File]::WriteAllText($extraFile, "unexpected file", (New-Object System.Text.UTF8Encoding $false))
    }

    $extraOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$validateScript' -CodexHome '$($fix4.CodexHome)' -AgentsHome '$($fix4.AgentsHome)' -AntigravityHome '$($fix4.AntigravityHome)' -SkipGateTests" 2>&1
    $extraExit = $LASTEXITCODE

    Assert-Test -Name "Validate rejects unexpected file in mirror tree" -Condition ($extraExit -ne 0 -and (Test-Path -LiteralPath $extraFile))
}
finally {
    Remove-MirrorFixture $fix4
}

# -------------------------------------------------------------------------
# Test Group 5: Uninstall & Rollback Safety
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 5: Uninstall & Rollback Safety ---" -ForegroundColor Yellow
$fix5 = New-MirrorFixture
try {
    $installScript = Join-Path $fix5.Repo 'scripts\install.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix5.CodexHome)' -AgentsHome '$($fix5.AgentsHome)' -AntigravityHome '$($fix5.AntigravityHome)' -Force" | Out-Null

    # Add an unrelated user skill in agents/skills
    $unrelatedDir = Join-Path $fix5.AgentsHome 'skills\my-custom-skill'
    New-Item -ItemType Directory -Path $unrelatedDir -Force | Out-Null
    $unrelatedFile = Join-Path $unrelatedDir 'SKILL.md'
    [IO.File]::WriteAllText($unrelatedFile, "unrelated custom skill", (New-Object System.Text.UTF8Encoding $false))

    # Run uninstaller
    $uninstallerScript = Join-Path $fix5.Repo 'scripts\uninstall.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$uninstallerScript' -CodexHome '$($fix5.CodexHome)' -AgentsHome '$($fix5.AgentsHome)' -AntigravityHome '$($fix5.AntigravityHome)' -Force" | Out-Null

    # Verify managed free MCP skills were removed
    $cbmInstalled = Test-Path -LiteralPath (Join-Path $fix5.AgentsHome 'skills\codebase-memory-mcp')
    $ctxInstalled = Test-Path -LiteralPath (Join-Path $fix5.AgentsHome 'skills\context7-mcp')
    Assert-Test -Name "Uninstall removes managed codebase-memory-mcp mirror" -Condition (-not $cbmInstalled)
    Assert-Test -Name "Uninstall removes managed context7-mcp mirror" -Condition (-not $ctxInstalled)

    # Verify unrelated user skill was NOT touched
    Assert-Test -Name "Uninstall preserves unrelated user skill" -Condition (Test-Path -LiteralPath $unrelatedFile -PathType Leaf)
}
finally {
    Remove-MirrorFixture $fix5
}

# -------------------------------------------------------------------------
# Test Group 6: Regression — Context7 URL Redaction & Optional Skill Status
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 6: Context7 URL Redaction & Optional Skill Status ---" -ForegroundColor Yellow
$fix6 = New-MirrorFixture
try {
    # 6A: Doctor with sensitive credentials in Context7 URL
    $configPath = Join-Path $fix6.CodexHome 'config.toml'
    $secretUrlConfig = @"
[features]
multi_agent = false

[mcp_servers.subagents]
command = "node"
args = ["server.js"]

[mcp_servers.context7]
url = "https://user:SuperSecretToken123@custom.context7.local/mcp?api_key=PrivateSecret456"
"@
    [IO.File]::WriteAllText($configPath, $secretUrlConfig, (New-Object System.Text.UTF8Encoding $false))

    $doctorScript = Join-Path $fix6.Repo 'scripts\doctor.ps1'
    $docOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$doctorScript' -CodexHome '$($fix6.CodexHome)' -AgentsHome '$($fix6.AgentsHome)' -AntigravityHome '$($fix6.AntigravityHome)' -Detailed" 2>&1 | Out-String

    Assert-Test -Name "Doctor does not leak Context7 userinfo or query secrets" -Condition (-not ($docOutput -match 'SuperSecretToken123') -and -not ($docOutput -match 'PrivateSecret456') -and -not ($docOutput -match 'custom\.context7\.local'))
    Assert-Test -Name "Doctor displays redacted unrecognized endpoint label" -Condition ($docOutput -match 'Configured \(redacted unrecognized endpoint\)')

    # 6B: Doctor with exact canonical Context7 URL
    $canonicalUrlConfig = @"
[features]
multi_agent = false

[mcp_servers.subagents]
command = "node"
args = ["server.js"]

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
"@
    [IO.File]::WriteAllText($configPath, $canonicalUrlConfig, (New-Object System.Text.UTF8Encoding $false))
    $docCanonicalOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$doctorScript' -CodexHome '$($fix6.CodexHome)' -AgentsHome '$($fix6.AgentsHome)' -AntigravityHome '$($fix6.AntigravityHome)' -Detailed" 2>&1 | Out-String

    Assert-Test -Name "Doctor displays exact canonical endpoint when matched" -Condition ($docCanonicalOutput -match 'Configured \(https://mcp\.context7\.com/mcp\)')

    # 6C: Optional missing skill status is clearly [WARN] / not-installed (not Passed=true [OK])
    Assert-Test -Name "Doctor reports optional missing skill as not installed" -Condition ($docCanonicalOutput -match 'Optional skill not installed \(not runtime validated\)')
    Assert-Test -Name "Doctor does not report Passed=true [OK] for missing optional skill" -Condition (-not ($docCanonicalOutput -match '\[OK\]\s+Optional free skill'))
}
finally {
    Remove-MirrorFixture $fix6
}

# -------------------------------------------------------------------------
# Test Group 7: Regression — Missing Source Fails Before Writes
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 7: Missing Source Fails Before Writes ---" -ForegroundColor Yellow
$fix7 = New-MirrorFixture
try {
    # Delete canonical source context7-mcp/SKILL.md from fake repo
    $ctxSkill = Join-Path $fix7.CtxSource 'SKILL.md'
    if (Test-Path -LiteralPath $ctxSkill) {
        Remove-Item -LiteralPath $ctxSkill -Force
    }

    $installScript = Join-Path $fix7.Repo 'scripts\install.ps1'
    $installOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix7.CodexHome)' -AgentsHome '$($fix7.AgentsHome)' -AntigravityHome '$($fix7.AntigravityHome)' -Force" 2>&1 | Out-String
    $installExit = $LASTEXITCODE

    Assert-Test -Name "Install fails closed when canonical source skill is missing" -Condition ($installExit -ne 0) -Details $installOutput
    Assert-Test -Name "Zero skill files written when preflight fails" -Condition (-not (Test-Path -LiteralPath (Join-Path $fix7.AgentsHome 'skills\workflows')) -and -not (Test-Path -LiteralPath (Join-Path $fix7.AgentsHome 'skills\context7-mcp')))
    Assert-Test -Name "Install state manifest is not created on preflight failure" -Condition (-not (Test-Path -LiteralPath (Join-Path $fix7.CodexHome 'codex-workflows-kit\install-state.json')))
}
finally {
    Remove-MirrorFixture $fix7
}

# -------------------------------------------------------------------------
# Test Group 8: Regression — Unmanaged Context7 Reparse Point & Ambiguous Custom Conflict
# -------------------------------------------------------------------------
Write-Host "`n--- Test Group 8: Unmanaged Context7 Reparse Point & Ambiguous Conflict ---" -ForegroundColor Yellow
$fix8 = New-MirrorFixture
try {
    # 8A: Ambiguous custom conflict fail-closed
    $unmanagedDir8 = Join-Path $fix8.AgentsHome 'skills\context7-mcp'
    New-Item -ItemType Directory -Path (Join-Path $unmanagedDir8 'agents') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $unmanagedDir8 'SKILL.md'), "UNMANAGED SKILL", (New-Object System.Text.UTF8Encoding $false))
    $conflictFile = Join-Path $unmanagedDir8 'agents\openai.yaml'
    [IO.File]::WriteAllText($conflictFile, "custom_conflicting: content_that_differs", (New-Object System.Text.UTF8Encoding $false))

    $installScript = Join-Path $fix8.Repo 'scripts\install.ps1'
    $conflictOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix8.CodexHome)' -AgentsHome '$($fix8.AgentsHome)' -AntigravityHome '$($fix8.AntigravityHome)' -Force" 2>&1 | Out-String
    $conflictExit = $LASTEXITCODE

    Assert-Test -Name "Install fails closed on ambiguous custom conflict" -Condition ($conflictExit -ne 0 -and $conflictOutput -match 'Ambiguous custom conflict') -Details $conflictOutput
    Assert-Test -Name "Ambiguous custom file was not destroyed or overwritten" -Condition (Test-Path -LiteralPath $conflictFile -PathType Leaf)

    # Clean up conflict dir for 8B
    Remove-Item -LiteralPath $unmanagedDir8 -Recurse -Force

    # 8B: Reparse point detection fail-closed (no recursive removal)
    $protectedDir = Join-Path $fix8.Root 'protected_dir'
    New-Item -ItemType Directory -Path $protectedDir -Force | Out-Null
    $protectedFile = Join-Path $protectedDir 'important.txt'
    [IO.File]::WriteAllText($protectedFile, "DO NOT DELETE", (New-Object System.Text.UTF8Encoding $false))

    $unmanagedOldCtx = Join-Path $fix8.AgentsHome 'skills\context7'
    New-Item -ItemType Directory -Path $unmanagedOldCtx -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $unmanagedOldCtx 'SKILL.md'), "OLD CONTEXT7", (New-Object System.Text.UTF8Encoding $false))

    $junctionPath = Join-Path $unmanagedOldCtx 'link_to_protected'
    & cmd.exe /c "mklink /J `"$junctionPath`" `"$protectedDir`"" | Out-Null

    $reparseOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$installScript' -Profile safe -CodexHome '$($fix8.CodexHome)' -AgentsHome '$($fix8.AgentsHome)' -AntigravityHome '$($fix8.AntigravityHome)' -Force" 2>&1 | Out-String
    $reparseExit = $LASTEXITCODE

    Assert-Test -Name "Install fails closed when candidate contains reparse point" -Condition ($reparseExit -ne 0 -and $reparseOutput -match 'Reparse point detected') -Details $reparseOutput
    Assert-Test -Name "Reparse target protected directory and file were preserved" -Condition (Test-Path -LiteralPath $protectedFile -PathType Leaf)

    # Clean up junction
    if (Test-Path -LiteralPath $junctionPath) {
        & cmd.exe /c "rmdir `"$junctionPath`"" | Out-Null
    }
}
finally {
    Remove-MirrorFixture $fix8
}

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "Tests Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })

if ($script:FailedCount -gt 0) {
    Write-Host "`nFailed Tests:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host " - $f" -ForegroundColor Red
    }
    exit 1
}

exit 0
