function Get-NativeProfileContractIssue {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return "Native profile is missing: $Path"
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $expected = [ordered]@{
        model = 'gpt-5.6-luna'
        model_reasoning_effort = 'high'
        sandbox_mode = 'read-only'
    }
    $seen = @{}
    $valuePattern = '^\s*(?:model|model_reasoning_effort|sandbox_mode)\s*=\s*"(?<value>(?:\\.|[^"\\])*)"\s*(?:#.*)?$'
    $keyPattern = '^\s*(?<key>model|model_reasoning_effort|sandbox_mode)\s*='
    $multilineDelimiter = $null
    $basicTriple = ([char]34).ToString() * 3
    $literalTriple = ([char]39).ToString() * 3

    $lineNumber = 0
    foreach ($line in ($text -split '\r?\n')) {
        $lineNumber++
        if ($null -ne $multilineDelimiter) {
            $delimiterCount = @([regex]::Matches($line, [regex]::Escape($multilineDelimiter))).Count
            if (($delimiterCount % 2) -eq 1) {
                $multilineDelimiter = $null
            }
            continue
        }

        if ($line -match '^\s*\[') {
            return "Native profile contains a table header at line ${lineNumber}: $Path"
        }

        $keyMatch = [regex]::Match($line, $keyPattern)
        if ($keyMatch.Success) {
            $key = $keyMatch.Groups['key'].Value
            if ($seen.ContainsKey($key)) {
                return "Native profile duplicates $key at line ${lineNumber}: $Path"
            }

            $valueMatch = [regex]::Match($line, $valuePattern)
            if (-not $valueMatch.Success) {
                return "Native profile has an invalid $key assignment at line ${lineNumber}: $Path"
            }

            $actual = $valueMatch.Groups['value'].Value
            if ($actual -cne [string]$expected[$key]) {
                return "Native profile has an invalid $key value at line ${lineNumber}: $Path"
            }

            $seen[$key] = $true
        }

        $delimiter = if ($line.Contains($basicTriple)) { $basicTriple } elseif ($line.Contains($literalTriple)) { $literalTriple } else { $null }
        if ($null -ne $delimiter) {
            $delimiterCount = @([regex]::Matches($line, [regex]::Escape($delimiter))).Count
            if (($delimiterCount % 2) -eq 1) {
                $multilineDelimiter = $delimiter
            }
        }
    }

    foreach ($setting in $expected.Keys) {
        if (-not $seen.ContainsKey($setting)) {
            return "Native profile is missing ${setting}: $Path"
        }
    }

    return $null
}

function Assert-NativeProfileContract {
    param([Parameter(Mandatory)][string]$Path)

    $issue = Get-NativeProfileContractIssue -Path $Path
    if ($null -ne $issue) {
        throw $issue
    }
}

function Test-NativeProfileContract {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Assert-NativeProfileContract -Path $Path
        return $true
    }
    catch {
        return $false
    }
}
