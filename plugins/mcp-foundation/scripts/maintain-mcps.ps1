[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Repair')]
    [string]$Mode = 'Audit',

    [ValidateRange(0, 720)]
    [int]$MaxAgeHours = 24,

    [string]$RepositoryRoot,

    [switch]$Hook,

    [switch]$InstallScheduledTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$MarketplaceName = 'codex-workflows-local'
$PluginName = 'mcp-foundation'
$PluginSelector = "$PluginName@$MarketplaceName"
$RequiredMcpServers = @('codegraph', 'context7', 'openaiDeveloperDocs')
$MaintenanceRoot = Join-Path $env:USERPROFILE '.codex\maintenance'
$LogRoot = Join-Path $MaintenanceRoot 'logs'
$StatePath = Join-Path $MaintenanceRoot 'mcp-foundation-state.json'
$ConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'

New-Item -ItemType Directory -Force -Path $MaintenanceRoot, $LogRoot | Out-Null
$LogPath = Join-Path $LogRoot ("mcp-foundation-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

$script:ConfigBackedUp = $false
$script:Changed = $false
$script:Issues = New-Object System.Collections.Generic.List[string]
$script:CodexCli = $null
$script:CodeGraphVersion = $null

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Add-Issue {
    param([Parameter(Mandatory)][string]$Message)

    if (-not $script:Issues.Contains($Message)) {
        $script:Issues.Add($Message)
    }
    Write-Log "Issue: $Message"
}

function Get-State {
    $state = @{}
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $state
    }

    try {
        $parsed = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        foreach ($property in $parsed.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
    }
    catch {
        Write-Log "Ignoring unreadable state file: $($_.Exception.Message)"
    }

    return $state
}

function Save-State {
    param([Parameter(Mandatory)][hashtable]$State)

    $tempPath = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -Force -LiteralPath $tempPath -Destination $StatePath
}

function Test-AuditFresh {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Hours
    )

    if ($Hours -eq 0 -or -not $State.ContainsKey('lastAuditUtc')) {
        return $false
    }

    $lastAudit = [datetime]::MinValue
    if (-not [datetime]::TryParse(
        [string]$State['lastAuditUtc'],
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$lastAudit
    )) {
        return $false
    }

    return ([datetime]::UtcNow - $lastAudit.ToUniversalTime()).TotalHours -lt $Hours
}

function Resolve-RepositoryRoot {
    param(
        [string]$RequestedRoot,
        [Parameter(Mandatory)][hashtable]$State
    )

    if ($RequestedRoot) {
        $resolved = [IO.Path]::GetFullPath($RequestedRoot)
        if (Test-Path -LiteralPath (Join-Path $resolved '.agents\plugins\marketplace.json')) {
            return $resolved
        }
        throw "Repository root does not contain .agents\plugins\marketplace.json: $resolved"
    }

    if ($State.ContainsKey('repositoryRoot')) {
        $stored = [string]$State['repositoryRoot']
        if ($stored -and (Test-Path -LiteralPath (Join-Path $stored '.agents\plugins\marketplace.json'))) {
            return [IO.Path]::GetFullPath($stored)
        }
    }

    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $pluginsRoot = Split-Path -Parent $pluginRoot
    if ((Split-Path -Leaf $pluginsRoot) -eq 'plugins') {
        $candidate = Split-Path -Parent $pluginsRoot
        if (Test-Path -LiteralPath (Join-Path $candidate '.agents\plugins\marketplace.json')) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Get-CodexAppCli {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:CODEX_CLI_PATH) {
        $candidates.Add($env:CODEX_CLI_PATH)
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $configText = Get-Content -LiteralPath $ConfigPath -Raw
        $match = [regex]::Match(
            $configText,
            '(?m)^\s*CODEX_CLI_PATH\s*=\s*[''"]([^''"]+)[''"]\s*$'
        )
        if ($match.Success) {
            $candidates.Add($match.Groups[1].Value)
        }
    }

    $appBinRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $appBinRoot) {
        Get-ChildItem -LiteralPath $appBinRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $candidate = Join-Path $_.FullName 'codex.exe'
                if (Test-Path -LiteralPath $candidate) {
                    $candidates.Add($candidate)
                }
            }
    }

    Get-Command codex -All -ErrorAction SilentlyContinue |
        ForEach-Object { $candidates.Add($_.Source) }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        try {
            $version = (& $candidate --version 2>$null | Select-Object -First 1)
            if ($version) {
                Write-Log "Using Codex CLI: $candidate ($version)"
                return $candidate
            }
        }
        catch {
            Write-Log "Rejected Codex CLI candidate $candidate`: $($_.Exception.Message)"
        }
    }

    return $null
}

function Invoke-Codex {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not $script:CodexCli) {
        throw 'Codex App CLI is unavailable.'
    }

    $output = @(& $script:CodexCli @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Codex command failed ($LASTEXITCODE): $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }

    return $output
}

