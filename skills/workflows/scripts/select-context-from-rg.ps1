# skills/workflows/scripts/select-context-from-rg.ps1
# Ripgrep adapter that executes structured local searches (rg --json), groups matching
# code lines into contiguous snippet candidates, and invokes the TypeSafe/Jev context reranker.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Query,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$Path = '.',

    [Parameter(Mandatory = $false)]
    [string[]]$Glob = @(),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 500)]
    [int]$MaxMatches = 50,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 10)]
    [int]$ContextLines = 2,

    [Parameter(Mandatory = $false)]
    [string]$RoutingObjective = '',

    [Parameter(Mandatory = $false)]
    [string]$TaskObjective = '',

    [Parameter(Mandatory = $false)]
    [string]$Mode = '',

    [Parameter(Mandatory = $false)]
    [string]$WorkingDir = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('off', 'advisory')]
    [string]$Policy = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('none', 'metadata_only', 'snippets_allowed')]
    [string]$PrivacyScope = '',

    [Parameter(Mandatory = $false)]
    [switch]$AuthorizeContentTransmission,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0.0, 1.0)]
    [double]$KeepThreshold = 0.70,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0.0, 1.0)]
    [double]$MaybeThreshold = 0.40,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MaxSelectedCandidates = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(512, 10485760)]
    [int]$MaxBudgetBytes = 16384,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MinCandidates = 8,

    [Parameter(Mandatory = $false)]
    [ValidateRange(256, 10485760)]
    [int]$ContextBudgetTriggerBytes = 12000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MaxCandidatesToEvaluate = 100,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$MaxJevCalls = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 10485760)]
    [int]$MaxTotalPayloadBytes = 262144,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$BatchSize = 20,

    [Parameter(Mandatory = $false)]
    [string[]]$PinnedIds = @(),

    [Parameter(Mandatory = $false)]
    [object]$MockRgOutput = $null,

    [Parameter(Mandatory = $false)]
    [int]$MockRgExitCode = 0,

    [Parameter(Mandatory = $false)]
    [hashtable]$MockResponses = $null,

    [Parameter(Mandatory = $false)]
    [scriptblock]$HttpTransportMock = $null,

    [Parameter(Mandatory = $false)]
    [switch]$AsJson,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. Environment & Path Resolution
$resolvedWorkingDir = if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
    [IO.Path]::GetFullPath($PWD.Path)
}
else {
    [IO.Path]::GetFullPath($WorkingDir)
}

$modulePath = Join-Path $PSScriptRoot 'context-reranking.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required module not found at: $modulePath"
}
Import-Module -Name $modulePath -Force

$canonicalRepoRoot = Resolve-CanonicalDirectoryRoot -Path $resolvedWorkingDir
$canonicalRepoPrefix = $canonicalRepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

# Objective resolution: RoutingObjective (preferred) -> TaskObjective -> Query
$effectiveObjective = if (-not [string]::IsNullOrWhiteSpace($RoutingObjective)) {
    $RoutingObjective
}
elseif (-not [string]::IsNullOrWhiteSpace($TaskObjective)) {
    $TaskObjective
}
else {
    $Query
}

# Validate requested -Path containment BEFORE executing ripgrep
if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Search path cannot be empty or whitespace."
}

