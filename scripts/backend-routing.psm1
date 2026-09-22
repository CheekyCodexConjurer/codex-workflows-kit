Set-StrictMode -Version Latest

$script:BackendKeyDefinitions = @(
    [ordered]@{ Path = 'features.multi_agent'; Table = 'features'; Key = 'multi_agent'; NativeValue = 'true'; ValueKind = 'bool' },
    [ordered]@{ Path = 'features.fast_mode'; Table = 'features'; Key = 'fast_mode'; NativeValue = 'false'; ValueKind = 'bool' },
    [ordered]@{ Path = 'agents.default_subagent_model'; Table = 'agents'; Key = 'default_subagent_model'; NativeValue = '"gpt-6-luna"'; ValueKind = 'string' },
    [ordered]@{ Path = 'agents.default_subagent_reasoning_effort'; Table = 'agents'; Key = 'default_subagent_reasoning_effort'; NativeValue = '"max"'; ValueKind = 'string' },
    [ordered]@{ Path = 'mcp_servers.subagents.enabled'; Table = 'mcp_servers.subagents'; Key = 'enabled'; NativeValue = 'false'; ValueKind = 'bool'; AliasPath = 'mcp_servers.deepseek-subagent.enabled'; AliasTable = 'mcp_servers.deepseek-subagent' }
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
        $matchedTable = $null
        $table = if ($tables.ContainsKey($definition.Table)) {
            $matchedTable = $definition.Table
            $tables[$definition.Table]
        }
        elseif ($definition.Contains('AliasTable') -and $tables.ContainsKey($definition.AliasTable)) {
            $matchedTable = $definition.AliasTable
            $tables[$definition.AliasTable]
        }
        else { $null }

        $resolvedTable = if ($null -ne $matchedTable) { $matchedTable } else { $definition.Table }
        $record = [ordered]@{
            path = $definition.Path
            resolvedPath = if ($null -ne $matchedTable -and $definition.Contains('AliasTable') -and $matchedTable -eq $definition.AliasTable) { $definition.AliasPath } else { $definition.Path }
            resolvedTable = $resolvedTable
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
                throw "Backend configuration contains duplicate key '$($definition.Key)' under [$resolvedTable]"
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
        if ($definition.Contains('AliasPath')) {
            $records[$definition.AliasPath] = $record
        }
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

    $alias = $null
    foreach ($definition in $script:BackendKeyDefinitions) {
        if ($definition.Path -ceq $Path -and $definition.Contains('AliasPath')) {
            $alias = $definition.AliasPath
            break
        }
        elseif ($definition.Contains('AliasPath') -and $definition.AliasPath -ceq $Path) {
            $alias = $definition.Path
            break
        }
    }

    foreach ($record in @((Get-ObjectPropertyValue -Object $BackendState -Name 'prior'))) {
        if ($null -ne $record) {
            $p = [string](Get-ObjectPropertyValue -Object $record -Name 'path')
            if ($p -ceq $Path -or ($null -ne $alias -and $p -ceq $alias)) {
                return $record
            }
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
    $aliasToCanonical = @{}
    foreach ($definition in $script:BackendKeyDefinitions) {
        $knownPaths[$definition.Path] = $true
        if ($definition.Contains('AliasPath')) {
            $knownPaths[$definition.AliasPath] = $true
            $aliasToCanonical[$definition.AliasPath] = $definition.Path
        }
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
        $canonicalPath = if ($aliasToCanonical.ContainsKey($path)) { $aliasToCanonical[$path] } else { $path }
        if ($recordsByPath.ContainsKey($canonicalPath)) {
            throw "Backend state contains duplicate prior record: $path"
        }
        $recordsByPath[$canonicalPath] = $record
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
        $targetTableName = if ($record.Contains('resolvedTable')) { [string]$record.resolvedTable } else { $Definition.Table }
        $table = $snapshot.Tables[$targetTableName]
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

function Assert-CodexDelegationState {
    param([Parameter(Mandatory)][object]$DelegationState)

    if (-not (Test-ObjectProperty -Object $DelegationState -Name 'selected')) {
        throw 'Delegation state is missing selected policy.'
    }
    $selected = [string](Get-ObjectPropertyValue -Object $DelegationState -Name 'selected')
    if ($selected -notin @('balanced', 'aggressive', 'swarm')) {
        throw "Delegation state has unsupported selected policy: $selected"
    }
}

function Assert-CodexStrategyState {
    param([Parameter(Mandatory)][object]$StrategyState)

    if (-not (Test-ObjectProperty -Object $StrategyState -Name 'selected')) {
        throw 'Strategy state is missing selected strategy.'
    }
    $selected = [string](Get-ObjectPropertyValue -Object $StrategyState -Name 'selected')
    if ($selected -notin @('worker', 'critical')) {
        throw "Strategy state has unsupported selected strategy: $selected"
    }
}

function Assert-CodexContinuationState {
    param([Parameter(Mandatory)][object]$ContinuationState)

    if (-not (Test-ObjectProperty -Object $ContinuationState -Name 'selected')) {
        throw 'Continuation state is missing selected continuation.'
    }
    $selected = [string](Get-ObjectPropertyValue -Object $ContinuationState -Name 'selected')
    if ($selected -notin @('active_follow', 'park_and_wake')) {
        throw "Continuation state has unsupported selected continuation: $selected"
    }
}

function New-CodexContinuationState {
    param([object]$ExistingInstallState)

    if ($null -ne $ExistingInstallState -and (Test-ObjectProperty -Object $ExistingInstallState -Name 'codexContinuation')) {
        $existingContinuation = Get-ObjectPropertyValue -Object $ExistingInstallState -Name 'codexContinuation'
        Assert-CodexContinuationState -ContinuationState $existingContinuation
        return [ordered]@{
            version = 1
            selected = [string](Get-ObjectPropertyValue -Object $existingContinuation -Name 'selected')
        }
    }

    $state = [ordered]@{
        version = 1
        selected = 'active_follow'
    }
    Assert-CodexContinuationState -ContinuationState $state
    return $state
}

function Get-CodexRuntimeBlockInfo {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalized = $Text -replace '\r\n', "`n"
    $beginMatches = @([regex]::Matches($normalized, '(?m)^# BEGIN CODEX-WORKFLOWS-KIT: runtime\s*(?:#.*)?$'))
    $endMatches = @([regex]::Matches($normalized, '(?m)^# END CODEX-WORKFLOWS-KIT: runtime\s*(?:#.*)?$'))

    if ($beginMatches.Count -eq 0) {
        if ($endMatches.Count -gt 0) {
            throw 'Managed runtime block has an end marker without a begin marker.'
        }
        return [pscustomobject]@{
            Present = $false
            Backend = $null
            Policy = $null
            Strategy = $null
            Continuation = $null
            HasStrategyKey = $false
            HasContinuationKey = $false
            Body = ''
        }
    }

    if ($beginMatches.Count -gt 1 -or $endMatches.Count -gt 1) {
        throw "AGENTS.md contains duplicate managed runtime blocks ($($beginMatches.Count) begin markers, $($endMatches.Count) end markers)."
    }

    if ($beginMatches.Count -ne $endMatches.Count) {
        throw 'Managed runtime block is incomplete.'
    }

    $pattern = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT: runtime\s*\r?\n(?<body>.*?)^# END CODEX-WORKFLOWS-KIT: runtime(?:\r?\n|$)'
    $match = [regex]::Match($normalized, $pattern)
    if (-not $match.Success) {
        throw 'Managed runtime block is malformed or incomplete.'
    }

    $body = $match.Groups['body'].Value
    $backendMatches = @([regex]::Matches($body, '(?m)^\s*subagent_backend\s*=\s*([^\r\n#]+?)\s*(?:#.*)?$'))
    $policyMatches = @([regex]::Matches($body, '(?m)^\s*delegation_policy\s*=\s*([^\r\n#]+?)\s*(?:#.*)?$'))
    $strategyMatches = @([regex]::Matches($body, '(?m)^\s*subagent_strategy\s*=\s*([^\r\n#]+?)\s*(?:#.*)?$'))
    $continuationMatches = @([regex]::Matches($body, '(?m)^\s*subagent_continuation\s*=\s*([^\r\n#]+?)\s*(?:#.*)?$'))

    if ($backendMatches.Count -gt 1) {
        throw "Managed runtime block contains duplicate 'subagent_backend' keys."
    }
    if ($policyMatches.Count -gt 1) {
        throw "Managed runtime block contains duplicate 'delegation_policy' keys."
    }
    if ($strategyMatches.Count -gt 1) {
        throw "Managed runtime block contains duplicate 'subagent_strategy' keys."
    }
    if ($continuationMatches.Count -gt 1) {
        throw "Managed runtime block contains duplicate 'subagent_continuation' keys."
    }
    if ($backendMatches.Count -eq 0) {
        throw "Managed runtime block is missing 'subagent_backend' key."
    }
    $backendVal = $backendMatches[0].Groups[1].Value.Trim()
    $policyVal = if ($policyMatches.Count -eq 1) { $policyMatches[0].Groups[1].Value.Trim() } else { $null }
    $strategyVal = if ($strategyMatches.Count -eq 1) { $strategyMatches[0].Groups[1].Value.Trim() } else { 'worker' }
    $continuationVal = if ($continuationMatches.Count -eq 1) { $continuationMatches[0].Groups[1].Value.Trim() } else { 'active_follow' }

    if ($backendVal -notin @('native', 'deepseek')) {
        throw "Managed runtime block contains unsupported subagent_backend: '$backendVal'"
    }
    if ($null -ne $policyVal -and $policyVal -notin @('balanced', 'aggressive', 'swarm')) {
        throw "Managed runtime block contains unsupported delegation_policy: '$policyVal'"
    }
    if ($strategyVal -notin @('worker', 'critical')) {
        throw "Managed runtime block contains unsupported subagent_strategy: '$strategyVal'"
    }
    if ($continuationVal -notin @('active_follow', 'park_and_wake')) {
        throw "Managed runtime block contains unsupported subagent_continuation: '$continuationVal'"
    }

    return [pscustomobject]@{
        Present = $true
        Backend = $backendVal
        Policy = $policyVal
        Strategy = $strategyVal
        Continuation = $continuationVal
        HasStrategyKey = ($strategyMatches.Count -eq 1)
        HasContinuationKey = ($continuationMatches.Count -eq 1)
        Body = $body
    }
}

function Format-CodexRuntimeBlock {
    param(
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter()][ValidateSet('active_follow', 'park_and_wake')][string]$Continuation = 'active_follow'
    )

    $nl = [Environment]::NewLine
    return '# BEGIN CODEX-WORKFLOWS-KIT: runtime' + $nl +
        'subagent_backend = ' + $Backend + $nl +
        'subagent_continuation = ' + $Continuation + $nl +
        '# END CODEX-WORKFLOWS-KIT: runtime'
}

function Set-CodexAgentsManagedBlockText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingAgentsText,
        [Parameter(Mandatory)][string]$TemplateText,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter()][ValidateSet('active_follow', 'park_and_wake')][string]$Continuation = 'active_follow'
    )

    $nl = [Environment]::NewLine
    $runtimeBlock = Format-CodexRuntimeBlock -Backend $Backend -Continuation $Continuation
    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $end = '# END CODEX-WORKFLOWS-KIT'
    $normalizedTemplate = ($TemplateText.Trim() -replace "`r?`n", $nl)
    $managed = $begin + $nl + $runtimeBlock + $nl + $nl + $normalizedTemplate + $nl + $end + $nl

    $blockRegex = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT\s*\r?\n.*?^# END CODEX-WORKFLOWS-KIT\s*(?:\r?\n|$)'
    $match = [regex]::Match($ExistingAgentsText, $blockRegex)
    if ($match.Success) {
        $head = $ExistingAgentsText.Substring(0, $match.Index)
        $tail = $ExistingAgentsText.Substring($match.Index + $match.Length).TrimStart([char[]]@([char]13, [char]10))
        return ($head + $managed + $tail)
    }
    elseif ($ExistingAgentsText.IndexOf($begin, [StringComparison]::Ordinal) -ge 0) {
        throw "Managed AGENTS.md block is incomplete."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExistingAgentsText)) {
        return ($managed + $ExistingAgentsText.TrimStart([char[]]@([char]13, [char]10)))
    }
    else {
        return $managed
    }
}

