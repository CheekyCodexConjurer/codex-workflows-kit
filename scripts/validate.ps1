[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [switch]$SkipInstalled
)

. (Join-Path $PSScriptRoot 'native-profile-contract.ps1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$codexHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($CodexHome)) { $defaultCodexHome } else { $CodexHome }))
$agentsHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($AgentsHome)) { $defaultAgentsHome } else { $AgentsHome }))

function Read-RequiredText {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Needles
    )

    foreach ($needle in $Needles) {
        if ($Text.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            throw "$Label is missing required text: $needle"
        }
    }
}

function Assert-CompletionPolicy {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $policyDeclaration = 'completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }'
    $policyDeclarations = @([regex]::Matches($normalized, 'completion_policy\s*=\s*\{'))
    if ($policyDeclarations.Count -ne 1 -or $normalized.IndexOf($policyDeclaration, [StringComparison]::Ordinal) -lt 0) {
        throw "$Label is missing the unique normative completion policy declaration"
    }

    $requiredPatterns = @(
        '(?i)for every required sidecar,? the parent must wait for a `?final response`? before `?synthesis or advancement`?',
        '(?i)while a sidecar is `?running`?,? do not send an `?interruptive follow-up`? or `?replace`? it',
        '(?i)`?interrupted`?,? `?errored`?,? `?timed out`?,? or `?missing final response`? means unavailable: keep `?sidecar-gate`? `?open/BLOCKED`?; do not use a `?silent fallback`?'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label has an incomplete or incorrectly ordered completion policy: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|has permission to|is permitted to|is allowed to|is free to)\b\s+(?!not\b|never\b)[^.;]*\b(?:interrupt|cancel|terminate|stop)\w*\b',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|has permission to|is permitted to|is allowed to|is free to)\b\s+(?!not\b|never\b)[^.;]*\b(?:replace|substitute|switch|delegate|assign)\b',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|has permission to|is permitted to|is allowed to|is free to)\b\s+(?!not\b|never\b)[^.;]*\b(?:use|allow|permit|select|choose|switch to|fall back|fallback|backup|alternate worker|backup worker|another worker|another agent)\b',
        '(?i)(?:synthesis|advancement|synthesize|advance|proceed|continue)[^.;]*(?:before|prior to|without|in the absence of)[^.;]*(?:final response|response|reply|answer|return)'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains a forbidden completion-policy exception: $pattern"
        }
    }
}

function Assert-ManagedAgentDefaults {
    param([Parameter(Mandatory)][string]$Path)

    $text = Read-RequiredText $Path
    $allAgentsHeaders = @([regex]::Matches($text, '(?im)^[ \t]*\[\[?[ \t]*(?:agents|"agents"|''agents'')[ \t]*\]\]?[ \t]*(?:#.*)?$'))
    if ($allAgentsHeaders.Count -ne 1) {
        throw "Configuration has a duplicated or missing [agents] table: $Path"
    }

    $blockPattern = '(?ms)^# BEGIN CODEX-WORKFLOWS-KIT: agents\r?\n(?<block>.*?)^# END CODEX-WORKFLOWS-KIT: agents\r?$'
    $blocks = @([regex]::Matches($text, $blockPattern))
    if ($blocks.Count -ne 1) {
        throw "Managed agents configuration block is missing or duplicated: $Path"
    }

    $block = $blocks[0].Groups['block'].Value
    $headers = @([regex]::Matches($block, '(?m)^[ \t]*\[\[?[^\r\n\]]+\]\]?[ \t]*(?:#.*)?$'))
    if ($headers.Count -ne 1 -or $headers[0].Value.Trim() -notmatch '^\[agents\][ \t]*(?:#.*)?$') {
        throw "Managed agents configuration has an invalid or non-unique [agents] section: $Path"
    }

    $requiredSettings = [ordered]@{
        default_subagent_model = 'gpt-5.6-luna'
        default_subagent_reasoning_effort = 'high'
    }
    foreach ($setting in $requiredSettings.GetEnumerator()) {
        $pattern = '(?m)^\s*' + [regex]::Escape([string]$setting.Key) + '\s*=\s*"([^\"]+)"\s*$'
        $matches = @([regex]::Matches($block, $pattern))
        if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne [string]$setting.Value) {
            throw "Managed agents configuration has an invalid $($setting.Key): $Path"
        }
    }

    if ($block -match '(?m)^\s*default_subagent_reasoning_effort\s*=\s*"max"\s*$') {
        throw "Managed agents configuration retains max reasoning: $Path"
    }
}

function Assert-Profile {
    param([Parameter(Mandatory)][string]$Path)

    Assert-NativeProfileContract -Path $Path
}

function Assert-SameFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) {
        throw "Installed $Label is missing: $Installed"
    }

    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
        throw "Installed $Label is stale: $Installed"
    }
}

