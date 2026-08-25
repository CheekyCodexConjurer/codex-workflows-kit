Set-StrictMode -Version Latest

$script:BackendKeyDefinitions = @(
    [ordered]@{ Path = 'features.multi_agent'; Table = 'features'; Key = 'multi_agent'; NativeValue = 'true'; ValueKind = 'bool' },
    [ordered]@{ Path = 'features.fast_mode'; Table = 'features'; Key = 'fast_mode'; NativeValue = 'false'; ValueKind = 'bool' },
    [ordered]@{ Path = 'agents.default_subagent_model'; Table = 'agents'; Key = 'default_subagent_model'; NativeValue = '"gpt-5.6-luna"'; ValueKind = 'string' },
    [ordered]@{ Path = 'agents.default_subagent_reasoning_effort'; Table = 'agents'; Key = 'default_subagent_reasoning_effort'; NativeValue = '"max"'; ValueKind = 'string' },
    [ordered]@{ Path = 'mcp_servers.deepseek-subagent.enabled'; Table = 'mcp_servers.deepseek-subagent'; Key = 'enabled'; NativeValue = 'false'; ValueKind = 'bool' }
)

function Get-BackendKeyDefinitions {
    return @($script:BackendKeyDefinitions)
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-BackendTableHeader {
    param([AllowEmptyString()][string]$Line)

    return ($Line -replace '\r\n?', '') -match '^[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?$'
}

function Get-BackendConfigSnapshot {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalized = $Text -replace '\r\n', "`n"
    $lines = [System.Collections.Generic.List[string]]([regex]::Split($normalized, "`n"))
    $tables = @{}
    $headers = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], '^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
        if (-not $match.Success) {
            continue
        }
        $name = $match.Groups[1].Value
        if ($tables.ContainsKey($name)) {
            throw "Backend configuration contains duplicate TOML table: [$name]"
        }
        $table = [pscustomobject]@{
            Name = $name
            HeaderIndex = $index
            EndIndex = $lines.Count
        }
        $tables[$name] = $table
        $headers.Add($table)
    }

    # Header discovery already walks the lines in ascending source order. Keep
    # that integer ordering directly; sorting OrderedDictionary records is
    # host-dependent in Windows PowerShell 5.1.
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $end = if ($i + 1 -lt $headers.Count) { [int]$headers[$i + 1].HeaderIndex } else { $lines.Count }
        $headers[$i].EndIndex = $end
    }
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $header = $headers[$i]
        $headerIndex = [int]$header.HeaderIndex
        $endIndex = [int]$header.EndIndex
        if ($headerIndex -lt 0 -or $headerIndex -ge $endIndex -or $endIndex -gt $lines.Count) {
            throw "Backend configuration has an invalid table range for [$($header.Name)]: header=$headerIndex end=$endIndex lineCount=$($lines.Count)"
        }
    }

    $records = [ordered]@{}
    foreach ($definition in $script:BackendKeyDefinitions) {
        $table = if ($tables.ContainsKey($definition.Table)) { $tables[$definition.Table] } else { $null }
        $record = [ordered]@{
            path = $definition.Path
            tablePresent = $null -ne $table
            present = $false
            value = $null
            lineIndex = -1
        }

        if ($null -ne $table) {
            $keyPattern = '^\s*' + [regex]::Escape($definition.Key) + '\s*='
            $matches = New-Object System.Collections.Generic.List[object]
            for ($index = $table.HeaderIndex + 1; $index -lt $table.EndIndex; $index++) {
                if ([regex]::IsMatch($lines[$index], $keyPattern)) {
                    $matches.Add([pscustomobject]@{ Index = $index; Line = $lines[$index] })
                }
            }
            if ($matches.Count -gt 1) {
                throw "Backend configuration contains duplicate key '$($definition.Key)' under [$($definition.Table)]"
            }
            if ($matches.Count -eq 1) {
                $valueMatch = [regex]::Match(
                    $matches[0].Line,
                    '^\s*' + [regex]::Escape($definition.Key) + '\s*=\s*(?<value>"(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)*''|[^#\r\n]+?)\s*(?:#.*)?$'
                )
                if (-not $valueMatch.Success -or [string]::IsNullOrWhiteSpace($valueMatch.Groups['value'].Value)) {
                    throw "Backend configuration contains an invalid value for '$($definition.Path)'"
                }
                $record.present = $true
                $record.value = $valueMatch.Groups['value'].Value.Trim()
                $record.lineIndex = $matches[0].Index
            }
        }

        $records[$definition.Path] = $record
    }

    return [pscustomobject]@{
        Text = $Text
        Lines = $lines
        Tables = $tables
        Records = $records
    }
}