function Get-GeminiManagedBlockInfo {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $beginMarker = '# BEGIN CODEX-WORKFLOWS-KIT'
    $endMarker = '# END CODEX-WORKFLOWS-KIT'

    $beginIdx = $Content.IndexOf($beginMarker, [StringComparison]::Ordinal)
    $endIdx = if ($beginIdx -ge 0) { $Content.IndexOf($endMarker, $beginIdx, [StringComparison]::Ordinal) } else { -1 }

    $hasValidMarkers = ($beginIdx -ge 0 -and $endIdx -ge 0 -and $endIdx -ge ($beginIdx + $beginMarker.Length))

    $head = ''
    $managed = ''
    $tail = ''

    if ($hasValidMarkers) {
        $head = $Content.Substring(0, $beginIdx)
        $managed = $Content.Substring($beginIdx, ($endIdx + $endMarker.Length) - $beginIdx)
        $tail = $Content.Substring($endIdx + $endMarker.Length)
    }

    return [pscustomobject]@{
        HasValidMarkers = $hasValidMarkers
        BeginIndex      = $beginIdx
        EndIndex        = $endIdx
        Head            = $head
        Managed         = $managed
        Tail            = $tail
    }
}

function Get-GeminiLegacyConflicts {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $conflicts = New-Object System.Collections.Generic.List[string]

    if ($Text -match '(?m)^\s*-\s*Read-only subagents default to 5\.6 Sol Medium' -or
        $Text -match '(?m)^\s*-\s*Every read-only spawn must select the exact custom role' -or
        $Text -match '(?m)^\s*-\s*Custom-role spawns must omit' -or
        $Text -match '(?m)^\s*-\s*On a transient launch, stream, or account-availability error, continue useful local work and make one fresh retry with the same explicit role') {
        $conflicts.Add('native subagent models/roles (5.6 Sol Medium, custom role restrictions)')
    }

    if ($Text -match '(?m)^\s*-\s*In delivery, scouts and implementation workers may start early, but independent reviewers start only after all approved phases are integrated and frozen' -or
        $Text -match '(?m)^\s*-\s*Deduplicate findings into one fix batch.*do not spawn reviewers per phase') {
        $conflicts.Add('delivery review veto (prohibits intermediate phase reviews)')
    }

    if ($Text -match '(?m)^\s*-\s*Allowlisted baseline:.*openaiDeveloperDocs' -or
        $Text -match '(?m)^\s*-\s*If an allowlisted MCP is missing,\s*run.*?maintain-mcps\.ps1\s+-Mode\s+Repair') {
        $conflicts.Add('maintain-mcps repair / divergent allowlist (openaiDeveloperDocs, maintain-mcps.ps1 -Mode Repair)')
    }

    return @($conflicts)
}

