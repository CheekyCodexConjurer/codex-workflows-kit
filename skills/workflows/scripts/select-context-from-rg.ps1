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
    [ValidateRange(1, 100)]
    [int]$BatchSize = 20,

    [Parameter(Mandatory = $false)]
    [string[]]$PinnedIds = @(),

    [Parameter(Mandatory = $false)]
    [object]$MockRgOutput = $null,

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

$effectiveObjective = if (-not [string]::IsNullOrWhiteSpace($TaskObjective)) {
    $TaskObjective
}
else {
    $Query
}

$modulePath = Join-Path $PSScriptRoot 'context-reranking.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required module not found at: $modulePath"
}
Import-Module -Name $modulePath -Force

# 2. Ripgrep Execution or Mock Ingestion
$rawLines = [System.Collections.Generic.List[string]]::new()

if ($null -ne $MockRgOutput) {
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
else {
    $rgCommand = Get-Command -Name 'rg' -ErrorAction SilentlyContinue
    if (-not $rgCommand) {
        throw "ripgrep ('rg') executable not found in PATH."
    }

    $rgArgs = [System.Collections.Generic.List[string]]::new()
    $rgArgs.Add('--json')
    if ($ContextLines -gt 0) {
        $rgArgs.Add('-C')
        $rgArgs.Add([string]$ContextLines)
    }
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

    $resolvedSearchPath = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    }
    else {
        [IO.Path]::GetFullPath([IO.Path]::Combine($resolvedWorkingDir, $Path))
    }

    # Pass query and path as data arguments
    $rgArgs.Add('-e')
    $rgArgs.Add($Query)
    $rgArgs.Add($resolvedSearchPath)

    # Execute rg safely
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $rgCommand.Source @rgArgs
        if ($null -ne $output) {
            if ($output -is [System.Collections.IEnumerable] -and -not ($output -is [string])) {
                foreach ($o in $output) {
                    $rawLines.Add([string]$o)
                }
            }
            else {
                $rawLines.Add([string]$output)
            }
        }
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
}

# 3. Parse JSON Objects and Group by File
# In rg --json, matches and context lines come in stream order.
# We group contiguous/adjacent lines into candidate chunks.

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

    # Make relative path canonical to working dir
    $fullFilePath = if ([IO.Path]::IsPathRooted($filePath)) {
        [IO.Path]::GetFullPath($filePath)
    }
    else {
        [IO.Path]::GetFullPath([IO.Path]::Combine($resolvedWorkingDir, $filePath))
    }

    $cleanPath = if ($fullFilePath.StartsWith($resolvedWorkingDir, [StringComparison]::OrdinalIgnoreCase)) {
        $fullFilePath.Substring($resolvedWorkingDir.Length).TrimStart('\', '/').Replace('\', '/')
    }
    else {
        $filePath.Replace('\', '/') -replace '^\./', ''
    }

    if (-not $fileMatchGroups.Contains($cleanPath)) {
        $fileMatchGroups[$cleanPath] = [System.Collections.Generic.List[object]]::new()
    }

    $fileMatchGroups[$cleanPath].Add([ordered]@{
        LineNumber = $lineNum
        LineText   = $lineText
        IsMatch    = ($type -eq 'match')
    })
}

# 4. Form Candidate Snippets
$candidateList = [System.Collections.Generic.List[object]]::new()
$rankCounter = 1

foreach ($filePath in $fileMatchGroups.Keys) {
    $lines = @($fileMatchGroups[$filePath] | Sort-Object -Property LineNumber)
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
    TaskObjective                = $effectiveObjective
    Mode                         = $Mode
    WorkingDir                   = $resolvedWorkingDir
    KeepThreshold                = $KeepThreshold
    MaybeThreshold               = $MaybeThreshold
    MaxSelectedCandidates        = $MaxSelectedCandidates
    MaxBudgetBytes               = $MaxBudgetBytes
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
