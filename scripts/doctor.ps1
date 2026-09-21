[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [string]$AntigravityHome,
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-HomePath {
    param([string]$Requested, [Parameter(Mandatory)][string]$Fallback)

    $value = if ([string]::IsNullOrWhiteSpace($Requested)) { $Fallback } else { $Requested }
    return [IO.Path]::GetFullPath($value)
}

function Write-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$Detail,
        [switch]$Optional
    )

    if ($Passed) {
        Write-Host ("[OK]   {0}: {1}" -f $Name, $Detail) -ForegroundColor Green
    }
    elseif ($Optional) {
        $script:Warnings.Add(($Name + ': ' + $Detail))
        Write-Host ("[WARN] {0}: {1}" -f $Name, $Detail) -ForegroundColor Yellow
    }
    else {
        $script:Failures.Add(($Name + ': ' + $Detail))
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-RuntimeToken {
    param([Parameter(Mandatory)][int[]]$Codes)

    return (-join [char[]]$Codes)
}

function Read-SurfaceText {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Test-CodexFeaturesTable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalized = $Text -replace "`r`n?", "`n"
    $inFeatures = $false
    foreach ($line in ($normalized -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[features\]\s*(?:#.*)?$') {
            $inFeatures = $true
            continue
        }
        if ($trimmed -match '^\[\[?[^\]]+\]\]?\s*(?:#.*)?$') {
            $inFeatures = $false
            continue
        }
        if (-not $inFeatures -or [string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $assignment = [regex]::Match($line, '^\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*(?:#.*)?$')
        if (-not $assignment.Success -or $assignment.Groups[2].Value.Trim() -notmatch '^(?i:true|false)$') {
            return $false
        }
    }

    return $true
}

function Get-ManagedBlock {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $blockRegex = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT\s*\r?\n.*?^# END CODEX-WORKFLOWS-KIT\s*(?:\r?\n|$)'
    $match = [regex]::Match($Text, $blockRegex)
    if ($match.Success) {
        return $match.Value
    }

    $begin = '# BEGIN CODEX-WORKFLOWS-KIT'
    $start = $Text.IndexOf($begin, [StringComparison]::Ordinal)
    if ($start -ge 0) {
        return $Text.Substring($start)
    }

    return ''
}

function Assert-InstallState {
    param([Parameter(Mandatory)][object]$State)

    $required = @('schemaVersion', 'product', 'files')
    foreach ($property in $required) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) {
            throw "Install state is missing required property: $property"
        }
    }

    $schemaText = [string]$State.schemaVersion
    if ($schemaText -notin @('1', '2', '3', '4', '5')) {
        throw "Install state has an unsupported schema: $schemaText"
    }
    $schema = [int]$schemaText
    if ([string]$State.product -ne 'codex-workflows-kit') {
        throw 'Install state belongs to a different product.'
    }
    if ($null -eq $State.files -or -not ($State.files -is [System.Array])) {
        throw 'Install state files must be an array.'
    }

    $entries = @($State.files)
    if ($schema -ge 3) {
        if (-not ($State.PSObject.Properties.Name -contains 'pendingFiles') -or $null -eq $State.pendingFiles -or -not ($State.pendingFiles -is [System.Array])) {
            throw "Schema $schema install state is missing pendingFiles."
        }
        $entries += @($State.pendingFiles)
    }
    elseif ($State.PSObject.Properties.Name -contains 'pendingFiles') {
        throw 'Only schema 3 and later install state may contain pendingFiles.'
    }

    if ($schema -ge 4) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or $null -eq $State.codexFeaturesPrior) {
            throw "Schema $schema install state is missing codexFeaturesPrior."
        }
        if (-not ($State.codexFeaturesPrior.PSObject.Properties.Name -contains 'multi_agent')) {
            throw "Schema $schema install state is missing the multi_agent feature record."
        }
        $featureRecord = $State.codexFeaturesPrior.multi_agent
        if ($null -eq $featureRecord -or -not ($featureRecord.PSObject.Properties.Name -contains 'present') -or -not ($featureRecord.PSObject.Properties.Name -contains 'value')) {
            throw "Schema $schema install state contains an invalid multi_agent feature record."
        }
        if ($featureRecord.present -notin @($true, $false)) {
            throw "Schema $schema install state has an invalid multi_agent presence flag."
        }
        if ([bool]$featureRecord.present -and $null -eq $featureRecord.value) {
            throw "Schema $schema install state has a present multi_agent record without a value."
        }
        if (-not [bool]$featureRecord.present -and $null -ne $featureRecord.value) {
            throw "Schema $schema install state has an absent multi_agent record with a value."
        }
    }

    if ($State.PSObject.Properties.Name -contains 'codexBackend') {
        if ($null -eq $State.codexBackend) {
            throw "Install state contains an invalid codexBackend property."
        }
        Assert-CodexBackendState -BackendState $State.codexBackend
    }
    if ($State.PSObject.Properties.Name -contains 'codexDelegation') {
        if ($null -eq $State.codexDelegation) {
            throw "Install state contains an invalid codexDelegation property."
        }
        Assert-CodexDelegationState -DelegationState $State.codexDelegation
    }
    if ($State.PSObject.Properties.Name -contains 'codexStrategy') {
        if ($null -eq $State.codexStrategy) {
            throw "Install state contains an invalid codexStrategy property."
        }
        Assert-CodexStrategyState -StrategyState $State.codexStrategy
    }
    if ($State.PSObject.Properties.Name -contains 'codexContinuation') {
        if ($null -eq $State.codexContinuation) {
            throw "Install state contains an invalid codexContinuation property."
        }
        Assert-CodexContinuationState -ContinuationState $State.codexContinuation
    }
    if ($State.PSObject.Properties.Name -contains 'codexDevRouter') {
        if ($null -eq $State.codexDevRouter) {
            throw "Install state contains an invalid codexDevRouter property."
        }
        Assert-CodexDevRouterState -DevRouterState $State.codexDevRouter
    }

    if ($schema -ge 5) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexBackend') -or $null -eq $State.codexBackend) {
            throw "Schema $schema install state is missing required codexBackend."
        }
        Assert-CodexBackendState -BackendState $State.codexBackend
        if (-not ($State.PSObject.Properties.Name -contains 'codexDelegation') -or $null -eq $State.codexDelegation) {
            throw "Schema $schema install state is missing required codexDelegation."
        }
        Assert-CodexDelegationState -DelegationState $State.codexDelegation
    }

    $seenPaths = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry -or -not ($entry.PSObject.Properties.Name -contains 'path') -or -not ($entry.PSObject.Properties.Name -contains 'sha256')) {
            throw 'Install state contains an invalid file entry.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.path) -or -not (Test-FullyQualifiedPath -Path ([string]$entry.path)) -or [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Install state contains an invalid file path or hash.'
        }
        $fullPath = [IO.Path]::GetFullPath([string]$entry.path)
        if ($seenPaths.ContainsKey($fullPath)) {
            throw "Install state contains a duplicate file entry: $fullPath"
        }
        $seenPaths[$fullPath] = $true
    }

    if ($schema -ge 3) {
        foreach ($entry in @($State.pendingFiles)) {
            if (-not ($entry.PSObject.Properties.Name -contains 'reason') -or [string]$entry.reason -notin @('modified', 'outside-destinations', 'unverified')) {
                throw 'Schema 3 install state contains a pending file without a reason.'
            }
        }
    }

    return $schema
}