function Remove-GeminiLegacyConflicts {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $patterns = @(
        # Conflict 1: Native models / custom roles
        '(?m)^\s*-\s*Read-only subagents default to 5\.6 Sol Medium.*?(?:\r?\n|$)',
        '(?m)^\s*-\s*Every read-only spawn must select the exact custom role.*?(?:\r?\n|$)',
        '(?m)^\s*-\s*Custom-role spawns must omit.*?(?:\r?\n|$)',
        '(?m)^\s*-\s*On a transient launch, stream, or account-availability error, continue useful local work and make one fresh retry with the same explicit role.*?(?:\r?\n|$)',

        # Conflict 2: Intermediate review veto
        '(?m)^\s*-\s*In delivery, scouts and implementation workers may start early, but independent reviewers start only after all approved phases are integrated and frozen.*?(?:\r?\n|$)',
        '(?m)^\s*-\s*Deduplicate findings into one fix batch, then revalidate and run one delta-focused closure review; do not spawn reviewers per phase.*?(?:\r?\n|$)',

        # Conflict 3: maintain-mcps repair & divergent allowlist
        '(?m)^\s*-\s*Allowlisted baseline:\s*`?codegraph`?,\s*`?context7`?,\s*and\s*`?openaiDeveloperDocs`?.*?(?:\r?\n|$)',
        '(?m)^\s*-\s*If an allowlisted MCP is missing,\s*run.*?maintain-mcps\.ps1\s+-Mode\s+Repair.*?(?:\r?\n|$)'
    )

    $cleaned = $Text
    foreach ($pat in $patterns) {
        $cleaned = [regex]::Replace($cleaned, $pat, '')
    }

    return $cleaned
}

function Assert-CodexAgentsRuntimeBlock {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter()][ValidateSet('active_follow', 'park_and_wake')][string]$Continuation = 'active_follow'
    )

    $info = Get-CodexRuntimeBlockInfo -Text $Text
    if (-not $info.Present) {
        throw 'Installed AGENTS.md is missing the managed runtime block (# BEGIN CODEX-WORKFLOWS-KIT: runtime).'
    }
    if ($info.Backend -cne $Backend) {
        throw "Installed AGENTS.md runtime block has subagent_backend='$($info.Backend)', expected '$Backend'."
    }
    if ($info.Body -match '(?m)^\s*(?:delegation_policy|subagent_strategy)\s*=' -or
        $null -ne $info.Policy -or $info.HasStrategyKey) {
        throw 'Installed AGENTS.md contains retired orchestration selectors; migrate the managed block before use.'
    }
    if ($info.Continuation -cne $Continuation) {
        throw "Installed AGENTS.md runtime block has subagent_continuation='$($info.Continuation)', expected '$Continuation'."
    }
}

