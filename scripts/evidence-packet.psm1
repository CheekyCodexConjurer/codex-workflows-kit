# scripts/evidence-packet.psm1
# Reusable owned-path whitespace validator and structured evidence packet generator
# with staging-invariant target identity binding, dynamic counts, and bounded heuristic secret detection.

Set-StrictMode -Version Latest

# Import sibling backend-routing module for canonical target identity and commit classification
$script:BackendRoutingPath = Join-Path $PSScriptRoot 'backend-routing.psm1'
if (Test-Path -LiteralPath $script:BackendRoutingPath -PathType Leaf) {
    Import-Module $script:BackendRoutingPath -Force
}

function Resolve-CanonicalReparsePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string[]]$RelativeSegments
    )

    $current = $BasePath
    foreach ($seg in $RelativeSegments) {
        $next = [IO.Path]::Combine($current, $seg)
        if (Test-Path -LiteralPath $next) {
            $item = Get-Item -LiteralPath $next -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($item -is [IO.DirectoryInfo] -or $item -is [IO.FileInfo]) {
                    $target = $item.ResolveLinkTarget($true)
                    if ($null -ne $target) {
                        $next = [IO.Path]::GetFullPath($target.FullName)
                    }
                }
            }
        }
        $current = $next
    }
    return [IO.Path]::GetFullPath($current)
}