function New-BackendPriorRecord {
    param([Parameter(Mandatory)][object]$Record)

    return [ordered]@{
        path = [string]$Record.path
        tablePresent = [bool]$Record.tablePresent
        present = [bool]$Record.present
        value = if ([bool]$Record.present) { [string]$Record.value } else { $null }
    }
}

function Get-BackendPriorRecord {
    param(
        [Parameter(Mandatory)][object]$BackendState,
        [Parameter(Mandatory)][string]$Path
    )

    foreach ($record in @((Get-ObjectPropertyValue -Object $BackendState -Name 'prior'))) {
        if ($null -ne $record -and [string](Get-ObjectPropertyValue -Object $record -Name 'path') -ceq $Path) {
            return $record
        }
    }
    return $null
}

function Assert-CodexBackendState {
    param([Parameter(Mandatory)][object]$BackendState)

    if (-not (Test-ObjectProperty -Object $BackendState -Name 'selected')) {
        throw 'Backend state is missing selected backend.'
    }
    $selected = [string](Get-ObjectPropertyValue -Object $BackendState -Name 'selected')
    if ($selected -notin @('native', 'deepseek')) {
        throw "Backend state has unsupported selected backend: $selected"
    }
    $prior = Get-ObjectPropertyValue -Object $BackendState -Name 'prior'
    if ($null -eq $prior) {
        throw 'Backend state is missing prior managed-key records.'
    }

    $records = @($prior)
    if ($records.Count -ne $script:BackendKeyDefinitions.Count) {
        throw "Backend state must contain exactly $($script:BackendKeyDefinitions.Count) prior managed-key records."
    }
    $knownPaths = @{}
    foreach ($definition in $script:BackendKeyDefinitions) {
        $knownPaths[$definition.Path] = $true
    }
    $recordsByPath = @{}
    foreach ($record in $records) {
        if ($null -eq $record -or -not (Test-ObjectProperty -Object $record -Name 'path')) {
            throw 'Backend state contains a prior record without a path.'
        }
        $path = [string](Get-ObjectPropertyValue -Object $record -Name 'path')
        if (-not $knownPaths.ContainsKey($path)) {
            throw "Backend state contains an unmanaged prior record: $path"
        }
        if ($recordsByPath.ContainsKey($path)) {
            throw "Backend state contains duplicate prior record: $path"
        }
        $recordsByPath[$path] = $record
    }

    foreach ($definition in $script:BackendKeyDefinitions) {
        if (-not $recordsByPath.ContainsKey($definition.Path)) {
            throw "Backend state is missing prior record: $($definition.Path)"
        }
        $record = $recordsByPath[$definition.Path]
        foreach ($property in @('tablePresent', 'present')) {
            $value = Get-ObjectPropertyValue -Object $record -Name $property
            if ($value -notin @($true, $false)) {
                throw "Backend state has invalid $property flag for $($definition.Path)"
            }
        }
        $present = [bool](Get-ObjectPropertyValue -Object $record -Name 'present')
        $tablePresent = [bool](Get-ObjectPropertyValue -Object $record -Name 'tablePresent')
        $value = Get-ObjectPropertyValue -Object $record -Name 'value'
        if ($present -and -not $tablePresent) {
            throw "Backend state records a present key in an absent table: $($definition.Path)"
        }
        if ($present -and [string]::IsNullOrWhiteSpace([string]$value)) {
            throw "Backend state has a present key without a value: $($definition.Path)"
        }
        if (-not $present -and $null -ne $value) {
            throw "Backend state has an absent key with a value: $($definition.Path)"
        }
    }
}