function Get-CodexDeliveryTargetIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$OwnedPaths,
        [string]$Baseline = ''
    )

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    if (-not (Test-Path -LiteralPath $fullRepoPath -PathType Container)) {
        throw "Repository path does not exist: $fullRepoPath"
    }

    # 1. Resolve and validate the baseline as an exact commit. Without this
    # check, an invalid ref makes every cat-file lookup fail and can silently
    # misclassify all owned files as newly added.
    $baselineRef = if ([string]::IsNullOrWhiteSpace($Baseline)) { 'HEAD' } else { $Baseline.Trim() }
    $commitRef = $baselineRef + '^{commit}'
    $revParse = & git -C $fullRepoPath rev-parse --verify $commitRef 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid delivery baseline '$baselineRef' for repository '$fullRepoPath'."
    }
    $baselineSha = (($revParse | ForEach-Object { $_.ToString().Trim() }) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($baselineSha)) {
        throw "Git returned an empty commit identity for delivery baseline '$baselineRef'."
    }

    # 2. Normalize and sort owned paths
    $normalizedOwnedPaths = New-Object System.Collections.Generic.List[string]
    $repoPrefix = $fullRepoPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($p in $OwnedPaths) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $rawPath = $p.Trim()
            if ([IO.Path]::IsPathRooted($rawPath)) {
                throw "Owned delivery path must be repository-relative: '$rawPath'."
            }

            $norm = $rawPath.Replace('\', '/') -replace '^\./', ''
            $segments = @($norm -split '/')
            if ([string]::IsNullOrWhiteSpace($norm) -or $norm.Contains(':') -or $segments -contains '.' -or $segments -contains '..') {
                throw "Owned delivery path is not canonical and repository-contained: '$rawPath'."
            }

            $candidatePath = [IO.Path]::GetFullPath([IO.Path]::Combine($fullRepoPath, ($norm -replace '/', [IO.Path]::DirectorySeparatorChar)))
            if (-not $candidatePath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Owned delivery path escapes the repository: '$rawPath'."
            }

            if (-not $normalizedOwnedPaths.Contains($norm)) {
                $normalizedOwnedPaths.Add($norm)
            }
        }
    }
    $sortedPaths = @($normalizedOwnedPaths.ToArray())
    [Array]::Sort($sortedPaths, [System.StringComparer]::Ordinal)

    # 3. Compute per-file hashes and HEAD-relative content status
    $headStatus = [ordered]@{}
    $fileSha256 = [ordered]@{}
    $diffChunks = New-Object System.Collections.Generic.List[string]

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

    foreach ($relPath in $sortedPaths) {
        $diskPath = [IO.Path]::Combine($fullRepoPath, ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar))
        $existsOnDisk = Test-Path -LiteralPath $diskPath -PathType Leaf

        # Check if file exists in HEAD commit
        $treeRef = $baselineSha + ":" + $relPath
        $null = & git -C $fullRepoPath cat-file -e $treeRef 2>&1
        $existsInHead = ($LASTEXITCODE -eq 0)

        if ($existsOnDisk) {
            $fileBytes = [IO.File]::ReadAllBytes($diskPath)
            $hashBytes = $sha256.ComputeHash($fileBytes)
            $hexHash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
            $fileSha256[$relPath] = $hexHash

            if ($existsInHead) {
                # Only patch stdout belongs to the deterministic digest. Git may
                # emit environment-dependent EOL diagnostics on stderr before
                # staging and stop emitting them after git add. Windows
                # PowerShell otherwise decodes the same UTF-8 patch through the
                # active console code page, so CP850 and UTF-8 would produce
                # different target identities for non-ASCII content.
                $originalConsoleOutputEncoding = [Console]::OutputEncoding
                try {
                    [Console]::OutputEncoding = $utf8NoBom
                    $headDiff = & git -C $fullRepoPath diff $baselineSha -- $relPath 2>$null
                    $headDiffExitCode = $LASTEXITCODE
                }
                finally {
                    [Console]::OutputEncoding = $originalConsoleOutputEncoding
                }
                if ($headDiffExitCode -ne 0) {
                    throw "Failed to compute HEAD-relative diff for owned path '$relPath'."
                }
                $headDiffText = ($headDiff | ForEach-Object { $_.ToString() }) -join "`n"
                if (-not [string]::IsNullOrWhiteSpace($headDiffText)) {
                    $headStatus[$relPath] = 'M'
                    $diffChunks.Add(("--- HEAD:" + $relPath + "`n+++ worktree:" + $relPath + "`n" + $headDiffText))
                }
                else {
                    $headStatus[$relPath] = 'unchanged'
                }
            }
            else {
                $headStatus[$relPath] = 'A'
                $diffChunks.Add(("+++ new_file:" + $relPath + " sha256:" + $hexHash))
            }
        }
        else {
            if ($existsInHead) {
                $headStatus[$relPath] = 'D'
                $diffChunks.Add(("--- deleted_file:" + $relPath + " in HEAD:" + $baselineSha))
            }
            else {
                $headStatus[$relPath] = 'absent'
            }
        }
    }

    # 4. Integrated diff SHA256
    $integratedDiffText = ($diffChunks.ToArray()) -join "`n"
    $diffBytes = $utf8NoBom.GetBytes($integratedDiffText)
    $diffHashBytes = $sha256.ComputeHash($diffBytes)
    $diffSha256 = ([System.BitConverter]::ToString($diffHashBytes)).Replace('-', '').ToLowerInvariant()

    # 5. Composite target identity payload (canonical ordered JSON)
    $identityPayload = [ordered]@{
        baseline = $baselineSha
        head_status = $headStatus
        diff_sha256 = $diffSha256
        file_sha256 = $fileSha256
    }
    $canonicalJson = ConvertTo-Json $identityPayload -Depth 10 -Compress
    $payloadBytes = $utf8NoBom.GetBytes($canonicalJson)
    $targetIdBytes = $sha256.ComputeHash($payloadBytes)
    $targetId = ([System.BitConverter]::ToString($targetIdBytes)).Replace('-', '').ToLowerInvariant()

    # Observational evidence: raw porcelain (outside target_id digest)
    $rawPorcelainOutput = & git -C $fullRepoPath status --porcelain 2>&1
    $rawPorcelain = ($rawPorcelainOutput | ForEach-Object { $_.ToString() }) -join "`n"

    return [pscustomobject]@{
        TargetId = $targetId
        Baseline = $baselineSha
        HeadStatus = $headStatus
        DiffSha256 = $diffSha256
        FileSha256 = $fileSha256
        PayloadJson = $canonicalJson
        RawPorcelain = $rawPorcelain
    }
}

