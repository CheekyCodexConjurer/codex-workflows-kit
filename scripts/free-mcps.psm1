# scripts/free-mcps.psm1
# Core module for free MCPs: codebase-memory-mcp v0.10.8 and Context7 (remote)
# Strict zero-billing, explicit pin, safe zip extraction, delimited rollback

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-CbmMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$Arch = ''
    )

    if (-not $Arch) {
        try {
            $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
            $Arch = if ($osArch -eq 'Arm64') { 'arm64' } else { 'amd64' }
        } catch {
            if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
                $Arch = 'arm64'
            } else {
                $Arch = 'amd64'
            }
        }
    }

    $version = 'v0.10.8'
    $archiveHashes = @{
        'amd64' = 'b43ad982994c4d829670749e08d3b622a74bb20041fc0a7d02bef6113f81c34d'
        'arm64' = '254b26e819f00bab7f430c5f809d37d22b07bb3eb6427e290e5a27ba5b8e983e'
    }
    $binaryHashes = @{
        'amd64' = 'b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6'
        'arm64' = '67b0341ee62f07f850d3954e4f387855f90ea8c6c4b7ed41b8a62d61344373a4'
    }

    if (-not $archiveHashes.ContainsKey($Arch)) {
        throw "Unsupported architecture: $Arch. Only amd64 and arm64 are officially supported on Windows."
    }

    $archiveName = "codebase-memory-mcp-windows-$Arch.zip"
    $downloadUrl = "https://github.com/DeusData/codebase-memory-mcp/releases/download/$version/$archiveName"

    return [pscustomobject]@{
        Version       = $version
        Architecture  = $Arch
        ArchiveName   = $archiveName
        ArchiveSha256 = $archiveHashes[$Arch]
        BinaryName    = 'codebase-memory-mcp.exe'
        BinarySha256  = $binaryHashes[$Arch]
        DownloadUrl   = $downloadUrl
        AllowedFiles  = @(
            'codebase-memory-mcp.exe',
            'LICENSE',
            'install.ps1',
            'THIRD_PARTY_NOTICES.md'
        )
    }
}

function Get-Context7Metadata {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        ServerUrl            = 'https://mcp.context7.com/mcp'
        BillingStatus        = 'unproven_anonymous_intent'
        BillingTier          = 'unproven'
        RequiresAuth         = $false
        EnforceNoAuth        = $true
        OAuthStatus          = 'unknown'
        ConfigSafetyExpected = 'verified_no_credentials'
    }
}