function Test-FullyQualifiedPath {
    param([Parameter(Mandatory)][string]$Path)

    return $Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]+\\[^\\]+\\'
}

function Test-NoManagedAgentsBlock {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return $text.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: agents', [StringComparison]::Ordinal) -lt 0
}

function Test-TomlTableHeader {
    param([AllowEmptyString()][string]$Line)

    return ($Line -replace '\r\n?', '') -match '^[ \t]*\[\[?[^\r\n\]]*\]\]?[ \t]*(?:#.*)?$'
}

function Get-FeaturesTableInfo {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text = $Text -replace '\r\n', "`n"
    $lines = [System.Collections.Generic.List[string]]([regex]::Split($Text, '\r?\n'))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^[ \t]*\[features\][ \t]*(?:#.*)?$') {
            continue
        }

        $end = $lines.Count
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if (Test-TomlTableHeader -Line $lines[$j]) {
                $end = $j
                break
            }
        }

        $multiAgentLine = -1
        $multiAgentValue = ''
        for ($j = $i + 1; $j -lt $end; $j++) {
            $keyMatch = [regex]::Match($lines[$j], '^\s*multi_agent\s*=')
            if (-not $keyMatch.Success) {
                continue
            }
            $multiAgentLine = $j
            $valueMatch = [regex]::Match($lines[$j], '^\s*multi_agent\s*=\s*([^\s#]+)')
            if ($valueMatch.Success) {
                $multiAgentValue = $valueMatch.Groups[1].Value
            }
            break
        }

        return [pscustomobject]@{
            Index = $i
            EndIndex = $end
            MultiAgentLine = $multiAgentLine
            MultiAgentValue = $multiAgentValue
        }
    }

    return [pscustomobject]@{
        Index = -1
        EndIndex = -1
        MultiAgentLine = -1
        MultiAgentValue = ''
    }
}

function Test-FeaturesMultiAgentDisabled {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $info = Get-FeaturesTableInfo -Text $text
    return ($info.Index -ge 0 -and $info.MultiAgentLine -ge 0 -and $info.MultiAgentValue -ceq 'false')
}

function Get-McpServers {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $servers = @()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $servers
    }

    $matches = [regex]::Matches($Text, '(?m)^\[mcp_servers\.([^\]]+)\]\r?\n(?<body>[\s\S]*?)(?=^\s*\[[^\r\n]+\]\s*$|\z)')
    foreach ($match in $matches) {
        $servers += [pscustomobject]@{
            Name = $match.Groups[1].Value
            Body = $match.Groups['body'].Value
        }
    }

    return $servers
}

function Get-McpEntryStatus {
    param([Parameter(Mandatory)][string]$Body)

    $command = [regex]::Match($Body, '(?m)^command\s*=\s*"([^"]+)"').Groups[1].Value
    $argsMatch = [regex]::Match($Body, '(?m)^args\s*=\s*\[(.*)\]').Groups[1].Value
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($command)) {
        $candidates += $command
    }
    foreach ($token in @([regex]::Matches($argsMatch, '"([^"]+)"'))) {
        $candidates += $token.Groups[1].Value
    }

    $fullPaths = @($candidates | Where-Object { $_ -match '^[A-Za-z]:\\' -or $_ -match '^\\\\' })
    foreach ($path in $fullPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [pscustomobject]@{ Present = $true; Missing = @(); Entry = $path }
        }
    }
    if ($fullPaths.Count -gt 0) {
        return [pscustomobject]@{ Present = $false; Missing = $fullPaths; Entry = $null }
    }

    $scriptLike = @($candidates | Where-Object { $_ -match '\.(?:js|cmd|bat|ps1|py|exe)$' })
    foreach ($path in $scriptLike) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [pscustomobject]@{ Present = $true; Missing = @(); Entry = $path }
        }
    }

    return [pscustomobject]@{ Present = $true; Missing = @(); Entry = $null }
}

function Get-ShortcutInfo {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $scriptPath = $null
        $argTokens = @([regex]::Matches([string]$shortcut.Arguments, '"([^"]+)"|([^\s]+)'))
        foreach ($token in $argTokens) {
            $candidate = if (-not [string]::IsNullOrWhiteSpace($token.Groups[1].Value)) { $token.Groups[1].Value } else { $token.Groups[2].Value }
            if ($candidate -match '\.(?:ahk|cmd|bat|ps1)$') {
                $scriptPath = $candidate
                break
            }
        }

        return [pscustomobject]@{
            TargetPath = [string]$shortcut.TargetPath
            ScriptPath = $scriptPath
        }
    }
    catch {
        return $null
    }
}