function Backup-CodexConfig {
    if ($script:ConfigBackedUp -or -not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    $backupRoot = Join-Path $env:USERPROFILE '.codex\backups'
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $backupPath = Join-Path $backupRoot (
        'config.toml.{0}.mcp-foundation.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath
    $script:ConfigBackedUp = $true
    Write-Log "Backed up Codex config to $backupPath"
}

function Get-CodeGraphMcpProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -and
                $_.CommandLine -match '(?i)codegraph' -and
                $_.CommandLine -match '(?i)serve\s+--mcp'
            }
    )
}

function Get-InstalledCodeGraphVersion {
    $command = Get-Command codegraph -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }

    $version = (& codegraph --version 2>$null | Select-Object -First 1)
    if (-not $version) {
        return $null
    }

    return ([string]$version).Trim()
}

function Get-NpmCommand {
    foreach ($name in 'npm.cmd', 'npm') {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    return $null
}

function Ensure-CodeGraph {
    param([Parameter(Mandatory)][string]$Operation)

    $installed = Get-InstalledCodeGraphVersion
    $script:CodeGraphVersion = $installed

    if ($Operation -eq 'Audit') {
        if (-not $installed) {
            Add-Issue 'CodeGraph CLI is missing.'
        }
        else {
            Write-Log "CodeGraph installed: $installed"
        }
        return
    }

    $npm = Get-NpmCommand
    if (-not $npm) {
        if ($installed) {
            Add-Issue 'npm is unavailable; CodeGraph update check was skipped.'
            return
        }
        throw 'npm is required to install CodeGraph.'
    }

    $latestOutput = @(& $npm view '@colbymchenry/codegraph' version 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not $latestOutput) {
        if ($installed) {
            Add-Issue 'Could not resolve the latest CodeGraph version; current installation was preserved.'
            return
        }
        throw "Could not resolve the latest CodeGraph version: $($latestOutput -join ' ')"
    }

    $latest = ([string]($latestOutput | Select-Object -First 1)).Trim()
    Write-Log "CodeGraph installed: $(if ($installed) { $installed } else { 'missing' }); latest: $latest"

    if ($installed -eq $latest) {
        $script:CodeGraphVersion = $installed
        return
    }

    $activeProcesses = Get-CodeGraphMcpProcesses
    if ($activeProcesses.Count -gt 0) {
        Add-Issue "CodeGraph update to $latest was deferred because $($activeProcesses.Count) MCP process(es) are active."
        return
    }

    Write-Log "Installing @colbymchenry/codegraph@$latest globally."
    $installOutput = @(& $npm install -g "@colbymchenry/codegraph@$latest" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "CodeGraph installation failed: $($installOutput -join [Environment]::NewLine)"
    }

    $after = Get-InstalledCodeGraphVersion
    if ($after -ne $latest) {
        throw "CodeGraph version mismatch after installation. Expected $latest, got $after."
    }

    $script:CodeGraphVersion = $after
    $script:Changed = $true
    Write-Log "CodeGraph updated to $after"
}

function Get-PluginRoot {
    param([string]$RepoRoot)

    $localPluginRoot = Split-Path -Parent $PSScriptRoot
    if (Test-Path -LiteralPath (Join-Path $localPluginRoot '.codex-plugin\plugin.json')) {
        return $localPluginRoot
    }

    if ($RepoRoot) {
        $repoPluginRoot = Join-Path $RepoRoot 'plugins\mcp-foundation'
        if (Test-Path -LiteralPath (Join-Path $repoPluginRoot '.codex-plugin\plugin.json')) {
            return $repoPluginRoot
        }
    }

    return $null
}

function Test-PluginDefinition {
    param([string]$RepoRoot)

    $pluginRoot = Get-PluginRoot -RepoRoot $RepoRoot
    if (-not $pluginRoot) {
        Add-Issue 'MCP Foundation plugin files are unavailable.'
        return $null
    }

    try {
        $manifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw |
            ConvertFrom-Json
        $mcp = Get-Content -LiteralPath (Join-Path $pluginRoot '.mcp.json') -Raw |
            ConvertFrom-Json
    }
    catch {
        Add-Issue "MCP Foundation plugin definition is invalid: $($_.Exception.Message)"
        return $null
    }

    if ($manifest.name -ne $PluginName) {
        Add-Issue "Plugin manifest name must be $PluginName."
    }

    $serverNames = @($mcp.mcpServers.PSObject.Properties.Name)
    foreach ($server in $RequiredMcpServers) {
        if ($serverNames -notcontains $server) {
            Add-Issue "Plugin definition is missing MCP server: $server."
        }
    }

    return [pscustomobject]@{
        Root = $pluginRoot
        Version = [string]$manifest.version
    }
}

function Get-MarketplaceDefinition {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $marketplacePath = Join-Path $RepoRoot '.agents\plugins\marketplace.json'
    $marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
    if ($marketplace.name -ne $MarketplaceName) {
        throw "Marketplace name mismatch. Expected $MarketplaceName, got $($marketplace.name)."
    }

    $entry = @($marketplace.plugins | Where-Object { $_.name -eq $PluginName })
    if ($entry.Count -ne 1) {
        throw "Marketplace must contain exactly one $PluginName entry."
    }

    return $marketplace
}

function Test-PluginEnabled {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $false
    }

    $configText = Get-Content -LiteralPath $ConfigPath -Raw
    $sectionPattern = '(?ms)^\[plugins\."' +
        [regex]::Escape($PluginSelector) +
        '"\]\s*(?<body>.*?)(?=^\[|\z)'
    $section = [regex]::Match($configText, $sectionPattern)
    if (-not $section.Success) {
        return $false
    }

    return $section.Groups['body'].Value -match '(?m)^\s*enabled\s*=\s*true\s*$'
}