function Assert-NotBroadOrInvalidRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Root validation error: $Name cannot be empty or whitespace."
    }

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/')

    if ($full -eq $root -or [string]::IsNullOrEmpty($full)) {
        throw "Root validation error: $Name '$Path' is a filesystem root; broad roots are prohibited."
    }

    if ($env:SystemRoot) {
        $sysRoot = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\', '/')
        if ($full.Equals($sysRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($sysRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Root validation error: $Name '$Path' resides in system directory; broad roots are prohibited."
        }
    }

    if ($env:ProgramFiles) {
        $progFiles = [System.IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\', '/')
        if ($full.Equals($progFiles, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($progFiles + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Root validation error: $Name '$Path' resides in Program Files directory; broad roots are prohibited."
        }
    }

    if (${env:ProgramFiles(x86)}) {
        $progFilesX86 = [System.IO.Path]::GetFullPath(${env:ProgramFiles(x86)}).TrimEnd('\', '/')
        if ($full.Equals($progFilesX86, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($progFilesX86 + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Root validation error: $Name '$Path' resides in Program Files (x86) directory; broad roots are prohibited."
        }
    }

    if ($env:USERPROFILE) {
        $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
        if ($full.Equals($userProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Root validation error: $Name '$Path' is user profile home root; configuring user home directly is prohibited."
        }
    }
}

function Assert-ValidStateRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$false)][string]$CodexHome = '',
        [Parameter(Mandatory=$false)][string]$AntigravityHome = '',
        [Parameter(Mandatory=$false)][string]$InstallRoot = ''
    )

    Assert-NotBroadOrInvalidRoot -Path $StateRoot -Name 'StateRoot'

    if (Test-IsReparsePoint -Path $StateRoot) {
        throw "Security violation: StateRoot '$StateRoot' is a reparse point (junction/symlink). Reparse points are prohibited."
    }

    $fullState = [System.IO.Path]::GetFullPath($StateRoot).TrimEnd('\', '/')
    $cacheDir = [System.IO.Path]::GetFullPath((Join-Path $fullState 'cache')).TrimEnd('\', '/')
    $runtimeDir = [System.IO.Path]::GetFullPath((Join-Path $fullState 'runtime')).TrimEnd('\', '/')

    Assert-NotBroadOrInvalidRoot -Path $cacheDir -Name 'CBM_CACHE_DIR'
    Assert-NotBroadOrInvalidRoot -Path $runtimeDir -Name 'CBM_RUNTIME_DIR'

    if ($cacheDir.Equals($runtimeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Overlap violation: CBM_CACHE_DIR and CBM_RUNTIME_DIR cannot be identical: '$cacheDir'."
    }

    if ($cacheDir.StartsWith($runtimeDir + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        $runtimeDir.StartsWith($cacheDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Overlap violation: CBM_CACHE_DIR and CBM_RUNTIME_DIR cannot be subdirectories of each other."
    }

    if (Test-Path -LiteralPath $cacheDir) {
        if (Test-IsReparsePoint -Path $cacheDir) {
            throw "Security violation: CBM_CACHE_DIR '$cacheDir' is a reparse point."
        }
    }
    if (Test-Path -LiteralPath $runtimeDir) {
        if (Test-IsReparsePoint -Path $runtimeDir) {
            throw "Security violation: CBM_RUNTIME_DIR '$runtimeDir' is a reparse point."
        }
    }

    $otherRoots = @{
        'CodexHome'       = $CodexHome
        'AntigravityHome' = $AntigravityHome
        'InstallRoot'     = $InstallRoot
    }

    foreach ($entry in $otherRoots.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace($entry.Value)) {
            $otherFull = [System.IO.Path]::GetFullPath($entry.Value).TrimEnd('\', '/')
            if ($fullState.Equals($otherFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Overlap violation: StateRoot '$fullState' cannot be identical to $($entry.Key) '$otherFull'."
            }
            if ($fullState.StartsWith($otherFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Overlap violation: StateRoot '$fullState' cannot reside inside $($entry.Key) '$otherFull'."
            }
            if ($otherFull.StartsWith($fullState + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Overlap violation: $($entry.Key) '$otherFull' cannot reside inside StateRoot '$fullState'."
            }
        }
    }

    return [pscustomobject]@{
        StateRoot  = $fullState
        CacheDir   = $cacheDir
        RuntimeDir = $runtimeDir
    }
}

function Format-TomlStringValue {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Value)

    if ($Value.Contains("'")) {
        $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
        return "`"$escaped`""
    } else {
        return "'$Value'"
    }
}

function Test-IsReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool](($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $item.LinkType)
    } catch {
        return $false
    }
}

function Assert-NoInternalReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$false)][string]$AllowedRoot = ''
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    if (Test-IsReparsePoint -Path $Path) {
        throw "Security violation: Path '$Path' is a reparse point (junction/symlink). Reparse points are prohibited."
    }

    if ($AllowedRoot) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\', '/')
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
        $parent = Split-Path -Parent $resolvedPath
        while ($parent -and $parent.Length -gt $resolvedRoot.Length) {
            if ($parent.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            if (Test-IsReparsePoint -Path $parent) {
                throw "Security violation: Intermediate directory '$parent' under '$AllowedRoot' is a reparse point. Traversing internal reparse points is prohibited."
            }
            $parent = Split-Path -Parent $parent
        }
    }
}

function Remove-CheckedTempDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $resolvedTarget = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')

    if ($resolvedTarget.Length -le $tempRoot.Length -or
        -not $resolvedTarget.StartsWith($tempRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Security violation: Temp directory cleanup path '$resolvedTarget' is not strictly inside system temp directory '$tempRoot'."
    }

    if (-not (Test-Path -LiteralPath $resolvedTarget)) { return }

    if (Test-IsReparsePoint -Path $resolvedTarget) {
        throw "Security violation: Temp directory '$resolvedTarget' is a reparse point; refusing recursive deletion."
    }

    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction SilentlyContinue
}

function Assert-ArchiveSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Archive path does not exist: $Path"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "CHECKSUM MISMATCH: archive SHA256 mismatch. Expected: $expected, Actual: $actual"
    }
}

function Assert-ZipSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$false)][string[]]$AllowedNames = @()
    )

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "Zip archive does not exist: $ZipPath"
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            $isDirectory = $entryName.EndsWith('/')
            $pathForSegments = if ($isDirectory) { $entryName.TrimEnd('/') } else { $entryName }
            $segments = @($pathForSegments.Split('/'))

            if ([string]::IsNullOrWhiteSpace($pathForSegments) -or
                $entryName.StartsWith('/') -or
                $entryName.Contains(':') -or
                $segments -contains '' -or
                $segments -contains '.' -or
                $segments -contains '..' -or
                @($segments | Where-Object { $_.EndsWith('.') -or $_.EndsWith(' ') }).Count -gt 0) {
                throw "unsafe zip entry path (path traversal detected): $($entry.FullName)"
            }

            if (-not $seen.Add($pathForSegments)) {
                throw "duplicate or case-conflicting zip entry: $($entry.FullName)"
            }

            if ($AllowedNames.Count -gt 0 -and -not ($AllowedNames -ccontains $entryName) -and -not $isDirectory) {
                throw "archive contains an unexpected entry not in allowlist: $($entry.FullName)"
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Expand-CbmArchiveSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$DestinationPath,
        [Parameter(Mandatory=$true)][string]$ExpectedBinarySha256,
        [Parameter(Mandatory=$false)][string[]]$AllowedNames = @(),
        [Parameter(Mandatory=$false)][string]$BinaryName = 'codebase-memory-mcp.exe'
    )

    Assert-ZipSafe -ZipPath $ZipPath -AllowedNames $AllowedNames

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if ($entryName.EndsWith('/')) {
                continue
            }
            $destFile = Join-Path $DestinationPath $entryName
            $parent = Split-Path -Parent $destFile
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destFile, $true)
        }
    } finally {
        $zip.Dispose()
    }

    $extractedBinary = Join-Path $DestinationPath $BinaryName
    if (-not (Test-Path -LiteralPath $extractedBinary -PathType Leaf)) {
        throw "Binary $BinaryName was not found in destination $DestinationPath after extraction."
    }

    $actualBinHash = (Get-FileHash -LiteralPath $extractedBinary -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedBinHash = $ExpectedBinarySha256.Trim().ToLowerInvariant()
    if ($actualBinHash -ne $expectedBinHash) {
        Remove-Item -LiteralPath $extractedBinary -Force -ErrorAction SilentlyContinue
        throw "CHECKSUM MISMATCH: binary hash mismatch inside archive. Expected: $expectedBinHash, Actual: $actualBinHash"
    }

    return $extractedBinary
}

function Test-Context7ConfigSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][ValidateSet('codex', 'gemini')][string]$ConfigType
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return
    }

    if ($ConfigType -eq 'gemini') {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        try {
            $parsed = $raw | ConvertFrom-Json
        } catch {
            return
        }

        if ($parsed -and $parsed.PSObject.Properties['mcpServers']) {
            $servers = $parsed.mcpServers
            if ($servers.PSObject.Properties['context7']) {
                $ctx7 = $servers.context7
                $suspectProperties = @('headers', 'authorization', 'auth', 'apiKey', 'api_key', 'token', 'bearer')
                foreach ($prop in $suspectProperties) {
                    if ($ctx7.PSObject.Properties[$prop]) {
                        throw "Negative security gate: detected existing Context7 auth/credentials property '$prop' in Gemini configuration. Free tier requires zero billing credentials and no unproven costs."
                    }
                }
            }
        }
    } elseif ($ConfigType -eq 'codex') {
        $lines = Get-Content -LiteralPath $ConfigPath
        $inCtx7 = $false
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[mcp_servers\.context7\]' -or $trimmed -match '^\[mcp_servers\."context7"\]') {
                $inCtx7 = $true
                continue
            }
            if ($inCtx7 -and $trimmed -match '^\s*\[') {
                $inCtx7 = $false
            }
            if ($inCtx7) {
                if ($trimmed -match '^(headers|authorization|auth|api_key|token|bearer)\s*=') {
                    $matchedField = $Matches[1]
                    throw "Negative security gate: detected existing Context7 auth/credentials property '$matchedField' in Codex configuration. Free tier requires zero billing credentials and no unproven costs."
                }
            }
        }
    }
}

function Get-MergedCodexTomlContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$CbmBinaryPath,
        [Parameter(Mandatory=$false)][string]$Context7Endpoint = 'https://mcp.context7.com/mcp',
        [Parameter(Mandatory=$false)][string]$CacheDir = '',
        [Parameter(Mandatory=$false)][string]$RuntimeDir = ''
    )

    Test-Context7ConfigSafety -ConfigPath $ConfigPath -ConfigType 'codex'

    $existingContent = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($ConfigPath)
    } else {
        ""
    }

    # Normalize newlines
    $normalized = $existingContent -replace "`r`n", "`n"
    $lines = [System.Collections.Generic.List[string]]::new($normalized.Split("`n"))

    $cbmSectionIndex = -1
    $ctx7SectionIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -match '^\[mcp_servers\.codebase-memory-mcp\]' -or $line -match '^\[mcp_servers\."codebase-memory-mcp"\]') {
            $cbmSectionIndex = $i
        }
        if ($line -match '^\[mcp_servers\.context7\]' -or $line -match '^\[mcp_servers\."context7"\]') {
            $ctx7SectionIndex = $i
        }
    }

    $cbmCommandToml = Format-TomlStringValue -Value $CbmBinaryPath
    $cbmBlock = @"
[mcp_servers.codebase-memory-mcp]
command = $cbmCommandToml
args = []
"@ -replace "`r`n", "`n"

    if (-not [string]::IsNullOrWhiteSpace($CacheDir) -and -not [string]::IsNullOrWhiteSpace($RuntimeDir)) {
        $cbmCacheToml = Format-TomlStringValue -Value $CacheDir
        $cbmRuntimeToml = Format-TomlStringValue -Value $RuntimeDir
        $cbmBlock += @"

[mcp_servers.codebase-memory-mcp.env]
CBM_CACHE_DIR = $cbmCacheToml
CBM_RUNTIME_DIR = $cbmRuntimeToml
"@ -replace "`r`n", "`n"
    }

    $ctx7Block = @"
[mcp_servers.context7]
url = "$Context7Endpoint"
"@ -replace "`r`n", "`n"

    $outContent = $normalized

    if ($cbmSectionIndex -eq -1) {
        if (-not [string]::IsNullOrWhiteSpace($outContent) -and -not $outContent.EndsWith("`n`n")) {
            if ($outContent.EndsWith("`n")) { $outContent += "`n" } else { $outContent += "`n`n" }
        }
        $outContent += $cbmBlock + "`n"
    }

    if ($ctx7SectionIndex -eq -1) {
        if (-not [string]::IsNullOrWhiteSpace($outContent) -and -not $outContent.EndsWith("`n`n")) {
            if ($outContent.EndsWith("`n")) { $outContent += "`n" } else { $outContent += "`n`n" }
        }
        $outContent += $ctx7Block + "`n"
    }

    return ($outContent -replace "`n", "`r`n")
}

function Merge-CodexToml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$CbmBinaryPath,
        [Parameter(Mandatory=$false)][string]$Context7Endpoint = 'https://mcp.context7.com/mcp',
        [Parameter(Mandatory=$false)][string]$CacheDir = '',
        [Parameter(Mandatory=$false)][string]$RuntimeDir = ''
    )

    $parent = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $mergedContent = Get-MergedCodexTomlContent `
        -ConfigPath $ConfigPath `
        -CbmBinaryPath $CbmBinaryPath `
        -Context7Endpoint $Context7Endpoint `
        -CacheDir $CacheDir `
        -RuntimeDir $RuntimeDir
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ConfigPath, $mergedContent, $utf8NoBom)
}

function Get-MergedGeminiJsonContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$CbmBinaryPath,
        [Parameter(Mandatory=$false)][string]$Context7Endpoint = 'https://mcp.context7.com/mcp',
        [Parameter(Mandatory=$false)][string]$CacheDir = '',
        [Parameter(Mandatory=$false)][string]$RuntimeDir = ''
    )

    Test-Context7ConfigSafety -ConfigPath $ConfigPath -ConfigType 'gemini'

    $jsonDict = [ordered]@{}
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $parsed = $raw | ConvertFrom-Json -AsHashtable
                if ($parsed -is [System.Collections.IDictionary]) {
                    foreach ($key in $parsed.Keys) {
                        $jsonDict[$key] = $parsed[$key]
                    }
                }
            } catch {
                throw "Invalid JSON in Gemini configuration at ${ConfigPath} - $_"
            }
        }
    }

    if (-not $jsonDict.Contains('mcpServers') -or -not ($jsonDict['mcpServers'] -is [System.Collections.IDictionary])) {
        $jsonDict['mcpServers'] = [ordered]@{}
    }

    $cbmEntry = [ordered]@{
        command = $CbmBinaryPath
        args    = @()
    }
    if (-not [string]::IsNullOrWhiteSpace($CacheDir) -and -not [string]::IsNullOrWhiteSpace($RuntimeDir)) {
        $cbmEntry['env'] = [ordered]@{
            CBM_CACHE_DIR   = $CacheDir
            CBM_RUNTIME_DIR = $RuntimeDir
        }
    }
    $ctx7Entry = [ordered]@{
        serverUrl = $Context7Endpoint
    }

    $jsonDict['mcpServers']['codebase-memory-mcp'] = $cbmEntry
    $jsonDict['mcpServers']['context7'] = $ctx7Entry

    $jsonText = $jsonDict | ConvertTo-Json -Depth 100
    return ($jsonText -replace "`r?`n", "`r`n")
}

function Merge-GeminiMcpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$CbmBinaryPath,
        [Parameter(Mandatory=$false)][string]$Context7Endpoint = 'https://mcp.context7.com/mcp',
        [Parameter(Mandatory=$false)][string]$CacheDir = '',
        [Parameter(Mandatory=$false)][string]$RuntimeDir = ''
    )

    $parent = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $mergedContent = Get-MergedGeminiJsonContent `
        -ConfigPath $ConfigPath `
        -CbmBinaryPath $CbmBinaryPath `
        -Context7Endpoint $Context7Endpoint `
        -CacheDir $CacheDir `
        -RuntimeDir $RuntimeDir
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ConfigPath, $mergedContent, $utf8NoBom)
}

function Remove-CodexTomlSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string[]]$SectionNames
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }

    $raw = [System.IO.File]::ReadAllText($ConfigPath) -replace "`r`n", "`n"
    $lines = $raw.Split("`n")
    $resultLines = [System.Collections.Generic.List[string]]::new()

    $skipping = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $matchedTarget = $false
        foreach ($sec in $SectionNames) {
            $secPattern = "^\[mcp_servers\.(" + [regex]::Escape($sec) + "|" + """" + [regex]::Escape($sec) + """" + ")(\.|\s*\])"
            if ($trimmed -match $secPattern) {
                $matchedTarget = $true
                break
            }
        }

        if ($matchedTarget) {
            $skipping = $true
            continue
        }

        if ($skipping -and $trimmed -match '^\s*\[') {
            $skipping = $false
        }

        if (-not $skipping) {
            $resultLines.Add($line)
        }
    }

    # Cleanup excess trailing empty lines
    while ($resultLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($resultLines[$resultLines.Count - 1])) {
        $resultLines.RemoveAt($resultLines.Count - 1)
    }

    $newContent = [string]::Join("`r`n", $resultLines) + "`r`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ConfigPath, $newContent, $utf8NoBom)
}