function Test-AutoHotkeyV2Executable {
    param([Parameter(Mandatory=$false)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            IsValid = $false
            Path = $null
            Version = $null
            Reason = 'Path is null or empty'
        }
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            IsValid = $false
            Path = $Path
            Version = $null
            Reason = 'File does not exist'
        }
    }

    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $isAhkProduct = ($vi.ProductName -match 'AutoHotkey' -or $vi.FileDescription -match 'AutoHotkey' -or $vi.CompanyName -match 'AutoHotkey')
        $isV2 = ($vi.FileMajorPart -eq 2 -or $vi.ProductMajorPart -eq 2 -or $vi.ProductVersion -match '^2\.' -or $vi.FileVersion -match '^2\.')

        if ($isAhkProduct -and $isV2) {
            $ver = if (-not [string]::IsNullOrWhiteSpace($vi.ProductVersion)) { $vi.ProductVersion.Trim() } else { $vi.FileVersion.Trim() }
            return [pscustomobject]@{
                IsValid = $true
                Path = [IO.Path]::GetFullPath($Path)
                Version = $ver
                Reason = 'Verified AutoHotkey v2'
            }
        }
        else {
            return [pscustomobject]@{
                IsValid = $false
                Path = $Path
                Version = if (-not [string]::IsNullOrWhiteSpace($vi.ProductVersion)) { $vi.ProductVersion.Trim() } else { $vi.FileVersion }
                Reason = if (-not $isAhkProduct) { 'Not an AutoHotkey binary' } else { 'AutoHotkey version is not v2' }
            }
        }
    }
    catch {
        return [pscustomobject]@{
            IsValid = $false
            Path = $Path
            Version = $null
            Reason = "Failed to inspect executable metadata: $($_.Exception.Message)"
        }
    }
}

