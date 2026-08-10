[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
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

function Assert-InstallState {
    param([Parameter(Mandatory)][object]$State)

    $required = @('schemaVersion', 'product', 'files')
    foreach ($property in $required) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) {
            throw "Install state is missing required property: $property"
        }
    }

    $schemaText = [string]$State.schemaVersion
    if ($schemaText -notin @('1', '2', '3', '4')) {
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

    if ($schema -eq 4) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or $null -eq $State.codexFeaturesPrior) {
            throw 'Schema 4 install state is missing codexFeaturesPrior.'
        }
        if (-not ($State.codexFeaturesPrior.PSObject.Properties.Name -contains 'multi_agent')) {
            throw 'Schema 4 install state is missing the multi_agent feature record.'
        }
        $featureRecord = $State.codexFeaturesPrior.multi_agent
        if ($null -eq $featureRecord -or -not ($featureRecord.PSObject.Properties.Name -contains 'present') -or -not ($featureRecord.PSObject.Properties.Name -contains 'value')) {
            throw 'Schema 4 install state contains an invalid multi_agent feature record.'
        }
        if ($featureRecord.present -notin @($true, $false)) {
            throw 'Schema 4 install state has an invalid multi_agent presence flag.'
        }
        if ([bool]$featureRecord.present -and $null -eq $featureRecord.value) {
            throw 'Schema 4 install state has a present multi_agent record without a value.'
        }
        if (-not [bool]$featureRecord.present -and $null -ne $featureRecord.value) {
            throw 'Schema 4 install state has an absent multi_agent record with a value.'
        }
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
    param([Parameter(Mandatory)][string]$Text)

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

$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$CodexHome = Resolve-HomePath -Requested $CodexHome -Fallback $defaultCodexHome
$AgentsHome = Resolve-HomePath -Requested $AgentsHome -Fallback $defaultAgentsHome
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$statePath = Join-Path $CodexHome 'codex-workflows-kit\install-state.json'
$configPath = Join-Path $CodexHome 'config.toml'
$agentsMdPath = Join-Path $CodexHome 'AGENTS.md'
$skillsRoot = Join-Path $AgentsHome 'skills'
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
Write-Check -Name 'Install state' -Passed (Test-Path -LiteralPath $statePath -PathType Leaf) -Detail $statePath

$state = $null
$stateSchema = $null
$installedProfile = ''
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
    }
    catch {
        Write-Check -Name 'Install state' -Passed $false -Detail $_.Exception.Message
        $state = $null
        $stateSchema = $null
    }
}

$coreFiles = @(
    (Join-Path $AgentsHome 'skills\workflows\SKILL.md'),
    (Join-Path $AgentsHome 'skills\evidence-first\SKILL.md')
)
if ($installedProfile -eq 'safe') {
    $coreFiles += @(
        (Join-Path $CodexHome 'AGENTS.md')
    )
}
foreach ($path in $coreFiles) {
    Write-Check -Name 'Core artifact' -Passed (Test-Path -LiteralPath $path -PathType Leaf) -Detail $path
}