function Assert-MirrorTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Label
    )

    $sourceFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName)
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        Assert-SameFile -Source $file.FullName -Installed (Join-Path $Installed $relative) -Label $Label
    }

    $expected = @{}
    foreach ($file in $sourceFiles) {
        $expected[$file.FullName.Substring($Source.Length).TrimStart('\')] = $true
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Installed -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($Installed.Length).TrimStart('\')
        if (-not $expected.ContainsKey($relative)) {
            throw "Installed $Label has an unexpected file: $file"
        }
    }
}

function Assert-InstalledState {
    param([Parameter(Mandatory)][object]$State)

    $required = @('schemaVersion', 'product', 'files')
    foreach ($property in $required) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) {
            throw "Installed state is missing required property: $property"
        }
    }

    $schemaText = [string]$State.schemaVersion
    if ($schemaText -notin @('1', '2', '3')) {
        throw "Installed state has an unsupported schema: $schemaText"
    }
    $schema = [int]$schemaText
    if ([string]$State.product -ne 'codex-workflows-kit') {
        throw 'Installed state belongs to a different product.'
    }
    if ($null -eq $State.files -or -not ($State.files -is [System.Array])) {
        throw 'Installed state files must be an array.'
    }

    $entries = @($State.files)
    if ($schema -eq 3) {
        if (-not ($State.PSObject.Properties.Name -contains 'pendingFiles') -or $null -eq $State.pendingFiles -or -not ($State.pendingFiles -is [System.Array])) {
            throw 'Schema 3 installed state is missing pendingFiles.'
        }
        $entries += @($State.pendingFiles)
    }
    elseif ($State.PSObject.Properties.Name -contains 'pendingFiles') {
        throw 'Only schema 3 installed state may contain pendingFiles.'
    }

    $seenPaths = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry -or -not ($entry.PSObject.Properties.Name -contains 'path') -or -not ($entry.PSObject.Properties.Name -contains 'sha256')) {
            throw 'Installed state contains an invalid file entry.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.path) -or -not (Test-FullyQualifiedPath -Path ([string]$entry.path)) -or [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Installed state contains an invalid file path or hash.'
        }
        $fullPath = [IO.Path]::GetFullPath([string]$entry.path)
        if ($seenPaths.ContainsKey($fullPath)) {
            throw "Installed state contains a duplicate file entry: $fullPath"
        }
        $seenPaths[$fullPath] = $true
    }

    if ($schema -eq 3) {
        foreach ($entry in @($State.pendingFiles)) {
            if (-not ($entry.PSObject.Properties.Name -contains 'reason') -or [string]$entry.reason -notin @('modified', 'outside-destinations', 'unverified')) {
                throw 'Schema 3 installed state contains a pending file without a reason.'
            }
        }
    }
}

function Test-FullyQualifiedPath {
    param([Parameter(Mandatory)][string]$Path)

    return $Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]+\\[^\\]+\\'
}

$workflowSource = Join-Path $repo 'skills\workflows'
$evidenceSource = Join-Path $repo 'skills\evidence-first'
$agentsSource = Join-Path $repo 'agents'
$agentsMd = Join-Path $repo 'codex\AGENTS.md'
$skill = Read-RequiredText (Join-Path $workflowSource 'SKILL.md')
$agentsText = Read-RequiredText $agentsMd
$matrix = Read-RequiredText (Join-Path $workflowSource 'references\mode-matrix.md')
$backendPolicy = Read-RequiredText (Join-Path $workflowSource 'references\backend-policy.md')
$nativeRef = Read-RequiredText (Join-Path $workflowSource 'references\subagents.md')
$installer = Read-RequiredText (Join-Path $repo 'scripts\install.ps1')
$promptPad = Read-RequiredText (Join-Path $repo 'ahk\codex_prompt_pad.ahk')

$allModes = @(
    'PLAN.AUTO', 'PLAN', 'P.DEEP', 'RESEARCH.DEEP', 'IMPL.AUTO', 'IMPL',
    'IMPL.PHASE', 'DELIVER.AUTO', 'REVIEW', 'COMMIT', 'BUG.INV', 'BUG.FIX',
    'DEBUG', 'REWORK', 'R.A.F.V', 'TN.SKILL'
)
foreach ($mode in $allModes) {
    Assert-Contains -Label 'codex AGENTS.md' -Text $agentsText -Needles @($mode)
    Assert-Contains -Label 'mode matrix' -Text $matrix -Needles @($mode)
}

$matrixBackendPatterns = @(
    'subagents=',
    '(?i)\bmcp\b',
    '(?i)\bdeepseek\b',
    '(?i)\bnative\b'
)
foreach ($pattern in $matrixBackendPatterns) {
    if ([regex]::IsMatch($matrix, $pattern)) {
        throw "Mode matrix is not backend-neutral: $pattern"
    }
}