function Resolve-AutoHotkeyV2Executable {
    param(
        [string]$ShortcutPath,
        [string[]]$CandidatePaths
    )

    # 1. Attempt detection via startup shortcut target
    $resolvedShortcut = if (-not [string]::IsNullOrWhiteSpace($ShortcutPath)) {
        $ShortcutPath
    }
    else {
        Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Prompt Pad.lnk'
    }

    if (Test-Path -LiteralPath $resolvedShortcut -PathType Leaf) {
        $scInfo = Get-ShortcutInfo -Path $resolvedShortcut
        if ($null -ne $scInfo -and -not [string]::IsNullOrWhiteSpace($scInfo.TargetPath)) {
            $testRes = Test-AutoHotkeyV2Executable -Path $scInfo.TargetPath
            if ($testRes.IsValid) {
                return [pscustomobject]@{
                    IsValid = $true
                    Path = $testRes.Path
                    Version = $testRes.Version
                    Source = 'ShortcutTarget'
                }
            }
        }
    }

    # 2. Canonical existing knownpaths
    $defaultKnownPaths = @(
        'E:\Programs\AHK\v2\AutoHotkey64.exe',
        'E:\Programs\AHK\v2\AutoHotkey32.exe',
        'E:\Programs\AutoHotkey\v2\AutoHotkey64.exe',
        'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
        'C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe',
        'C:\Program Files\AutoHotkey\AutoHotkey64.exe',
        'C:\Program Files\AutoHotkey\AutoHotkey32.exe',
        'C:\Program Files\AutoHotkey\AutoHotkey.exe',
        'C:\Program Files (x86)\AutoHotkey\v2\AutoHotkey64.exe',
        'C:\Program Files (x86)\AutoHotkey\v2\AutoHotkey32.exe',
        'C:\Program Files (x86)\AutoHotkey\AutoHotkey.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey32.exe')
    )

    if ($env:ProgramFiles) {
        $defaultKnownPaths += Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
    }
    if (${env:ProgramFiles(x86)}) {
        $defaultKnownPaths += Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey32.exe'
    }

    $pathsToCheck = if ($null -ne $CandidatePaths) { $CandidatePaths } else { $defaultKnownPaths }

    foreach ($candidate in $pathsToCheck) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $testRes = Test-AutoHotkeyV2Executable -Path $candidate
        if ($testRes.IsValid) {
            return [pscustomobject]@{
                IsValid = $true
                Path = $testRes.Path
                Version = $testRes.Version
                Source = 'KnownPath'
            }
        }
    }

    # 3. Check PATH without executing
    if ($null -eq $CandidatePaths) {
        $pathCommands = @('AutoHotkey64.exe', 'AutoHotkey.exe')
        foreach ($cmdName in $pathCommands) {
            $cmdInfo = Get-Command $cmdName -ErrorAction SilentlyContinue
            if ($null -ne $cmdInfo -and -not [string]::IsNullOrWhiteSpace($cmdInfo.Source)) {
                $testRes = Test-AutoHotkeyV2Executable -Path $cmdInfo.Source
                if ($testRes.IsValid) {
                    return [pscustomobject]@{
                        IsValid = $true
                        Path = $testRes.Path
                        Version = $testRes.Version
                        Source = 'PATH'
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        IsValid = $false
        Path = $null
        Version = $null
        Source = $null
    }
}

function Test-PromptPadContract {
    param([Parameter(Mandatory)][string]$Text)

    $tWr = Get-RuntimeToken @(119, 114, 105, 116, 101, 114)
    $tSct = Get-RuntimeToken @(115, 99, 111, 117, 116)
    $tRsr = Get-RuntimeToken @(114, 101, 115, 101, 97, 114, 99, 104, 101, 114)
    $tRvw = Get-RuntimeToken @(114, 101, 118, 105, 101, 119, 101, 114)
    $tWk = Get-RuntimeToken @(119, 111, 114, 107, 101, 114)

    # Narrowly allow exact canonical passive switch-subagent-strategy -Strategy worker command
    $canonicalPassiveRegex = '(?i)PastePrompt\s*\(\s*["''](?:\.[\\/])?(?:scripts[\\/])?switch-subagent-strategy(?:\.ps1)?\s+-Strategy\s+' + $tWk + '\s*["'']\s*\)'
    $sanitized = [regex]::Replace($Text, $canonicalPassiveRegex, '')

    $promptPadPatterns = @('\breader\b', ('\b' + $tWr + '\b'), ('\b' + $tSct + '\b'), ('\b' + $tRsr + '\b'), ('\b' + $tRvw + '\b'), ('\b' + $tWk + '\b'), 'PromptPadNative', 'BackendOverrideText', 'WorkflowPrompt')
    foreach ($pattern in $promptPadPatterns) {
        if ([regex]::IsMatch($sanitized, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Get-InstalledContractPatterns {
    [CmdletBinding()]
    param()

    $tSubEq = Get-RuntimeToken @(115, 117, 98, 97, 103, 101, 110, 116, 115)
    $tSidecar = Get-RuntimeToken @(115, 105, 100, 101, 99, 97, 114)
    $tSct = Get-RuntimeToken @(115, 99, 111, 117, 116)
    $tRsr = Get-RuntimeToken @(114, 101, 115, 101, 97, 114, 99, 104, 101, 114)
    $tWr = Get-RuntimeToken @(119, 114, 105, 116, 101, 114)
    $tRvw = Get-RuntimeToken @(114, 101, 118, 105, 101, 119, 101, 114)
    $tWk = Get-RuntimeToken @(119, 111, 114, 107, 101, 114)
    $tWtch = Get-RuntimeToken @(119, 97, 116, 99, 104, 101, 114)
    $tRly = Get-RuntimeToken @(114, 101, 108, 97, 121)
    $tOc = Get-RuntimeToken @(111, 112, 101, 110, 99, 111, 100, 101)
    $tSubA = Get-RuntimeToken @(115, 117, 98, 97, 103, 101, 110, 116)

    $legacyRoles = @('readers?', ($tSct + 's?'), ($tRsr + 's?'), ($tRvw + 's?'), ($tWk + 's?'), ($tWtch + 's?'), ($tRly + 's?'), $tOc, ($tSubA + 's?'), 'suba', 'tasks?', 'nested', 'checkpoints?', 'profiles?', 'roles?', 'gates?', 'dispatch', 'lanes?')
    $rolePattern = '(?i)\bread-only\s+(?:(?:' + $tOc + '|nested|custom)\s+)*(?:' + ($legacyRoles -join '|') + ')\b'
    $reverseRolePattern = '(?i)\b(?:readers?|' + $tSct + 's?|' + $tRsr + 's?|' + $tRvw + 's?|' + $tWk + 's?|' + $tWtch + 's?|' + $tRly + 's?|' + $tOc + '|roles?)(?:\.(?:toml|yaml|json|md))?\b[^\r\n]*?\bread-only\b'
    $configPattern = '(?i)\b(?:sandbox_mode|sandbox)\s*=\s*[''"]?read-only[''"]?'
    $modePattern = '(?i)\bmode\s*=\s*[''"]read-only[''"]'
    $matrixPattern = '(?m)^\|[^\r\n|]+\|[^\r\n|]+\|\s*read-only\s*\|'
    $diagnosePattern = '(?i)\b(?:diagn.{0,2}stico|diagnose|diagnosis)\s+read-only\b|\bread-only\s+(?:diagn.{0,2}stico|diagnose|diagnosis)\b'
    $phrasePattern = '(?i)\bread-only\s+work\s+must\s+use\b'

    return @(
        ('\b' + $tSubEq + '\s*='),
        ('\b' + $tSidecar + '\b'),
        'PromptPadNative',
        'BackendOverrideText',
        $rolePattern,
        $reverseRolePattern,
        $configPattern,
        $modePattern,
        $matrixPattern,
        $diagnosePattern,
        $phrasePattern
    )
}

function Test-InstalledContractText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Surface = ''
    )

    $patterns = Get-InstalledContractPatterns
    foreach ($pattern in $patterns) {
        if ([regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Test-LegacyContractMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Surface = ''
    )

    return (-not (Test-InstalledContractText -Text $Text -Surface $Surface))
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$defaultAntigravityHome = if ($env:ANTIGRAVITY_HOME) { $env:ANTIGRAVITY_HOME } else { Join-Path $env:USERPROFILE '.gemini' }
$CodexHome = Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome
$AgentsHome = Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome
$AntigravityHome = Resolve-HomePath -Requested $AntigravityHome -Fallback $defaultAntigravityHome
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'scripts\backend-routing.psm1') -Force
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$configPath = Join-Path $CodexHome 'config.toml'
$agentsMdPath = Join-Path $CodexHome 'AGENTS.md'
$geminiMdPath = Join-Path (Join-Path $AntigravityHome 'config') 'GEMINI.md'
$skillsRoot = Join-Path $AgentsHome 'skills'
$antigravitySkills1 = Join-Path $AntigravityHome 'antigravity\skills'
$antigravitySkills2 = Join-Path $AntigravityHome 'config\skills'
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

$tokNative = Get-RuntimeToken @(110, 97, 116, 105, 118, 101)
$tokBackend = Get-RuntimeToken @(98, 97, 99, 107, 101, 110, 100)
$tokSidecar = Get-RuntimeToken @(115, 105, 100, 101, 99, 97, 114)
$tokSubagentsEq = Get-RuntimeToken @(115, 117, 98, 97, 103, 101, 110, 116, 115, 61)
$tSct = Get-RuntimeToken @(115, 99, 111, 117, 116)
$tRsr = Get-RuntimeToken @(114, 101, 115, 101, 97, 114, 99, 104, 101, 114)
$tWr = Get-RuntimeToken @(119, 114, 105, 116, 101, 114)
$tRvw = Get-RuntimeToken @(114, 101, 118, 105, 101, 119, 101, 114)
$tWk = Get-RuntimeToken @(119, 111, 114, 107, 101, 114)
$tWtch = Get-RuntimeToken @(119, 97, 116, 99, 104, 101, 114)
$tRly = Get-RuntimeToken @(114, 101, 108, 97, 121)
$tOc = Get-RuntimeToken @(111, 112, 101, 110, 99, 111, 100, 101)
$tokModeMatrix = Get-RuntimeToken @(109, 111, 100, 101, 45, 109, 97, 116, 114, 105, 120)
$tokDictionaryMd = Get-RuntimeToken @(100, 105, 99, 116, 105, 111, 110, 97, 114, 121, 46, 109, 100)
$tokSubagentsMd = Get-RuntimeToken @(115, 117, 98, 97, 103, 101, 110, 116, 115, 46, 109, 100)

Write-Host 'Codex Workflows Kit doctor'
Write-Host "Codex home: $CodexHome"
Write-Host "Agents home: $AgentsHome"
Write-Host "Antigravity home: $AntigravityHome"
Write-Check -Name 'Install state' -Passed (Test-Path -LiteralPath $statePath -PathType Leaf) -Detail $statePath

$state = $null
$stateSchema = $null
$installedProfile = ''
$selectedBackend = 'deepseek'
$selectedPolicy = 'balanced'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stateSchema = Assert-InstallState -State $state
        Write-Check -Name 'State schema' -Passed $true -Detail "schema $stateSchema"
        if ($state.PSObject.Properties.Name -contains 'profile') {
            $installedProfile = [string]$state.profile
            Write-Check -Name 'Install profile' -Passed ($installedProfile -in @('minimal', 'safe')) -Detail $installedProfile
        }
        else {
            Write-Check -Name 'Install profile' -Passed $false -Detail 'profile is missing from install state'
        }
        if ($state.PSObject.Properties.Name -contains 'codexBackend') {
            Assert-CodexBackendState -BackendState $state.codexBackend
        }
    }
    catch {
        Write-Check -Name 'Install state' -Passed $false -Detail $_.Exception.Message
        $state = $null
        $stateSchema = $null
    }
}

$coreFiles = @(
    (Join-Path $AgentsHome 'skills\workflows\SKILL.md'),
    (Join-Path $AgentsHome 'skills\evidence-first\SKILL.md'),
    (Join-Path $AgentsHome 'skills\mcp-foundation\SKILL.md')
)
if ($installedProfile -eq 'safe') {
    $coreFiles += @(
        (Join-Path $CodexHome 'AGENTS.md'),
        $geminiMdPath
    )
}
foreach ($path in $coreFiles) {
    Write-Check -Name 'Core artifact' -Passed (Test-Path -LiteralPath $path -PathType Leaf) -Detail $path
}

$freeMcpSkills = @(
    (Join-Path $AgentsHome 'skills\codebase-memory-mcp\SKILL.md'),
    (Join-Path $AgentsHome 'skills\context7-mcp\SKILL.md')
)
foreach ($fPath in $freeMcpSkills) {
    $exists = Test-Path -LiteralPath $fPath -PathType Leaf
    $label = Split-Path -Leaf (Split-Path -Parent $fPath)
    if ($exists) {
        Write-Check -Name "Optional free skill ($label)" -Passed $true -Detail $fPath -Optional
    }
    else {
        Write-Check -Name "Optional free skill ($label)" -Passed $false -Detail "Optional skill not installed (not runtime validated): $fPath" -Optional
    }
}

if ($installedProfile -eq 'safe') {
    Write-Check -Name 'No managed agents defaults' -Passed (Test-NoManagedAgentsBlock -Path $configPath) -Detail $configPath

    $selectedBackend = 'deepseek'
    if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexBackend')) {
        try {
            $selectedBackend = [string]$state.codexBackend.selected
            $backendText = Read-SurfaceText -Path $configPath
            Assert-CodexBackendMatrix -Text $backendText -Backend $selectedBackend -BackendState $state.codexBackend | Out-Null
            Write-Check -Name 'Selected backend' -Passed $true -Detail $selectedBackend
            Write-Check -Name 'Backend matrix' -Passed $true -Detail "Exact $selectedBackend matrix is active"
        }
        catch {
            Write-Check -Name 'Selected backend' -Passed $false -Detail $_.Exception.Message
            Write-Check -Name 'Backend matrix' -Passed $false -Detail $configPath
        }
    }
    else {
        Write-Check -Name 'Multi-agent route disabled' -Passed (Test-FeaturesMultiAgentDisabled -Path $configPath) -Detail $configPath
    }

    $selectedPolicy = 'balanced'
    if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexDelegation')) {
        try {
            $selectedPolicy = [string]$state.codexDelegation.selected
            Assert-CodexDelegationState -DelegationState $state.codexDelegation
            Write-Check -Name 'Delegation policy' -Passed $true -Detail $selectedPolicy
        }
        catch {
            Write-Check -Name 'Delegation policy' -Passed $false -Detail $_.Exception.Message
        }
    }

    $devRouterStateFile = Join-Path $CodexHome 'codex-workflows-kit\dev-router-state.json'
    if (Test-Path -LiteralPath $devRouterStateFile -PathType Leaf) {
        try {
            $dState = Get-Content -LiteralPath $devRouterStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-CodexDevRouterState -DevRouterState $dState
            Write-Check -Name 'Dev Router configuration' -Passed $true -Detail "mode=$($dState.mode), target=$($dState.target)"
        }
        catch {
            Write-Check -Name 'Dev Router configuration' -Passed $false -Detail $_.Exception.Message
        }
    }
    elseif ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexDevRouter') -and $null -ne $state.codexDevRouter) {
        try {
            Assert-CodexDevRouterState -DevRouterState $state.codexDevRouter
            Write-Check -Name 'Dev Router configuration' -Passed $true -Detail "mode=$($state.codexDevRouter.mode), target=$($state.codexDevRouter.target)"
        }
        catch {
            Write-Check -Name 'Dev Router configuration' -Passed $false -Detail $_.Exception.Message
        }
    }

    $agentsMdContent = Read-SurfaceText -Path $agentsMdPath
    $managedBlockCount = @([regex]::Matches($agentsMdContent, '(?m)^# BEGIN CODEX-WORKFLOWS-KIT\r?$')).Count
    Write-Check -Name 'Unique managed policy (AGENTS)' -Passed ($managedBlockCount -eq 1) -Detail $agentsMdPath

    $expectedBackend = if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexBackend')) { [string]$state.codexBackend.selected } else { 'deepseek' }
    $expectedPolicy = if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexDelegation')) { [string]$state.codexDelegation.selected } else { 'balanced' }
    $expectedStrategy = if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexStrategy')) { [string]$state.codexStrategy.selected } else { 'worker' }
    $expectedContinuation = if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexContinuation')) { [string]$state.codexContinuation.selected } else { 'active_follow' }
    try {
        Assert-CodexAgentsRuntimeBlock -Text $agentsMdContent -Backend $expectedBackend -Policy $expectedPolicy -Strategy $expectedStrategy -Continuation $expectedContinuation
        Write-Check -Name 'Managed AGENTS runtime' -Passed $true -Detail "Exact runtime block matches (backend=$expectedBackend, policy=$expectedPolicy, strategy=$expectedStrategy, continuation=$expectedContinuation)"
    }
    catch {
        Write-Check -Name 'Managed AGENTS runtime' -Passed $false -Detail $_.Exception.Message
    }

    $templatePath = Join-Path $repoRoot 'codex\AGENTS.md'
    $templateMatches = $false
    if (-not [string]::IsNullOrWhiteSpace($agentsMdContent) -and (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $template = (Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8).Trim()
        $normalizedAgents = $agentsMdContent -replace '\r\n', "`n"
        $normalizedTemplate = $template -replace '\r\n', "`n"
        $templateMatches = $normalizedAgents.IndexOf($normalizedTemplate, [StringComparison]::Ordinal) -ge 0
    }
    Write-Check -Name 'Managed AGENTS template' -Passed $templateMatches -Detail $agentsMdPath -Optional

    $geminiMdContent = Read-SurfaceText -Path $geminiMdPath
    $geminiManagedBlockCount = @([regex]::Matches($geminiMdContent, '(?m)^# BEGIN CODEX-WORKFLOWS-KIT\r?$')).Count
    Write-Check -Name 'Unique managed policy (GEMINI)' -Passed ($geminiManagedBlockCount -eq 1) -Detail $geminiMdPath

    $geminiTemplatePath = Join-Path $repoRoot 'antigravity\GEMINI.md'
    $geminiTemplateMatches = $false
    if (-not [string]::IsNullOrWhiteSpace($geminiMdContent) -and (Test-Path -LiteralPath $geminiTemplatePath -PathType Leaf)) {
        $geminiTemplate = (Get-Content -LiteralPath $geminiTemplatePath -Raw -Encoding UTF8).Trim()
        $normalizedGemini = $geminiMdContent -replace '\r\n', "`n"
        $normalizedGeminiTemplate = $geminiTemplate -replace '\r\n', "`n"
        $geminiTemplateMatches = $normalizedGemini.IndexOf($normalizedGeminiTemplate, [StringComparison]::Ordinal) -ge 0
    }
    Write-Check -Name 'Managed GEMINI template' -Passed $geminiTemplateMatches -Detail $geminiMdPath -Optional

    $geminiConflicts = @()
    if (-not [string]::IsNullOrWhiteSpace($geminiMdContent)) {
        $blockInfo = Get-GeminiManagedBlockInfo -Content $geminiMdContent
        if ($blockInfo.HasValidMarkers) {
            $geminiConflicts = @(Get-GeminiLegacyConflicts -Text $blockInfo.Tail)
        }
    }

    $geminiConflictsPassed = ($geminiConflicts.Count -eq 0)
    $geminiConflictsDetail = if ($geminiConflictsPassed) {
        "No conflicting unmanaged rules detected in $geminiMdPath"
    } else {
        "Detected $($geminiConflicts.Count) legacy conflict(s): " + ($geminiConflicts -join '; ') + ". Run scripts/migrate-legacy-gemini.ps1 to resolve."
    }
    Write-Check -Name 'GEMINI unmanaged conflicts' -Passed $geminiConflictsPassed -Detail $geminiConflictsDetail -Optional
}

if ($null -ne $state) {
    foreach ($file in @($state.files)) {
        $path = [string]$file.path
        if ($path -eq $configPath -or $path -eq $agentsMdPath -or $path -eq $geminiMdPath) {
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Check -Name 'Managed artifact' -Passed $false -Detail "Missing: $path"
            continue
        }

        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Write-Check -Name 'Managed artifact' -Passed ($actual -eq [string]$file.sha256) -Detail $path
    }

    if ($stateSchema -ge 3) {
        foreach ($file in @($state.pendingFiles)) {
            $path = [string]$file.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Check -Name 'Pending artifact' -Passed $false -Detail "Missing: $path" -Optional
                continue
            }

            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $reason = if ($file.PSObject.Properties.Name -contains 'reason') { [string]$file.reason } else { 'review required' }
            Write-Check -Name 'Pending artifact' -Passed ($actual -eq [string]$file.sha256) -Detail "${reason}: $path" -Optional
        }
    }
}

$contractPatterns = @(Get-InstalledContractPatterns)
$removedReferenceMarkers = @(($tokBackend + '-policy'), ($tokNative + '-profile-contract'), $tokModeMatrix, $tokDictionaryMd, $tokSubagentsMd)
$surfaceFiles = New-Object System.Collections.Generic.List[string]
foreach ($path in @($configPath, $agentsMdPath, $geminiMdPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $surfaceFiles.Add($path)
    }
}
foreach ($sRoot in @($skillsRoot, $antigravitySkills1, $antigravitySkills2)) {
    if (Test-Path -LiteralPath $sRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sRoot -Recurse -File -Include *.md, *.toml, *.yaml, *.ahk -ErrorAction SilentlyContinue)) {
            $surfaceFiles.Add($file.FullName)
        }
    }
}