function Test-McpRegistration {
    if (-not $script:CodexCli) {
        return
    }

    $mcpLines = @(Invoke-Codex -Arguments @('mcp', 'list'))
    foreach ($server in $RequiredMcpServers) {
        $serverLine = @(
            $mcpLines |
                Where-Object {
                    ([string]$_).TrimStart().StartsWith($server, [StringComparison]::OrdinalIgnoreCase)
                }
        )

        if ($serverLine.Count -eq 0 -or ([string]$serverLine[0]) -notmatch '\benabled\b') {
            Add-Issue "MCP server is not enabled: $server."
        }
    }

    $context7Line = @(
        $mcpLines |
            Where-Object {
                ([string]$_).TrimStart().StartsWith('context7', [StringComparison]::OrdinalIgnoreCase)
            }
    )
    if ($context7Line.Count -gt 0 -and ([string]$context7Line[0]) -match 'Not logged in') {
        Add-Issue 'Context7 requires one-time OAuth authentication in Codex Settings > MCP servers.'
    }
}

function Ensure-MarketplaceAndPlugin {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PluginVersion
    )

    Get-MarketplaceDefinition -RepoRoot $RepoRoot | Out-Null

    $marketplaceLines = @(Invoke-Codex -Arguments @('plugin', 'marketplace', 'list'))
    $nameLine = @(
        $marketplaceLines |
            Where-Object { ([string]$_).TrimStart().StartsWith($MarketplaceName, [StringComparison]::OrdinalIgnoreCase) }
    )

    if ($nameLine.Count -gt 0) {
        $matchingRoot = @(
            $nameLine |
                Where-Object { ([string]$_).IndexOf($RepoRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        )
        if ($matchingRoot.Count -eq 0) {
            throw "Marketplace $MarketplaceName is already registered from another root."
        }
    }
    else {
        Backup-CodexConfig
        Invoke-Codex -Arguments @('plugin', 'marketplace', 'add', $RepoRoot, '--json') | Out-Null
        $script:Changed = $true
        Write-Log "Registered marketplace $MarketplaceName from $RepoRoot"
    }

    $pluginLines = @(Invoke-Codex -Arguments @('plugin', 'list'))
    $installedLine = @(
        $pluginLines |
            Where-Object {
                ([string]$_).TrimStart().StartsWith($PluginSelector, [StringComparison]::OrdinalIgnoreCase) -and
                ([string]$_) -match 'installed,\s+enabled'
            }
    )

    $versionCurrent = $false
    if ($installedLine.Count -gt 0) {
        $versionCurrent = ([string]$installedLine[0]) -match (
            'installed,\s+enabled\s+' + [regex]::Escape($PluginVersion) + '(\s|$)'
        )
    }

    if (-not $versionCurrent -or -not (Test-PluginEnabled)) {
        Backup-CodexConfig
        Invoke-Codex -Arguments @('plugin', 'add', $PluginSelector, '--json') | Out-Null
        $script:Changed = $true
        Write-Log "Installed or refreshed plugin $PluginSelector at version $PluginVersion"
    }

    if (-not (Test-PluginEnabled)) {
        throw "Plugin $PluginSelector is not enabled after installation."
    }
}

function Ensure-ScheduledMaintenance {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    $description = 'Maintains the allowlisted Codex MCP foundation without terminating active MCP sessions.'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Repair -RepositoryRoot "{1}"' -f (
        [IO.Path]::GetFullPath($ScriptPath),
        [IO.Path]::GetFullPath($RepoRoot)
    )
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

    $legacyTask = Get-ScheduledTask -TaskName 'CodeGraph Auto Update' -ErrorAction SilentlyContinue
    if ($legacyTask) {
        Set-ScheduledTask -TaskName 'CodeGraph Auto Update' -Action $action | Out-Null
        Write-Log 'Updated existing CodeGraph Auto Update task to use MCP Foundation maintenance.'
        return 'CodeGraph Auto Update'
    }

    $taskName = 'Codex MCP Foundation Maintenance'
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
    }
    else {
        $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Monday -At 9:30am
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description $description |
            Out-Null
    }

    Write-Log "Scheduled weekly maintenance task: $taskName"
    return $taskName
}