$rawPath = $Path.Trim()
$fullSearchPath = $null
if ([IO.Path]::IsPathRooted($rawPath)) {
    $fullSearchPath = [IO.Path]::GetFullPath($rawPath)
}
else {
    $normSearch = $rawPath.Replace('\', '/') -replace '^\./', ''
    $searchSegments = @($normSearch -split '/')
    if ($searchSegments -contains '..') {
        throw "Search path contains upward directory traversal ('..') escaping repository scope: '$Path'."
    }
    $fullSearchPath = [IO.Path]::GetFullPath([IO.Path]::Combine($canonicalRepoRoot, $rawPath))
}

if (-not (Test-Path -LiteralPath $fullSearchPath)) {
    throw "Search path does not exist: '$Path'."
}

# Canonical check for repo containment and prefix collision avoidance
$canonicalSearchPath = Resolve-CanonicalDirectoryRoot -Path $fullSearchPath
$canonicalSearchCheck = if (Test-Path -LiteralPath $canonicalSearchPath -PathType Container) {
    $canonicalSearchPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
}
else {
    $canonicalSearchPath
}

if (-not $canonicalSearchCheck.StartsWith($canonicalRepoPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    -not $canonicalSearchPath.Equals($canonicalRepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Search path escapes repository containment: '$Path' resolves to '$canonicalSearchPath'."
}

# 2. Ripgrep Execution or Mock Ingestion
$rawLines = [System.Collections.Generic.List[string]]::new()

if ($null -ne $MockRgOutput -or $MockRgExitCode -ne 0) {
    if ($MockRgExitCode -eq 1) {
        # Normal zero-matches exit code: empty rawLines, successful execution
    }
    elseif ($MockRgExitCode -ge 2) {
        $errMsg = if ($null -ne $MockRgOutput -and -not ($MockRgOutput -is [System.Collections.IEnumerable])) {
            [string]$MockRgOutput
        }
        else {
            "Simulated ripgrep execution error (exit code $MockRgExitCode)"
        }
        throw "ripgrep process failed with exit code $($MockRgExitCode): $errMsg"
    }
    elseif ($null -ne $MockRgOutput) {
        if ($MockRgOutput -is [System.Collections.IEnumerable] -and -not ($MockRgOutput -is [string])) {
            foreach ($line in $MockRgOutput) {
                if ($null -ne $line) {
                    $rawLines.Add([string]$line)
                }
            }
        }
        else {
            $rawLines.Add([string]$MockRgOutput)
        }
    }
}
else {
    $rgCommand = Get-Command rg -ErrorAction SilentlyContinue
    if (-not $rgCommand) {
        throw "ripgrep (rg) is not installed or not in PATH."
    }

    # Build argument list as pure data
    $rgArgs = [System.Collections.Generic.List[string]]::new()
    $rgArgs.Add('--json')
    if ($ContextLines -gt 0) {
        $rgArgs.Add('-C')
        $rgArgs.Add([string]$ContextLines)
    }
    # NOTE: Ripgrep's -m / --max-count limits matches PER FILE, not globally across the entire search.
    # Global candidate limits are enforced by MaxCandidatesToEvaluate in rerank-context.ps1.
    if ($MaxMatches -gt 0) {
        $rgArgs.Add('-m')
        $rgArgs.Add([string]$MaxMatches)
    }
    foreach ($g in $Glob) {
        if (-not [string]::IsNullOrWhiteSpace($g)) {
            $rgArgs.Add('-g')
            $rgArgs.Add($g.Trim())
        }
    }

    # Pass query and search path
    $rgArgs.Add('-e')
    $rgArgs.Add($Query)
    $rgArgs.Add($canonicalSearchPath)

    # Execute ripgrep via ProcessStartInfo to accurately capture stdout, stderr and exit code
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $rgCommand.Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    # Branch explicitly by runtime capability (PowerShell 7+ / .NET Core vs Windows PowerShell 5.1 / .NET Framework)
    $hasArgumentList = [bool]($psi.PSObject.Properties['ArgumentList'])
    if ($hasArgumentList) {
        foreach ($arg in $rgArgs) {
            $psi.ArgumentList.Add($arg)
        }
    }
    else {
        # Format arguments safely without Invoke-Expression, preserving spaces and special characters
        $formatted = @($rgArgs | ForEach-Object { Format-WindowsProcessArgument $_ }) -join ' '
        $psi.Arguments = $formatted
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $proc.ExitCode

    if ($exitCode -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
            $stdoutLines = $stdoutText -split "\r?\n"
            foreach ($l in $stdoutLines) {
                if (-not [string]::IsNullOrWhiteSpace($l)) {
                    $rawLines.Add($l)
                }
            }
        }
    }
    elseif ($exitCode -eq 1) {
        # Normal termination: 0 matches found. No candidates, not an error.
    }
    else {
        $errSummary = if (-not [string]::IsNullOrWhiteSpace($stderrText)) { $stderrText.Trim() } else { "Unknown ripgrep execution error" }
        throw "ripgrep process failed with exit code $($exitCode): $errSummary"
    }
}

# 3. Parse JSON Objects and Group by File
$fileMatchGroups = [ordered]@{}

foreach ($jsonLine in $rawLines) {
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        continue
    }

    $entry = $null
    try {
        $entry = $jsonLine | ConvertFrom-Json
    }
    catch {
        continue
    }

    if ($null -eq $entry -or -not ($entry.PSObject.Properties.Name -contains 'type')) {
        continue
    }

    $type = [string]$entry.type
    if ($type -notin @('match', 'context')) {
        continue
    }

    $data = $entry.data
    if ($null -eq $data -or -not ($data.PSObject.Properties.Name -contains 'path')) {
        continue
    }

    $filePath = [string]$data.path.text
    $lineNum = [int]$data.line_number
    $lineText = [string]$data.lines.text

    # Make relative path canonical to working dir and prevent prefix collisions
    $fullFilePath = if ([IO.Path]::IsPathRooted($filePath)) {
        [IO.Path]::GetFullPath($filePath)
    }
    else {
        [IO.Path]::GetFullPath([IO.Path]::Combine($canonicalRepoRoot, $filePath))
    }

    $cleanPath = if ($fullFilePath.StartsWith($canonicalRepoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $fullFilePath.Substring($canonicalRepoPrefix.Length).Replace('\', '/')
    }
    else {
        $filePath.Replace('\', '/') -replace '^\./', ''
    }

    # Verify repository containment of match path
    try {
        $cleanPath = Assert-CandidatePathContainment -RepoPath $canonicalRepoRoot -RelativePath $cleanPath
    }
    catch {
        continue
    }

    if (-not $fileMatchGroups.Contains($cleanPath)) {
        $fileMatchGroups[$cleanPath] = [System.Collections.Generic.List[object]]::new()
    }

    $fileMatchGroups[$cleanPath].Add([pscustomobject]@{
        LineNumber = [int]$lineNum
        LineText   = $lineText
        IsMatch    = ($type -eq 'match')
    })
}

# 4. Form Candidate Snippets
$candidateList = [System.Collections.Generic.List[object]]::new()
$rankCounter = 1

foreach ($filePath in $fileMatchGroups.Keys) {
    $lines = @($fileMatchGroups[$filePath] | Sort-Object -Property @{ Expression = { [int]$_.LineNumber }; Ascending = $true })
    if ($lines.Count -eq 0) {
        continue
    }

    # Group lines that are adjacent or separated by at most (ContextLines + 1) lines
    $maxGap = [Math]::Max(1, $ContextLines + 1)
    $currentChunk = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cur = $lines[$i]
        if ($currentChunk.Count -eq 0) {
            $currentChunk.Add($cur)
        }
        else {
            $prev = $currentChunk[$currentChunk.Count - 1]
            if (($cur.LineNumber - $prev.LineNumber) -le $maxGap) {
                $currentChunk.Add($cur)
            }
            else {
                # Emit current chunk as candidate
                $startLine = $currentChunk[0].LineNumber
                $endLine = $currentChunk[$currentChunk.Count - 1].LineNumber
                $chunkContent = -join ($currentChunk | ForEach-Object { $_.LineText })

                $cand = New-ContextCandidate `
                    -Source 'rg' `
                    -SourceRef $filePath `
                    -Content $chunkContent `
                    -LineStart $startLine `
                    -LineEnd $endLine `
                    -OriginalRank $rankCounter `
                    -Representation 'snippet'

                $candidateList.Add($cand)
                $rankCounter++
                $currentChunk.Clear()
                $currentChunk.Add($cur)
            }
        }
    }

    if ($currentChunk.Count -gt 0) {
        $startLine = $currentChunk[0].LineNumber
        $endLine = $currentChunk[$currentChunk.Count - 1].LineNumber
        $chunkContent = -join ($currentChunk | ForEach-Object { $_.LineText })

        $cand = New-ContextCandidate `
            -Source 'rg' `
            -SourceRef $filePath `
            -Content $chunkContent `
            -LineStart $startLine `
            -LineEnd $endLine `
            -OriginalRank $rankCounter `
            -Representation 'snippet'

        $candidateList.Add($cand)
        $rankCounter++
    }
}

# 5. Invoke Context Reranker
$rerankScript = Join-Path $PSScriptRoot 'rerank-context.ps1'
$rerankParams = @{
    Candidates                   = @($candidateList)
    RoutingObjective             = $RoutingObjective
    TaskObjective                = $effectiveObjective
    Mode                         = $Mode
    WorkingDir                   = $canonicalRepoRoot
    KeepThreshold                = $KeepThreshold
    MaybeThreshold               = $MaybeThreshold
    MaxSelectedCandidates        = $MaxSelectedCandidates
    MaxBudgetBytes               = $MaxBudgetBytes
    MinCandidates                = $MinCandidates
    ContextBudgetTriggerBytes    = $ContextBudgetTriggerBytes
    MaxCandidatesToEvaluate      = $MaxCandidatesToEvaluate
    MaxJevCalls                  = $MaxJevCalls
    MaxTotalPayloadBytes         = $MaxTotalPayloadBytes
    BatchSize                    = $BatchSize
    PinnedIds                    = $PinnedIds
    MockResponses                = $MockResponses
    HttpTransportMock            = $HttpTransportMock
    AsJson                       = $AsJson.IsPresent
    Quiet                        = $Quiet.IsPresent
    AuthorizeContentTransmission = $AuthorizeContentTransmission.IsPresent
}

if (-not [string]::IsNullOrWhiteSpace($Policy)) {
    $rerankParams['Policy'] = $Policy
}
if (-not [string]::IsNullOrWhiteSpace($PrivacyScope)) {
    $rerankParams['PrivacyScope'] = $PrivacyScope
}

$rerankResult = & $rerankScript @rerankParams
return $rerankResult