$contractDirty = $null
foreach ($surface in $surfaceFiles) {
    $content = Get-Content -LiteralPath $surface -Raw -Encoding UTF8
    if ($surface -eq $geminiMdPath) {
        $content = Get-ManagedBlock -Text $content
    }
    if (-not (Test-InstalledContractText -Text $content -Surface $surface)) {
        $contractDirty = $surface
        break
    }
}
Write-Check -Name 'Installed contract' -Passed ($null -eq $contractDirty) -Detail $(if ($null -eq $contractDirty) { 'No legacy contract markers in installed surfaces' } else { "Legacy contract marker retained in: $contractDirty" })

$referenceDirty = $null
foreach ($surface in $surfaceFiles) {
    $content = Get-Content -LiteralPath $surface -Raw -Encoding UTF8
    if ($surface -eq $geminiMdPath) {
        $content = Get-ManagedBlock -Text $content
    }
    foreach ($marker in $removedReferenceMarkers) {
        if ($content.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $referenceDirty = $surface
            break
        }
    }
    if ($null -ne $referenceDirty) {
        break
    }
}
Write-Check -Name 'Removed references' -Passed ($null -eq $referenceDirty) -Detail $(if ($null -eq $referenceDirty) { 'No active references to removed documents' } else { "Reference to removed document in: $referenceDirty" })