function Get-CodexCommitCandidateClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Path
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $null
        }
        $rawPath = $Path.Trim()
        $norm = $rawPath.Replace('\', '/') -replace '^\./', '' -replace '^/', ''

        $category = 'clean'
        $suggestedRule = $null

        # 1. Secrets (never commit credentials, private keys, or environment files)
        # Keep the explicit example file available as documentation; every other
        # .env variant is treated as a secret candidate.
        if (($norm -match '(?i)(?:^|/)\.env(?:\.[^/]+)?$' -and
             $norm -notmatch '(?i)(?:^|/)\.env\.example$') -or
            $norm -match '(?i)\.(?:pem|key|pfx|p12)$' -or
            $norm -match '(?i)(?:^|/)id_(?:rsa|dsa|ecdsa|ed25519)(?:\.pub)?$' -or
            $norm -match '(?i)(?:^|/)(?:credentials|secrets)\.json$') {
            $category = 'secret'
            $suggestedRule = if ($norm -match '(?i)(?:^|/)\.env(?:\.[^/]+)?$') { '.env* (except .env.example)' } else { Split-Path -Leaf $norm }
        }
        # 2. Local environment & configuration overrides
        elseif ($norm -match '(?i)(?:^|/)\.serena/project\.local\.[^/]+$' -or
                $norm -match '(?i)(?:^|/)(?:config|settings)\.local$' -or
                $norm -match '(?i)(?:^|/)[^/]+\.local\.(?:json|ya?ml|toml|ini|conf|config|env|properties)$' -or
                $norm -match '(?i)(?:^|/)\.scratchpad(?:/|$)' -or
                $norm -match '(?i)(?:^|/)\.local(?:/|$)' -or
                $norm -match '(?i)(?:^|/)config/local(?:/|$)') {
            $category = 'local'
            if ($norm -match '(?i)\.serena/project\.local\.') {
                $suggestedRule = '.serena/project.local.*'
            }
            elseif ($norm -match '(?i)\.local\.(?:json|ya?ml|toml|ini|conf|config|env|properties)$' -or
                    $norm -match '(?i)(?:^|/)(?:config|settings)\.local$') {
                $suggestedRule = Split-Path -Leaf $norm
            }
            elseif ($norm -match '(?i)\.scratchpad') {
                $suggestedRule = '.scratchpad/'
            }
            else {
                $suggestedRule = Split-Path -Leaf $norm
            }
        }
        # 3. Cache directories & bytecode
        elseif ($norm -match '(?i)(?:^|/)\.serena/cache(?:/|$)' -or
                $norm -match '(?i)(?:^|/)__pycache__(?:/|$)' -or
                $norm -match '(?i)\.(?:py[cod]|cache)$' -or
                $norm -match '(?i)(?:^|/)\.cache(?:/|$)') {
            $category = 'cache'
            if ($norm -match '(?i)\.serena/cache') {
                $suggestedRule = '.serena/cache/'
            }
            elseif ($norm -match '(?i)__pycache__|\.py[cod]') {
                $suggestedRule = '__pycache__/'
            }
            else {
                $suggestedRule = '.cache/'
            }
        }
        # 4. Generated artifacts, temporary files, runtime databases, OS metadata
        # Notice: *.db is NOT globally matched here; only specific filenames like Thumbs.db
        elseif ($norm -match '(?i)\.(?:bak|tmp|log)$' -or
                $norm -match '(?i)(?:^|/)\.codegraph(?:/|$)' -or
                $norm -match '(?i)(?:^|/)\.serena/(?:memories|logs)(?:/|$)' -or
                $norm -match '(?i)(?:^|/)Thumbs\.db$' -or
                $norm -match '(?i)(?:^|/)\.DS_Store$') {
            $category = 'generated'
            if ($norm -match '(?i)\.codegraph') {
                $suggestedRule = '.codegraph/'
            }
            elseif ($norm -match '(?i)\.serena/memories') {
                $suggestedRule = '.serena/memories/'
            }
            elseif ($norm -match '(?i)\.serena/logs') {
                $suggestedRule = '.serena/logs/'
            }
            elseif ($norm -match '(?i)\.bak$') {
                $suggestedRule = '*.bak'
            }
            elseif ($norm -match '(?i)\.tmp$') {
                $suggestedRule = '*.tmp'
            }
            elseif ($norm -match '(?i)\.log$') {
                $suggestedRule = '*.log'
            }
            elseif ($norm -match '(?i)Thumbs\.db$') {
                $suggestedRule = 'Thumbs.db'
            }
            elseif ($norm -match '(?i)\.DS_Store$') {
                $suggestedRule = '.DS_Store'
            }
            else {
                $suggestedRule = Split-Path -Leaf $norm
            }
        }

        return [pscustomobject]@{
            Path = $norm
            Category = $category
            IsBlocked = ($category -ne 'clean')
            SuggestedRule = $suggestedRule
        }
    }
}