function Resolve-CanonicalDirectoryRoot {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $segments = if ([string]::IsNullOrEmpty($relative)) { @() } else { $relative.Split([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    return Resolve-CanonicalReparsePath -BasePath $root -RelativeSegments $segments
}

function Assert-ContainedRepoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty or whitespace."
    }

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    $repoPrefix = $fullRepoPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    $rawPath = $Path.Trim()
    if ([IO.Path]::IsPathRooted($rawPath)) {
        throw "Path must be repository-relative, got rooted path: '$rawPath'."
    }

    $norm = $rawPath.Replace('\', '/') -replace '^\./', ''
    $segments = @($norm -split '/')
    if ([string]::IsNullOrWhiteSpace($norm) -or $norm.Contains(':') -or $segments -contains '.' -or $segments -contains '..') {
        throw "Path is not canonical and repository-contained: '$rawPath'."
    }

    # 1. Lexical containment check
    $candidatePath = [IO.Path]::GetFullPath([IO.Path]::Combine($fullRepoPath, ($norm -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $candidatePath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the repository scope: '$rawPath'."
    }

    # 2. Reparse resolution check (junction, symlink, leaf link containment)
    # The repository root may legitimately be a junction or reparse point (e.g. worktree or link).
    # We resolve the canonical physical root of the repository, then walk all path segments
    # resolving any reparse points. If the resolved path escapes the canonical repository root, reject.
    $canonicalRepoRoot = Resolve-CanonicalDirectoryRoot -Path $fullRepoPath
    $canonicalRepoPrefix = $canonicalRepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    $resolvedCandidatePath = Resolve-CanonicalReparsePath -BasePath $canonicalRepoRoot -RelativeSegments $segments
    if (-not $resolvedCandidatePath.StartsWith($canonicalRepoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the repository scope via reparse traversal: '$rawPath' resolves to '$resolvedCandidatePath'."
    }

    return $norm
}

function Test-EvidenceSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string]$Content = ''
    )

    # Bounded heuristic secret & unsafe provenance detector.
    # NOTICE: This provides defensive heuristic boundary checks against accidental credential,
    # private key, and global config leakage in evidence packets.
    # It does NOT promise exhaustive detection against arbitrary steganography or custom obfuscation.

    $normPath = $Path.Trim().Replace('\', '/') -replace '^\./', '' -replace '^/', ''

    # 1. Secret filename patterns
    if (($normPath -match '(?i)(?:^|/)\.env(?:\.[^/]+)?$' -and $normPath -notmatch '(?i)(?:^|/)\.env\.example$') -or
        $normPath -match '(?i)\.(?:pem|key|pfx|p12)$' -or
        $normPath -match '(?i)(?:^|/)id_(?:rsa|dsa|ecdsa|ed25519)(?:\.pub)?$' -or
        $normPath -match '(?i)(?:^|/)(?:credentials|secrets|tokens?)\.json$') {
        throw "Safety check blocked: path '$normPath' matches forbidden credential or secret pattern."
    }

    # 2. Unsafe provenance & global configuration paths
    if ($normPath -match '(?i)(?:^|/)(?:\.codex|\.gemini|\.serena/project\.local)(?:/|$)' -or
        $normPath -match '(?i)(?:^|/)config\.toml$') {
        throw "Safety check blocked: path '$normPath' references unsafe global config or local profile provenance."
    }

    # 3. Content scanning (heuristic token and credential patterns)
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        # Private keys
        if ($Content -match '-----BEGIN (?:[A-Z0-9_-]+ )?PRIVATE KEY-----') {
            throw "Safety check blocked: payload contains private key header."
        }

        # API keys / tokens (e.g. OpenAI, Anthropic, GitHub, AWS)
        if ($Content -match '\bsk-[a-zA-Z0-9]{20,}\b' -or
            $Content -match '\b(?:sk-ant-|ghp_|gho_|github_pat_|glpat-)[a-zA-Z0-9_\-]{20,}\b' -or
            $Content -match '\bAKIA[0-9A-Z]{16}\b' -or
            $Content -match '\bBearer\s+[A-Za-z0-9_\-]{20,}\b' -or
            $Content -match '(?i)(?:api[_-]?key|secret|password|auth_token)\s*[:=]\s*["\x27][^"\x27]{8,}["\x27]') {
            throw "Safety check blocked: payload contains potential secret or credential token."
        }

        # Raw global configs dump rejection
        if ($Content -match '(?m)^\[(?:mcp_servers|agents|features)(?:\.[^\]]+)?\]') {
            throw "Safety check blocked: raw global config table dump in evidence payload is forbidden."
        }
    }

    return $true
}

function Test-OwnedPathWhitespace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$OwnedPaths
    )

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    if (-not (Test-Path -LiteralPath $fullRepoPath -PathType Container)) {
        throw "Repository path does not exist: $fullRepoPath"
    }

    $defects = New-Object System.Collections.Generic.List[object]
    $filesChecked = 0

    foreach ($p in $OwnedPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }

        $norm = Assert-ContainedRepoPath -RepoPath $fullRepoPath -Path $p
        $diskPath = [IO.Path]::Combine($fullRepoPath, ($norm -replace '/', [IO.Path]::DirectorySeparatorChar))

        if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
            # Absent or deleted files have no whitespace defects on disk
            continue
        }

        $filesChecked++
        $lines = [IO.File]::ReadAllLines($diskPath, [System.Text.Encoding]::UTF8)
        $rawText = [IO.File]::ReadAllText($diskPath, [System.Text.Encoding]::UTF8)

        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            $trimmedLine = $line -replace '\r$', ''

            # Defect 1: Trailing whitespace (spaces or tabs at line end)
            if ($trimmedLine -match '[ \t]+$') {
                $defects.Add([pscustomobject]@{
                    Path = $norm
                    LineNumber = $lineNum
                    DefectType = 'trailing-whitespace'
                    LineContent = $trimmedLine
                })
            }

            # Defect 2: Space before tab at indentation
            if ($trimmedLine -match '^[ ]+\t') {
                $defects.Add([pscustomobject]@{
                    Path = $norm
                    LineNumber = $lineNum
                    DefectType = 'space-before-tab'
                    LineContent = $trimmedLine
                })
            }
        }

        # Defect 3: Blank line at EOF (trailing empty line(s) before EOF)
        if ($rawText -match '(?:\r?\n){2,}$') {
            $defects.Add([pscustomobject]@{
                Path = $norm
                LineNumber = $lines.Count
                DefectType = 'blank-at-eof'
                LineContent = ''
            })
        }
    }

    return [pscustomobject]@{
        Pass = ($defects.Count -eq 0)
        TotalFilesChecked = $filesChecked
        DefectCount = $defects.Count
        Defects = @($defects.ToArray())
        Detail = if ($defects.Count -eq 0) {
            "All $filesChecked owned files passed whitespace validation."
        } else {
            "Detected $($defects.Count) whitespace defect(s) across owned files."
        }
    }
}