function New-CodexBackendState {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [object]$ExistingInstallState
    )

    if ($null -ne $ExistingInstallState -and (Test-ObjectProperty -Object $ExistingInstallState -Name 'codexBackend')) {
        $existingBackend = Get-ObjectPropertyValue -Object $ExistingInstallState -Name 'codexBackend'
        Assert-CodexBackendState -BackendState $existingBackend
        return $existingBackend
    }

    $prior = New-Object System.Collections.Generic.List[object]
    foreach ($definition in $script:BackendKeyDefinitions) {
        $record = $Snapshot.Records[$definition.Path]
        if ($definition.Path -ceq 'features.multi_agent' -and $null -ne $ExistingInstallState -and (Test-ObjectProperty -Object $ExistingInstallState -Name 'codexFeaturesPrior')) {
            $legacy = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $ExistingInstallState -Name 'codexFeaturesPrior') -Name 'multi_agent'
            if ($null -ne $legacy) {
                $record = [ordered]@{
                    path = $definition.Path
                    tablePresent = [bool]$record.tablePresent
                    present = [bool](Get-ObjectPropertyValue -Object $legacy -Name 'present')
                    value = Get-ObjectPropertyValue -Object $legacy -Name 'value'
                }
            }
        }
        $prior.Add((New-BackendPriorRecord -Record $record))
    }

    $state = [ordered]@{
        version = 1
        selected = 'deepseek'
        prior = @($prior.ToArray())
    }
    Assert-CodexBackendState -BackendState $state
    return $state
}

function Get-BackendTarget {
    param(
        [Parameter(Mandatory)][string]$Backend,
        [Parameter(Mandatory)][object]$BackendState,
        [Parameter(Mandatory)][object]$Definition
    )

    if ($Backend -notin @('native', 'deepseek')) {
        throw "Unsupported backend: $Backend"
    }
    if ($Definition.Path -ceq 'features.multi_agent') {
        return [pscustomobject]@{ Present = $true; Value = if ($Backend -ceq 'native') { 'true' } else { 'false' } }
    }
    if ($Backend -ceq 'native') {
        return [pscustomobject]@{ Present = $true; Value = [string]$Definition.NativeValue }
    }

    $prior = Get-BackendPriorRecord -BackendState $BackendState -Path $Definition.Path
    if ($null -eq $prior) {
        throw "Backend state is missing prior record: $($Definition.Path)"
    }
    return [pscustomobject]@{
        Present = [bool](Get-ObjectPropertyValue -Object $prior -Name 'present')
        Value = if ([bool](Get-ObjectPropertyValue -Object $prior -Name 'present')) { [string](Get-ObjectPropertyValue -Object $prior -Name 'value') } else { $null }
    }
}

function Remove-EmptyBackendBlocks {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $pattern = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT: backend[^\r\n]*\r?\n(?<body>.*?)^# END CODEX-WORKFLOWS-KIT: backend[^\r\n]*(?:\r?\n|$)'
    return [regex]::Replace($Text, $pattern, {
        param($match)
        $body = $match.Groups['body'].Value
        $body = [regex]::Replace($body, '(?m)^\s*\[[^\]]+\]\s*(?:#.*)?\r?\n?', '')
        if ([string]::IsNullOrWhiteSpace($body)) { return '' }
        return $match.Value
    })
}

function Set-BackendKeyText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][bool]$Present,
        [AllowNull()][string]$Value
    )

    $snapshot = Get-BackendConfigSnapshot -Text $Text
    $record = $snapshot.Records[$Definition.Path]
    $lines = [System.Collections.Generic.List[string]]([regex]::Split(($Text -replace '\r\n', "`n"), "`n"))
    $nl = [Environment]::NewLine

    if (-not [bool]$record.tablePresent) {
        if (-not $Present) {
            return $Text
        }
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add('')
        }
        $lines.Add('# BEGIN CODEX-WORKFLOWS-KIT: backend ' + $Definition.Table)
        $lines.Add('[' + $Definition.Table + ']')
        $lines.Add($Definition.Key + ' = ' + $Value)
        $lines.Add('# END CODEX-WORKFLOWS-KIT: backend ' + $Definition.Table)
        return (($lines -join $nl).TrimEnd() + $nl)
    }

    if ([bool]$record.present) {
        $lineIndex = [int]$record.lineIndex
        if (-not $Present) {
            $lines.RemoveAt($lineIndex)
        }
        else {
            $escaped = [regex]::Escape($Definition.Key)
            $line = $lines[$lineIndex]
            $match = [regex]::Match($line, '^([ \t]*' + $escaped + '\s*=\s*)(?<value>"(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)*''|[^#\r\n]+?)(?<suffix>\s*(?:#.*)?)$')
            if (-not $match.Success) {
                throw "Cannot safely rewrite backend key: $($Definition.Path)"
            }
            $lines[$lineIndex] = $match.Groups[1].Value + $Value + $match.Groups['suffix'].Value
        }
    }
    elseif ($Present) {
        $table = $snapshot.Tables[$Definition.Table]
        $lines.Insert(([int]$table.HeaderIndex + 1), $Definition.Key + ' = ' + $Value)
    }

    return (($lines -join $nl).TrimEnd() + $nl)
}

