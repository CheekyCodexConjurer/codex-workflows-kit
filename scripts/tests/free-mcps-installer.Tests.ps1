# scripts/tests/free-mcps-installer.Tests.ps1
# Deterministic unit tests for codebase-memory-mcp v0.10.8 and Context7 free installation

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Authorize mock binary SHA overrides strictly within internal deterministic tests
$env:FREE_MCPS_TEST_ALLOW_SHA_OVERRIDE = '1'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$modulePath = Join-Path $repoRoot 'scripts\free-mcps.psm1'
$cliPath = Join-Path $repoRoot 'scripts\install-free-mcps.ps1'

# Test runner harness
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

function New-TestFixture {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cbm-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $codexHome = Join-Path $tempDir 'codex'
    $geminiHome = Join-Path $tempDir 'gemini'
    $installRoot = Join-Path $tempDir 'install'
    $stateRoot = Join-Path $tempDir 'state'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    New-Item -ItemType Directory -Path $geminiHome -Force | Out-Null
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    return @{
        Root = $tempDir
        CodexHome = $codexHome
        GeminiHome = $geminiHome
        InstallRoot = $installRoot
        StateRoot = $stateRoot
    }
}

function Remove-TestFixture {
    param([hashtable]$Fixture)
    if ($Fixture -and (Test-Path -LiteralPath $Fixture.Root)) {
        Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Create-ZipWithEntries {
    param(
        [Parameter(Mandatory=$true)][string]$OutZipPath,
        [Parameter(Mandatory=$true)][hashtable]$Entries
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path -LiteralPath $OutZipPath) {
        Remove-Item -LiteralPath $OutZipPath -Force
    }

    $zip = [System.IO.Compression.ZipFile]::Open($OutZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($key in $Entries.Keys) {
            $content = $Entries[$key]
            $entry = $zip.CreateEntry($key)
            $stream = $entry.Open()
            try {
                $bytes = if ($content -is [byte[]]) { $content } else { [System.Text.Encoding]::UTF8.GetBytes($content) }
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function New-MockBinary {
    param(
        [Parameter(Mandatory=$true)][string]$DestinationPath,
        [Parameter(Mandatory=$false)][string]$Content = "valid mock binary content v0.10.8"
    )
    $parent = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    [System.IO.File]::WriteAllBytes($DestinationPath, $bytes)
    return (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

Write-Host "Running Free MCPs Installer Test Suite..." -ForegroundColor Cyan

# ---------------------------------------------------------
# Test 1: Module file exists and imports cleanly
# ---------------------------------------------------------
$moduleExists = Test-Path -LiteralPath $modulePath
Assert-Test -Name "Module file exists" -Condition $moduleExists -Details "Missing $modulePath"

if ($moduleExists) {
    Import-Module -Name $modulePath -Force
}

# ---------------------------------------------------------
# Test 2: Pinned Metadata (v0.10.8, official digests, no latest)
# ---------------------------------------------------------
try {
    $meta = Get-CbmMetadata -Arch 'amd64'
    Assert-Test -Name "Metadata version pinned to v0.10.8" -Condition ($meta.Version -eq 'v0.10.8')
    Assert-Test -Name "Metadata archive sha256 matches official v0.10.8 digest" -Condition ($meta.ArchiveSha256 -eq 'b43ad982994c4d829670749e08d3b622a74bb20041fc0a7d02bef6113f81c34d')
    Assert-Test -Name "Metadata binary sha256 matches official v0.10.8 digest" -Condition ($meta.BinarySha256 -eq 'b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6')
    Assert-Test -Name "Download URL contains explicit tag v0.10.8 and no latest" -Condition ($meta.DownloadUrl.Contains('/v0.10.8/') -and -not $meta.DownloadUrl.Contains('/latest/'))
} catch {
    Assert-Test -Name "Metadata function callable" -Condition $false -Details $_.Exception.Message
}

# ---------------------------------------------------------
# Test 3: Negative - Archive Checksum Mismatch
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $badZip = Join-Path $fix.Root "bad-checksum.zip"
    Create-ZipWithEntries -OutZipPath $badZip -Entries @{ "test.txt" = "corrupted content" }
    $expectedThrown = $false
    try {
        Assert-ArchiveSha256 -Path $badZip -ExpectedSha256 "0000000000000000000000000000000000000000000000000000000000000000"
    } catch {
        if ($_.Exception.Message -match "CHECKSUM MISMATCH|checksum mismatch|digest mismatch") {
            $expectedThrown = $true
        } else {
            throw
        }
    }
    Assert-Test -Name "Negative: Archive checksum mismatch throws" -Condition $expectedThrown
} catch {
    Assert-Test -Name "Negative: Archive checksum mismatch throws" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 4: Negative - Directory Traversal (Zip Slip with '..')
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $traversalZip = Join-Path $fix.Root "traversal.zip"
    Create-ZipWithEntries -OutZipPath $traversalZip -Entries @{
        "../evil.exe" = "bad"
        "codebase-memory-mcp.exe" = "dummy"
    }
    $expectedThrown = $false
    try {
        Assert-ZipSafe -ZipPath $traversalZip
    } catch {
        if ($_.Exception.Message -match "unsafe zip entry|path traversal|traversal") {
            $expectedThrown = $true
        } else {
            throw
        }
    }
    Assert-Test -Name "Negative: Zip entry with path traversal (..) throws" -Condition $expectedThrown
} catch {
    Assert-Test -Name "Negative: Zip entry with path traversal (..) throws" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 5: Negative - Zip Entry Traversal (Absolute path or colon)
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $colonZip = Join-Path $fix.Root "colon.zip"
    Create-ZipWithEntries -OutZipPath $colonZip -Entries @{
        "/rooted/evil.exe" = "bad"
    }
    $expectedThrown = $false
    try {
        Assert-ZipSafe -ZipPath $colonZip
    } catch {
        if ($_.Exception.Message -match "unsafe zip entry|path traversal|traversal") {
            $expectedThrown = $true
        } else {
            throw
        }
    }
    Assert-Test -Name "Negative: Zip entry starting with slash throws" -Condition $expectedThrown
} catch {
    Assert-Test -Name "Negative: Zip entry starting with slash throws" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 6: Negative - Binary Checksum Mismatch inside archive
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $mismatchZip = Join-Path $fix.Root "binary-mismatch.zip"
    Create-ZipWithEntries -OutZipPath $mismatchZip -Entries @{
        "codebase-memory-mcp.exe" = "tampered executable bytes"
        "LICENSE" = "MIT"
        "install.ps1" = "# stub"
        "THIRD_PARTY_NOTICES.md" = "notices"
    }
    $expectedThrown = $false
    try {
        Expand-CbmArchiveSafe -ZipPath $mismatchZip -DestinationPath $fix.InstallRoot -ExpectedBinarySha256 "b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6"
    } catch {
        if ($_.Exception.Message -match "CHECKSUM MISMATCH|checksum mismatch|binary hash mismatch") {
            $expectedThrown = $true
        } else {
            throw
        }
    }
    Assert-Test -Name "Negative: Extracted binary checksum mismatch throws" -Condition $expectedThrown
} catch {
    Assert-Test -Name "Negative: Extracted binary checksum mismatch throws" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 7: Preservação de Registros - Codex config.toml
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialToml = @"
# Global Codex settings
model = "gpt-5.6-luna"
approval_policy = "never"

[desktop]
followUpQueueMode = "queue"

[mcp_servers.codegraph]
command = "codegraph"
args = ["serve", "--mcp"]

[mcp_servers.serena]
command = 'C:\bin\serena.exe'
args = ["start-mcp-server"]
"@
    $tomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($tomlPath, $initialToml)

    $installExe = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    Merge-CodexToml -ConfigPath $tomlPath -CbmBinaryPath $installExe -Context7Endpoint "https://mcp.context7.com/mcp"

    $merged = [System.IO.File]::ReadAllText($tomlPath)
    $hasOriginal = $merged.Contains('model = "gpt-5.6-luna"') -and $merged.Contains('[mcp_servers.codegraph]') -and $merged.Contains('[mcp_servers.serena]')
    $hasCbm = $merged.Contains('[mcp_servers.codebase-memory-mcp]') -or $merged.Contains('[mcp_servers."codebase-memory-mcp"]')
    $hasCtx7 = $merged.Contains('[mcp_servers.context7]') -and $merged.Contains('https://mcp.context7.com/mcp')
    Assert-Test -Name "Codex TOML preserves existing entries and adds CBM + Context7" -Condition ($hasOriginal -and $hasCbm -and $hasCtx7)
} catch {
    Assert-Test -Name "Codex TOML preserves existing entries and adds CBM + Context7" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 8: Preservação de Registros - Gemini mcp_config.json
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialJson = @"
{
  "mcpServers": {
    "codegraph": {
      "command": "codegraph",
      "args": ["serve", "--mcp"]
    },
    "serena": {
      "command": "C:\\bin\\serena.exe",
      "args": ["start-mcp-server"]
    }
  }
}
"@
    $configDir = Join-Path $fix.GeminiHome 'config'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $jsonPath = Join-Path $configDir 'mcp_config.json'
    [System.IO.File]::WriteAllText($jsonPath, $initialJson)

    $installExe = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    Merge-GeminiMcpConfig -ConfigPath $jsonPath -CbmBinaryPath $installExe -Context7Endpoint "https://mcp.context7.com/mcp"

    $parsed = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $hasCodegraph = ($parsed.mcpServers.codegraph.command -eq 'codegraph')
    $hasSerena = ($parsed.mcpServers.serena.command -eq 'C:\bin\serena.exe')
    $hasCbm = ($parsed.mcpServers.'codebase-memory-mcp'.command -eq $installExe)
    $hasCtx7 = ($parsed.mcpServers.context7.serverUrl -eq 'https://mcp.context7.com/mcp')
    Assert-Test -Name "Gemini JSON preserves existing mcpServers and adds CBM + Context7" -Condition ($hasCodegraph -and $hasSerena -and $hasCbm -and $hasCtx7)
} catch {
    Assert-Test -Name "Gemini JSON preserves existing mcpServers and adds CBM + Context7" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 9: Negative - Credencial Desconhecida / Auth em Gemini JSON
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $taintedJson = @"
{
  "mcpServers": {
    "context7": {
      "serverUrl": "https://mcp.context7.com/mcp",
      "headers": {
        "Authorization": "Bearer super-secret-billing-key-12345"
      }
    }
  }
}
"@
    $configDir = Join-Path $fix.GeminiHome 'config'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $jsonPath = Join-Path $configDir 'mcp_config.json'
    [System.IO.File]::WriteAllText($jsonPath, $taintedJson)

    $threw = $false
    $caughtMsg = ""
    try {
        Test-Context7ConfigSafety -ConfigPath $jsonPath -ConfigType 'gemini'
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    $blocks = $threw -and ($caughtMsg.Contains("credentials") -or $caughtMsg.Contains("billing") -or $caughtMsg.Contains("auth") -or $caughtMsg.Contains("cost"))
    $noSecretLeak = -not $caughtMsg.Contains("super-secret-billing-key-12345")
    Assert-Test -Name "Negative: Existing Context7 JSON auth blocks without leaking secret" -Condition ($blocks -and $noSecretLeak)
} catch {
    Assert-Test -Name "Negative: Existing Context7 JSON auth blocks without leaking secret" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 10: Negative - Credencial Desconhecida / Auth em Codex TOML
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $taintedToml = @"
[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
api_key = "secret-token-codex-xyz"
"@
    $tomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($tomlPath, $taintedToml)

    $threw = $false
    $caughtMsg = ""
    try {
        Test-Context7ConfigSafety -ConfigPath $tomlPath -ConfigType 'codex'
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    $blocks = $threw -and ($caughtMsg.Contains("credentials") -or $caughtMsg.Contains("billing") -or $caughtMsg.Contains("auth") -or $caughtMsg.Contains("cost"))
    $noSecretLeak = -not $caughtMsg.Contains("secret-token-codex-xyz")
    Assert-Test -Name "Negative: Existing Context7 TOML auth blocks without leaking secret" -Condition ($blocks -and $noSecretLeak)
} catch {
    Assert-Test -Name "Negative: Existing Context7 TOML auth blocks without leaking secret" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 11: Negative - SkipBinaryDownload with absent binary throws
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -SkipBinaryDownload $true
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    Assert-Test -Name "Negative: SkipBinaryDownload with absent binary throws" -Condition ($threw -and $caughtMsg.Contains("Binary not found at expected path"))
} catch {
    Assert-Test -Name "Negative: SkipBinaryDownload with absent binary throws" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 12: Negative - SkipBinaryDownload with bad binary hash throws
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $actualSha = New-MockBinary -DestinationPath $binPath -Content "corrupted mock binary"
    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -SkipBinaryDownload $true `
            -ExpectedBinarySha "0000000000000000000000000000000000000000000000000000000000000000"
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    Assert-Test -Name "Negative: SkipBinaryDownload with bad binary hash throws" -Condition ($threw -and $caughtMsg.Contains("CHECKSUM MISMATCH"))
} catch {
    Assert-Test -Name "Negative: SkipBinaryDownload with bad binary hash throws" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 13: Negative - Config auth in second config (Gemini) blocks before first config (Codex) is modified
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'initial-codex-test'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    # Gemini config with unauthorized credentials
    $taintedGeminiJson = @"
{
  "mcpServers": {
    "context7": {
      "serverUrl": "https://mcp.context7.com/mcp",
      "headers": {
        "Authorization": "Bearer forbidden-secret-token"
      }
    }
  }
}
"@
    $geminiConfigDir = Join-Path $fix.GeminiHome 'config'
    New-Item -ItemType Directory -Path $geminiConfigDir -Force | Out-Null
    $geminiJsonPath = Join-Path $geminiConfigDir 'mcp_config.json'
    [System.IO.File]::WriteAllText($geminiJsonPath, $taintedGeminiJson)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -SkipBinaryDownload $true `
            -ExpectedBinarySha $mockSha
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    # Verify preflight blocked before ANY modification to Codex config
    $codexContentAfter = [System.IO.File]::ReadAllText($codexTomlPath)
    $codexUntouched = ($codexContentAfter -eq $initialCodexToml)
    $noManifestCreated = -not (Test-Path -LiteralPath (Join-Path $fix.InstallRoot 'free-mcps-manifest.json'))
    Assert-Test -Name "Negative: Config auth in second config blocks before first config is modified" -Condition ($threw -and $codexUntouched -and $noManifestCreated)
} catch {
    Assert-Test -Name "Negative: Config auth in second config blocks before first config is modified" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 14: Reinstall - Idempotent run preserves original manifest and backups
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'reinstall-original'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    # First install
    $firstInstall = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $manifestPath = $firstInstall.ManifestPath
    $firstManifestText = [System.IO.File]::ReadAllText($manifestPath)
    $backupDir = Join-Path $fix.InstallRoot 'backups'
    $initialBackups = Get-ChildItem -Path $backupDir

    # Second install (reinstall)
    $reinstall = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $secondManifestText = [System.IO.File]::ReadAllText($manifestPath)
    $afterBackups = Get-ChildItem -Path $backupDir

    $isAlreadyInstalled = ($reinstall.Status -eq 'AlreadyInstalled')
    $manifestUnchanged = ($firstManifestText -eq $secondManifestText)
    $backupsPreserved = (@($initialBackups).Count -eq @($afterBackups).Count)
    Assert-Test -Name "Reinstall: Idempotent run preserves original manifest and backups" -Condition ($isAlreadyInstalled -and $manifestUnchanged -and $backupsPreserved)
} catch {
    Assert-Test -Name "Reinstall: Idempotent run preserves original manifest and backups" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 15: Negative - Rollback drift in Codex config fails closed before modifying Gemini
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'rollback-drift-codex'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $geminiPath = Resolve-GeminiMcpConfigPath -AntigravityHome $fix.GeminiHome
    $geminiPostSha = (Get-FileHash -LiteralPath $geminiPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # Simulate subsequent user drift in Codex config
    [System.IO.File]::AppendAllText($codexTomlPath, "`n# user modified this after install`n")

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsRollbackWorkflow -ManifestPath $manifest.ManifestPath -InstallRoot $fix.InstallRoot -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    # Verify fail-closed: Gemini was NOT modified, manifest was NOT deleted
    $geminiCurrentSha = (Get-FileHash -LiteralPath $geminiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $geminiUntouched = ($geminiCurrentSha -eq $geminiPostSha)
    $manifestPreserved = Test-Path -LiteralPath $manifest.ManifestPath -PathType Leaf
    $driftCaught = $threw -and $caughtMsg.Contains("DRIFT DETECTED: Codex config")
    Assert-Test -Name "Negative: Rollback drift in Codex fails closed before modifying Gemini" -Condition ($driftCaught -and $geminiUntouched -and $manifestPreserved)
} catch {
    Assert-Test -Name "Negative: Rollback drift in Codex fails closed before modifying Gemini" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 16: Negative - Rollback drift in Gemini config fails closed before modifying Codex
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'rollback-drift-gemini'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $codexPostSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $geminiPath = Resolve-GeminiMcpConfigPath -AntigravityHome $fix.GeminiHome

    # Simulate subsequent user drift in Gemini config
    [System.IO.File]::AppendAllText($geminiPath, "`n// user modification after install`n")

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsRollbackWorkflow -ManifestPath $manifest.ManifestPath -InstallRoot $fix.InstallRoot -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    # Verify fail-closed: Codex was NOT restored, manifest was NOT deleted
    $codexCurrentSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $codexUntouched = ($codexCurrentSha -eq $codexPostSha)
    $manifestPreserved = Test-Path -LiteralPath $manifest.ManifestPath -PathType Leaf
    $driftCaught = $threw -and $caughtMsg.Contains("DRIFT DETECTED: Gemini config")
    Assert-Test -Name "Negative: Rollback drift in Gemini fails closed before modifying Codex" -Condition ($driftCaught -and $codexUntouched -and $manifestPreserved)
} catch {
    Assert-Test -Name "Negative: Rollback drift in Gemini fails closed before modifying Codex" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 17: Negative - Rollback with tampered backup fails closed without mutating targets
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'tamper-backup-test'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $codexPostSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # Tamper with the backup file
    $backupPath = $manifest.Manifest.CodexToml.BackupPath
    [System.IO.File]::WriteAllText($backupPath, "corrupted tampered backup data")

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsRollbackWorkflow -ManifestPath $manifest.ManifestPath -InstallRoot $fix.InstallRoot -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    # Verify fail closed: targets were NOT modified
    $codexCurrentSha = (Get-FileHash -LiteralPath $codexTomlPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $codexUntouched = ($codexCurrentSha -eq $codexPostSha)
    $manifestPreserved = Test-Path -LiteralPath $manifest.ManifestPath -PathType Leaf
    $tamperCaught = $threw -and $caughtMsg.Contains("CHECKSUM MISMATCH: Codex backup file has been tampered with")
    Assert-Test -Name "Negative: Rollback with tampered backup fails closed without mutating targets" -Condition ($tamperCaught -and $codexUntouched -and $manifestPreserved)
} catch {
    Assert-Test -Name "Negative: Rollback with tampered backup fails closed without mutating targets" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 18: Positive - Clean Rollback when no drift occurred
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialToml = "model = 'clean-rollback-test'`n"
    $tomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($tomlPath, $initialToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    # Verify installed
    $installedToml = [System.IO.File]::ReadAllText($tomlPath)
    $cbmAdded = $installedToml.Contains('[mcp_servers.codebase-memory-mcp]')

    # Rollback
    $null = Invoke-FreeMcpsRollbackWorkflow -ManifestPath $manifest.ManifestPath -InstallRoot $fix.InstallRoot -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome

    $revertedToml = [System.IO.File]::ReadAllText($tomlPath)
    $cleanRestored = ($revertedToml.Trim() -eq $initialToml.Trim())
    $manifestRemoved = -not (Test-Path -LiteralPath $manifest.ManifestPath)
    $binRemoved = -not (Test-Path -LiteralPath $binPath)
    Assert-Test -Name "Clean rollback: Restores exact original config when no drift occurred" -Condition ($cbmAdded -and $cleanRestored -and $manifestRemoved -and $binRemoved)
} catch {
    Assert-Test -Name "Clean rollback: Restores exact original config when no drift occurred" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 19: Readonly - Inspect Mode Makes No Changes and reports unproven anonymous billing
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $filesBefore = (Get-ChildItem -Path $fix.Root -Recurse).Count
    if (-not (Test-Path -LiteralPath $cliPath)) {
        throw "CLI file does not exist: $cliPath"
    }
    $psPath = (Get-Process -Id $PID).Path
    $inspectOut = & $psPath -File $cliPath -Mode Inspect -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome -InstallRoot $fix.InstallRoot 2>&1
    $filesAfter = (Get-ChildItem -Path $fix.Root -Recurse).Count
    $inspectReport = Invoke-FreeMcpsInspectWorkflow -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome -InstallRoot $fix.InstallRoot
    $billingUnproven = ($inspectReport.Context7Billing -eq 'unproven_anonymous_intent')
    $oauthUnknown = ($inspectReport.Context7OAuthStatus -eq 'unknown')
    Assert-Test -Name "Readonly: Inspect mode creates zero files and reports unproven billing" -Condition (($filesBefore -eq $filesAfter) -and $billingUnproven -and $oauthUnknown)
} catch {
    Assert-Test -Name "Readonly: Inspect mode creates zero files and reports unproven billing" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 20: CLI - -Json outputs pure parseable JSON without polluting objects
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $psPath = (Get-Process -Id $PID).Path
    $rawInspectJson = & $psPath -File $cliPath -Mode Inspect -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome -InstallRoot $fix.InstallRoot -Json 2>&1
    $parsedInspect = $rawInspectJson | ConvertFrom-Json
    $pureInspect = ($parsedInspect -is [pscustomobject]) -and ($parsedInspect.Context7Billing -eq 'unproven_anonymous_intent')

    $rawInstallJson = & $psPath -File $cliPath -Mode Install -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome -InstallRoot $fix.InstallRoot -SkipBinaryDownload -ExpectedBinarySha $mockSha -Json 2>&1
    $parsedInstall = $rawInstallJson | ConvertFrom-Json
    # Crucial: verify pure single object, not array polluted by Expand return value!
    $pureInstall = ($parsedInstall -is [pscustomobject]) -and ($parsedInstall.Status -eq 'Installed')

    Assert-Test -Name "CLI: -Json outputs pure parseable JSON without polluting objects" -Condition ($pureInspect -and $pureInstall)
} catch {
    Assert-Test -Name "CLI: -Json outputs pure parseable JSON without polluting objects" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 21: Negative - Outside-bound target or backup matching expected filename pattern
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'outside-bound-test'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $backupDir = Join-Path $fix.InstallRoot 'backups'
    $backupsBefore = @(Get-ChildItem -Path $backupDir)

    # 1. Tamper manifest to point backup outside InstallRoot\backups even though filename matches config.toml.bak.*
    $outsideDir = Join-Path $fix.Root 'outside'
    New-Item -ItemType Directory -Path $outsideDir -Force | Out-Null
    $outsideBak = Join-Path $outsideDir 'config.toml.bak.fake123'
    [System.IO.File]::WriteAllText($outsideBak, "outside backup content")

    $manifestContent = Get-Content -LiteralPath $manifest.ManifestPath -Raw | ConvertFrom-Json
    $manifestContent.CodexToml.BackupPath = $outsideBak
    [System.IO.File]::WriteAllText($manifest.ManifestPath, ($manifestContent | ConvertTo-Json -Depth 10))

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsRollbackWorkflow `
            -ManifestPath $manifest.ManifestPath `
            -InstallRoot $fix.InstallRoot `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    $backupsAfter = @(Get-ChildItem -Path $backupDir)
    $outsideStillPresent = Test-Path -LiteralPath $outsideBak
    $backupsPreserved = ($backupsBefore.Count -eq $backupsAfter.Count)
    $securityViolation = $threw -and ($caughtMsg.Contains("Security violation") -or $caughtMsg.Contains("outside trusted") -or $caughtMsg.Contains("is not strictly inside trusted backup directory"))

    Assert-Test -Name "Negative: Outside-bound backup matching filename pattern fails closed and preserves backups" -Condition ($securityViolation -and $backupsPreserved -and $outsideStillPresent)
} catch {
    Assert-Test -Name "Negative: Outside-bound backup matching filename pattern fails closed and preserves backups" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 22: Negative - Reparse point in targets or backups fails closed
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'reparse-test'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    # Create a junction inside InstallRoot to simulate an internal reparse point attack
    $realTargetDir = Join-Path $fix.Root 'reparse-target'
    New-Item -ItemType Directory -Path $realTargetDir -Force | Out-Null
    $canaryFile = Join-Path $realTargetDir 'canary.txt'
    [System.IO.File]::WriteAllText($canaryFile, "untouchable canary")

    # Move real backups and replace backups dir with a junction
    $backupDir = Join-Path $fix.InstallRoot 'backups'
    $savedBakDir = Join-Path $fix.Root 'saved-backups'
    Move-Item -LiteralPath $backupDir -Destination $savedBakDir
    New-Item -ItemType Junction -Path $backupDir -Target $realTargetDir | Out-Null

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsRollbackWorkflow `
            -ManifestPath $manifest.ManifestPath `
            -InstallRoot $fix.InstallRoot `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    $reparseDetected = $threw -and ($caughtMsg.Contains("reparse point") -or $caughtMsg.Contains("Security violation"))
    $canaryUntouched = (Test-Path -LiteralPath $canaryFile) -and ([System.IO.File]::ReadAllText($canaryFile) -eq "untouchable canary")
    Assert-Test -Name "Negative: Reparse point in target/backup directory fails closed before mutation" -Condition ($reparseDetected -and $canaryUntouched)
} catch {
    Assert-Test -Name "Negative: Reparse point in target/backup directory fails closed before mutation" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 23: Negative - Manifest receipt write failure triggers transaction rollback
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'receipt-failure-test'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    # Pre-create a directory at the exact manifest file path so [System.IO.File]::WriteAllText fails
    $manifestPath = Join-Path $fix.InstallRoot 'free-mcps-manifest.json'
    New-Item -ItemType Directory -Path $manifestPath -Force | Out-Null

    $threw = $false
    $caughtMsg = ""
    try {
        Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -SkipBinaryDownload $true `
            -ExpectedBinarySha $mockSha
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    # Verify transaction rollback: config.toml was restored to initial content!
    $codexCurrent = [System.IO.File]::ReadAllText($codexTomlPath)
    $codexRestored = ($codexCurrent -eq $initialCodexToml)
    $txFailedCaught = $threw -and $caughtMsg.Contains("INSTALL TRANSACTION FAILED")

    Assert-Test -Name "Negative: Manifest receipt write failure rolls back configs without leaving unreceipted state" -Condition ($txFailedCaught -and $codexRestored)
} catch {
    Assert-Test -Name "Negative: Manifest receipt write failure rolls back configs without leaving unreceipted state" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 24: Negative - Drift with matching block headers rejects fake AlreadyInstalled
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $initialCodexToml = "model = 'drift-fake-alreadyinstalled'`n"
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml)

    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $manifest = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $backupDir = Join-Path $fix.InstallRoot 'backups'
    $backupsBefore = @(Get-ChildItem -Path $backupDir)

    # Tamper with Codex config: keep section headers, but alter command to fake binary
    $tamperedToml = @"
model = 'drift-fake-alreadyinstalled'

[mcp_servers.codebase-memory-mcp]
command = 'C:\fake\trojan.exe'
args = []

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
"@
    [System.IO.File]::WriteAllText($codexTomlPath, $tamperedToml)

    $threw = $false
    $caughtMsg = ""
    $installResult = $null
    try {
        $installResult = Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -SkipBinaryDownload $true `
            -ExpectedBinarySha $mockSha
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }

    $backupsAfter = @(Get-ChildItem -Path $backupDir)
    $driftCaught = $threw -and $caughtMsg.Contains("DRIFT DETECTED")
    $noFakeAlreadyInstalled = ($installResult -eq $null -or $installResult.Status -ne 'AlreadyInstalled')
    $backupsPreserved = ($backupsBefore.Count -eq $backupsAfter.Count)

    Assert-Test -Name "Negative: Drift with block headers rejects fake AlreadyInstalled and preserves backups" -Condition ($driftCaught -and $noFakeAlreadyInstalled -and $backupsPreserved)
} catch {
    Assert-Test -Name "Negative: Drift with block headers rejects fake AlreadyInstalled and preserves backups" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 25: Negative - Public CLI ExpectedBinarySha override blocked without test authorization
# ---------------------------------------------------------
$fix = New-TestFixture
$origEnv = $env:FREE_MCPS_TEST_ALLOW_SHA_OVERRIDE
try {
    Remove-Item Env:\FREE_MCPS_TEST_ALLOW_SHA_OVERRIDE -ErrorAction SilentlyContinue
    $psPath = (Get-Process -Id $PID).Path
    $fakeSha = "1111111111111111111111111111111111111111111111111111111111111111"
    $cliOutput = & $psPath -File $cliPath -Mode Install -CodexHome $fix.CodexHome -AntigravityHome $fix.GeminiHome -InstallRoot $fix.InstallRoot -SkipBinaryDownload -ExpectedBinarySha $fakeSha 2>&1
    $cliOutputStr = ($cliOutput | Out-String)
    $pinViolationCaught = $cliOutputStr.Contains("Public CLI pin violation")

    Assert-Test -Name "Negative: Public CLI ExpectedBinarySha override is blocked without test authorization" -Condition $pinViolationCaught
} catch {
    Assert-Test -Name "Negative: Public CLI ExpectedBinarySha override is blocked without test authorization" -Condition $false -Details $_.Exception.Message
} finally {
    if ($origEnv) {
        $env:FREE_MCPS_TEST_ALLOW_SHA_OVERRIDE = $origEnv
    }
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 26: State Root Persistence - Explicit CBM_CACHE_DIR and CBM_RUNTIME_DIR in Codex TOML and Gemini JSON
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $installRes = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    $geminiJsonPath = Resolve-GeminiMcpConfigPath -AntigravityHome $fix.GeminiHome
    $expectedCache = Join-Path $fix.StateRoot 'cache'
    $expectedRuntime = Join-Path $fix.StateRoot 'runtime'

    # Check Codex TOML
    $codexContent = [System.IO.File]::ReadAllText($codexTomlPath)
    $hasTomlEnvSection = $codexContent.Contains('[mcp_servers.codebase-memory-mcp.env]')
    $hasTomlCache = $codexContent.Contains("CBM_CACHE_DIR = '$expectedCache'") -or $codexContent.Contains("CBM_CACHE_DIR = `"$($expectedCache.Replace('\','\\'))`"")
    $hasTomlRuntime = $codexContent.Contains("CBM_RUNTIME_DIR = '$expectedRuntime'") -or $codexContent.Contains("CBM_RUNTIME_DIR = `"$($expectedRuntime.Replace('\','\\'))`"")
    $noAllowedRootToml = -not $codexContent.Contains("CBM_ALLOWED_ROOT")

    # Check Gemini JSON
    $geminiParsed = Get-Content -LiteralPath $geminiJsonPath -Raw | ConvertFrom-Json
    $cbmJson = $geminiParsed.mcpServers.'codebase-memory-mcp'
    $hasJsonEnv = ($null -ne $cbmJson.env)
    $hasJsonCache = ($cbmJson.env.CBM_CACHE_DIR -eq $expectedCache)
    $hasJsonRuntime = ($cbmJson.env.CBM_RUNTIME_DIR -eq $expectedRuntime)
    $noAllowedRootJson = -not ($cbmJson.env.PSObject.Properties['CBM_ALLOWED_ROOT'])

    # Check Manifest receipt
    $manifest = $installRes.Manifest
    $manifestHasCache = ($manifest.CbmCacheDir -eq $expectedCache)
    $manifestHasRuntime = ($manifest.CbmRuntimeDir -eq $expectedRuntime)

    $allPassed = $hasTomlEnvSection -and $hasTomlCache -and $hasTomlRuntime -and $noAllowedRootToml -and
                 $hasJsonEnv -and $hasJsonCache -and $hasJsonRuntime -and $noAllowedRootJson -and
                 $manifestHasCache -and $manifestHasRuntime

    Assert-Test -Name "State Root: Absolute CBM_CACHE_DIR and CBM_RUNTIME_DIR persisted identically in TOML and JSON without allowed-root" -Condition $allPassed
} catch {
    Assert-Test -Name "State Root: Absolute CBM_CACHE_DIR and CBM_RUNTIME_DIR persisted identically in TOML and JSON without allowed-root" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 27: Quote Escaping - Paths with special characters handled correctly in TOML and JSON
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $specialStateRoot = Join-Path $fix.Root "user's state dir"
    New-Item -ItemType Directory -Path $specialStateRoot -Force | Out-Null
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $installRes = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $specialStateRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    $geminiJsonPath = Resolve-GeminiMcpConfigPath -AntigravityHome $fix.GeminiHome
    $expectedCache = Join-Path $specialStateRoot 'cache'
    $expectedRuntime = Join-Path $specialStateRoot 'runtime'

    $codexContent = [System.IO.File]::ReadAllText($codexTomlPath)
    $geminiParsed = Get-Content -LiteralPath $geminiJsonPath -Raw | ConvertFrom-Json

    # TOML should escape single quote properly using basic string
    $escapedExpectedCache = $expectedCache.Replace('\', '\\').Replace('"', '\"')
    $hasTomlEscaped = $codexContent.Contains("`"$escapedExpectedCache`"")
    $hasJsonPreserved = ($geminiParsed.mcpServers.'codebase-memory-mcp'.env.CBM_CACHE_DIR -eq $expectedCache)

    Assert-Test -Name "Quote Escaping: Paths with quotes properly escaped in TOML and roundtrip in JSON" -Condition ($hasTomlEscaped -and $hasJsonPreserved)
} catch {
    Assert-Test -Name "Quote Escaping: Paths with quotes properly escaped in TOML and roundtrip in JSON" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 28: Negative - StateRoot rejected if pointing directly to UserProfile root
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $threw = $false
    $caughtMsg = ""
    try {
        Assert-ValidStateRoot -StateRoot $env:USERPROFILE
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    $rejectedHome = $threw -and ($caughtMsg.Contains("user profile home root") -or $caughtMsg.Contains("user home directly is prohibited"))
    Assert-Test -Name "Negative: StateRoot rejected if pointing directly to UserProfile root" -Condition $rejectedHome
} catch {
    Assert-Test -Name "Negative: StateRoot rejected if pointing directly to UserProfile root" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 29: Negative - StateRoot rejected if filesystem drive root
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $threw = $false
    $caughtMsg = ""
    try {
        Assert-ValidStateRoot -StateRoot "C:\"
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    $rejectedDriveRoot = $threw -and ($caughtMsg.Contains("filesystem root") -or $caughtMsg.Contains("broad roots are prohibited"))
    Assert-Test -Name "Negative: StateRoot rejected if filesystem drive root" -Condition $rejectedDriveRoot
} catch {
    Assert-Test -Name "Negative: StateRoot rejected if filesystem drive root" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 30: Negative - StateRoot rejected if overlapping with CodexHome or InstallRoot
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $threw = $false
    $caughtMsg = ""
    try {
        Assert-ValidStateRoot -StateRoot $fix.CodexHome -CodexHome $fix.CodexHome -InstallRoot $fix.InstallRoot
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    $rejectedOverlap = $threw -and $caughtMsg.Contains("Overlap violation")
    Assert-Test -Name "Negative: StateRoot rejected if overlapping with CodexHome" -Condition $rejectedOverlap
} catch {
    Assert-Test -Name "Negative: StateRoot rejected if overlapping with CodexHome" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 31: Negative - Reparse point in StateRoot rejected before writes
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $realTarget = Join-Path $fix.Root 'reparse-state-target'
    New-Item -ItemType Directory -Path $realTarget -Force | Out-Null
    $reparseState = Join-Path $fix.Root 'junction-state'
    New-Item -ItemType Junction -Path $reparseState -Target $realTarget | Out-Null

    $threw = $false
    $caughtMsg = ""
    try {
        Assert-ValidStateRoot -StateRoot $reparseState
    } catch {
        $threw = $true
        $caughtMsg = $_.Exception.Message
    }
    $rejectedReparse = $threw -and $caughtMsg.Contains("reparse point")
    Assert-Test -Name "Negative: Reparse point in StateRoot rejected before writes" -Condition $rejectedReparse
} catch {
    Assert-Test -Name "Negative: Reparse point in StateRoot rejected before writes" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 32: Idempotence & Drift with State Env
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $firstInstall = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    # Second install with same StateRoot returns AlreadyInstalled
    $secondInstall = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $alreadyInstalled = ($secondInstall.Status -eq 'AlreadyInstalled')

    # Now alter CBM_CACHE_DIR in Codex TOML to simulate env drift
    $codexTomlPath = Join-Path $fix.CodexHome 'config.toml'
    $codexText = [System.IO.File]::ReadAllText($codexTomlPath)
    $tamperedCodex = $codexText -replace 'cache', 'drifted_cache'
    [System.IO.File]::WriteAllText($codexTomlPath, $tamperedCodex)

    $driftThrew = $false
    $driftMsg = ""
    try {
        Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -StateRoot $fix.StateRoot `
            -SkipBinaryDownload $true `
            -ExpectedBinarySha $mockSha
    } catch {
        $driftThrew = $true
        $driftMsg = $_.Exception.Message
    }

    $driftCaught = $driftThrew -and $driftMsg.Contains("DRIFT DETECTED")
    Assert-Test -Name "Idempotence and Drift: Second run succeeds; env path drift fails closed" -Condition ($alreadyInstalled -and $driftCaught)
} catch {
    Assert-Test -Name "Idempotence and Drift: Second run succeeds; env path drift fails closed" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 33: Rollback preserves state data and preexisting indexes (zero state deletion)
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $installRes = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    # Create dummy database and index files inside cache and runtime directories
    $dbFile = Join-Path $fix.StateRoot 'cache\codebase-memory.db'
    [System.IO.File]::WriteAllText($dbFile, "sqlite index binary database content")
    $logFile = Join-Path $fix.StateRoot 'cache\logs\cbm-daemon.log'
    $logParent = Split-Path -Parent $logFile
    New-Item -ItemType Directory -Path $logParent -Force | Out-Null
    [System.IO.File]::WriteAllText($logFile, "level=info msg=daemon.start")
    $socketFile = Join-Path $fix.StateRoot 'runtime\cbm.sock'
    [System.IO.File]::WriteAllText($socketFile, "ipc socket dummy")

    # Perform Rollback
    $null = Invoke-FreeMcpsRollbackWorkflow `
        -ManifestPath $installRes.ManifestPath `
        -InstallRoot $fix.InstallRoot `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -StateRoot $fix.StateRoot

    # Verify registration and binary removed
    $binRemoved = -not (Test-Path -LiteralPath $binPath)
    $manifestRemoved = -not (Test-Path -LiteralPath $installRes.ManifestPath)

    # CRITICAL: Verify state files and pre-existing indexes are COMPLETELY PRESERVED
    $dbPreserved = (Test-Path -LiteralPath $dbFile) -and ([System.IO.File]::ReadAllText($dbFile) -eq "sqlite index binary database content")
    $logPreserved = (Test-Path -LiteralPath $logFile)
    $socketPreserved = (Test-Path -LiteralPath $socketFile)

    $statePreserved = $binRemoved -and $manifestRemoved -and $dbPreserved -and $logPreserved -and $socketPreserved
    Assert-Test -Name "Rollback: Preserves state root, pre-existing indexes, and data (zero state deletion)" -Condition $statePreserved
} catch {
    Assert-Test -Name "Rollback: Preserves state root, pre-existing indexes, and data (zero state deletion)" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 34: Inspect Mode - Reports observed root configuration without guaranteeing runtime
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath

    $installRes = Invoke-FreeMcpsInstallWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot `
        -SkipBinaryDownload $true `
        -ExpectedBinarySha $mockSha

    $inspectReport = Invoke-FreeMcpsInspectWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot

    $expectedCache = Join-Path $fix.StateRoot 'cache'
    $expectedRuntime = Join-Path $fix.StateRoot 'runtime'

    $reportsConfigured = ($inspectReport.ConfiguredStateRoot -eq $fix.StateRoot) -and
                         ($inspectReport.ConfiguredCacheDir -eq $expectedCache) -and
                         ($inspectReport.ConfiguredRuntimeDir -eq $expectedRuntime)
    $reportsObservedCodex = ($inspectReport.CodexObservedCacheDir -eq $expectedCache) -and
                            ($inspectReport.CodexObservedRuntimeDir -eq $expectedRuntime)
    $reportsObservedGemini = ($inspectReport.GeminiObservedCacheDir -eq $expectedCache) -and
                             ($inspectReport.GeminiObservedRuntimeDir -eq $expectedRuntime)
    $reportsRuntimeAssessment = $inspectReport.RuntimeGuarantee.Contains("does not guarantee runtime execution")

    $inspectValid = $reportsConfigured -and $reportsObservedCodex -and $reportsObservedGemini -and $reportsRuntimeAssessment
    Assert-Test -Name "Inspect: Reports observed root configuration and runtime execution non-guarantee" -Condition $inspectValid
} catch {
    Assert-Test -Name "Inspect: Reports observed root configuration and runtime execution non-guarantee" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 35: Active Antigravity config wins over the Gemini CLI config
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $activeDir = Join-Path $fix.GeminiHome 'antigravity'
    $activePath = Join-Path $activeDir 'mcp_config.json'
    $geminiConfigDir = Join-Path $fix.GeminiHome 'config'
    $geminiPath = Join-Path $geminiConfigDir 'mcp_config.json'
    New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $geminiConfigDir -Force | Out-Null
    [System.IO.File]::WriteAllText($activePath, '')
    [System.IO.File]::WriteAllText($geminiPath, '{"mcpServers":{"context7":{"serverUrl":"https://mcp.context7.com/mcp"}}}')

    $resolved = Resolve-GeminiMcpConfigPath -AntigravityHome $fix.GeminiHome
    Assert-Test -Name "Resolver: Existing Antigravity config takes precedence over Gemini CLI config" `
        -Condition ([IO.Path]::GetFullPath($resolved) -eq [IO.Path]::GetFullPath($activePath)) `
        -Details "Resolved '$resolved' instead of active '$activePath'"
} catch {
    Assert-Test -Name "Resolver: Existing Antigravity config takes precedence over Gemini CLI config" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 36: Codex feature maps are rejected before MCP installation writes
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $codexPath = Join-Path $fix.CodexHome 'config.toml'
    $invalidCodex = "[features]`ncontext_management = { experimental_mode = true }`n"
    [System.IO.File]::WriteAllText($codexPath, $invalidCodex)
    $binPath = Join-Path $fix.InstallRoot 'codebase-memory-mcp.exe'
    $mockSha = New-MockBinary -DestinationPath $binPath
    $threw = $false
    $message = ''
    try {
        Invoke-FreeMcpsInstallWorkflow `
            -CodexHome $fix.CodexHome `
            -AntigravityHome $fix.GeminiHome `
            -InstallRoot $fix.InstallRoot `
            -StateRoot $fix.StateRoot `
            -SkipBinaryDownload $true `
            -ExpectedBinarySha $mockSha
    } catch {
        $threw = $true
        $message = $_.Exception.Message
    }
    $unchanged = [System.IO.File]::ReadAllText($codexPath) -ceq $invalidCodex
    $blocksInvalidFeatures = $message -match '(?i)(features|context_management).*(boolean|map|invalid)'
    Assert-Test -Name "Negative: Invalid Codex feature map fails closed before MCP installation writes" `
        -Condition ($threw -and $blocksInvalidFeatures -and $unchanged) `
        -Details $message
} catch {
    Assert-Test -Name "Negative: Invalid Codex feature map fails closed before MCP installation writes" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

# ---------------------------------------------------------
# Test 37: Inspect exposes an invalid Codex feature schema without mutating it
# ---------------------------------------------------------
$fix = New-TestFixture
try {
    $codexPath = Join-Path $fix.CodexHome 'config.toml'
    [System.IO.File]::WriteAllText($codexPath, "[features]`ncontext_management = { experimental_mode = true }`n")
    $inspect = Invoke-FreeMcpsInspectWorkflow `
        -CodexHome $fix.CodexHome `
        -AntigravityHome $fix.GeminiHome `
        -InstallRoot $fix.InstallRoot `
        -StateRoot $fix.StateRoot
    Assert-Test -Name "Inspect: Invalid Codex feature schema is reported without mutation" `
        -Condition (-not [bool]$inspect.CodexFeaturesValid -and -not [string]::IsNullOrWhiteSpace([string]$inspect.CodexFeaturesError) -and (Test-Path -LiteralPath $codexPath))
} catch {
    Assert-Test -Name "Inspect: Invalid Codex feature schema is reported without mutation" -Condition $false -Details $_.Exception.Message
} finally {
    Remove-TestFixture $fix
}

Write-Host ""
Write-Host "================================"
Write-Host "Total Tests : $script:TestCount"
Write-Host "Passed      : $script:PassedCount" -ForegroundColor Green
Write-Host "Failed      : $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "================================"

if ($script:FailedCount -gt 0) {
    exit 1
} else {
    exit 0
}
