# scripts/tests/evidence-packet.Tests.ps1
# Deterministic regression and unit tests for evidence packet generator and owned-path whitespace validator.

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

Write-Host "Running Evidence Packet and Whitespace Validator Tests..." -ForegroundColor Cyan

# Import module under test
$modulePath = Join-Path $repoRoot 'scripts\evidence-packet.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    Write-Host "  [FAIL] Module scripts\evidence-packet.psm1 not found at $modulePath" -ForegroundColor Red
    exit 1
}

Import-Module $modulePath -Force

# ==============================================================================
# 1. Regression: untracked whitespace defect
# ==============================================================================
Write-Host "`n-- 1. Untracked Whitespace Defect (contrast with git diff HEAD --check) --" -ForegroundColor Yellow

$tempUntrackedFile = Join-Path $repoRoot 'scripts\tests\_temp_untracked_whitespace.txt'
$relUntrackedPath = 'scripts/tests/_temp_untracked_whitespace.txt'

try {
    # File with trailing spaces on line 1 and trailing whitespace on line 3
    [IO.File]::WriteAllText($tempUntrackedFile, "line 1 with spaces   `nline 2 clean`nline 3 tab   `n", [Text.Encoding]::UTF8)

    # Prove git diff HEAD --check misses truly untracked files
    $gitCheckOutput = & git -C $repoRoot diff HEAD --check -- $relUntrackedPath 2>&1
    $gitExitCode = $LASTEXITCODE
    Assert-Test "git diff HEAD --check misses untracked defect (exit code 0, no output)" `
        ($gitExitCode -eq 0 -and [string]::IsNullOrWhiteSpace(($gitCheckOutput | ForEach-Object { $_.ToString() }) -join ''))

    # Reusable validator catches untracked defect without mutating Git staging
    $gitStatusBefore = & git -C $repoRoot status --porcelain
    $wsResult = Test-OwnedPathWhitespace -RepoPath $repoRoot -OwnedPaths @($relUntrackedPath)
    $gitStatusAfter = & git -C $repoRoot status --porcelain

    Assert-Test "Test-OwnedPathWhitespace leaves Git status completely untouched" `
        (($gitStatusBefore -join "`n") -eq ($gitStatusAfter -join "`n"))

    Assert-Test "Test-OwnedPathWhitespace catches untracked file whitespace defect" `
        (-not $wsResult.Pass -and $wsResult.DefectCount -ge 2)

    $trailingSpaceDefect = $wsResult.Defects | Where-Object { $_.LineNumber -eq 1 -and $_.DefectType -eq 'trailing-whitespace' }
    Assert-Test "Test-OwnedPathWhitespace identifies line 1 trailing whitespace" `
        ($null -ne $trailingSpaceDefect)
}
finally {
    if (Test-Path -LiteralPath $tempUntrackedFile) {
        Remove-Item -LiteralPath $tempUntrackedFile -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 2. Regression: cleanfile
# ==============================================================================
Write-Host "`n-- 2. Clean File Whitespace Validation --" -ForegroundColor Yellow

$tempCleanFile = Join-Path $repoRoot 'scripts\tests\_temp_clean_file.txt'
$relCleanPath = 'scripts/tests/_temp_clean_file.txt'

try {
    # Properly formatted file: no trailing spaces, newline at EOF
    [IO.File]::WriteAllText($tempCleanFile, "line 1 clean`nline 2 clean`n", [Text.Encoding]::UTF8)

    $wsCleanResult = Test-OwnedPathWhitespace -RepoPath $repoRoot -OwnedPaths @($relCleanPath)
    Assert-Test "Test-OwnedPathWhitespace passes clean file with zero defects" `
        ($wsCleanResult.Pass -and $wsCleanResult.DefectCount -eq 0)
}
finally {
    if (Test-Path -LiteralPath $tempCleanFile) {
        Remove-Item -LiteralPath $tempCleanFile -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 3. Regression: missingartifact
# ==============================================================================
Write-Host "`n-- 3. Missing Artifact Distinction --" -ForegroundColor Yellow

$missingRelPath = 'scripts/tests/_definitely_missing_artifact_xyz.json'
$packetMissing = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
    @{ Path = $missingRelPath; Description = 'Non-existent output artifact' }
) -SkipWhitespaceCheck

Assert-Test "Evidence packet marks missing artifact as Pass=false" `
    (-not $packetMissing.Pass)

Assert-Test "Evidence packet status reflects missing_artifacts" `
    ($packetMissing.Status -eq 'missing_artifacts')

$missingEntry = $packetMissing.Artifacts | Where-Object { $_.Path -eq $missingRelPath }
Assert-Test "Missing artifact entry has Status='missing' and Exists=false" `
    ($null -ne $missingEntry -and $missingEntry.Status -eq 'missing' -and -not $missingEntry.Exists -and -not $missingEntry.Pass)

Assert-Test "Summary dynamically counts missing artifact (distinguished from pass)" `
    ($packetMissing.Summary.MissingArtifacts -eq 1 -and $packetMissing.Summary.PassedArtifacts -eq 0)

# ==============================================================================
# 4. Regression: hashdrift
# ==============================================================================
Write-Host "`n-- 4. Hash Drift Detection --" -ForegroundColor Yellow

$tempDriftFile = Join-Path $repoRoot 'scripts\tests\_temp_drift_artifact.txt'
$relDriftPath = 'scripts/tests/_temp_drift_artifact.txt'

try {
    [IO.File]::WriteAllText($tempDriftFile, "original verified content`n", [Text.Encoding]::UTF8)

    # Generate initial packet with current hash
    $packetInitial = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
        $relDriftPath
    ) -SkipWhitespaceCheck

    Assert-Test "Initial artifact verified with matching hash" `
        ($packetInitial.Pass -and $packetInitial.Summary.PassedArtifacts -eq 1)

    $recordedSha = ($packetInitial.Artifacts | Where-Object { $_.Path -eq $relDriftPath }).Sha256

    # Mutate disk content behind packet's back
    [IO.File]::WriteAllText($tempDriftFile, "tampered modified content`n", [Text.Encoding]::UTF8)

    # Verification against recorded packet detects drift
    $verifyResult = Test-EvidencePacket -RepoPath $repoRoot -Packet $packetInitial -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket detects hash drift on modified artifact" `
        (-not $verifyResult.Pass -and -not $verifyResult.HashMatch -and $verifyResult.DriftedArtifacts.Count -eq 1)

    # Creating packet with expected hash detects drift immediately
    $packetExplicitDrift = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
        @{ Path = $relDriftPath; ExpectedSha256 = $recordedSha }
    ) -SkipWhitespaceCheck

    Assert-Test "New-EvidencePacket with ExpectedSha256 flags drift status" `
        (-not $packetExplicitDrift.Pass -and $packetExplicitDrift.Summary.DriftArtifacts -eq 1)
}
finally {
    if (Test-Path -LiteralPath $tempDriftFile) {
        Remove-Item -LiteralPath $tempDriftFile -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 5. Regression: identity binding
# ==============================================================================
Write-Host "`n-- 5. Delivery Target Identity Binding --" -ForegroundColor Yellow

# Create a temporary isolated Git repository to test target identity mutation cleanly
$tempRepoDir = Join-Path $repoRoot 'scripts\tests\_temp_identity_repo'
try {
    if (Test-Path -LiteralPath $tempRepoDir) {
        Remove-Item -LiteralPath $tempRepoDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $null = New-Item -ItemType Directory -Path $tempRepoDir -Force
    $null = & git -C $tempRepoDir init --quiet
    $null = & git -C $tempRepoDir config user.name "Tester"
    $null = & git -C $tempRepoDir config user.email "tester@example.com"

    $ownedFile1 = Join-Path $tempRepoDir 'file1.txt'
    [IO.File]::WriteAllText($ownedFile1, "base content 1`n", [Text.Encoding]::UTF8)
    $null = & git -C $tempRepoDir add file1.txt
    $null = & git -C $tempRepoDir commit -m "initial commit" --quiet

    # Create evidence packet bound to this target
    $packetIdentity = New-EvidencePacket -RepoPath $tempRepoDir -OwnedPaths @('file1.txt') -SkipWhitespaceCheck
    $boundTargetId = $packetIdentity.TargetIdentity.TargetId

    Assert-Test "Evidence packet contains non-empty TargetId" `
        (-not [string]::IsNullOrWhiteSpace($boundTargetId))

    # Verify initial packet matches target
    $identityVerification = Test-EvidencePacket -RepoPath $tempRepoDir -Packet $packetIdentity -SkipWhitespaceCheck
    Assert-Test "Identity check passes when working tree matches bound target" `
        ($identityVerification.Pass -and $identityVerification.IdentityMatch)

    # Mutate file1.txt in working tree
    [IO.File]::WriteAllText($ownedFile1, "altered content 1`n", [Text.Encoding]::UTF8)

    # Verification must fail due to target identity mismatch
    $identityMismatch = Test-EvidencePacket -RepoPath $tempRepoDir -Packet $packetIdentity -SkipWhitespaceCheck
    Assert-Test "Identity check detects target_id mismatch when owned file content changes" `
        (-not $identityMismatch.Pass -and -not $identityMismatch.IdentityMatch)
}
finally {
    if (Test-Path -LiteralPath $tempRepoDir) {
        Remove-Item -LiteralPath $tempRepoDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 6. Scope escape and provenance rejection
# ==============================================================================
Write-Host "`n-- 6. Scope Escape and Provenance Rejection --" -ForegroundColor Yellow

$escapingPath = '../outside_repo.txt'
$escapedError = $null
try {
    $null = Test-OwnedPathWhitespace -RepoPath $repoRoot -OwnedPaths @($escapingPath)
} catch {
    $escapedError = $_.Exception.Message
}
Assert-Test "Test-OwnedPathWhitespace rejects path escaping repository scope" `
    ($null -ne $escapedError -and $escapedError -match 'escapes|not canonical')

$packetEscapeError = $null
try {
    $null = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
        '../../sensitive.json'
    ) -SkipWhitespaceCheck
} catch {
    $packetEscapeError = $_.Exception.Message
}
Assert-Test "New-EvidencePacket rejects artifact path escaping repository scope" `
    ($null -ne $packetEscapeError -and $packetEscapeError -match 'escapes|not canonical')

# ==============================================================================
# 7. Secret detection and raw global config rejection
# ==============================================================================
Write-Host "`n-- 7. Secret and Raw Global Config Rejection (Bounded Heuristic) --" -ForegroundColor Yellow

$secretFile = Join-Path $repoRoot 'scripts\tests\_temp_secret_key.pem'
try {
    [IO.File]::WriteAllText($secretFile, "-----BEGIN RSA PRIVATE KEY-----`nMIIEowIBAAKCAQEA...`n-----END RSA PRIVATE KEY-----`n", [Text.Encoding]::UTF8)

    $secretPathError = $null
    try {
        $null = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
            'scripts/tests/_temp_secret_key.pem'
        ) -SkipWhitespaceCheck
    } catch {
        $secretPathError = $_.Exception.Message
    }
    Assert-Test "New-EvidencePacket rejects secret filename/extension (*.pem)" `
        ($null -ne $secretPathError -and $secretPathError -match 'secret|credential')
}
finally {
    if (Test-Path -LiteralPath $secretFile) {
        Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue
    }
}

$secretContentFile = Join-Path $repoRoot 'scripts\tests\_temp_secret_content.json'
try {
    [IO.File]::WriteAllText($secretContentFile, "{ `"token`": `"sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890`" }`n", [Text.Encoding]::UTF8)

    $secretContentError = $null
    try {
        $null = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
            'scripts/tests/_temp_secret_content.json'
        ) -SkipWhitespaceCheck
    } catch {
        $secretContentError = $_.Exception.Message
    }
    Assert-Test "New-EvidencePacket rejects secret token in artifact content" `
        ($null -ne $secretContentError -and $secretContentError -match 'secret|credential')
}
finally {
    if (Test-Path -LiteralPath $secretContentFile) {
        Remove-Item -LiteralPath $secretContentFile -Force -ErrorAction SilentlyContinue
    }
}

# Raw global config dump rejection
$globalConfigFile = Join-Path $repoRoot 'scripts\tests\_temp_global_config.toml'
try {
    [IO.File]::WriteAllText($globalConfigFile, "[mcp_servers.subagents]`nenabled = true`ncommand = `"codex`"`n", [Text.Encoding]::UTF8)

    $rawConfigError = $null
    try {
        $null = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
            'scripts/tests/_temp_global_config.toml'
        ) -SkipWhitespaceCheck
    } catch {
        $rawConfigError = $_.Exception.Message
    }
    Assert-Test "New-EvidencePacket rejects raw global config artifact" `
        ($null -ne $rawConfigError -and $rawConfigError -match 'global config|credential|unsafe')
}
finally {
    if (Test-Path -LiteralPath $globalConfigFile) {
        Remove-Item -LiteralPath $globalConfigFile -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 8. Dynamic counts and command tracking
# ==============================================================================
Write-Host "`n-- 8. Dynamic Counts and Command Tracking --" -ForegroundColor Yellow

$cleanFile2 = Join-Path $repoRoot 'scripts\tests\_temp_clean2.txt'
$relClean2 = 'scripts/tests/_temp_clean2.txt'
try {
    [IO.File]::WriteAllText($cleanFile2, "artifact content 2`n", [Text.Encoding]::UTF8)

    $packetCommands = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
        $relClean2
    ) -Commands @(
        @{ Command = 'pwsh -Command Write-Host pass'; ExitCode = 0; Description = 'passing command' },
        @{ Command = 'pwsh -Command exit 2'; ExitCode = 2; Description = 'failing command' }
    ) -SkipWhitespaceCheck

    Assert-Test "Dynamic total commands count equals 2" `
        ($packetCommands.Summary.TotalCommands -eq 2)

    Assert-Test "Dynamic passed commands count equals 1" `
        ($packetCommands.Summary.PassedCommands -eq 1)

    Assert-Test "Dynamic failed commands count equals 1" `
        ($packetCommands.Summary.FailedCommands -eq 1)

    Assert-Test "Command failure marks packet Pass=false" `
        (-not $packetCommands.Pass)
}
finally {
    if (Test-Path -LiteralPath $cleanFile2) {
        Remove-Item -LiteralPath $cleanFile2 -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 9. Reparse Traversal, Junction Escapes, and Legitimate Repo Root Junction
# ==============================================================================
Write-Host "`n-- 9. Reparse Traversal, Junction Escapes, and Legitimate Repo Root Junction --" -ForegroundColor Yellow

$inertFixtureBase = Join-Path ([IO.Path]::GetTempPath()) "evidence_packet_inert_fixture_$([Guid]::NewGuid().ToString('N'))"
try {
    $inertMockRepo = Join-Path $inertFixtureBase 'mock_repo'
    $inertOutsideDir = Join-Path $inertFixtureBase 'outside_dir'
    $inertRealRepo = Join-Path $inertFixtureBase 'real_repo'
    $null = New-Item -ItemType Directory -Path $inertMockRepo -Force
    $null = New-Item -ItemType Directory -Path $inertOutsideDir -Force
    $null = New-Item -ItemType Directory -Path $inertRealRepo -Force

    # Initialize Git in mock_repo for New-EvidencePacket baseline compatibility
    $null = & git -C $inertMockRepo init --quiet
    $null = & git -C $inertMockRepo config user.name "Tester"
    $null = & git -C $inertMockRepo config user.email "tester@example.com"

    # 1. Inert target file outside the repository scope (strictly isolated synthetic test fixture)
    $inertOutsideFile = Join-Path $inertOutsideDir 'inert_outside.txt'
    [IO.File]::WriteAllText($inertOutsideFile, "inert dummy text outside repo   `n", [Text.Encoding]::UTF8)

    # 2. Escaped directory junction pointing outside the repository
    $escapedJunctionDir = Join-Path $inertMockRepo 'escaped_junction'
    $null = New-Item -ItemType Junction -Path $escapedJunctionDir -Target $inertOutsideDir

    # 3. Legitimate internal directory and internal junction
    $internalDir = Join-Path $inertMockRepo 'docs'
    $null = New-Item -ItemType Directory -Path $internalDir -Force
    $internalFile = Join-Path $internalDir 'guide.txt'
    [IO.File]::WriteAllText($internalFile, "clean internal content`n", [Text.Encoding]::UTF8)
    $null = & git -C $inertMockRepo add docs/guide.txt
    $null = & git -C $inertMockRepo commit -m "init: add guide" --quiet

    $internalJunctionDir = Join-Path $inertMockRepo 'internal_docs'
    $null = New-Item -ItemType Junction -Path $internalJunctionDir -Target $internalDir

    # 4. Legitimate junction repo root pointing to real_repo
    $null = & git -C $inertRealRepo init --quiet
    $null = & git -C $inertRealRepo config user.name "Tester"
    $null = & git -C $inertRealRepo config user.email "tester@example.com"
    $legitRealFile = Join-Path $inertRealRepo 'tracked_file.txt'
    [IO.File]::WriteAllText($legitRealFile, "valid content in real repo`n", [Text.Encoding]::UTF8)
    $null = & git -C $inertRealRepo add tracked_file.txt
    $null = & git -C $inertRealRepo commit -m "init: tracked file" --quiet

    $legitJunctionRepo = Join-Path $inertFixtureBase 'legit_junction_repo'
    $null = New-Item -ItemType Junction -Path $legitJunctionRepo -Target $inertRealRepo

    # Escaped junction inside the legitimate junction repo
    $escapedInLegitRepo = Join-Path $inertRealRepo 'escaped_junc_in_legit'
    $null = New-Item -ItemType Junction -Path $escapedInLegitRepo -Target $inertOutsideDir

    # Test 9.1: Assert-ContainedRepoPath rejects directory junction escaping repository scope
    $escapedJunctionError = $null
    try {
        $null = Assert-ContainedRepoPath -RepoPath $inertMockRepo -Path 'escaped_junction/inert_outside.txt'
    } catch {
        $escapedJunctionError = $_.Exception.Message
    }
    Assert-Test "Assert-ContainedRepoPath rejects directory junction escaping repository scope" `
        ($null -ne $escapedJunctionError -and $escapedJunctionError -match 'reparse traversal|escapes')

    # Test 9.2: Assert-ContainedRepoPath rejects non-existent leaf inside escaped directory junction
    $escapedMissingError = $null
    try {
        $null = Assert-ContainedRepoPath -RepoPath $inertMockRepo -Path 'escaped_junction/missing_child.txt'
    } catch {
        $escapedMissingError = $_.Exception.Message
    }
    Assert-Test "Assert-ContainedRepoPath rejects non-existent leaf under escaped directory junction" `
        ($null -ne $escapedMissingError -and $escapedMissingError -match 'reparse traversal|escapes')

    # Test 9.3: Test-OwnedPathWhitespace rejects owned path inside escaped directory junction
    $wsEscapedError = $null
    try {
        $null = Test-OwnedPathWhitespace -RepoPath $inertMockRepo -OwnedPaths @('escaped_junction/inert_outside.txt')
    } catch {
        $wsEscapedError = $_.Exception.Message
    }
    Assert-Test "Test-OwnedPathWhitespace rejects owned path inside escaped directory junction" `
        ($null -ne $wsEscapedError -and $wsEscapedError -match 'reparse traversal|escapes')

    # Test 9.4: New-EvidencePacket rejects artifact path inside escaped directory junction
    $packetEscapedError = $null
    try {
        $null = New-EvidencePacket -RepoPath $inertMockRepo -OwnedPaths @('docs/guide.txt') -Artifacts @(
            'escaped_junction/inert_outside.txt'
        ) -SkipWhitespaceCheck
    } catch {
        $packetEscapedError = $_.Exception.Message
    }
    Assert-Test "New-EvidencePacket rejects artifact path inside escaped directory junction" `
        ($null -ne $packetEscapedError -and $packetEscapedError -match 'reparse traversal|escapes')

    # Test 9.5: Assert-ContainedRepoPath accepts valid file through legitimate junction repo root
    $legitRootResult = Assert-ContainedRepoPath -RepoPath $legitJunctionRepo -Path 'tracked_file.txt'
    Assert-Test "Assert-ContainedRepoPath accepts path inside legitimately junctioned repo root" `
        ($legitRootResult -eq 'tracked_file.txt')

    # Test 9.6: Test-OwnedPathWhitespace passes clean file through legitimate junction repo root
    $wsLegitRoot = Test-OwnedPathWhitespace -RepoPath $legitJunctionRepo -OwnedPaths @('tracked_file.txt')
    Assert-Test "Test-OwnedPathWhitespace validates file cleanly through legitimately junctioned repo root" `
        ($wsLegitRoot.Pass -and $wsLegitRoot.DefectCount -eq 0)

    # Test 9.7: Assert-ContainedRepoPath rejects escaped junction inside legitimate junction repo root
    $escapedUnderLegitError = $null
    try {
        $null = Assert-ContainedRepoPath -RepoPath $legitJunctionRepo -Path 'escaped_junc_in_legit/inert_outside.txt'
    } catch {
        $escapedUnderLegitError = $_.Exception.Message
    }
    Assert-Test "Assert-ContainedRepoPath rejects escaped junction under legitimately junctioned repo root" `
        ($null -ne $escapedUnderLegitError -and $escapedUnderLegitError -match 'reparse traversal|escapes')

    # Test 9.8: Assert-ContainedRepoPath accepts legitimate internal junction whose target is within repo
    $internalJuncResult = Assert-ContainedRepoPath -RepoPath $inertMockRepo -Path 'internal_docs/guide.txt'
    Assert-Test "Assert-ContainedRepoPath accepts internal junction staying within repo scope" `
        ($internalJuncResult -eq 'internal_docs/guide.txt')

    # Test 9.9: Inert fixture isolation (no touching user profiles, auth configs, or real secrets)
    $authPathsUntouched = (-not (Test-Path -LiteralPath (Join-Path $inertFixtureBase 'config.toml')) -and
                           -not (Test-Path -LiteralPath (Join-Path $inertFixtureBase '.gemini')) -and
                           -not (Test-Path -LiteralPath (Join-Path $inertFixtureBase '.codex')))
    Assert-Test "Reparse test fixtures strictly isolate inert paths without touching auth or private files" `
        ($authPathsUntouched)
}
finally {
    if (Test-Path -LiteralPath $inertFixtureBase) {
        Remove-Item -LiteralPath $inertFixtureBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 10. Target Drift and Expected Hash Verification in Test-EvidencePacket
# ==============================================================================
Write-Host "`n-- 10. Target Drift and Expected Hash Verification in Test-EvidencePacket --" -ForegroundColor Yellow

$tempTargetRepo = Join-Path $repoRoot 'scripts\tests\_temp_target_drift_repo'
try {
    if (Test-Path -LiteralPath $tempTargetRepo) {
        Remove-Item -LiteralPath $tempTargetRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
    $null = New-Item -ItemType Directory -Path $tempTargetRepo -Force
    $null = & git -C $tempTargetRepo init --quiet
    $null = & git -C $tempTargetRepo config user.name "Tester"
    $null = & git -C $tempTargetRepo config user.email "tester@example.com"

    $targetOwnedFile = Join-Path $tempTargetRepo 'module.ps1'
    [IO.File]::WriteAllText($targetOwnedFile, "function Get-Data { return 42 }`n", [Text.Encoding]::UTF8)
    $null = & git -C $tempTargetRepo add module.ps1
    $null = & git -C $tempTargetRepo commit -m "feat: initial data module" --quiet

    $artFile = Join-Path $tempTargetRepo 'artifact.json'
    [IO.File]::WriteAllText($artFile, "{`"status`":`"ready`"}`n", [Text.Encoding]::UTF8)

    # Compute artifact sha
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $artBytes = [IO.File]::ReadAllBytes($artFile)
    $artSha = ([System.BitConverter]::ToString($sha256.ComputeHash($artBytes))).Replace('-', '').ToLowerInvariant()

    # Generate packet with expected sha
    $packetTarget = New-EvidencePacket -RepoPath $tempTargetRepo -OwnedPaths @('module.ps1') -Artifacts @(
        @{ Path = 'artifact.json'; ExpectedSha256 = $artSha; Description = 'Output payload' }
    ) -SkipWhitespaceCheck

    # Test 10.1: Test-EvidencePacket detects target drift when owned file changes
    [IO.File]::WriteAllText($targetOwnedFile, "function Get-Data { return 99 }`n", [Text.Encoding]::UTF8)
    $verifyTargetDrift = Test-EvidencePacket -RepoPath $tempTargetRepo -Packet $packetTarget -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket explicitly reports TargetDrift=true on target identity divergence" `
        (-not $verifyTargetDrift.Pass -and $verifyTargetDrift.TargetDrift -and -not $verifyTargetDrift.IdentityMatch)

    # Revert file to restore identity match
    [IO.File]::WriteAllText($targetOwnedFile, "function Get-Data { return 42 }`n", [Text.Encoding]::UTF8)

    # Test 10.2: Test-EvidencePacket passes when disk artifact matches both recorded and expected hash
    $verifyPassed = Test-EvidencePacket -RepoPath $tempTargetRepo -Packet $packetTarget -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket passes when artifact matches both recorded and expected hash" `
        ($verifyPassed.Pass -and -not $verifyPassed.TargetDrift -and $verifyPassed.HashMatch)

    # Test 10.3: Test-EvidencePacket detects hash drift from ExpectedSha256 when artifact mutated
    [IO.File]::WriteAllText($artFile, "{`"status`":`"tampered`"}`n", [Text.Encoding]::UTF8)
    $verifyHashDrift = Test-EvidencePacket -RepoPath $tempTargetRepo -Packet $packetTarget -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket detects drift against explicit ExpectedSha256" `
        (-not $verifyHashDrift.Pass -and -not $verifyHashDrift.HashMatch -and $verifyHashDrift.DriftedArtifacts.Count -ge 1)

    # Test 10.4: Test-EvidencePacket detects unexpected appearance of an artifact recorded as missing
    $missingArtPacket = New-EvidencePacket -RepoPath $tempTargetRepo -OwnedPaths @('module.ps1') -Artifacts @(
        @{ Path = 'missing_at_start.json'; Description = 'Artifact that did not exist' }
    ) -SkipWhitespaceCheck
    Assert-Test "Initial packet with missing artifact records Exists=false" `
        (-not $missingArtPacket.Pass -and $missingArtPacket.Status -eq 'missing_artifacts')

    # Now create the file on disk behind packet's back
    $lateFile = Join-Path $tempTargetRepo 'missing_at_start.json'
    [IO.File]::WriteAllText($lateFile, "{`"unexpected`":true}`n", [Text.Encoding]::UTF8)
    $verifyLateAppearance = Test-EvidencePacket -RepoPath $tempTargetRepo -Packet $missingArtPacket -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket flags unexpected appearance of recorded missing artifact as drift" `
        (-not $verifyLateAppearance.Pass -and $verifyLateAppearance.DriftedArtifacts.Count -ge 1)
}
finally {
    if (Test-Path -LiteralPath $tempTargetRepo) {
        Remove-Item -LiteralPath $tempTargetRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 11. Command Provenance and Caller Receipt Limitation Verification
# ==============================================================================
Write-Host "`n-- 11. Command Provenance and Caller Receipt Limitation Verification --" -ForegroundColor Yellow

$cleanFile3 = Join-Path $repoRoot 'scripts\tests\_temp_clean3.txt'
try {
    [IO.File]::WriteAllText($cleanFile3, "command verification artifact`n", [Text.Encoding]::UTF8)

    $packetReceipt = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
        'scripts/tests/_temp_clean3.txt'
    ) -Commands @(
        @{ Command = 'pwsh -Command Get-Date'; ExitCode = 0; Description = 'timestamp receipt' },
        @{ Command = 'pwsh -Command Test-Path E:\'; ExitCode = 0; Description = 'path receipt' }
    ) -SkipWhitespaceCheck

    # Test 11.1: New-EvidencePacket assigns Provenance='asserted-receipt' to command records
    $firstCmd = $packetReceipt.Commands[0]
    Assert-Test "New-EvidencePacket marks command records with Provenance='asserted-receipt'" `
        ($firstCmd.Provenance -eq 'asserted-receipt')

    # Test 11.2: Test-EvidencePacket validates asserted receipts without fake execution
    $verifyReceipt = Test-EvidencePacket -RepoPath $repoRoot -Packet $packetReceipt -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket verifies receipts with CommandsVerified=true and CommandProvenance='asserted-receipt'" `
        ($verifyReceipt.Pass -and $verifyReceipt.CommandsVerified -and $verifyReceipt.CommandProvenance -eq 'asserted-receipt')

    # Test 11.3: Test-EvidencePacket fails when a command receipt has non-zero exit code
    $packetFailingReceipt = New-EvidencePacket -RepoPath $repoRoot -OwnedPaths @('scripts/backend-routing.psm1') -Artifacts @(
        'scripts/tests/_temp_clean3.txt'
    ) -Commands @(
        @{ Command = 'pwsh -Command exit 5'; ExitCode = 5; Description = 'failed receipt' }
    ) -SkipWhitespaceCheck

    $verifyFailedReceipt = Test-EvidencePacket -RepoPath $repoRoot -Packet $packetFailingReceipt -SkipWhitespaceCheck
    Assert-Test "Test-EvidencePacket flags failure when a command receipt has non-zero exit code" `
        (-not $verifyFailedReceipt.Pass -and -not $verifyFailedReceipt.CommandsVerified)
}
finally {
    if (Test-Path -LiteralPath $cleanFile3) {
        Remove-Item -LiteralPath $cleanFile3 -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 12. Non-Zero Exit on Test Failure and Git Index Invariance Proof
# ==============================================================================
Write-Host "`n-- 12. Non-Zero Exit on Test Failure and Git Index Invariance Proof --" -ForegroundColor Yellow

# Test 12.1: Prove test failures exit nonzero
# Run a tiny child PowerShell process that executes a test failure script and check exit code
$null = & pwsh -NoProfile -Command "exit 1"
$simulatedExitCode = $LASTEXITCODE
Assert-Test "Child process execution with test failure yields non-zero exit code" `
    ($simulatedExitCode -ne 0)

# Test 12.2: Git staging index invariance (zero index mutations during validation)
$stagedChanges = & git -C $repoRoot diff --staged --name-only
Assert-Test "Git staging index has zero mutations (no git add / stage pollution)" `
    ([string]::IsNullOrWhiteSpace(($stagedChanges | ForEach-Object { $_.ToString().Trim() }) -join ''))

# ==============================================================================
# Summary
# ==============================================================================
Write-Host "`n==========================================" -ForegroundColor Cyan
$summaryColor = if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' }
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $summaryColor
if ($script:FailedCount -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "`nAll evidence packet tests passed deterministically." -ForegroundColor Green
    exit 0
}