function Get-CodexCommitCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)
    if (-not (Test-Path -LiteralPath $fullRepoPath -PathType Container)) {
        throw "Repository path does not exist: $fullRepoPath"
    }

    $statusOutput = @(& git -C $fullRepoPath -c core.quotePath=false status --porcelain=v1 -uall 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $detail = ($statusOutput | ForEach-Object { $_.ToString() }) -join "`n"
        throw "Unable to enumerate Git commit candidates: $detail"
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($rawLine in $statusOutput) {
        $line = $rawLine.ToString()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.Length -lt 4) {
            throw "Unexpected Git porcelain line while enumerating commit candidates: $line"
        }

        $indexStatus = $line.Substring(0, 1)
        $worktreeStatus = $line.Substring(1, 1)
        $pathText = $line.Substring(3)
        $pathParts = @($pathText)
        if ($pathText -match '\s+->\s+') {
            $pathParts = @($pathText -split '\s+->\s+', 2)
        }

        foreach ($pathPart in $pathParts) {
            $candidatePath = $pathPart.Trim()
            if ($candidatePath.StartsWith('"') -and $candidatePath.EndsWith('"') -and $candidatePath.Length -ge 2) {
                $candidatePath = $candidatePath.Substring(1, $candidatePath.Length - 2)
            }
            if ([string]::IsNullOrWhiteSpace($candidatePath)) {
                continue
            }
            $classification = Get-CodexCommitCandidateClassification -Path $candidatePath
            $changeKind = if ($indexStatus -eq '?' -and $worktreeStatus -eq '?') {
                'untracked'
            }
            elseif ($indexStatus -ne ' ' -and $worktreeStatus -ne ' ') {
                'staged-and-unstaged'
            }
            elseif ($indexStatus -ne ' ') {
                'staged'
            }
            else {
                'unstaged'
            }

            $candidates.Add([pscustomobject]@{
                Path = $classification.Path
                Status = "$indexStatus$worktreeStatus"
                IndexStatus = $indexStatus
                WorktreeStatus = $worktreeStatus
                ChangeKind = $changeKind
                Category = $classification.Category
                IsBlocked = $classification.IsBlocked
                SuggestedRule = $classification.SuggestedRule
            })
        }
    }

    return @($candidates.ToArray())
}

function Get-CodexCodeGraphMaintenanceDecision {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Status,
        [switch]$WriteMode
    )

    $state = ''
    if ($null -ne $Status) {
        foreach ($propertyName in @('state', 'status', 'indexState', 'index_status')) {
            $property = $Status.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $state = ([string]$property.Value).Trim().ToLowerInvariant()
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($state)) {
        $state = 'unknown'
    }

    if (-not $WriteMode) {
        return [pscustomobject]@{
            State = $state
            Action = 'inspect'
            Reason = 'Read-only mode never synchronizes or mutates a CodeGraph index.'
        }
    }

    switch -Regex ($state) {
        '^(fresh|ready|current|up-to-date)$' {
            return [pscustomobject]@{
                State = $state
                Action = 'none'
                Reason = 'CodeGraph index is current; no sync is needed.'
            }
        }
        '^(stale|outdated|pending|dirty)$' {
            return [pscustomobject]@{
                State = $state
                Action = 'sync'
                Reason = 'CodeGraph index is stale or pending; run one bounded incremental sync, then recheck.'
            }
        }
        default {
            return [pscustomobject]@{
                State = $state
                Action = 'fallback'
                Reason = 'CodeGraph status is failed or unknown; do not initialize/reindex/restart, and use Serena/rg with an explicit warning.'
            }
        }
    }
}

function Get-CodexMcpMaintenanceDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Context7', 'CodeGraph', 'Serena', 'CBM')][string]$Mcp,
        [AllowNull()][object]$Status,
        [Parameter(Mandatory)][ValidateSet('ALINHAMENTO', 'PLAN.AUTO', 'PLAN', 'P.DEEP', 'RESEARCH.DEEP', 'IMPL.AUTO', 'IMPL', 'IMPL.PHASE', 'DELIVER.AUTO', 'REVIEW', 'COMMIT', 'BUG.INV', 'BUG.FIX', 'DEBUG', 'REWORK', 'R.A.F.V', 'TN.SKILL', 'CONSULT')][string]$Mode
    )

    $writeModes = @('IMPL.AUTO', 'IMPL', 'IMPL.PHASE', 'DELIVER.AUTO', 'BUG.FIX', 'DEBUG', 'R.A.F.V')
    $writeMode = $writeModes -contains $Mode
    $state = ''
    if ($null -ne $Status) {
        foreach ($propertyName in @('state', 'status', 'indexState', 'index_status')) {
            $propertyValue = $null
            if ($Status -is [System.Collections.IDictionary]) {
                if ($Status.Contains($propertyName)) {
                    $propertyValue = $Status[$propertyName]
                }
            }
            else {
                $property = $Status.PSObject.Properties[$propertyName]
                if ($null -ne $property) {
                    $propertyValue = $property.Value
                }
            }
            if ($null -ne $propertyValue -and -not [string]::IsNullOrWhiteSpace([string]$propertyValue)) {
                $state = ([string]$propertyValue).Trim().ToLowerInvariant()
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($state)) {
        $state = 'unknown'
    }

    $result = [ordered]@{
        Mcp = $Mcp
        Mode = $Mode
        State = $state
        Action = 'inspect'
        Mutates = $false
        RequiresRecheck = $false
        Reason = ''
    }

    switch ($Mcp) {
        'CodeGraph' {
            switch -Regex ($state) {
                '^(fresh|ready|current|up-to-date|available|configured)$' {
                    $result.Action = 'none'
                    $result.Reason = 'CodeGraph is ready; use codegraph_explore directly without background maintenance.'
                }
                '^(stale|outdated|pending|dirty)$' {
                    if ($writeMode) {
                        $result.Action = 'sync'
                        $result.Mutates = $true
                        $result.RequiresRecheck = $true
                        $result.Reason = 'CodeGraph is stale or pending; run one bounded sync and recheck before structural use.'
                    }
                    else {
                        $result.Reason = 'Read-only mode may inspect a stale CodeGraph but never synchronizes it.'
                    }
                }
                '^(missing|absent|not.?initialized|uninitialized)$' {
                    $result.Action = 'manual_init'
                    $result.Reason = 'CodeGraph initialization remains an explicit operator action; use Serena or rg until an index exists.'
                }
                default {
                    $result.Action = 'fallback'
                    $result.Reason = 'CodeGraph status is failed or unknown; fall back to Serena or rg with an explicit warning.'
                }
            }
        }
        'Serena' {
            switch -Regex ($state) {
                '^(fresh|ready|current|up-to-date|available|configured|active)$' {
                    $result.Action = 'none'
                    $result.Reason = 'Serena project and configuration are ready for --project-from-cwd use.'
                }
                '^(missing|absent|not.?initialized|uninitialized)$' {
                    if ($writeMode) {
                        $result.Action = 'activate'
                        $result.Mutates = $true
                        $result.RequiresRecheck = $true
                        $result.Reason = 'Serena is not active for this repository; activate the project from the current working directory and recheck.'
                    }
                    else {
                        $result.Reason = 'Read-only mode verifies Serena configuration but does not onboard or activate a missing project.'
                    }
                }
                default {
                    $result.Action = 'fallback'
                    $result.Reason = 'Serena status is failed or unknown; use targeted rg and report the unavailable semantic route.'
                }
            }
        }
        'CBM' {
            switch -Regex ($state) {
                '^(fresh|ready|current|up-to-date|available|configured|active)$' {
                    $result.Action = 'none'
                    $result.Reason = 'CBM index is ready; verify load-bearing findings against original source and freshness.'
                }
                '^(stale|outdated|pending|dirty)$' {
                    if ($writeMode) {
                        $result.Action = 'refresh'
                        $result.Mutates = $true
                        $result.RequiresRecheck = $true
                        $result.Reason = 'CBM is stale or pending; acquire the canonical-root owner lock, refresh once, and recheck.'
                    }
                    else {
                        $result.Reason = 'Read-only mode may inspect CBM status but never refreshes or creates an index.'
                    }
                }
                '^(missing|absent|not.?initialized|uninitialized)$' {
                    if ($writeMode) {
                        $result.Action = 'initialize'
                        $result.Mutates = $true
                        $result.RequiresRecheck = $true
                        $result.Reason = 'CBM is absent; verify exclusions and the canonical-root owner lock, initialize once, and recheck.'
                    }
                    else {
                        $result.Reason = 'Read-only mode reports the missing CBM index and falls back to source or rg.'
                    }
                }
                default {
                    $result.Action = 'fallback'
                    $result.Reason = 'CBM status is failed or unknown; do not start an unprepared store and use source or rg.'
                }
            }
        }
        'Context7' {
            switch -Regex ($state) {
                '^(fresh|ready|current|up-to-date|available|configured|active)$' {
                    $result.Action = 'use'
                    $result.Reason = 'Context7 is available; resolve then query only for a triggered, current documentation need.'
                }
                default {
                    $result.Action = 'blocked'
                    $result.Reason = 'Context7 is unavailable; do not install or authenticate automatically; use approved official documentation and disclose the limitation.'
                }
            }
        }
    }

    return [pscustomobject]$result
}

function Test-CodexCommitGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ApprovedTargetId,
        [Parameter(Mandatory)][string[]]$ApprovedOwnedPaths,
        [string]$Baseline = ''
    )

    $fullRepoPath = [IO.Path]::GetFullPath($RepoPath)

    # 0. Enumerate every staged, unstaged, and untracked candidate before the
    # target/index checks. This is observational and never edits the Git index.
    $allCandidates = @(Get-CodexCommitCandidates -RepoPath $fullRepoPath)
    foreach ($candidate in $allCandidates) {
        if ($candidate.IsBlocked) {
            return [pscustomobject]@{
                Pass = $false
                Detail = "Commit candidate blocked: '$($candidate.Path)' ($($candidate.ChangeKind)) is classified as $($candidate.Category) (suggested rule: '$($candidate.SuggestedRule)')."
                RecomputedTarget = $null
            }
        }
    }

    # 0.1 Candidate classifier check on approved owned paths (kept explicit for
    # callers whose approved set is not present in porcelain output).
    foreach ($p in $ApprovedOwnedPaths) {
        $candidateClassification = Get-CodexCommitCandidateClassification -Path $p
        if ($null -ne $candidateClassification -and $candidateClassification.IsBlocked) {
            return [pscustomobject]@{
                Pass = $false
                Detail = "Commit candidate blocked: approved path '$p' is classified as $($candidateClassification.Category) (suggested rule: '$($candidateClassification.SuggestedRule)')."
                RecomputedTarget = $null
            }
        }
    }

    # 1. Recompute staging-invariant delivery target identity
    $recomputed = Get-CodexDeliveryTargetIdentity -RepoPath $fullRepoPath -OwnedPaths $ApprovedOwnedPaths -Baseline $Baseline

    if ($recomputed.TargetId -cne $ApprovedTargetId) {
        return [pscustomobject]@{
            Pass = $false
            Detail = "Delivery target_id mismatch: approved='$ApprovedTargetId', recomputed='$($recomputed.TargetId)'."
            RecomputedTarget = $recomputed
        }
    }

    # 2. Verify staged path set
    $stagedOutput = & git -C $fullRepoPath diff --name-only --cached 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Pass = $false
            Detail = "Failed to inspect git index: $stagedOutput"
            RecomputedTarget = $recomputed
        }
    }

    $actualStagedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $stagedOutput) {
        $trimmed = $line.ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $norm = $trimmed.Replace('\', '/') -replace '^\./', '' -replace '^/', ''
            if (-not $actualStagedPaths.Contains($norm)) {
                $actualStagedPaths.Add($norm)
            }
        }
    }
    $sortedActualStaged = @($actualStagedPaths.ToArray())
    [Array]::Sort($sortedActualStaged, [System.StringComparer]::Ordinal)

    $approvedNormalized = New-Object System.Collections.Generic.List[string]
    foreach ($p in $ApprovedOwnedPaths) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $norm = $p.Trim().Replace('\', '/') -replace '^\./', '' -replace '^/', ''
            if (-not $approvedNormalized.Contains($norm)) {
                $approvedNormalized.Add($norm)
            }
        }
    }
    $sortedApproved = @($approvedNormalized.ToArray())
    [Array]::Sort($sortedApproved, [System.StringComparer]::Ordinal)

    $actualJoined = $sortedActualStaged -join ';'
    $approvedJoined = $sortedApproved -join ';'

    if ($actualJoined -cne $approvedJoined) {
        return [pscustomobject]@{
            Pass = $false
            Detail = "Staged path set mismatch: expected approved set '[$approvedJoined]', but actual staged set is '[$actualJoined]'."
            RecomputedTarget = $recomputed
        }
    }

    # 3. Verify that the index contains the exact approved worktree content.
    # Path equality alone is insufficient: an unreviewed blob could be staged and
    # the working tree restored to the approved content before this gate runs.
    foreach ($relPath in $sortedApproved) {
        $diskPath = [IO.Path]::Combine($fullRepoPath, ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar))
        $existsOnDisk = Test-Path -LiteralPath $diskPath -PathType Leaf

        $indexRef = ':' + $relPath
        $indexBlobOutput = & git -C $fullRepoPath rev-parse --verify $indexRef 2>$null
        $indexBlobExists = ($LASTEXITCODE -eq 0)
        $indexBlob = (($indexBlobOutput | ForEach-Object { $_.ToString().Trim() }) -join '').Trim()

        if (-not $existsOnDisk) {
            if ($indexBlobExists) {
                return [pscustomobject]@{
                    Pass = $false
                    Detail = "Staged index content mismatch for deleted path '$relPath': the approved working tree is absent but an index blob remains."
                    RecomputedTarget = $recomputed
                }
            }
            continue
        }

        if (-not $indexBlobExists -or [string]::IsNullOrWhiteSpace($indexBlob)) {
            return [pscustomobject]@{
                Pass = $false
                Detail = "Staged index content mismatch for '$relPath': no staged blob exists."
                RecomputedTarget = $recomputed
            }
        }

        # hash-object applies the repository's clean filters and EOL rules, so
        # the would-be worktree blob is comparable with the staged index blob.
        $worktreeBlobOutput = & git -C $fullRepoPath hash-object --path=$relPath $diskPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{
                Pass = $false
                Detail = "Failed to compute Git-normalized worktree blob for '$relPath'."
                RecomputedTarget = $recomputed
            }
        }
        $worktreeBlob = (($worktreeBlobOutput | ForEach-Object { $_.ToString().Trim() }) -join '').Trim()

        if ($indexBlob -cne $worktreeBlob) {
            return [pscustomobject]@{
                Pass = $false
                Detail = "Staged index blob content differs from the approved working tree for '$relPath'."
                RecomputedTarget = $recomputed
            }
        }
    }

    return [pscustomobject]@{
        Pass = $true
        Detail = "Commit gate passed: staging-invariant target_id matched '$ApprovedTargetId', staged paths matched the approved set, and every staged blob matched approved content."
        RecomputedTarget = $recomputed
    }
}