function New-EvidencePacket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$OwnedPaths,
        [string]$Baseline = '',
        [object[]]$Artifacts = @(),
        [object[]]$Commands = @(),
        [switch]$SkipWhitespaceCheck
    )

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    if (-not (Test-Path -LiteralPath $fullRepoPath -PathType Container)) {
        throw "Repository path does not exist: $fullRepoPath"
    }

    # 1. Validate owned paths containment
    $normalizedOwnedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($p in $OwnedPaths) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $norm = Assert-ContainedRepoPath -RepoPath $fullRepoPath -Path $p
            if (-not $normalizedOwnedPaths.Contains($norm)) {
                $normalizedOwnedPaths.Add($norm)
            }
        }
    }
    $sortedOwned = @($normalizedOwnedPaths.ToArray())
    [Array]::Sort($sortedOwned, [System.StringComparer]::Ordinal)

    # 2. Compute canonical staging-invariant target identity via backend-routing helper
    $targetIdentity = Get-CodexDeliveryTargetIdentity -RepoPath $fullRepoPath -OwnedPaths $sortedOwned -Baseline $Baseline

    # 3. Validate owned-path whitespace (pure disk inspection, zero Git mutations)
    $wsResult = if ($SkipWhitespaceCheck) {
        [pscustomobject]@{
            Pass = $true
            TotalFilesChecked = 0
            DefectCount = 0
            Defects = @()
            Detail = 'Whitespace check skipped by caller request'
        }
    } else {
        Test-OwnedPathWhitespace -RepoPath $fullRepoPath -OwnedPaths $sortedOwned
    }

    # 4. Process Artifacts with exact hash computation and distinction of missing from pass
    $artifactRecords = New-Object System.Collections.Generic.List[object]
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    foreach ($art in $Artifacts) {
        $artPath = ''
        $artDesc = ''
        $expectedSha = ''

        if ($art -is [string]) {
            $artPath = $art
        } elseif ($art -is [System.Collections.IDictionary]) {
            if ($art.Contains('Path')) { $artPath = [string]$art['Path'] }
            if ($art.Contains('Description')) { $artDesc = [string]$art['Description'] }
            if ($art.Contains('ExpectedSha256')) { $expectedSha = [string]$art['ExpectedSha256'] }
        } else {
            $propPath = $art.PSObject.Properties['Path']
            if ($null -ne $propPath) { $artPath = [string]$propPath.Value }
            $propDesc = $art.PSObject.Properties['Description']
            if ($null -ne $propDesc) { $artDesc = [string]$propDesc.Value }
            $propExpected = $art.PSObject.Properties['ExpectedSha256']
            if ($null -ne $propExpected) { $expectedSha = [string]$propExpected.Value }
        }

        $normArtPath = Assert-ContainedRepoPath -RepoPath $fullRepoPath -Path $artPath
        $null = Test-EvidenceSafety -Path $normArtPath

        $diskArtPath = [IO.Path]::Combine($fullRepoPath, ($normArtPath -replace '/', [IO.Path]::DirectorySeparatorChar))
        $existsOnDisk = Test-Path -LiteralPath $diskArtPath -PathType Leaf

        if (-not $existsOnDisk) {
            # CRITICAL: Missing artifact is distinguished from pass, with explicit Exists=false and Status='missing'
            $artifactRecords.Add([pscustomobject]@{
                Path = $normArtPath
                Description = $artDesc
                Exists = $false
                Status = 'missing'
                Sha256 = $null
                ExpectedSha256 = if ([string]::IsNullOrWhiteSpace($expectedSha)) { $null } else { $expectedSha.ToLowerInvariant() }
                Bytes = 0
                Pass = $false
                Detail = "Artifact does not exist on disk: '$normArtPath'"
            })
            continue
        }

        $fileBytes = [IO.File]::ReadAllBytes($diskArtPath)
        $hashBytes = $sha256.ComputeHash($fileBytes)
        $actualSha = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()

        # Check safety on text content (sample first 64KB if text)
        try {
            $contentSample = [IO.File]::ReadAllText($diskArtPath, [System.Text.Encoding]::UTF8)
            $null = Test-EvidenceSafety -Path $normArtPath -Content $contentSample
        } catch [System.Text.DecoderFallbackException] {
            # Binary file
        }

        $expectedLower = if ([string]::IsNullOrWhiteSpace($expectedSha)) { '' } else { $expectedSha.Trim().ToLowerInvariant() }
        if (-not [string]::IsNullOrWhiteSpace($expectedLower) -and $actualSha -ne $expectedLower) {
            $artifactRecords.Add([pscustomobject]@{
                Path = $normArtPath
                Description = $artDesc
                Exists = $true
                Status = 'drift'
                Sha256 = $actualSha
                ExpectedSha256 = $expectedLower
                Bytes = $fileBytes.Length
                Pass = $false
                Detail = "Artifact SHA256 drift detected: expected '$expectedLower', got '$actualSha'"
            })
        } else {
            $artifactRecords.Add([pscustomobject]@{
                Path = $normArtPath
                Description = $artDesc
                Exists = $true
                Status = 'pass'
                Sha256 = $actualSha
                ExpectedSha256 = if ([string]::IsNullOrWhiteSpace($expectedLower)) { $null } else { $expectedLower }
                Bytes = $fileBytes.Length
                Pass = $true
                Detail = "Artifact verified with matching SHA256"
            })
        }
    }

    # 5. Process Command execution evidence
    $commandRecords = New-Object System.Collections.Generic.List[object]
    foreach ($cmd in $Commands) {
        $cmdStr = ''
        $exitCode = 0
        $cmdDesc = ''
        $cmdOutput = ''

        if ($cmd -is [System.Collections.IDictionary]) {
            if ($cmd.Contains('Command')) { $cmdStr = [string]$cmd['Command'] }
            if ($cmd.Contains('ExitCode')) { $exitCode = [int]$cmd['ExitCode'] }
            if ($cmd.Contains('Description')) { $cmdDesc = [string]$cmd['Description'] }
            if ($cmd.Contains('Output')) { $cmdOutput = [string]$cmd['Output'] }
        } else {
            $propCmd = $cmd.PSObject.Properties['Command']
            if ($null -ne $propCmd) { $cmdStr = [string]$propCmd.Value }
            $propExit = $cmd.PSObject.Properties['ExitCode']
            if ($null -ne $propExit) { $exitCode = [int]$propExit.Value }
            $propDesc = $cmd.PSObject.Properties['Description']
            if ($null -ne $propDesc) { $cmdDesc = [string]$propDesc.Value }
            $propOut = $cmd.PSObject.Properties['Output']
            if ($null -ne $propOut) { $cmdOutput = [string]$propOut.Value }
        }

        # Check safety on command text and output
        $null = Test-EvidenceSafety -Path 'command' -Content "$cmdStr`n$cmdOutput"

        $cmdPass = ($exitCode -eq 0)
        $commandRecords.Add([pscustomobject]@{
            Command = $cmdStr
            ExitCode = $exitCode
            Status = if ($cmdPass) { 'pass' } else { 'failed' }
            Description = $cmdDesc
            Pass = $cmdPass
            Provenance = 'asserted-receipt'
        })
    }

    # 6. Dynamic Counts (NO hardcoded success counts)
    $allArtifacts = @($artifactRecords.ToArray())
    $allCommands = @($commandRecords.ToArray())

    $totalArtifacts = $allArtifacts.Count
    $passedArtifacts = @($allArtifacts | Where-Object { $_.Status -eq 'pass' }).Count
    $missingArtifacts = @($allArtifacts | Where-Object { $_.Status -eq 'missing' }).Count
    $driftArtifacts = @($allArtifacts | Where-Object { $_.Status -eq 'drift' }).Count
    $failedArtifacts = @($allArtifacts | Where-Object { $_.Status -notin @('pass', 'missing', 'drift') }).Count

    $totalCommands = $allCommands.Count
    $passedCommands = @($allCommands | Where-Object { $_.ExitCode -eq 0 }).Count
    $failedCommands = @($allCommands | Where-Object { $_.ExitCode -ne 0 }).Count

    $whitespacePassed = [bool]$wsResult.Pass
    $whitespaceDefects = [int]$wsResult.DefectCount

    $overallPass = ($missingArtifacts -eq 0 -and $driftArtifacts -eq 0 -and $failedArtifacts -eq 0 -and $failedCommands -eq 0 -and $whitespacePassed)
    $status = if ($overallPass) {
        'pass'
    } elseif ($missingArtifacts -gt 0) {
        'missing_artifacts'
    } elseif ($driftArtifacts -gt 0) {
        'hash_drift'
    } elseif ($failedCommands -gt 0) {
        'command_failed'
    } elseif (-not $whitespacePassed) {
        'whitespace_failed'
    } else {
        'failed'
    }

    return [pscustomobject]@{
        SchemaVersion = '1.0'
        GeneratedAt = [DateTime]::UtcNow.ToString('o')
        Pass = $overallPass
        Status = $status
        TargetIdentity = [pscustomobject]@{
            TargetId = $targetIdentity.TargetId
            Baseline = $targetIdentity.Baseline
            HeadStatus = $targetIdentity.HeadStatus
            DiffSha256 = $targetIdentity.DiffSha256
            FileSha256 = $targetIdentity.FileSha256
            OwnedPaths = $sortedOwned
        }
        Summary = [pscustomobject]@{
            TotalArtifacts = $totalArtifacts
            PassedArtifacts = $passedArtifacts
            MissingArtifacts = $missingArtifacts
            DriftArtifacts = $driftArtifacts
            FailedArtifacts = $failedArtifacts
            TotalCommands = $totalCommands
            PassedCommands = $passedCommands
            FailedCommands = $failedCommands
            WhitespacePassed = $whitespacePassed
            WhitespaceDefects = $whitespaceDefects
        }
        Artifacts = $allArtifacts
        Commands = $allCommands
        Whitespace = $wsResult
    }
}