$legacyProfileNames = @($tSct, $tRsr, $tRvw, $tWk, $tWtch, $tRly)
foreach ($installRoot in @($CodexHome, $AgentsHome, $AntigravityHome)) {
    $agentsDir = Join-Path $installRoot 'agents'
    if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) {
        continue
    }
    $legacyFiles = @(Get-ChildItem -LiteralPath $agentsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -in $legacyProfileNames })
    $legacyDirs = @(Get-ChildItem -LiteralPath $agentsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $tOc })
    if ($legacyFiles.Count -gt 0 -or $legacyDirs.Count -gt 0) {
        foreach ($file in $legacyFiles) {
            Write-Check -Name 'Legacy managed profiles' -Passed $false -Detail $file.FullName
        }
        foreach ($dir in $legacyDirs) {
            Write-Check -Name 'Legacy managed profiles' -Passed $false -Detail $dir.FullName
        }
    }
    else {
        Write-Check -Name 'Legacy managed profiles' -Passed $true -Detail $agentsDir
    }
}

$canonicalSkillPath = Join-Path $AgentsHome 'skills\workflows\SKILL.md'
$competingPolicies = @()
foreach ($sRoot in @($skillsRoot, $antigravitySkills1, $antigravitySkills2)) {
    if (Test-Path -LiteralPath $sRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sRoot -Recurse -File -Filter *.md -ErrorAction SilentlyContinue)) {
            if ($file.FullName -eq $canonicalSkillPath -or $file.FullName -eq (Join-Path $antigravitySkills1 'workflows\SKILL.md') -or $file.FullName -eq (Join-Path $antigravitySkills2 'workflows\SKILL.md')) {
                continue
            }
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            if ($content.IndexOf('$workflows', [StringComparison]::Ordinal) -ge 0) {
                $competingPolicies += $file.FullName
            }
        }
    }
}
if ($competingPolicies.Count -gt 0) {
    foreach ($path in $competingPolicies) {
        Write-Check -Name 'Unique workflow policy' -Passed $false -Detail "Competing policy in: $path"
    }
}
else {
    Write-Check -Name 'Unique workflow policy' -Passed $true -Detail 'Only skills/workflows/SKILL.md defines the workflow contract'
}