function Set-CodexBackendConfigText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter(Mandatory)][object]$BackendState
    )

    Assert-CodexBackendState -BackendState $BackendState
    $result = $Text
    foreach ($definition in $script:BackendKeyDefinitions) {
        $target = Get-BackendTarget -Backend $Backend -BackendState $BackendState -Definition $definition
        $result = Set-BackendKeyText -Text $result -Definition $definition -Present $target.Present -Value $target.Value
    }
    return (Remove-EmptyBackendBlocks -Text $result)
}

function Test-CodexBackendMatrix {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter(Mandatory)][object]$BackendState
    )

    Assert-CodexBackendState -BackendState $BackendState
    $snapshot = Get-BackendConfigSnapshot -Text $Text
    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($definition in $script:BackendKeyDefinitions) {
        $actual = $snapshot.Records[$definition.Path]
        $target = Get-BackendTarget -Backend $Backend -BackendState $BackendState -Definition $definition
        if ([bool]$actual.present -ne [bool]$target.Present) {
            $mismatches.Add("$($definition.Path) presence is $($actual.present), expected $($target.Present)")
            continue
        }
        if ([bool]$target.Present -and [string]$actual.value -cne [string]$target.Value) {
            $mismatches.Add("$($definition.Path) is '$($actual.value)', expected '$($target.Value)'")
        }
    }
    return [pscustomobject]@{
        IsMatch = $mismatches.Count -eq 0
        Mismatches = @($mismatches.ToArray())
        Snapshot = $snapshot
    }
}

function Assert-CodexBackendMatrix {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter(Mandatory)][object]$BackendState
    )

    $result = Test-CodexBackendMatrix -Text $Text -Backend $Backend -BackendState $BackendState
    if (-not $result.IsMatch) {
        throw ("Backend state is inconsistent with the selected '$Backend' matrix: " + ($result.Mismatches -join '; '))
    }
    return $result
}

function Restore-CodexBackendConfigText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][object]$BackendState
    )

    Assert-CodexBackendState -BackendState $BackendState
    $result = $Text
    foreach ($definition in $script:BackendKeyDefinitions) {
        $prior = Get-BackendPriorRecord -BackendState $BackendState -Path $definition.Path
        $present = [bool](Get-ObjectPropertyValue -Object $prior -Name 'present')
        $value = if ($present) { [string](Get-ObjectPropertyValue -Object $prior -Name 'value') } else { $null }
        $result = Set-BackendKeyText -Text $result -Definition $definition -Present $present -Value $value
    }
    return (Remove-EmptyBackendBlocks -Text $result)
}

function Get-BackendFileHash {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-BackendUtf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Backup-BackendFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $safeName = [regex]::Replace([IO.Path]::GetFullPath($Path), '[^A-Za-z0-9._-]', '_')
    $backupPath = Join-Path $BackupRoot $safeName
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

Export-ModuleMember -Function @(
    'Get-BackendKeyDefinitions',
    'Get-BackendConfigSnapshot',
    'New-CodexBackendState',
    'Assert-CodexBackendState',
    'Get-BackendPriorRecord',
    'Get-BackendTarget',
    'Set-CodexBackendConfigText',
    'Test-CodexBackendMatrix',
    'Assert-CodexBackendMatrix',
    'Restore-CodexBackendConfigText',
    'Get-BackendFileHash',
    'Write-BackendUtf8NoBom',
    'Backup-BackendFile'
)