function Test-EvidencePacket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][object]$Packet,
        [switch]$SkipWhitespaceCheck
    )

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    if (-not (Test-Path -LiteralPath $fullRepoPath -PathType Container)) {
        throw "Repository path does not exist: $fullRepoPath"
    }

    if ($null -eq $Packet -or $null -eq $Packet.TargetIdentity) {
        throw "Invalid evidence packet: TargetIdentity missing."
    }

    # 1. Recompute target identity and compare with bound target
    $boundTargetId = [string]$Packet.TargetIdentity.TargetId
    $baseline = [string]$Packet.TargetIdentity.Baseline
    $ownedPaths = @($Packet.TargetIdentity.OwnedPaths)

    $recomputedTarget = Get-CodexDeliveryTargetIdentity -RepoPath $fullRepoPath -OwnedPaths $ownedPaths -Baseline $baseline
    $identityMatch = ($recomputedTarget.TargetId -ceq $boundTargetId)

    # 2. Re-verify artifacts on disk and compare hashes against recorded and expected digests
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $driftedArtifacts = New-Object System.Collections.Generic.List[object]
    $missingArtifacts = New-Object System.Collections.Generic.List[object]

    if ($null -ne $Packet.Artifacts) {
        foreach ($art in $Packet.Artifacts) {
            $norm = Assert-ContainedRepoPath -RepoPath $fullRepoPath -Path ([string]$art.Path)
            $diskPath = [IO.Path]::Combine($fullRepoPath, ($norm -replace '/', [IO.Path]::DirectorySeparatorChar))

            $existsOnDisk = Test-Path -LiteralPath $diskPath -PathType Leaf
            $recordedExists = if ($null -ne $art.PSObject.Properties['Exists']) { [bool]$art.Exists } else { $true }

            if (-not $existsOnDisk) {
                if ($recordedExists) {
                    $missingArtifacts.Add([pscustomobject]@{
                        Path = $norm
                        ExpectedSha = [string]$art.Sha256
                        Reason = 'Artifact recorded as existing is now missing on disk'
                    })
                }
                continue
            }

            # File exists on disk
            $fileBytes = [IO.File]::ReadAllBytes($diskPath)
            $hashBytes = $sha256.ComputeHash($fileBytes)
            $currentSha = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()

            # If artifact was recorded as missing, but now unexpectedly exists on disk:
            if (-not $recordedExists) {
                $driftedArtifacts.Add([pscustomobject]@{
                    Path = $norm
                    RecordedSha = $null
                    ExpectedSha = if ($null -ne $art.PSObject.Properties['ExpectedSha256']) { [string]$art.ExpectedSha256 } else { $null }
                    CurrentSha = $currentSha
                    Reason = "Artifact recorded as missing now unexpectedly exists on disk with hash '$currentSha'"
                })
                continue
            }

            $recordedSha = if ($null -ne $art.PSObject.Properties['Sha256'] -and -not [string]::IsNullOrWhiteSpace([string]$art.Sha256)) {
                ([string]$art.Sha256).Trim().ToLowerInvariant()
            } else {
                ''
            }

            $expectedSha = if ($null -ne $art.PSObject.Properties['ExpectedSha256'] -and -not [string]::IsNullOrWhiteSpace([string]$art.ExpectedSha256)) {
                ([string]$art.ExpectedSha256).Trim().ToLowerInvariant()
            } else {
                ''
            }

            $hasRecordedMismatch = (-not [string]::IsNullOrWhiteSpace($recordedSha) -and $currentSha -ne $recordedSha)
            $hasExpectedMismatch = (-not [string]::IsNullOrWhiteSpace($expectedSha) -and $currentSha -ne $expectedSha)

            if ($hasRecordedMismatch -or $hasExpectedMismatch) {
                $reason = if ($hasRecordedMismatch -and $hasExpectedMismatch) {
                    "Artifact hash '$currentSha' drifts from both recorded '$recordedSha' and expected '$expectedSha'"
                } elseif ($hasRecordedMismatch) {
                    "Artifact hash '$currentSha' drifts from recorded hash '$recordedSha'"
                } else {
                    "Artifact hash '$currentSha' drifts from expected hash '$expectedSha'"
                }

                $driftedArtifacts.Add([pscustomobject]@{
                    Path = $norm
                    RecordedSha = if ([string]::IsNullOrWhiteSpace($recordedSha)) { $null } else { $recordedSha }
                    ExpectedSha = if ([string]::IsNullOrWhiteSpace($expectedSha)) { $null } else { $expectedSha }
                    CurrentSha = $currentSha
                    Reason = $reason
                })
            }
        }
    }

    $hashMatch = ($driftedArtifacts.Count -eq 0 -and $missingArtifacts.Count -eq 0)

    # 3. Whitespace re-check
    $wsResult = if ($SkipWhitespaceCheck) {
        $null
    } else {
        Test-OwnedPathWhitespace -RepoPath $fullRepoPath -OwnedPaths $ownedPaths
    }
    $wsMatch = if ($null -eq $wsResult) { $true } else { [bool]$wsResult.Pass }

    # 4. Command receipt verification (asserted receipts evaluation, NOT fake re-execution)
    # NOTICE: Command exit codes in an evidence packet are caller-asserted execution receipts.
    # Test-EvidencePacket verifies the structure and recorded pass status of these receipts.
    # It does NOT re-execute commands, preserving safety and avoiding arbitrary side effects.
    $commandPass = $true
    if ($null -ne $Packet.Commands) {
        foreach ($cmd in $Packet.Commands) {
            $exitCode = if ($null -ne $cmd.PSObject.Properties['ExitCode']) { [int]$cmd.ExitCode } else { -1 }
            $isPass = if ($null -ne $cmd.PSObject.Properties['Pass']) { [bool]$cmd.Pass } else { ($exitCode -eq 0) }
            if ($exitCode -ne 0 -or -not $isPass) {
                $commandPass = $false
            }
        }
    }

    $targetDrift = (-not $identityMatch)
    $pass = ($identityMatch -and $hashMatch -and $wsMatch -and $commandPass -and $Packet.Pass)

    return [pscustomobject]@{
        Pass = $pass
        IdentityMatch = $identityMatch
        TargetDrift = $targetDrift
        HashMatch = $hashMatch
        WhitespaceMatch = $wsMatch
        CommandsVerified = $commandPass
        CommandProvenance = 'asserted-receipt'
        BoundTargetId = $boundTargetId
        RecomputedTargetId = $recomputedTarget.TargetId
        DriftedArtifacts = @($driftedArtifacts.ToArray())
        MissingArtifacts = @($missingArtifacts.ToArray())
        Whitespace = $wsResult
        Detail = if ($pass) {
            "Evidence packet deterministically verified against disk and repository state (commands verified as caller-asserted receipts)."
        } else {
            "Evidence packet verification failed (IdentityMatch=$identityMatch, TargetDrift=$targetDrift, HashMatch=$hashMatch, WhitespaceMatch=$wsMatch, CommandsVerified=$commandPass)."
        }
    }
}

Export-ModuleMember -Function @(
    'Resolve-CanonicalReparsePath',
    'Resolve-CanonicalDirectoryRoot',
    'Assert-ContainedRepoPath',
    'Test-EvidenceSafety',
    'Test-OwnedPathWhitespace',
    'New-EvidencePacket',
    'Test-EvidencePacket'
)