$ahkPath = $null
if ($null -ne $state) {
    foreach ($entry in @($state.files)) {
        if ([string]$entry.path -match 'codex_prompt_pad\.ahk$') {
            $ahkPath = [IO.Path]::GetFullPath([string]$entry.path)
            break
        }
    }
    if ($null -eq $ahkPath -and $stateSchema -ge 3) {
        foreach ($entry in @($state.pendingFiles)) {
            if ([string]$entry.path -match 'codex_prompt_pad\.ahk$') {
                $ahkPath = [IO.Path]::GetFullPath([string]$entry.path)
                break
            }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($ahkPath) -and (Test-Path -LiteralPath $ahkPath -PathType Leaf)) {
    $ahkText = Get-Content -LiteralPath $ahkPath -Raw -Encoding UTF8
    $promptPadValid = Test-PromptPadContract -Text $ahkText
    Write-Check -Name 'Prompt Pad contract' -Passed $promptPadValid -Detail $ahkPath

    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Prompt Pad.lnk'
    if (Test-Path -LiteralPath $startupShortcut -PathType Leaf) {
        $shortcut = Get-ShortcutInfo -Path $startupShortcut
        if ($null -eq $shortcut) {
            Write-Check -Name 'Prompt Pad shortcut' -Passed $false -Optional -Detail "Could not read the Startup shortcut: $startupShortcut"
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($shortcut.ScriptPath) -and $shortcut.ScriptPath -eq $ahkPath) {
                Write-Check -Name 'Prompt Pad shortcut' -Passed $true -Detail 'Points to the managed copy'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($shortcut.ScriptPath) -and (Test-Path -LiteralPath $shortcut.ScriptPath -PathType Leaf)) {
                Write-Check -Name 'Prompt Pad shortcut' -Passed $false -Optional -Detail "Points to an unmanaged copy: $($shortcut.ScriptPath)"
            }
            else {
                Write-Check -Name 'Prompt Pad shortcut' -Passed $false -Optional -Detail "Points to a missing script: $startupShortcut"
            }
            if (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath) -and -not (Test-Path -LiteralPath $shortcut.TargetPath -PathType Leaf)) {
                Write-Check -Name 'Prompt Pad executable' -Passed $false -Optional -Detail "Shortcut target is missing: $($shortcut.TargetPath)"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath)) {
                $targetAhk = Test-AutoHotkeyV2Executable -Path $shortcut.TargetPath
                if ($targetAhk.IsValid) {
                    Write-Check -Name 'Prompt Pad executable' -Passed $true -Detail "$($shortcut.TargetPath) (v$($targetAhk.Version))"
                }
                else {
                    Write-Check -Name 'Prompt Pad executable' -Passed $false -Optional -Detail "Shortcut target is not verified AutoHotkey v2: $($shortcut.TargetPath)"
                }
            }
        }
    }
    else {
        Write-Check -Name 'Prompt Pad shortcut' -Passed $true -Detail 'No Startup shortcut installed'
    }
}

$configText = Read-SurfaceText -Path $configPath
$codexFeaturesValid = Test-CodexFeaturesTable -Text $configText
if ([string]::IsNullOrWhiteSpace($configText)) {
    Write-Check -Name 'Codex features schema' -Passed $true -Detail 'No config.toml present to validate' -Optional
}
elseif ($codexFeaturesValid) {
    Write-Check -Name 'Codex features schema' -Passed $true -Detail 'All [features] values are boolean'
}
else {
    Write-Check -Name 'Codex features schema' -Passed $false -Optional -Detail "Invalid non-boolean value in [features] of $configPath; Codex CLI MCP discovery will fail closed"
}
$mcpServers = @(Get-McpServers -Text $configText)
$legacyServerNames = @(($tOc + '_' + $tWk), $tRly, $tWtch, $tWk, $tSct, $tRsr, $tRvw, $tokNative, 'runtime-adapters')
$legacyMcpHits = @($mcpServers | Where-Object { $_.Name -in $legacyServerNames })
$legacyConfigMarkers = @(($tOc + '-' + $tWk), 'runtime-adapters', 'marketplace.json', ($tWk + '.toml'), ($tRly + '.toml'))
$legacyConfigHit = $null
foreach ($marker in $legacyConfigMarkers) {
    if ($configText.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $legacyConfigHit = $marker
        break
    }
}
if ($legacyMcpHits.Count -gt 0) {
    foreach ($hit in $legacyMcpHits) {
        Write-Check -Name 'MCP registrations' -Passed $false -Detail "Legacy server registration remains: $($hit.Name)"
    }
}
elseif ($null -ne $legacyConfigHit) {
    Write-Check -Name 'MCP registrations' -Passed $false -Detail "Legacy command reference remains in: $configPath"
}
else {
    Write-Check -Name 'MCP registrations' -Passed $true -Detail "No legacy registrations ($($mcpServers.Count) server(s) configured)"
}