Assert-Contains -Label 'workflow skill' -Text $skill -Needles @(
    'name: workflows',
    'AGENTS.md',
    'backend-policy'
)
Assert-Contains -Label 'codex AGENTS.md' -Text $agentsText -Needles @(
    'backend-policy'
)
Assert-Contains -Label 'backend policy' -Text $backendPolicy -Needles @(
    'subagents=mcp',
    'subagents=native',
    'default local backend',
    'opt-in',
    'lifecycle',
    'pending obligation',
    'delegation audit',
    'deepseek_spawn',
    'deepseek_continue',
    'deepseek_follow',
    'deepseek_consult',
    'deepseek_abort',
    'deepseek_close',
    'deepseek_recover_result',
    'BUG.INV',
    'DEBUG',
    'no-edit',
    'never change files',
    'DELIVER.AUTO',
    'never commit',
    'COMMIT',
    'Git index',
    'never push',
    'final response',
    'interrupted',
    'errored',
    'timed out',
    'sidecar-gate'
)
Assert-Contains -Label 'native sub-agent reference' -Text $nativeRef -Needles @(
    'subagents=native',
    'opt-in',
    'backend-policy'
)
Assert-Contains -Label 'installer' -Text $installer -Needles @(
    'default_subagent_model = "gpt-5.6-luna"',
    'default_subagent_reasoning_effort = "high"'
)
Assert-CompletionPolicy -Label 'backend policy' -Text $backendPolicy

$expectedProfiles = @('scout.toml', 'researcher.toml', 'reviewer.toml')
$actualProfiles = @(Get-ChildItem -LiteralPath $agentsSource -Recurse -File | ForEach-Object {
    $_.FullName.Substring($agentsSource.Length).TrimStart('\')
})
if (@($actualProfiles | Where-Object { $_ -notin $expectedProfiles }).Count -gt 0) {
    throw "Unexpected native profile source: $($actualProfiles -join ', ')"
}
foreach ($profileName in $expectedProfiles) {
    Assert-Profile (Join-Path $agentsSource $profileName)
}

$promptBindings = @([regex]::Matches($promptPad, '(?m)^[^;\r\n]+::PastePrompt\("([^\"]+)"\)'))
if ($promptBindings.Count -eq 0) {
    throw 'Prompt pad has no workflow bindings.'
}
foreach ($binding in $promptBindings) {
    if (-not $binding.Groups[1].Value.StartsWith('$workflows mode=', [StringComparison]::Ordinal)) {
        throw 'Prompt pad contains a binding outside the workflow contract.'
    }
}
if ($promptPad -match '(?m)^![A-Za-z0-9]+::') {
    throw 'Prompt pad contains a non-workflow hotkey binding.'
}

$forbidden = @(
    (-join [char[]]@(111, 112, 101, 110, 99, 111, 100, 101)),
    (-join [char[]]@(114, 101, 108, 97, 121)),
    (-join [char[]]@(119, 97, 116, 99, 104, 101, 114)),
    (-join [char[]]@(97, 110, 116, 105, 103, 114, 97, 118, 105, 116, 121))
)
foreach ($relativePath in @(git -C $repo ls-files)) {
    $path = Join-Path $repo $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($token in $forbidden) {
        if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Unsupported retained token in $relativePath"
        }
    }
}

if (-not $SkipInstalled) {
    $statePath = Join-Path $codexHome 'codex-workflows-kit\install-state.json'
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-InstalledState -State $state
    if ([string]$state.profile -notin @('minimal', 'safe')) {
        throw "Installed state has an unsupported profile: $statePath"
    }

    $workflowsDest = Join-Path $agentsHome 'skills\workflows'
    $evidenceDest = Join-Path $agentsHome 'skills\evidence-first'
    Assert-MirrorTree -Source $workflowSource -Installed $workflowsDest -Label 'workflows skill'
    Assert-MirrorTree -Source $evidenceSource -Installed $evidenceDest -Label 'evidence skill'

    if ([string]$state.profile -eq 'safe') {
        Assert-ManagedAgentDefaults -Path (Join-Path $codexHome 'config.toml')

        foreach ($profileName in $expectedProfiles) {
            Assert-SameFile -Source (Join-Path $agentsSource $profileName) -Installed (Join-Path $codexHome (Join-Path 'agents' $profileName)) -Label "native profile $profileName"
        }

        $installedAgents = Read-RequiredText (Join-Path $codexHome 'AGENTS.md')
        if ($installedAgents.IndexOf($agentsText.Trim(), [StringComparison]::Ordinal) -lt 0) {
            throw 'Installed AGENTS.md does not contain the current managed contract.'
        }
    }
}

Write-Host 'Validation OK.'