function Remove-GeminiMcpServers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string[]]$ServerNames
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $jsonObj = $raw | ConvertFrom-Json

    if ($jsonObj.PSObject.Properties['mcpServers']) {
        foreach ($s in $ServerNames) {
            if ($jsonObj.mcpServers.PSObject.Properties[$s]) {
                $jsonObj.mcpServers.PSObject.Properties.Remove($s)
            }
        }
    }

    $jsonText = $jsonObj | ConvertTo-Json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ConfigPath, ($jsonText -replace "`r?`n", "`r`n"), $utf8NoBom)
}

function Resolve-GeminiMcpConfigPath {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AntigravityHome)

    # Check direct config/mcp_config.json
    $direct = Join-Path $AntigravityHome 'config\mcp_config.json'
    if (Test-Path -LiteralPath $direct) { return $direct }

    # Check .gemini/config/mcp_config.json
    $dotGemini = Join-Path $AntigravityHome '.gemini\config\mcp_config.json'
    if (Test-Path -LiteralPath $dotGemini) { return $dotGemini }

    # Default location based on whether AntigravityHome already ends in .gemini
    if ($AntigravityHome.TrimEnd('\', '/').EndsWith('.gemini', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $direct
    } else {
        return $dotGemini
    }
}

function Invoke-FreeMcpsInstallWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$CodexHome = '',
        [Parameter(Mandatory=$false)][string]$AntigravityHome = '',
        [Parameter(Mandatory=$false)][string]$InstallRoot = '',
        [Parameter(Mandatory=$false)][string]$StateRoot = '',
        [Parameter(Mandatory=$false)][string]$OfflineArchive = '',
        [Parameter(Mandatory=$false)][bool]$SkipBinaryDownload = $false,
        [Parameter(Mandatory=$false)][string]$ExpectedBinarySha = ''
    )

    if (-not $CodexHome) {
        $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    }
    if (-not $AntigravityHome) {
        $AntigravityHome = if ($env:ANTIGRAVITY_HOME) { $env:ANTIGRAVITY_HOME } else { Join-Path $env:USERPROFILE '.gemini' }
    }
    if (-not $InstallRoot) {
        $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\codebase-memory-mcp'
    }
    if (-not $StateRoot) {
        $userProfilePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { [System.Environment]::GetFolderPath('UserProfile') }
        $StateRoot = Join-Path $userProfilePath '.cbm-state'
    }

    # Validate roots (reject broad/system/empty roots and reparse on InstallRoot)
    Assert-NotBroadOrInvalidRoot -Path $CodexHome -Name 'CodexHome'
    Assert-NotBroadOrInvalidRoot -Path $AntigravityHome -Name 'AntigravityHome'
    Assert-NotBroadOrInvalidRoot -Path $InstallRoot -Name 'InstallRoot'

    if (Test-IsReparsePoint -Path $InstallRoot) {
        throw "Security violation: InstallRoot cannot be a reparse point: $InstallRoot"
    }

    $validatedState = Assert-ValidStateRoot `
        -StateRoot $StateRoot `
        -CodexHome $CodexHome `
        -AntigravityHome $AntigravityHome `
        -InstallRoot $InstallRoot

    $resolvedStateRoot = $validatedState.StateRoot
    $resolvedCacheDir = $validatedState.CacheDir
    $resolvedRuntimeDir = $validatedState.RuntimeDir

    $cbmMeta = Get-CbmMetadata
    $ctx7Meta = Get-Context7Metadata

    $officialSha = $cbmMeta.BinarySha256
    $effectiveExpectedBinarySha = $officialSha

    if (-not [string]::IsNullOrWhiteSpace($ExpectedBinarySha)) {
        $cleanSha = $ExpectedBinarySha.Trim().ToLowerInvariant()
        if ($cleanSha -eq $officialSha.ToLowerInvariant()) {
            $effectiveExpectedBinarySha = $officialSha
        } else {
            if ($env:FREE_MCPS_TEST_ALLOW_SHA_OVERRIDE -eq '1') {
                $effectiveExpectedBinarySha = $cleanSha
            } else {
                throw "Public CLI pin violation: ExpectedBinarySha override is restricted to internal tests and must match official pinned digest ($officialSha)."
            }
        }
    }

    $codexTomlPath = Join-Path $CodexHome 'config.toml'
    $geminiJsonPath = Resolve-GeminiMcpConfigPath -AntigravityHome $AntigravityHome
    $binaryDest = Join-Path $InstallRoot $cbmMeta.BinaryName
    $manifestPath = Join-Path $InstallRoot 'free-mcps-manifest.json'

    # Assert no reparse points on existing targets before any operation
    Assert-NoInternalReparsePoint -Path $binaryDest -AllowedRoot $InstallRoot
    Assert-NoInternalReparsePoint -Path $codexTomlPath -AllowedRoot $CodexHome
    Assert-NoInternalReparsePoint -Path $geminiJsonPath -AllowedRoot $AntigravityHome

    # PHASE 1: Preflight BOTH configs BEFORE any download, extraction, or disk writes
    Test-Context7ConfigSafety -ConfigPath $codexTomlPath -ConfigType 'codex'
    Test-Context7ConfigSafety -ConfigPath $geminiJsonPath -ConfigType 'gemini'

    if (Test-Path -LiteralPath $geminiJsonPath -PathType Leaf) {
        $gRaw = Get-Content -LiteralPath $geminiJsonPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($gRaw)) {
            try {
                $null = $gRaw | ConvertFrom-Json
            } catch {
                throw "Invalid JSON syntax in Gemini configuration at ${geminiJsonPath} - $_"
            }
        }
    }

    # PHASE 2: Check for existing installation (idempotency or fail closed on drift)
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Assert-NoInternalReparsePoint -Path $manifestPath -AllowedRoot $InstallRoot

        $existingRaw = Get-Content -LiteralPath $manifestPath -Raw
        $existingManifest = $null
        try {
            $existingManifest = $existingRaw | ConvertFrom-Json
        } catch {
            throw "Corrupted installation manifest found at $manifestPath. Rollback or remove manually before installing."
        }

        if (-not $existingManifest -or -not $existingManifest.CodexToml -or -not $existingManifest.GeminiJson -or -not $existingManifest.BinaryPath) {
            throw "Invalid manifest structure found at $manifestPath. Reinstallation cannot proceed over invalid manifest. Run Rollback first."
        }

        # Check binary exact match
        $binMatches = (Test-Path -LiteralPath $binaryDest -PathType Leaf) -and
                      -not (Test-IsReparsePoint -Path $binaryDest) -and
                      ((Get-FileHash -LiteralPath $binaryDest -Algorithm SHA256).Hash.ToLowerInvariant() -eq $effectiveExpectedBinarySha)

        # Check manifest state root and env paths match
        $manifestStateMatches = $false
        if ($existingManifest.PSObject.Properties['CbmCacheDir'] -and $existingManifest.PSObject.Properties['CbmRuntimeDir']) {
            if ($existingManifest.CbmCacheDir -eq $resolvedCacheDir -and $existingManifest.CbmRuntimeDir -eq $resolvedRuntimeDir) {
                $manifestStateMatches = $true
            }
        }

        # Check Codex exact match: post-install hash, target command/url, and env paths
        $codexMatches = $false
        if (Test-Path -LiteralPath $codexTomlPath -PathType Leaf) {
            Assert-NoInternalReparsePoint -Path $codexTomlPath -AllowedRoot $CodexHome
            $curCodexSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $expectedCodexSha = if ($existingManifest.CodexToml.PostInstallSha256) { $existingManifest.CodexToml.PostInstallSha256.ToLowerInvariant() } else { '' }
            if ($curCodexSha -eq $expectedCodexSha) {
                $cTxt = [System.IO.File]::ReadAllText($codexTomlPath)
                $hasCbmCommand = $cTxt.Contains("command = '$binaryDest'") -or $cTxt.Contains("command = `"$($binaryDest.Replace('\','\\'))`"") -or $cTxt.Contains("command = `"$binaryDest`"")
                $hasCtx7Url = $cTxt.Contains("url = `"$($ctx7Meta.ServerUrl)`"") -or $cTxt.Contains("url = '$($ctx7Meta.ServerUrl)'")
                $hasCbmCache = $cTxt.Contains("CBM_CACHE_DIR = '$resolvedCacheDir'") -or $cTxt.Contains("CBM_CACHE_DIR = `"$($resolvedCacheDir.Replace('\','\\'))`"")
                $hasCbmRuntime = $cTxt.Contains("CBM_RUNTIME_DIR = '$resolvedRuntimeDir'") -or $cTxt.Contains("CBM_RUNTIME_DIR = `"$($resolvedRuntimeDir.Replace('\','\\'))`"")
                if ($hasCbmCommand -and $hasCtx7Url -and $hasCbmCache -and $hasCbmRuntime) {
                    $codexMatches = $true
                }
            }
        }

        # Check Gemini exact match: post-install hash, target command/url, and env paths
        $geminiMatches = $false
        if (Test-Path -LiteralPath $geminiJsonPath -PathType Leaf) {
            Assert-NoInternalReparsePoint -Path $geminiJsonPath -AllowedRoot $AntigravityHome
            $curGeminiSha = (Get-FileHash -LiteralPath $geminiJsonPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $expectedGeminiSha = if ($existingManifest.GeminiJson.PostInstallSha256) { $existingManifest.GeminiJson.PostInstallSha256.ToLowerInvariant() } else { '' }
            if ($curGeminiSha -eq $expectedGeminiSha) {
                try {
                    $gParsed = Get-Content -LiteralPath $geminiJsonPath -Raw | ConvertFrom-Json
                    if ($gParsed -and $gParsed.mcpServers) {
                        $cbmEntry = $gParsed.mcpServers.PSObject.Properties['codebase-memory-mcp']
                        $ctx7Entry = $gParsed.mcpServers.PSObject.Properties['context7']
                        if ($cbmEntry -and $cbmEntry.Value.command -eq $binaryDest -and
                            $ctx7Entry -and $ctx7Entry.Value.serverUrl -eq $ctx7Meta.ServerUrl) {
                            if ($cbmEntry.Value.PSObject.Properties['env'] -and
                                $cbmEntry.Value.env.CBM_CACHE_DIR -eq $resolvedCacheDir -and
                                $cbmEntry.Value.env.CBM_RUNTIME_DIR -eq $resolvedRuntimeDir) {
                                $geminiMatches = $true
                            }
                        }
                    }
                } catch { }
            }
        }

        if ($binMatches -and $codexMatches -and $geminiMatches -and $manifestStateMatches) {
            return [pscustomobject]@{
                Status       = 'AlreadyInstalled'
                ManifestPath = $manifestPath
                Manifest     = $existingManifest
            }
        } else {
            throw "DRIFT DETECTED: Installation manifest already exists at $manifestPath, but current configurations, environment paths, or binary do not match the exact manifest state. Reinstallation cannot proceed over drifted state. Run Rollback first."
        }
    }

    # PHASE 3: Prepare merged contents for BOTH configs in memory before any writes
    $newCodexContent = Get-MergedCodexTomlContent `
        -ConfigPath $codexTomlPath `
        -CbmBinaryPath $binaryDest `
        -Context7Endpoint $ctx7Meta.ServerUrl `
        -CacheDir $resolvedCacheDir `
        -RuntimeDir $resolvedRuntimeDir

    $newGeminiContent = Get-MergedGeminiJsonContent `
        -ConfigPath $geminiJsonPath `
        -CbmBinaryPath $binaryDest `
        -Context7Endpoint $ctx7Meta.ServerUrl `
        -CacheDir $resolvedCacheDir `
        -RuntimeDir $resolvedRuntimeDir

    # PHASE 4: Handle Binary (Download / Unpack / Verify without bypass)
    if ($SkipBinaryDownload) {
        if (-not (Test-Path -LiteralPath $binaryDest -PathType Leaf)) {
            throw "Binary not found at expected path $binaryDest while SkipBinaryDownload was specified."
        }
        $actualBinSha = (Get-FileHash -LiteralPath $binaryDest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualBinSha -ne $effectiveExpectedBinarySha) {
            throw "CHECKSUM MISMATCH: existing binary at $binaryDest does not match expected SHA256. Expected: $effectiveExpectedBinarySha, Actual: $actualBinSha"
        }
    } else {
        $archivePath = $OfflineArchive
        $downloadTmpDir = $null
        try {
            if (-not $archivePath) {
                $downloadTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cbm-dl-" + [Guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $downloadTmpDir -Force | Out-Null
                $archivePath = Join-Path $downloadTmpDir $cbmMeta.ArchiveName

                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                Invoke-WebRequest -Uri $cbmMeta.DownloadUrl -OutFile $archivePath -UseBasicParsing
            }

            Assert-ArchiveSha256 -Path $archivePath -ExpectedSha256 $cbmMeta.ArchiveSha256
            Assert-ZipSafe -ZipPath $archivePath -AllowedNames $cbmMeta.AllowedFiles

            # Capture return value to avoid polluting output pipeline
            $null = Expand-CbmArchiveSafe `
                -ZipPath $archivePath `
                -DestinationPath $InstallRoot `
                -ExpectedBinarySha256 $effectiveExpectedBinarySha `
                -AllowedNames $cbmMeta.AllowedFiles
        } finally {
            if ($downloadTmpDir) {
                Remove-CheckedTempDirectory -Path $downloadTmpDir
            }
        }
    }

    # Ensure state directories exist with reparse point checks before transactional write
    if (-not (Test-Path -LiteralPath $resolvedCacheDir)) {
        New-Item -ItemType Directory -Path $resolvedCacheDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $resolvedRuntimeDir)) {
        New-Item -ItemType Directory -Path $resolvedRuntimeDir -Force | Out-Null
    }
    Assert-NoInternalReparsePoint -Path $resolvedCacheDir -AllowedRoot $resolvedStateRoot
    Assert-NoInternalReparsePoint -Path $resolvedRuntimeDir -AllowedRoot $resolvedStateRoot

    # PHASE 5: Config Backups with unique names before any modification
    $timestamp = (Get-Date -Format "yyyyMMddHHmmss") + "_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupDir = Join-Path $InstallRoot 'backups'
    if (Test-Path -LiteralPath $backupDir) {
        if (Test-IsReparsePoint -Path $backupDir) {
            throw "Security violation: Backup directory '$backupDir' cannot be a reparse point."
        }
    } else {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $codexPreSha = $null
    $codexBackupPath = $null
    if (Test-Path -LiteralPath $codexTomlPath -PathType Leaf) {
        $codexPreSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $codexBackupPath = Join-Path $backupDir "config.toml.bak.$timestamp"
        Copy-Item -LiteralPath $codexTomlPath -Destination $codexBackupPath -Force
    }

    $geminiPreSha = $null
    $geminiBackupPath = $null
    if (Test-Path -LiteralPath $geminiJsonPath -PathType Leaf) {
        $geminiPreSha = (Get-FileHash -LiteralPath $geminiJsonPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $geminiBackupPath = Join-Path $backupDir "mcp_config.json.bak.$timestamp"
        Copy-Item -LiteralPath $geminiJsonPath -Destination $geminiBackupPath -Force
    }

    # PHASE 6: Transactional Write (Configurations AND Manifest receipt) with automatic rollback on error
    $codexWritten = $false
    $geminiWritten = $false
    $manifestWritten = $false
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

    try {
        $codexParent = Split-Path -Parent $codexTomlPath
        if (-not (Test-Path -LiteralPath $codexParent)) {
            New-Item -ItemType Directory -Path $codexParent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($codexTomlPath, $newCodexContent, $utf8NoBom)
        $codexWritten = $true

        $geminiParent = Split-Path -Parent $geminiJsonPath
        if (-not (Test-Path -LiteralPath $geminiParent)) {
            New-Item -ItemType Directory -Path $geminiParent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($geminiJsonPath, $newGeminiContent, $utf8NoBom)
        $geminiWritten = $true

        # Capture post-install hashes
        $codexPostSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $geminiPostSha = (Get-FileHash -LiteralPath $geminiJsonPath -Algorithm SHA256).Hash.ToLowerInvariant()

        $manifestObj = [ordered]@{
            ManifestVersion   = '1.1'
            InstalledAt       = (Get-Date -Format "o")
            CbmVersion        = $cbmMeta.Version
            Architecture      = $cbmMeta.Architecture
            BinaryPath        = $binaryDest
            ExpectedBinarySha = $effectiveExpectedBinarySha
            StateRoot         = $resolvedStateRoot
            CbmCacheDir       = $resolvedCacheDir
            CbmRuntimeDir     = $resolvedRuntimeDir
            CodexToml         = [ordered]@{
                Path              = $codexTomlPath
                PreInstallSha256  = $codexPreSha
                PostInstallSha256 = $codexPostSha
                BackupPath        = $codexBackupPath
            }
            GeminiJson        = [ordered]@{
                Path              = $geminiJsonPath
                PreInstallSha256  = $geminiPreSha
                PostInstallSha256 = $geminiPostSha
                BackupPath        = $geminiBackupPath
            }
        }

        $manifestJson = $manifestObj | ConvertTo-Json -Depth 10
        $manifestParent = Split-Path -Parent $manifestPath
        if (-not (Test-Path -LiteralPath $manifestParent)) {
            New-Item -ItemType Directory -Path $manifestParent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($manifestPath, ($manifestJson -replace "`r?`n", "`r`n"), $utf8NoBom)
        $manifestWritten = $true
    } catch {
        # Transaction rollback on ANY failure during config or manifest write
        if ($codexWritten) {
            if ($codexBackupPath -and (Test-Path -LiteralPath $codexBackupPath -PathType Leaf)) {
                Copy-Item -LiteralPath $codexBackupPath -Destination $codexTomlPath -Force
            } elseif ([string]::IsNullOrEmpty($codexPreSha)) {
                Remove-Item -LiteralPath $codexTomlPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ($geminiWritten) {
            if ($geminiBackupPath -and (Test-Path -LiteralPath $geminiBackupPath -PathType Leaf)) {
                Copy-Item -LiteralPath $geminiBackupPath -Destination $geminiJsonPath -Force
            } elseif ([string]::IsNullOrEmpty($geminiPreSha)) {
                Remove-Item -LiteralPath $geminiJsonPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ($manifestWritten -or (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        }
        throw "INSTALL TRANSACTION FAILED: Error during configuration or manifest receipt write; changes were rolled back. Original error: $_"
    }

    return [pscustomobject]@{
        Status       = 'Installed'
        ManifestPath = $manifestPath
        Manifest     = $manifestObj
    }
}

function Invoke-FreeMcpsRollbackWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$ManifestPath = '',
        [Parameter(Mandatory=$false)][string]$InstallRoot = '',
        [Parameter(Mandatory=$false)][string]$CodexHome = '',
        [Parameter(Mandatory=$false)][string]$AntigravityHome = '',
        [Parameter(Mandatory=$false)][string]$StateRoot = ''
    )

    if (-not $CodexHome) {
        $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    }
    if (-not $AntigravityHome) {
        $AntigravityHome = if ($env:ANTIGRAVITY_HOME) { $env:ANTIGRAVITY_HOME } else { Join-Path $env:USERPROFILE '.gemini' }
    }
    if (-not $InstallRoot) {
        $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\codebase-memory-mcp'
    }

    # 1. Validate independent trusted roots (reject broad/system/empty roots)
    Assert-NotBroadOrInvalidRoot -Path $CodexHome -Name 'CodexHome'
    Assert-NotBroadOrInvalidRoot -Path $AntigravityHome -Name 'AntigravityHome'
    Assert-NotBroadOrInvalidRoot -Path $InstallRoot -Name 'InstallRoot'

    if (Test-IsReparsePoint -Path $InstallRoot) {
        throw "Security violation: InstallRoot cannot be a reparse point: $InstallRoot"
    }

    $cbmMeta = Get-CbmMetadata
    $expectedInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $expectedBackupDir = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot 'backups')).TrimEnd('\', '/')
    $expectedBinaryPath = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot $cbmMeta.BinaryName))
    $expectedDefaultManifestPath = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot 'free-mcps-manifest.json'))

    if (-not $ManifestPath) {
        $ManifestPath = $expectedDefaultManifestPath
    } else {
        $resolvedManifest = [System.IO.Path]::GetFullPath($ManifestPath)
        if (-not $resolvedManifest.StartsWith($expectedInstallRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            $resolvedManifest -ne $expectedDefaultManifestPath) {
            throw "Security violation: ManifestPath '$ManifestPath' is outside trusted InstallRoot '$InstallRoot'."
        }
        $ManifestPath = $resolvedManifest
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Rollback manifest not found: $ManifestPath"
    }
    if (Test-IsReparsePoint -Path $ManifestPath) {
        throw "Security violation: ManifestPath '$ManifestPath' is a reparse point."
    }

    # 2. Parse and validate manifest structure
    $raw = Get-Content -LiteralPath $ManifestPath -Raw
    $manifest = $null
    try {
        $manifest = $raw | ConvertFrom-Json
    } catch {
        throw "Manifest corrupted or invalid JSON: $ManifestPath"
    }

    if (-not $manifest -or -not $manifest.CodexToml -or -not $manifest.GeminiJson -or -not $manifest.BinaryPath -or -not $manifest.ExpectedBinarySha) {
        throw "Manifest structure invalid or missing required sections: $ManifestPath"
    }

    # 3. Exact target comparison against independent trusted roots & reparse checks BEFORE ANY mutation
    # Binary Target
    $manifestBinaryPath = [System.IO.Path]::GetFullPath($manifest.BinaryPath)
    if ($manifestBinaryPath -ne $expectedBinaryPath) {
        throw "Security violation: Manifest binary path '$($manifest.BinaryPath)' does not match expected binary path under trusted InstallRoot: '$expectedBinaryPath'."
    }
    Assert-NoInternalReparsePoint -Path $manifestBinaryPath -AllowedRoot $InstallRoot

    # Codex Target (support legitimate root junction C:\Users\mathe\.codex -> E:\CodexData\.codex or explicitly passed canonical root)
    $resolvedCodexHome = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\', '/')
    $canonicalCodexHome = if (Test-Path -LiteralPath $resolvedCodexHome) {
        $cItem = Get-Item -LiteralPath $resolvedCodexHome -Force
        if ($cItem.LinkType) { [System.IO.Path]::GetFullPath($cItem.ResolveLinkTarget($true).FullName).TrimEnd('\', '/') } else { $resolvedCodexHome }
    } else { $resolvedCodexHome }

    $expectedCodexPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedCodexHome 'config.toml'))
    $canonicalExpectedCodexPath = [System.IO.Path]::GetFullPath((Join-Path $canonicalCodexHome 'config.toml'))
    $manifestCodexPath = [System.IO.Path]::GetFullPath($manifest.CodexToml.Path)

    if ($manifestCodexPath -ne $expectedCodexPath -and $manifestCodexPath -ne $canonicalExpectedCodexPath) {
        throw "Security violation: Manifest Codex config path '$($manifest.CodexToml.Path)' does not match expected path under trusted CodexHome: '$expectedCodexPath'."
    }
    Assert-NoInternalReparsePoint -Path $manifestCodexPath -AllowedRoot $resolvedCodexHome
    if ($canonicalCodexHome -ne $resolvedCodexHome) {
        Assert-NoInternalReparsePoint -Path $manifestCodexPath -AllowedRoot $canonicalCodexHome
    }

    # Gemini Target
    $expectedGeminiPath = [System.IO.Path]::GetFullPath((Resolve-GeminiMcpConfigPath -AntigravityHome $AntigravityHome))
    $manifestGeminiPath = [System.IO.Path]::GetFullPath($manifest.GeminiJson.Path)

    if ($manifestGeminiPath -ne $expectedGeminiPath) {
        throw "Security violation: Manifest Gemini config path '$($manifest.GeminiJson.Path)' does not match expected path under trusted AntigravityHome: '$expectedGeminiPath'."
    }
    $resolvedAgHome = [System.IO.Path]::GetFullPath($AntigravityHome).TrimEnd('\', '/')
    Assert-NoInternalReparsePoint -Path $manifestGeminiPath -AllowedRoot $resolvedAgHome

    # Backup files strictly under InstallRoot\backups
    if (Test-Path -LiteralPath $expectedBackupDir) {
        if (Test-IsReparsePoint -Path $expectedBackupDir) {
            throw "Security violation: Backup directory '$expectedBackupDir' cannot be a reparse point."
        }
    }

    if ($manifest.CodexToml.BackupPath) {
        $resolvedCodexBak = [System.IO.Path]::GetFullPath($manifest.CodexToml.BackupPath)
        $codexBakParent = [System.IO.Path]::GetDirectoryName($resolvedCodexBak).TrimEnd('\', '/')
        if ($codexBakParent -ne $expectedBackupDir) {
            throw "Security violation: Codex backup path '$resolvedCodexBak' is not strictly inside trusted backup directory '$expectedBackupDir'."
        }
        $bakLeaf = Split-Path -Leaf $resolvedCodexBak
        if (-not ($bakLeaf -like 'config.toml.bak.*')) {
            throw "Manifest validation error: Codex backup filename '$bakLeaf' does not match expected pattern config.toml.bak.*"
        }
        Assert-NoInternalReparsePoint -Path $resolvedCodexBak -AllowedRoot $expectedBackupDir
    }

    if ($manifest.GeminiJson.BackupPath) {
        $resolvedGeminiBak = [System.IO.Path]::GetFullPath($manifest.GeminiJson.BackupPath)
        $geminiBakParent = [System.IO.Path]::GetDirectoryName($resolvedGeminiBak).TrimEnd('\', '/')
        if ($geminiBakParent -ne $expectedBackupDir) {
            throw "Security violation: Gemini backup path '$resolvedGeminiBak' is not strictly inside trusted backup directory '$expectedBackupDir'."
        }
        $bakLeaf = Split-Path -Leaf $resolvedGeminiBak
        if (-not ($bakLeaf -like 'mcp_config.json.bak.*')) {
            throw "Manifest validation error: Gemini backup filename '$bakLeaf' does not match expected pattern mcp_config.json.bak.*"
        }
        Assert-NoInternalReparsePoint -Path $resolvedGeminiBak -AllowedRoot $expectedBackupDir
    }

    # 4. Verify backup file SHA256 integrity before ANY mutation
    if ($manifest.CodexToml.PreInstallSha256) {
        if (-not $manifest.CodexToml.BackupPath -or -not (Test-Path -LiteralPath $manifest.CodexToml.BackupPath -PathType Leaf)) {
            throw "Backup missing: Codex backup file not found at $($manifest.CodexToml.BackupPath)"
        }
        $actualCodexBakSha = (Get-FileHash -LiteralPath $manifest.CodexToml.BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualCodexBakSha -ne $manifest.CodexToml.PreInstallSha256.ToLowerInvariant()) {
            throw "CHECKSUM MISMATCH: Codex backup file has been tampered with or corrupted. Expected: $($manifest.CodexToml.PreInstallSha256), Actual: $actualCodexBakSha"
        }
    }

    if ($manifest.GeminiJson.PreInstallSha256) {
        if (-not $manifest.GeminiJson.BackupPath -or -not (Test-Path -LiteralPath $manifest.GeminiJson.BackupPath -PathType Leaf)) {
            throw "Backup missing: Gemini backup file not found at $($manifest.GeminiJson.BackupPath)"
        }
        $actualGeminiBakSha = (Get-FileHash -LiteralPath $manifest.GeminiJson.BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualGeminiBakSha -ne $manifest.GeminiJson.PreInstallSha256.ToLowerInvariant()) {
            throw "CHECKSUM MISMATCH: Gemini backup file has been tampered with or corrupted. Expected: $($manifest.GeminiJson.PreInstallSha256), Actual: $actualGeminiBakSha"
        }
    }

    # 5. Strict drift check on ALL targets: fail closed before ANY mutation
    if (Test-Path -LiteralPath $manifestCodexPath -PathType Leaf) {
        $curCodexSha = (Get-FileHash -LiteralPath $manifestCodexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($curCodexSha -ne $manifest.CodexToml.PostInstallSha256.ToLowerInvariant()) {
            throw "DRIFT DETECTED: Codex config at '$manifestCodexPath' was modified after installation. Expected post-install SHA: $($manifest.CodexToml.PostInstallSha256), Actual: $curCodexSha. Rollback aborted to prevent overwriting user edits."
        }
    } else {
        if (-not [string]::IsNullOrEmpty($manifest.CodexToml.PostInstallSha256)) {
            throw "DRIFT DETECTED: Codex config at '$manifestCodexPath' was removed after installation. Rollback aborted."
        }
    }

    if (Test-Path -LiteralPath $manifestGeminiPath -PathType Leaf) {
        $curGeminiSha = (Get-FileHash -LiteralPath $manifestGeminiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($curGeminiSha -ne $manifest.GeminiJson.PostInstallSha256.ToLowerInvariant()) {
            throw "DRIFT DETECTED: Gemini config at '$manifestGeminiPath' was modified after installation. Expected post-install SHA: $($manifest.GeminiJson.PostInstallSha256), Actual: $curGeminiSha. Rollback aborted to prevent overwriting user edits."
        }
    } else {
        if (-not [string]::IsNullOrEmpty($manifest.GeminiJson.PostInstallSha256)) {
            throw "DRIFT DETECTED: Gemini config at '$manifestGeminiPath' was removed after installation. Rollback aborted."
        }
    }

    # 6. Restore target configurations (both verified clean)
    if ($manifest.CodexToml.PreInstallSha256) {
        Copy-Item -LiteralPath $manifest.CodexToml.BackupPath -Destination $manifestCodexPath -Force
        $restoredCodexSha = (Get-FileHash -LiteralPath $manifestCodexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($restoredCodexSha -ne $manifest.CodexToml.PreInstallSha256.ToLowerInvariant()) {
            throw "RESTORE VERIFICATION FAILED: Codex restored file hash does not match pre-install SHA."
        }
    } else {
        if (Test-Path -LiteralPath $manifestCodexPath -PathType Leaf) {
            Remove-Item -LiteralPath $manifestCodexPath -Force
        }
    }

    if ($manifest.GeminiJson.PreInstallSha256) {
        Copy-Item -LiteralPath $manifest.GeminiJson.BackupPath -Destination $manifestGeminiPath -Force
        $restoredGeminiSha = (Get-FileHash -LiteralPath $manifestGeminiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($restoredGeminiSha -ne $manifest.GeminiJson.PreInstallSha256.ToLowerInvariant()) {
            throw "RESTORE VERIFICATION FAILED: Gemini restored file hash does not match pre-install SHA."
        }
    } else {
        if (Test-Path -LiteralPath $manifestGeminiPath -PathType Leaf) {
            Remove-Item -LiteralPath $manifestGeminiPath -Force
        }
    }

    # 7. Post-success cleanup: binary, backups, and manifest preserved until restoration succeeds!
    # Zero state deletion: never delete StateRoot, cache, runtime, or pre-existing indexes
    if (Test-Path -LiteralPath $manifestBinaryPath -PathType Leaf) {
        $binHash = (Get-FileHash -LiteralPath $manifestBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($binHash -eq $manifest.ExpectedBinarySha.ToLowerInvariant()) {
            Remove-Item -LiteralPath $manifestBinaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Zero broad deletion: remove only exact backup files created for this install
    if ($manifest.CodexToml.BackupPath -and (Test-Path -LiteralPath $manifest.CodexToml.BackupPath -PathType Leaf)) {
        Remove-Item -LiteralPath $manifest.CodexToml.BackupPath -Force -ErrorAction SilentlyContinue
    }
    if ($manifest.GeminiJson.BackupPath -and (Test-Path -LiteralPath $manifest.GeminiJson.BackupPath -PathType Leaf)) {
        Remove-Item -LiteralPath $manifest.GeminiJson.BackupPath -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $ManifestPath -Force

    return [pscustomobject]@{
        Status       = 'RolledBack'
        ManifestPath = $ManifestPath
    }
}

function Invoke-FreeMcpsInspectWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$CodexHome = '',
        [Parameter(Mandatory=$false)][string]$AntigravityHome = '',
        [Parameter(Mandatory=$false)][string]$InstallRoot = '',
        [Parameter(Mandatory=$false)][string]$StateRoot = ''
    )

    if (-not $CodexHome) {
        $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    }
    if (-not $AntigravityHome) {
        $AntigravityHome = if ($env:ANTIGRAVITY_HOME) { $env:ANTIGRAVITY_HOME } else { Join-Path $env:USERPROFILE '.gemini' }
    }
    if (-not $InstallRoot) {
        $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\codebase-memory-mcp'
    }
    if (-not $StateRoot) {
        $userProfilePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { [System.Environment]::GetFolderPath('UserProfile') }
        $StateRoot = Join-Path $userProfilePath '.cbm-state'
    }

    $resolvedState = [System.IO.Path]::GetFullPath($StateRoot).TrimEnd('\', '/')
    $expectedCache = [System.IO.Path]::GetFullPath((Join-Path $resolvedState 'cache')).TrimEnd('\', '/')
    $expectedRuntime = [System.IO.Path]::GetFullPath((Join-Path $resolvedState 'runtime')).TrimEnd('\', '/')

    $cbmMeta = Get-CbmMetadata
    $ctx7Meta = Get-Context7Metadata

    $codexToml = Join-Path $CodexHome 'config.toml'
    $geminiJson = Resolve-GeminiMcpConfigPath -AntigravityHome $AntigravityHome
    $binaryPath = Join-Path $InstallRoot $cbmMeta.BinaryName
    $manifestPath = Join-Path $InstallRoot 'free-mcps-manifest.json'

    $binaryFound = Test-Path -LiteralPath $binaryPath -PathType Leaf
    $binaryHash = if ($binaryFound) { (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }

    $codexFound = Test-Path -LiteralPath $codexToml -PathType Leaf
    $codexHasCbm = $false
    $codexHasCtx7 = $false
    $codexSafety = 'unverified'
    $codexObservedCache = $null
    $codexObservedRuntime = $null
    if ($codexFound) {
        $content = [System.IO.File]::ReadAllText($codexToml)
        $codexHasCbm = $content.Contains('[mcp_servers.codebase-memory-mcp]') -or $content.Contains('[mcp_servers."codebase-memory-mcp"]')
        $codexHasCtx7 = $content.Contains('[mcp_servers.context7]') -or $content.Contains('[mcp_servers."context7"]')
        if ($content -match 'CBM_CACHE_DIR\s*=\s*[''"]([^''"]+)[''"]') {
            $codexObservedCache = $Matches[1]
        }
        if ($content -match 'CBM_RUNTIME_DIR\s*=\s*[''"]([^''"]+)[''"]') {
            $codexObservedRuntime = $Matches[1]
        }
        try {
            Test-Context7ConfigSafety -ConfigPath $codexToml -ConfigType 'codex'
            $codexSafety = 'verified_no_credentials'
        } catch {
            $codexSafety = 'credentials_detected'
        }
    }

    $geminiFound = Test-Path -LiteralPath $geminiJson -PathType Leaf
    $geminiHasCbm = $false
    $geminiHasCtx7 = $false
    $geminiSafety = 'unverified'
    $geminiObservedCache = $null
    $geminiObservedRuntime = $null
    if ($geminiFound) {
        try {
            $parsed = Get-Content -LiteralPath $geminiJson -Raw | ConvertFrom-Json
            if ($parsed -and $parsed.mcpServers) {
                $geminiHasCbm = [bool]($parsed.mcpServers.PSObject.Properties['codebase-memory-mcp'])
                $geminiHasCtx7 = [bool]($parsed.mcpServers.PSObject.Properties['context7'])
                if ($geminiHasCbm) {
                    $cbm = $parsed.mcpServers.PSObject.Properties['codebase-memory-mcp'].Value
                    if ($cbm -and $cbm.PSObject.Properties['env']) {
                        if ($cbm.env.PSObject.Properties['CBM_CACHE_DIR']) { $geminiObservedCache = [string]$cbm.env.CBM_CACHE_DIR }
                        if ($cbm.env.PSObject.Properties['CBM_RUNTIME_DIR']) { $geminiObservedRuntime = [string]$cbm.env.CBM_RUNTIME_DIR }
                    }
                }
            }
        } catch { }
        try {
            Test-Context7ConfigSafety -ConfigPath $geminiJson -ConfigType 'gemini'
            $geminiSafety = 'verified_no_credentials'
        } catch {
            $geminiSafety = 'credentials_detected'
        }
    }

    $manifestStateRoot = $null
    $manifestCacheDir = $null
    $manifestRuntimeDir = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $mParsed = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($mParsed) {
                if ($mParsed.PSObject.Properties['StateRoot']) { $manifestStateRoot = [string]$mParsed.StateRoot }
                if ($mParsed.PSObject.Properties['CbmCacheDir']) { $manifestCacheDir = [string]$mParsed.CbmCacheDir }
                if ($mParsed.PSObject.Properties['CbmRuntimeDir']) { $manifestRuntimeDir = [string]$mParsed.CbmRuntimeDir }
            }
        } catch { }
    }

    return [pscustomobject]@{
        Mode                    = 'Inspect (ReadOnly)'
        CbmPinnedVersion        = $cbmMeta.Version
        CbmArchitecture         = $cbmMeta.Architecture
        CbmExpectedSha          = $cbmMeta.BinarySha256
        CbmBinaryPath           = $binaryPath
        CbmBinaryPresent        = $binaryFound
        CbmBinaryShaValid       = ($binaryHash -eq $cbmMeta.BinarySha256)
        Context7Endpoint        = $ctx7Meta.ServerUrl
        Context7Billing         = 'unproven_anonymous_intent'
        Context7BillingIntent   = 'anonymous_unauthenticated'
        Context7OAuthStatus     = 'unknown'
        Context7SafetyVerified  = ($codexSafety -eq 'verified_no_credentials' -and $geminiSafety -eq 'verified_no_credentials')
        CodexTomlPath           = $codexToml
        CodexTomlPresent        = $codexFound
        CodexTomlHasCbm         = $codexHasCbm
        CodexTomlHasCtx7        = $codexHasCtx7
        CodexSafety             = $codexSafety
        GeminiJsonPath          = $geminiJson
        GeminiJsonPresent       = $geminiFound
        GeminiJsonHasCbm        = $geminiHasCbm
        GeminiJsonHasCtx7       = $geminiHasCtx7
        GeminiSafety            = $geminiSafety
        ManifestPresent         = (Test-Path -LiteralPath $manifestPath -PathType Leaf)
        ConfiguredStateRoot     = $resolvedState
        ConfiguredCacheDir      = $expectedCache
        ConfiguredRuntimeDir    = $expectedRuntime
        CodexObservedCacheDir   = $codexObservedCache
        CodexObservedRuntimeDir = $codexObservedRuntime
        GeminiObservedCacheDir  = $geminiObservedCache
        GeminiObservedRuntimeDir = $geminiObservedRuntime
        ManifestStateRoot       = $manifestStateRoot
        ManifestCacheDir        = $manifestCacheDir
        ManifestRuntimeDir      = $manifestRuntimeDir
        RuntimeGuarantee        = 'Observed root configuration reported; inspect mode does not guarantee runtime execution.'
    }
}

Export-ModuleMember -Function @(
    'Get-CbmMetadata',
    'Get-Context7Metadata',
    'Assert-ArchiveSha256',
    'Assert-ZipSafe',
    'Expand-CbmArchiveSafe',
    'Test-Context7ConfigSafety',
    'Get-MergedCodexTomlContent',
    'Get-MergedGeminiJsonContent',
    'Merge-CodexToml',
    'Merge-GeminiMcpConfig',
    'Remove-CodexTomlSections',
    'Remove-GeminiMcpServers',
    'Resolve-GeminiMcpConfigPath',
    'Invoke-FreeMcpsInstallWorkflow',
    'Invoke-FreeMcpsRollbackWorkflow',
    'Invoke-FreeMcpsInspectWorkflow',
    'Assert-NotBroadOrInvalidRoot',
    'Assert-ValidStateRoot',
    'Format-TomlStringValue',
    'Test-IsReparsePoint',
    'Assert-NoInternalReparsePoint',
    'Remove-CheckedTempDirectory'
)