function Test-CodexBatchCapabilityGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter(Mandatory)][bool]$ParallelRequested,
        [string[]]$Capabilities = @(),
        [int]$ExposedCapacity = -1,
        [string[]]$CallableTools = @(),
        [object]$AuthoritativeBridgeProbe = $null
    )

    if (-not $ParallelRequested) {
        return [pscustomobject]@{ Pass = $true; Detail = 'Single-front dispatch needs no batch scheduler.'; RequiredCapability = $null }
    }
    if ($Backend -eq 'native') {
        if ($ExposedCapacity -lt 2) {
            return [pscustomobject]@{ Pass = $false; Detail = 'Native parallel capacity is absent or unverified.'; RequiredCapability = 'native_capacity' }
        }
        return [pscustomobject]@{ Pass = $true; Detail = 'Native parallel capacity observed.'; RequiredCapability = 'native_capacity' }
    }
    if ($CallableTools -notcontains 'subagents_spawn_batch' -and $CallableTools -notcontains 'deepseek_spawn_batch') {
        return [pscustomobject]@{ Pass = $false; Detail = 'Parallel MCP dispatch requires a callable batch tool.'; RequiredCapability = 'subagents_spawn_batch' }
    }
    if ($null -eq $AuthoritativeBridgeProbe) {
        return [pscustomobject]@{ Pass = $false; Detail = 'Authoritative bridge status is required for parallel dispatch.'; RequiredCapability = 'batch_scheduler' }
    }
    $status = if ($AuthoritativeBridgeProbe -is [System.Collections.IDictionary]) { [string]$AuthoritativeBridgeProbe['status'] } else { [string]$AuthoritativeBridgeProbe.status }
    $probeCaps = if ($AuthoritativeBridgeProbe -is [System.Collections.IDictionary]) { @($AuthoritativeBridgeProbe['capabilities']) } else { @($AuthoritativeBridgeProbe.capabilities) }
    if ($status -notin @('ok','healthy','ready') -or $probeCaps -notcontains 'batch_scheduler' -or $Capabilities -notcontains 'batch_scheduler') {
        return [pscustomobject]@{ Pass = $false; Detail = 'Bridge status or batch_scheduler capability is absent or inconsistent.'; RequiredCapability = 'batch_scheduler' }
    }
    return [pscustomobject]@{ Pass = $true; Detail = 'MCP batch tool and authoritative scheduler capability observed.'; RequiredCapability = 'batch_scheduler' }
}

function Assert-CodexBatchCapabilityGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter(Mandatory)][bool]$ParallelRequested,
        [string[]]$Capabilities = @(),
        [int]$ExposedCapacity = -1,
        [string[]]$CallableTools = @(),
        [object]$AuthoritativeBridgeProbe = $null
    )
    $result = Test-CodexBatchCapabilityGate -Backend $Backend -ParallelRequested $ParallelRequested -Capabilities $Capabilities -ExposedCapacity $ExposedCapacity -CallableTools $CallableTools -AuthoritativeBridgeProbe $AuthoritativeBridgeProbe
    if (-not $result.Pass) { throw $result.Detail }
    return $result
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
    'Backup-BackendFile',
    'Assert-CodexDelegationState',
    'Assert-CodexStrategyState',
    'Assert-CodexContinuationState',
    'New-CodexContinuationState',
    'Get-CodexRuntimeBlockInfo',
    'Format-CodexRuntimeBlock',
    'Set-CodexAgentsManagedBlockText',
    'Assert-CodexAgentsRuntimeBlock',
    'Get-CodexDeliveryTargetIdentity',
    'Test-CodexCommitGate',
    'Get-CodexCommitCandidateClassification',
    'Get-CodexCommitCandidates',
    'Get-CodexCodeGraphMaintenanceDecision',
    'Get-CodexMcpMaintenanceDecision',
    'Test-CodexBatchCapabilityGate',
    'Assert-CodexBatchCapabilityGate',
    'Get-GeminiManagedBlockInfo',
    'Get-GeminiLegacyConflicts',
    'Remove-GeminiLegacyConflicts'
)