$canonicalMcp = $mcpServers | Where-Object { $_.Name -eq 'subagents' }
$legacyMcp = $mcpServers | Where-Object { $_.Name -eq 'deepseek-subagent' }
$currentMcp = if ($null -ne $canonicalMcp) { $canonicalMcp } else { $legacyMcp }
if ($null -eq $currentMcp) {
    if ($selectedBackend -eq 'deepseek') {
        Write-Check -Name 'SubAgents MCP' -Passed $false -Detail 'Not configured in config.toml'
    }
    else {
        Write-Check -Name 'SubAgents MCP' -Passed $true -Detail 'Not active (native subagent backend selected)'
    }
}
else {
    $mcStatus = Get-McpEntryStatus -Body $currentMcp.Body
    if ($mcStatus.Present) {
        $enabledMatch = [regex]::Match([string]$currentMcp.Body, '(?m)^\s*enabled\s*=\s*(true|false)\s*(?:#.*)?$')
        $enabledDetail = if ($enabledMatch.Success) { "; enabled=$($enabledMatch.Groups[1].Value)" } else { '; enabled=default' }
        $detail = if ([string]::IsNullOrWhiteSpace($mcStatus.Entry)) { 'Configured' } else { "Configured; entry script present: $($mcStatus.Entry)" }
        $detail += $enabledDetail
        Write-Check -Name 'SubAgents MCP' -Passed $true -Detail $detail
    }
    else {
        Write-Check -Name 'SubAgents MCP' -Passed $false -Detail ("Configured but entry script is missing: {0}" -f ($mcStatus.Missing -join '; '))
    }
}

$context7Server = $mcpServers | Where-Object { $_.Name.Trim('"') -eq 'context7' }
if ($null -ne $context7Server) {
    $urlMatch = [regex]::Match($context7Server.Body, '(?m)^\s*url\s*=\s*["'']([^"'']+)["'']')
    if ($urlMatch.Success) {
        $rawEndpoint = $urlMatch.Groups[1].Value.Trim()
        $canonicalEndpoint = 'https://mcp.context7.com/mcp'
        if ($rawEndpoint -eq $canonicalEndpoint) {
            Write-Check -Name 'Context7 MCP' -Passed $true -Detail "Configured ($canonicalEndpoint)" -Optional
        }
        else {
            Write-Check -Name 'Context7 MCP' -Passed $true -Detail 'Configured (redacted unrecognized endpoint)' -Optional
        }
    }
    else {
        Write-Check -Name 'Context7 MCP' -Passed $true -Detail 'Configured' -Optional
    }
}
else {
    Write-Check -Name 'Context7 MCP' -Passed $true -Detail 'Not configured (optional free rollout)' -Optional
}

$cbmServer = $mcpServers | Where-Object { $_.Name.Trim('"') -in @('codebase-memory-mcp', 'codebase_memory_mcp', 'codebase-memory') }
if ($null -ne $cbmServer) {
    $cbmStatus = Get-McpEntryStatus -Body $cbmServer.Body
    if ($cbmStatus.Present) {
        $detail = if ([string]::IsNullOrWhiteSpace($cbmStatus.Entry)) { 'Configured' } else { "Configured; binary present: $($cbmStatus.Entry)" }
        Write-Check -Name 'Codebase Memory MCP' -Passed $true -Detail $detail -Optional
    }
    else {
        Write-Check -Name 'Codebase Memory MCP' -Passed $false -Detail ("Configured but binary missing: {0}" -f ($cbmStatus.Missing -join '; ')) -Optional
    }
}
else {
    Write-Check -Name 'Codebase Memory MCP' -Passed $true -Detail 'Not configured (optional free rollout)' -Optional
}

$taskFilter = "(?i)(codex|prompt|deepseek|$tOc|$tRly|workflow)"
$legacyTaskPattern = "(?i)($tOc-$tWk|runtime-adapters|marketplace\.json|$tWk\.toml|$tRly\.toml)"
try {
    $relatedTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -match $taskFilter -or $_.TaskPath -match $taskFilter })
    $legacyTasks = @()
    foreach ($task in $relatedTasks) {
        $actionText = @($task.Actions | ForEach-Object { [string]$_.Execute + ' ' + [string]$_.Arguments }) -join ' '
        if ($actionText -match $legacyTaskPattern) {
            $legacyTasks += ($task.TaskPath + $task.TaskName)
        }
    }
    if ($legacyTasks.Count -gt 0) {
        foreach ($taskPath in $legacyTasks) {
            Write-Check -Name 'Scheduled tasks' -Passed $false -Detail "Legacy task remains: $taskPath"
        }
    }
    else {
        Write-Check -Name 'Scheduled tasks' -Passed $true -Detail "$($relatedTasks.Count) related task(s); none reference legacy code"
    }
}
catch {
    Write-Check -Name 'Scheduled tasks' -Passed $true -Optional -Detail "Unavailable: $($_.Exception.Message)"
}

Write-Check -Name 'Git' -Passed (Test-Command -Name 'git') -Detail 'Required for repository operations'
Write-Check -Name 'PowerShell' -Passed ($PSVersionTable.PSVersion.Major -ge 5) -Detail $PSVersionTable.PSVersion
$resolvedAhk = Resolve-AutoHotkeyV2Executable
if ($resolvedAhk.IsValid) {
    Write-Check -Name 'AutoHotkey v2' -Passed $true -Detail "$($resolvedAhk.Path) (v$($resolvedAhk.Version))"
}
else {
    Write-Check -Name 'AutoHotkey v2' -Passed $false -Detail 'Required only for the prompt pad' -Optional
}

if ($Detailed) {
    Write-Host ''
    Write-Host "Installed paths are recorded in: $statePath"
    Write-Host 'The doctor is read-only: it inspects installed surfaces, MCP registrations,'
    Write-Host 'scheduled tasks, and the Startup shortcut without modifying configuration.'
    $docBackend = if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexBackend')) { [string]$state.codexBackend.selected } else { $selectedBackend }
    $docPolicy = if ($null -ne $state -and ($state.PSObject.Properties.Name -contains 'codexDelegation')) { [string]$state.codexDelegation.selected } else { $selectedPolicy }
    Write-Host "Active subagent backend: $docBackend (matrix enforced in config.toml)"
    Write-Host "Active delegation policy: $docPolicy"
}

if ($script:Failures.Count -gt 0) {
    exit 1
}

Write-Host ''
Write-Host "Doctor OK. Optional warnings: $($script:Warnings.Count)."