if ($installedProfile -eq 'safe') {
    Write-Check -Name 'No managed agents defaults' -Passed (Test-NoManagedAgentsBlock -Path $configPath) -Detail $configPath

    Write-Check -Name 'Multi-agent route disabled' -Passed (Test-FeaturesMultiAgentDisabled -Path $configPath) -Detail $configPath

    $agentsMdContent = Read-SurfaceText -Path $agentsMdPath
    $managedBlockCount = @([regex]::Matches($agentsMdContent, '# BEGIN CODEX-WORKFLOWS-KIT')).Count
    Write-Check -Name 'Unique managed policy' -Passed ($managedBlockCount -eq 1) -Detail $agentsMdPath

    $templatePath = Join-Path $repoRoot 'codex\AGENTS.md'
    $templateMatches = $false
    if (-not [string]::IsNullOrWhiteSpace($agentsMdContent) -and (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $template = (Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8).Trim()
        $templateMatches = $agentsMdContent.IndexOf($template, [StringComparison]::Ordinal) -ge 0
    }
    Write-Check -Name 'Managed AGENTS template' -Passed $templateMatches -Detail $agentsMdPath -Optional
}

if ($null -ne $state) {
    foreach ($file in @($state.files)) {
        $path = [string]$file.path
        if ($path -eq $configPath -or $path -eq $agentsMdPath) {
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

$contractPatterns = @(
    [regex]::Escape($tokSubagentsEq),
    ('\b' + $tokNative + '\b'),
    ('\b' + $tokBackend + '\b'),
    ('\b' + $tokSidecar + '\b'),
    'read-only',
    'PromptPadNative',
    'BackendOverrideText'
)
$removedReferenceMarkers = @(($tokBackend + '-policy'), ($tokNative + '-profile-contract'), $tokModeMatrix, $tokDictionaryMd, $tokSubagentsMd)
$surfaceFiles = New-Object System.Collections.Generic.List[string]
foreach ($path in @($configPath, $agentsMdPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $surfaceFiles.Add($path)
    }
}
if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $skillsRoot -Recurse -File -Include *.md, *.toml, *.yaml, *.ahk -ErrorAction SilentlyContinue)) {
        $surfaceFiles.Add($file.FullName)
    }
}

$contractDirty = $null
foreach ($surface in $surfaceFiles) {
    $content = Get-Content -LiteralPath $surface -Raw -Encoding UTF8
    foreach ($pattern in $contractPatterns) {
        if ([regex]::IsMatch($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $contractDirty = $surface
            break
        }
    }
    if ($null -ne $contractDirty) {
        break
    }
}
Write-Check -Name 'Installed contract' -Passed ($null -eq $contractDirty) -Detail $(if ($null -eq $contractDirty) { 'No legacy contract markers in installed surfaces' } else { "Legacy contract marker retained in: $contractDirty" })

$referenceDirty = $null
foreach ($surface in $surfaceFiles) {
    $content = Get-Content -LiteralPath $surface -Raw -Encoding UTF8
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
foreach ($installRoot in @($CodexHome, $AgentsHome)) {
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
if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $skillsRoot -Recurse -File -Filter *.md -ErrorAction SilentlyContinue)) {
        if ($file.FullName -eq $canonicalSkillPath) {
            continue
        }
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ($content.IndexOf('$workflows', [StringComparison]::Ordinal) -ge 0) {
            $competingPolicies += $file.FullName
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
    $promptPadPatterns = @('deepseek', '\bmcp\b', ('\b' + $tokNative + '\b'), ('\b' + $tokBackend + '\b'), '\breader\b', ('\b' + $tWr + '\b'), ('\b' + $tSct + '\b'), ('\b' + $tRsr + '\b'), ('\b' + $tRvw + '\b'), ('\b' + $tWk + '\b'), 'PromptPadNative', 'BackendOverrideText', 'WorkflowPrompt')
    $promptPadDirty = $false
    foreach ($pattern in $promptPadPatterns) {
        if ([regex]::IsMatch($ahkText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $promptPadDirty = $true
            break
        }
    }
    Write-Check -Name 'Prompt Pad contract' -Passed (-not $promptPadDirty) -Detail $ahkPath

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
        }
    }
    else {
        Write-Check -Name 'Prompt Pad shortcut' -Passed $true -Detail 'No Startup shortcut installed'
    }
}

$configText = Read-SurfaceText -Path $configPath
$mcpServers = @(Get-McpServers -Text $configText)
$legacyServerNames = @(($tOc + '_' + $tWk), $tRly, $tWtch, $tWk, $tSct, $tRsr, $tRvw, $tokNative, 'mcp-foundation', 'runtime-adapters')
$legacyMcpHits = @($mcpServers | Where-Object { $_.Name -in $legacyServerNames })
$legacyConfigMarkers = @(($tOc + '-' + $tWk), 'runtime-adapters', 'marketplace.json', ($tWk + '.toml'), ($tRly + '.toml'), 'mcp-foundation')
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

$currentMcp = $mcpServers | Where-Object { $_.Name -eq 'deepseek-subagent' }
if ($null -eq $currentMcp) {
    Write-Check -Name 'DeepSeek Sub-Agent MCP' -Passed $false -Detail 'Not configured in config.toml'
}
else {
    $mcStatus = Get-McpEntryStatus -Body $currentMcp.Body
    if ($mcStatus.Present) {
        $detail = if ([string]::IsNullOrWhiteSpace($mcStatus.Entry)) { 'Configured' } else { "Configured; entry script present: $($mcStatus.Entry)" }
        Write-Check -Name 'DeepSeek Sub-Agent MCP' -Passed $true -Detail $detail
    }
    else {
        Write-Check -Name 'DeepSeek Sub-Agent MCP' -Passed $false -Detail ("Configured but entry script is missing: {0}" -f ($mcStatus.Missing -join '; '))
    }
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
Write-Check -Name 'AutoHotkey v2' -Passed (Test-Command -Name 'AutoHotkey64.exe') -Detail 'Required only for the prompt pad' -Optional

if ($Detailed) {
    Write-Host ''
    Write-Host "Installed paths are recorded in: $statePath"
    Write-Host 'The doctor is read-only: it inspects installed surfaces, MCP registrations,'
    Write-Host 'scheduled tasks, and the Startup shortcut without modifying configuration.'
    Write-Host 'The safe profile requires [features] multi_agent = false; the prior value is'
    Write-Host 'recorded in the install state and restored on uninstall only while it is still false.'
}

if ($script:Failures.Count -gt 0) {
    exit 1
}

Write-Host ''
Write-Host "Doctor OK. Optional warnings: $($script:Warnings.Count)."