function Invoke-Audit {
    param(
        [string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$State
    )

    if (-not $script:CodexCli) {
        $script:CodexCli = Get-CodexAppCli
    }
    if (-not $script:CodexCli) {
        Add-Issue 'Codex App CLI is unavailable.'
    }

    Ensure-CodeGraph -Operation 'Audit'
    Test-PluginDefinition -RepoRoot $RepoRoot | Out-Null

    if ($script:CodexCli -and -not (Test-PluginEnabled)) {
        Add-Issue "Plugin $PluginSelector is not enabled in Codex."
    }

    if ($script:CodexCli -and (Test-PluginEnabled)) {
        Test-McpRegistration
    }

    $State['lastAuditUtc'] = [datetime]::UtcNow.ToString('o')
    $State['issues'] = @($script:Issues)
    $State['codeGraphVersion'] = $script:CodeGraphVersion
    if ($RepoRoot) {
        $State['repositoryRoot'] = $RepoRoot
    }
}

function Write-HookResult {
    param([Parameter(Mandatory)][string]$Message)

    $payload = @{
        continue = $true
        systemMessage = $Message
        hookSpecificOutput = @{
            hookEventName = 'SessionStart'
            additionalContext = (
                'The allowlisted MCP foundation is degraded. Run ' +
                '~/.codex/maintenance/maintain-mcps.ps1 -Mode Repair once if one of these MCPs is needed, ' +
                'then restart Codex or open a new task when registration changes.'
            )
        }
    }
    $payload | ConvertTo-Json -Depth 4 -Compress
}

$state = Get-State
$resolvedRepositoryRoot = $null

try {
    Write-Log "Starting MCP Foundation maintenance. Mode=$Mode"
    $resolvedRepositoryRoot = Resolve-RepositoryRoot -RequestedRoot $RepositoryRoot -State $state

    if ($Mode -eq 'Audit' -and (Test-AuditFresh -State $state -Hours $MaxAgeHours)) {
        Write-Log "Audit skipped; state is newer than $MaxAgeHours hour(s)."
        if ($Hook -and $state.ContainsKey('issues') -and @($state['issues']).Count -gt 0) {
            Write-HookResult -Message ("MCP Foundation: " + (@($state['issues']) -join ' '))
        }
        exit 0
    }

    if ($Mode -eq 'Repair') {
        if (-not $resolvedRepositoryRoot) {
            throw 'Repository root is required to repair the MCP Foundation plugin installation.'
        }

        $script:CodexCli = Get-CodexAppCli
        if (-not $script:CodexCli) {
            throw 'Codex App CLI is unavailable.'
        }

        $plugin = Test-PluginDefinition -RepoRoot $resolvedRepositoryRoot
        if (-not $plugin -or $script:Issues.Count -gt 0) {
            throw "MCP Foundation plugin definition failed validation: $($script:Issues -join '; ')"
        }

        Ensure-CodeGraph -Operation 'Repair'
        Ensure-MarketplaceAndPlugin -RepoRoot $resolvedRepositoryRoot -PluginVersion $plugin.Version

        if ($InstallScheduledTask) {
            $taskName = Ensure-ScheduledMaintenance -RepoRoot $resolvedRepositoryRoot -ScriptPath $PSCommandPath
            $state['scheduledTask'] = $taskName
        }

        $state['lastRepairUtc'] = [datetime]::UtcNow.ToString('o')
        $script:Issues.Clear()
    }

    Invoke-Audit -RepoRoot $resolvedRepositoryRoot -State $state
    $state['changed'] = $script:Changed
    Save-State -State $state

    if ($Hook) {
        if ($script:Issues.Count -gt 0) {
            Write-HookResult -Message ("MCP Foundation: " + ($script:Issues -join ' '))
        }
        exit 0
    }

    if ($script:Issues.Count -gt 0) {
        Write-Warning ("MCP Foundation completed with warnings: " + ($script:Issues -join ' '))
    }
    else {
        Write-Host "MCP Foundation OK. CodeGraph: $script:CodeGraphVersion; changed: $script:Changed"
    }
}
catch {
    Write-Log "Failure: $($_.Exception.Message)"

    if ($Hook) {
        Write-HookResult -Message ("MCP Foundation audit failed: " + $_.Exception.Message)
        exit 0
    }

    throw
}
