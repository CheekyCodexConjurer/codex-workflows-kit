Set-StrictMode -Version Latest

# Dev Router Module (TypeSafe/Jev Autonomous Orchestrator Router)
# Controls parent orchestrator model and reasoning effort for Codex App / CLI.
# Supports ALINHAMENTO conversations and explicit workflows with thread isolation.
# Implements real Codex Desktop App model selector dropdown integration via GPT-Adaptive.

$script:DevRouterModelCatalog = [ordered]@{
    'Luna' = [ordered]@{
        Id               = 'gpt-5.6-luna'
        Name             = 'Luna'
        Aliases          = @('gpt-5.6-luna', 'luna')
        SupportedEfforts = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh')
        Profile          = 'mechanical_low_risk'
        Description      = 'Mechanical, low-risk, explicit target, minimal ambiguity'
    }
    'Sol' = [ordered]@{
        Id               = 'gpt-5.6-sol'
        Name             = 'Sol'
        Aliases          = @('gpt-5.6-sol', 'sol')
        SupportedEfforts = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh')
        Profile          = 'investigation_synthesis_implementation'
        Description      = 'Investigation, synthesis, standard/complex implementation, debugging with context'
    }
    'Astra' = [ordered]@{
        Id               = 'gpt-6-astra'
        Name             = 'Astra'
        Aliases          = @('gpt-6-astra', 'astra')
        SupportedEfforts = @('low', 'medium', 'high', 'xhigh')
        Profile          = 'architecture_concurrency_security'
        Description      = 'Difficult architecture, concurrency, security, high impact or exceptional ambiguity'
    }
}

$script:ManualPassThroughModels = [ordered]@{
    'Terra' = [ordered]@{
        Id               = 'gpt-5.6-terra'
        Name             = 'Terra'
        Aliases          = @('gpt-5.6-terra', 'terra')
        SupportedEfforts = @('none', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        Profile          = 'balanced_coding'
        Description      = 'Balanced agentic coding model (manual selection pass-through only)'
    }
}

$script:DisallowedModels = @('gpt-5.6-terra', 'terra')
$script:AllValidEfforts = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')

function Invoke-DevRouterSynchronized {
    param(
        [Parameter(Mandatory)][string]$LockName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $mutex = $null
    $acquired = $false
    try {
        try {
            $mutex = New-Object System.Threading.Mutex($false, "Global\CodexWorkflows_$LockName")
        }
        catch {
            $mutex = New-Object System.Threading.Mutex($false, "Local\CodexWorkflows_$LockName")
        }
        try {
            $acquired = $mutex.WaitOne(5000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        return (& $ScriptBlock)
    }
    finally {
        if ($acquired -and $null -ne $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-DevRouterModelCatalog {
    return [ordered]@{
        Models           = $script:DevRouterModelCatalog
        DisallowedModels = @($script:DisallowedModels)
        AllValidEfforts  = @($script:AllValidEfforts)
    }
}

function Resolve-DevRouterModel {
    param(
        [Parameter(Mandatory)][string]$ModelNameOrId,
        [switch]$IncludeDisallowed
    )

    $raw = $ModelNameOrId.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    # If disallowed models are not explicitly included, reject immediately
    if (-not $IncludeDisallowed) {
        foreach ($disallowed in $script:DisallowedModels) {
            if ($raw -eq $disallowed -or $raw -like "*$disallowed*") {
                return $null
            }
        }
    }

    # 1. Check primary automatic routing catalog
    foreach ($key in $script:DevRouterModelCatalog.Keys) {
        $entry = $script:DevRouterModelCatalog[$key]
        if ($raw -ceq [string]$entry.Name -or $raw -ceq [string]$entry.Id) {
            return $entry
        }
        foreach ($alias in $entry.Aliases) {
            if ($raw.Equals($alias, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $entry
            }
        }
    }

    # 2. Check manual pass-through catalog if requested
    if ($IncludeDisallowed) {
        foreach ($key in $script:ManualPassThroughModels.Keys) {
            $entry = $script:ManualPassThroughModels[$key]
            if ($raw -ceq [string]$entry.Name -or $raw -ceq [string]$entry.Id) {
                return $entry
            }
            foreach ($alias in $entry.Aliases) {
                if ($raw.Equals($alias, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $entry
                }
            }
        }
    }

    return $null
}

function Test-DevRouterModelAllowed {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    # Strictly verifies model is in allowed catalog and NOT disallowed
    $resolved = Resolve-DevRouterModel -ModelNameOrId $ModelNameOrId
    return ($null -ne $resolved)
}

function Get-DevRouterModelEfforts {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    $resolved = Resolve-DevRouterModel -ModelNameOrId $ModelNameOrId -IncludeDisallowed
    if ($null -eq $resolved) {
        return @()
    }
    return @($resolved.SupportedEfforts)
}

function Test-DevRouterEffortSupported {
    param(
        [Parameter(Mandatory)][string]$ModelNameOrId,
        [Parameter(Mandatory)][string]$Effort
    )

    $efforts = Get-DevRouterModelEfforts -ModelNameOrId $ModelNameOrId
    return ($efforts -contains $Effort.Trim().ToLowerInvariant())
}

function Get-DevRouterPaths {
    param([string]$CodexHome)

    $defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $resolvedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) { $defaultCodexHome } else { $CodexHome }
    $fullCodexHome = [IO.Path]::GetFullPath($resolvedCodexHome)
    $kitDir = Join-Path $fullCodexHome 'codex-workflows-kit'

    return [pscustomobject]@{
        CodexHome   = $fullCodexHome
        KitDir      = $kitDir
        StateFile   = Join-Path $kitDir 'dev-router-state.json'
        LocksFile   = Join-Path $kitDir 'dev-router-locks.json'
        CatalogFile = Join-Path $kitDir 'model-catalog.json'
        ProxyScript = Join-Path $kitDir 'dev-router-proxy.mjs'
        ProxyPid    = Join-Path $kitDir 'dev-router-proxy.pid'
        InstallState= Join-Path $kitDir 'install-state.json'
        ConfigToml  = Join-Path $fullCodexHome 'config.toml'
    }
}

function Get-DevRouterState {
    param([string]$CodexHome)

    return Invoke-DevRouterSynchronized -LockName 'State' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome

        # 1. Primary: dev-router-state.json
        if (Test-Path -LiteralPath $paths.StateFile -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $paths.StateFile -Raw -Encoding UTF8
                $state = $raw | ConvertFrom-Json
                if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'mode' -and $state.PSObject.Properties.Name -contains 'target') {
                    return [ordered]@{
                        version   = if ($state.PSObject.Properties.Name -contains 'version') { [int]$state.version } else { 1 }
                        mode      = [string]$state.mode
                        target    = [string]$state.target
                        updatedAt = if ($state.PSObject.Properties.Name -contains 'updatedAt') { [string]$state.updatedAt } else { $null }
                    }
                }
            }
            catch {}
        }

        # 2. Secondary: check install-state.json
        if (Test-Path -LiteralPath $paths.InstallState -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $paths.InstallState -Raw -Encoding UTF8
                $istate = $raw | ConvertFrom-Json
                if ($null -ne $istate -and $istate.PSObject.Properties.Name -contains 'codexDevRouter' -and $null -ne $istate.codexDevRouter) {
                    return [ordered]@{
                        version   = if ($istate.codexDevRouter.PSObject.Properties.Name -contains 'version') { [int]$istate.codexDevRouter.version } else { 1 }
                        mode      = [string]$istate.codexDevRouter.mode
                        target    = [string]$istate.codexDevRouter.target
                        updatedAt = $null
                    }
                }
            }
            catch {}
        }

        # 3. Default initial configuration: mode=off, target=effort_only
        return [ordered]@{
            version   = 1
            mode      = 'off'
            target    = 'effort_only'
            updatedAt = $null
        }
    }
}

function Set-DevRouterState {
    param(
        [Parameter(Mandatory)][ValidateSet('off', 'shadow', 'on')][string]$Mode,
        [Parameter()][ValidateSet('effort_only', 'model_only', 'model_and_effort')][string]$Target = 'effort_only',
        [string]$CodexHome
    )

    return Invoke-DevRouterSynchronized -LockName 'State' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome

        if (-not (Test-Path -LiteralPath $paths.KitDir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($paths.KitDir)
        }

        $now = [datetime]::UtcNow.ToString('o')
        $stateObj = [ordered]@{
            version   = 1
            product   = 'codex-workflows-kit'
            component = 'dev-router'
            mode      = $Mode
            target    = $Target
            updatedAt = $now
        }

        $json = ($stateObj | ConvertTo-Json -Depth 4) + [Environment]::NewLine
        $tempFile = Join-Path $paths.KitDir ("dev-router-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))

        # Atomic write to dev-router-state.json
        [IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $paths.StateFile -PathType Leaf) {
            $backupPath = $paths.StateFile + '.bak'
            Copy-Item -LiteralPath $paths.StateFile -Destination $backupPath -Force
        }
        Move-Item -LiteralPath $tempFile -Destination $paths.StateFile -Force

        # Synchronize codexDevRouter in install-state.json if it exists
        if (Test-Path -LiteralPath $paths.InstallState -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $paths.InstallState -Raw -Encoding UTF8
                $istate = $raw | ConvertFrom-Json
                if ($null -ne $istate) {
                    $orderedState = [ordered]@{}
                    foreach ($prop in $istate.PSObject.Properties) {
                        if ($prop.Name -ne 'codexDevRouter') {
                            $orderedState[$prop.Name] = $prop.Value
                        }
                    }
                    $orderedState['codexDevRouter'] = [ordered]@{
                        version = 1
                        mode    = $Mode
                        target  = $Target
                    }
                    $istateJson = ($orderedState | ConvertTo-Json -Depth 8) + [Environment]::NewLine
                    $tempIstate = Join-Path $paths.KitDir ("install-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
                    [IO.File]::WriteAllText($tempIstate, $istateJson, [System.Text.Encoding]::UTF8)
                    Move-Item -LiteralPath $tempIstate -Destination $paths.InstallState -Force
                }
            }
            catch {}
        }

        return $stateObj
    }
}

function Get-DevRouterLocks {
    param([string]$CodexHome)

    return Invoke-DevRouterSynchronized -LockName 'Locks' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome
        if (-not (Test-Path -LiteralPath $paths.LocksFile -PathType Leaf)) {
            return @{}
        }

        try {
            $raw = Get-Content -LiteralPath $paths.LocksFile -Raw -Encoding UTF8
            $locks = $raw | ConvertFrom-Json
            $map = @{}
            if ($null -ne $locks) {
                foreach ($prop in $locks.PSObject.Properties) {
                    $map[$prop.Name] = $prop.Value
                }
            }
            return $map
        }
        catch {
            return @{}
        }
    }
}

function Get-DevRouterLock {
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [string]$CodexHome
    )

    if ([string]::IsNullOrWhiteSpace($ConversationId)) {
        return $null
    }

    $locks = Get-DevRouterLocks -CodexHome $CodexHome
    if ($locks.ContainsKey($ConversationId)) {
        return $locks[$ConversationId]
    }
    return $null
}

function Acquire-DevRouterLock {
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [Parameter(Mandatory)][ValidateSet('turn', 'workflow')][string]$Scope,
        [string]$ExecutionId = $null,
        [string]$TurnId = $null,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort,
        [string]$Mode = 'on',
        [string]$Target = 'effort_only',
        [string]$Reason = 'routed',
        [string]$CodexHome
    )

    return Invoke-DevRouterSynchronized -LockName 'Locks' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome
        if (-not (Test-Path -LiteralPath $paths.KitDir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($paths.KitDir)
        }

        $locks = Get-DevRouterLocks -CodexHome $CodexHome
        $now = [datetime]::UtcNow.ToString('o')

        $lockRecord = [ordered]@{
            conversation_id   = $ConversationId
            scope             = $Scope
            execution_id      = $ExecutionId
            turn_id           = $TurnId
            locked_model      = $Model
            locked_effort     = $Effort
            mode              = $Mode
            target            = $Target
            locked_at_utc     = $now
            reason            = $Reason
        }

        $locks[$ConversationId] = $lockRecord

        $json = ($locks | ConvertTo-Json -Depth 5) + [Environment]::NewLine
        $tempFile = Join-Path $paths.KitDir ("dev-router-locks-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
        Move-Item -LiteralPath $tempFile -Destination $paths.LocksFile -Force

        return $lockRecord
    }
}

function Release-DevRouterLock {
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [string]$CodexHome
    )

    return Invoke-DevRouterSynchronized -LockName 'Locks' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome
        if (-not (Test-Path -LiteralPath $paths.LocksFile -PathType Leaf)) {
            return $false
        }

        $locks = Get-DevRouterLocks -CodexHome $CodexHome
        if (-not $locks.ContainsKey($ConversationId)) {
            return $false
        }

        [void]$locks.Remove($ConversationId)
        $json = ($locks | ConvertTo-Json -Depth 5) + [Environment]::NewLine
        $tempFile = Join-Path $paths.KitDir ("dev-router-locks-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
        Move-Item -LiteralPath $tempFile -Destination $paths.LocksFile -Force

        return $true
    }
}

function Clear-AllDevRouterLocks {
    param([string]$CodexHome)

    Invoke-DevRouterSynchronized -LockName 'Locks' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome
        if (Test-Path -LiteralPath $paths.LocksFile -PathType Leaf) {
            Remove-Item -LiteralPath $paths.LocksFile -Force
        }
    }
}

function Get-CodexBaselineConfig {
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $baselineModel = $null
    $baselineEffort = $null

    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        try {
            $lines = Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8
            $inTopLevel = $true
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed.StartsWith('#') -or $trimmed.Length -eq 0) {
                    continue
                }
                # Section header marks departure from root top-level
                if ($trimmed.StartsWith('[')) {
                    $inTopLevel = $false
                    continue
                }
                if ($inTopLevel) {
                    $mMatch = [regex]::Match($trimmed, '^model\s*=\s*"([^"]+)"')
                    if ($mMatch.Success) {
                        $mVal = $mMatch.Groups[1].Value.Trim()
                        $resolved = Resolve-DevRouterModel -ModelNameOrId $mVal -IncludeDisallowed
                        if ($null -ne $resolved) {
                            $baselineModel = $resolved.Name
                        }
                        else {
                            $baselineModel = $mVal
                        }
                    }
                    $eMatch = [regex]::Match($trimmed, '^model_reasoning_effort\s*=\s*"([^"]+)"')
                    if ($eMatch.Success) {
                        $baselineEffort = $eMatch.Groups[1].Value.Trim()
                    }
                }
            }
        }
        catch {
            # Preserve nulls
        }
    }

    return [ordered]@{
        Model  = $baselineModel
        Effort = $baselineEffort
    }
}

function Test-DevRouterCatalogRegistered {
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf)) {
        return $false
    }

    try {
        $toml = Get-Content -LiteralPath $paths.ConfigToml -Raw -Encoding UTF8
        $hasCatalog = ($toml -match '(?m)^\s*model_catalog_json\s*=')
        $hasProvider = ($toml -match '\[model_providers\.dev-router\]')
        return ($hasCatalog -and $hasProvider)
    }
    catch {
        return $false
    }
}

function Get-DevRouterProxyStatus {
    param(
        [string]$CodexHome,
        [int]$Port = 4040,
        [int]$TimeoutMs = 500
    )

    $url = "http://127.0.0.1:$Port/health"
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $res = $req.GetResponse()
        $stream = $res.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $stream.Close()
        $res.Close()

        $json = $body | ConvertFrom-Json
        return [pscustomobject]@{
            Running   = $true
            Port      = $Port
            Service   = [string]$json.service
            Mode      = [string]$json.mode
            Target    = [string]$json.target
        }
    }
    catch {
        return [pscustomobject]@{
            Running   = $false
            Port      = $Port
            Service   = 'dev-router-proxy'
            Mode      = 'unknown'
            Target    = 'unknown'
        }
    }
}

function Start-DevRouterProxy {
    param(
        [string]$CodexHome,
        [int]$Port = 4040
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $currentStatus = Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $Port -TimeoutMs 400
    if ($currentStatus.Running) {
        return $currentStatus
    }

    # Find node executable
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $nodeCmd) {
        throw "Node.js executable ('node') was not found in PATH. Node.js 18+ is required for Dev Router proxy."
    }

    # Ensure proxy script exists
    $repoProxyScript = Join-Path (Split-Path -Parent $PSCommandPath) 'dev-router-proxy.mjs'
    $targetProxyScript = $paths.ProxyScript
    if (Test-Path -LiteralPath $repoProxyScript -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $paths.KitDir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($paths.KitDir)
        }
        Copy-Item -LiteralPath $repoProxyScript -Destination $targetProxyScript -Force
    }
    elseif (-not (Test-Path -LiteralPath $targetProxyScript -PathType Leaf)) {
        throw "Dev Router proxy script not found at '$targetProxyScript' or '$repoProxyScript'."
    }

    $args = @(
        "`"$targetProxyScript`"",
        "--port", [string]$Port,
        "--codex-home", "`"$($paths.CodexHome)`""
    )

    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = $nodeCmd.Source
    $pInfo.Arguments = ($args -join ' ')
    $pInfo.UseShellExecute = $false
    $pInfo.CreateNoWindow = $true
    $pInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $pInfo.WorkingDirectory = $paths.KitDir

    # Forward environment
    if ($env:TYPESAFE_API_KEY) {
        $pInfo.EnvironmentVariables['TYPESAFE_API_KEY'] = $env:TYPESAFE_API_KEY
    }

    $proc = [System.Diagnostics.Process]::Start($pInfo)
    if ($null -ne $proc) {
        [IO.File]::WriteAllText($paths.ProxyPid, [string]$proc.Id, [System.Text.Encoding]::UTF8)
    }

    # Poll up to 2.5 seconds for readiness
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 250
        $status = Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $Port -TimeoutMs 400
        if ($status.Running) {
            return $status
        }
    }

    return Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $Port -TimeoutMs 500
}

function Stop-DevRouterProxy {
    param(
        [string]$CodexHome,
        [int]$Port = 4040
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome

    # Check pid file
    if (Test-Path -LiteralPath $paths.ProxyPid -PathType Leaf) {
        try {
            $pidStr = (Get-Content -LiteralPath $paths.ProxyPid -Raw -Encoding UTF8).Trim()
            $procId = [int]$pidStr
            $proc = [System.Diagnostics.Process]::GetProcessById($procId)
            if ($null -ne $proc -and -not $proc.HasExited) {
                $proc.Kill()
                [void]$proc.WaitForExit(2000)
            }
        }
        catch {}
        Remove-Item -LiteralPath $paths.ProxyPid -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Export-DevRouterModelCatalog {
    param(
        [string]$CodexHome,
        [string]$OutputPath
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $targetPath = if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath } else { $paths.CatalogFile }
    $targetDir = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($targetDir)
    }

    $officialModels = New-Object System.Collections.Generic.List[object]
    $modelsCachePath = Join-Path $paths.CodexHome 'models_cache.json'
    $foundCached = $false

    if (Test-Path -LiteralPath $modelsCachePath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $modelsCachePath -Raw -Encoding UTF8
            $cacheObj = $raw | ConvertFrom-Json
            $entries = if ($cacheObj -is [System.Collections.IEnumerable] -and -not ($cacheObj -is [string])) {
                $cacheObj
            }
            elseif ($cacheObj.PSObject.Properties.Name -contains 'models') {
                $cacheObj.models
            }
            else {
                @($cacheObj)
            }

            foreach ($m in $entries) {
                if ($null -ne $m -and $m.id -ne 'gpt-adaptive') {
                    $officialModels.Add($m)
                    $foundCached = $true
                }
            }
        }
        catch {}
    }

    if (-not $foundCached) {
        # Standard known official models for Codex Desktop
        $defaultOfficials = @(
            [ordered]@{ id = 'gpt-5.6-sol'; display_name = 'gpt-5.6-sol'; description = 'Latest frontier agentic coding model'; supported_reasoning_efforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra'); default_reasoning_effort = 'medium' },
            [ordered]@{ id = 'gpt-6-astra'; display_name = 'gpt-6-astra'; description = 'Our most capable model for complex work'; supported_reasoning_efforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra'); default_reasoning_effort = 'low' },
            [ordered]@{ id = 'gpt-5.6-terra'; display_name = 'gpt-5.6-terra'; description = 'Balanced agentic coding model for everyday work'; supported_reasoning_efforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra'); default_reasoning_effort = 'medium' },
            [ordered]@{ id = 'gpt-5.6-luna'; display_name = 'gpt-5.6-luna'; description = 'Fast and affordable agentic coding model'; supported_reasoning_efforts = @('low', 'medium', 'high', 'xhigh', 'max'); default_reasoning_effort = 'medium' },
            [ordered]@{ id = 'gpt-5.5'; display_name = 'gpt-5.5'; description = 'Frontier model for complex coding and research'; supported_reasoning_efforts = @('low', 'medium', 'high', 'xhigh'); default_reasoning_effort = 'medium' }
        )
        foreach ($d in $defaultOfficials) {
            $officialModels.Add([pscustomobject]$d)
        }
    }

    # Virtual model: GPT-Adaptive
    $adaptiveEntry = [ordered]@{
        id                          = 'gpt-adaptive'
        display_name                = 'GPT-Adaptive'
        description                 = 'Adaptive intelligent model routing powered by TypeSafe/Jev'
        model_provider_id           = 'dev-router'
        supported_reasoning_efforts = @('none', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        default_reasoning_effort    = 'medium'
    }

    $combined = New-Object System.Collections.Generic.List[object]
    $combined.Add([pscustomobject]$adaptiveEntry)
    foreach ($m in $officialModels) {
        if ($m.id -ne 'gpt-adaptive') {
            $combined.Add($m)
        }
    }

    $json = ($combined | ConvertTo-Json -Depth 6) + [Environment]::NewLine
    $tempFile = Join-Path $targetDir ("model-catalog-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tempFile -Destination $targetPath -Force

    return $targetPath
}

function Register-DevRouterCodexIntegration {
    param(
        [string]$CodexHome,
        [int]$Port = 4040
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome

    # 1. Export composite catalog
    $catalogPath = Export-DevRouterModelCatalog -CodexHome $CodexHome

    # 2. Deploy proxy script if needed
    $repoProxyScript = Join-Path (Split-Path -Parent $PSCommandPath) 'dev-router-proxy.mjs'
    if (Test-Path -LiteralPath $repoProxyScript -PathType Leaf) {
        Copy-Item -LiteralPath $repoProxyScript -Destination $paths.ProxyScript -Force
    }

    # 3. Configure config.toml
    $normCatalogPath = $catalogPath -replace '\\', '/'
    $configLines = if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8
    } else {
        @()
    }

    $newLines = New-Object System.Collections.Generic.List[string]
    $catalogSet = $false
    $inDevRouterProvider = $false
    $inTopLevel = $true

    foreach ($line in $configLines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[')) {
            $inTopLevel = $false
            if ($trimmed -eq '[model_providers.dev-router]') {
                $inDevRouterProvider = $true
                continue
            }
            elseif ($inDevRouterProvider) {
                $inDevRouterProvider = $false
            }
        }

        if ($inDevRouterProvider) {
            # Skip existing provider keys to rewrite cleanly
            continue
        }

        if ($inTopLevel -and $trimmed -match '^model_catalog_json\s*=') {
            $newLines.Add("model_catalog_json = `"$normCatalogPath`"")
            $catalogSet = $true
            continue
        }

        $newLines.Add($line)
    }

    # If model_catalog_json was not set in top level, insert it near top
    if (-not $catalogSet) {
        $insertIdx = 0
        while ($insertIdx -lt $newLines.Count -and ($newLines[$insertIdx].Trim().StartsWith('#') -or $newLines[$insertIdx].Trim().Length -eq 0)) {
            $insertIdx++
        }
        $newLines.Insert($insertIdx, "model_catalog_json = `"$normCatalogPath`"")
    }

    # Append provider section
    $providerBlock = @"

[model_providers.dev-router]
name = "Dev Router"
base_url = "http://127.0.0.1:$Port/v1"
wire_api = "responses"
requires_openai_auth = true
"@
    $newLines.Add($providerBlock.TrimStart("`r`n"))

    $tomlContent = ($newLines -join [Environment]::NewLine) + [Environment]::NewLine
    $tempConfig = Join-Path $paths.CodexHome ("config-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempConfig, $tomlContent, [System.Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tempConfig -Destination $paths.ConfigToml -Force

    return [ordered]@{
        CatalogPath = $catalogPath
        ConfigToml  = $paths.ConfigToml
        Port        = $Port
    }
}

function Unregister-DevRouterCodexIntegration {
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    [void](Stop-DevRouterProxy -CodexHome $CodexHome)

    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        $lines = Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8
        $newLines = New-Object System.Collections.Generic.List[string]
        $inDevRouterProvider = $false

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '[model_providers.dev-router]') {
                $inDevRouterProvider = $true
                continue
            }
            if ($inDevRouterProvider) {
                if ($trimmed.StartsWith('[')) {
                    $inDevRouterProvider = $false
                }
                else {
                    continue
                }
            }
            if ($trimmed -match '^model_catalog_json\s*=\s*".*codex-workflows-kit[/\\]model-catalog\.json"') {
                continue
            }
            $newLines.Add($line)
        }

        $tomlContent = ($newLines -join [Environment]::NewLine) + [Environment]::NewLine
        $tempConfig = Join-Path $paths.CodexHome ("config-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tempConfig, $tomlContent, [System.Text.Encoding]::UTF8)
        Move-Item -LiteralPath $tempConfig -Destination $paths.ConfigToml -Force
    }

    if (Test-Path -LiteralPath $paths.CatalogFile -PathType Leaf) {
        Remove-Item -LiteralPath $paths.CatalogFile -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Get-DevRouterStatus {
    param(
        [string]$CodexHome,
        [string]$ConversationId = $null
    )

    $state = Get-DevRouterState -CodexHome $CodexHome
    $baseline = Get-CodexBaselineConfig -CodexHome $CodexHome

    $activeLock = $null
    if (-not [string]::IsNullOrWhiteSpace($ConversationId)) {
        $activeLock = Get-DevRouterLock -ConversationId $ConversationId -CodexHome $CodexHome
    }

    $lockScope = if ($null -ne $activeLock) { [string]$activeLock.scope } else { 'none' }

    # Extract configured proxy port from config.toml if present
    $configuredPort = 4040
    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        try {
            $toml = Get-Content -LiteralPath $paths.ConfigToml -Raw -Encoding UTF8
            $pMatch = [regex]::Match($toml, '(?i)base_url\s*=\s*"http://127\.0\.0\.1:(\d+)/v1"')
            if ($pMatch.Success) {
                $configuredPort = [int]$pMatch.Groups[1].Value
            }
        }
        catch {}
    }

    # Integration Status check
    $proxyStatus = Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $configuredPort -TimeoutMs 500
    $catalogRegistered = Test-DevRouterCatalogRegistered -CodexHome $CodexHome

    $integrationStatus = 'unintegrated'
    $integrationNotes = 'Codex Desktop GUI does not expose a native dynamic model-switching IPC; adapter is unintegrated for GUI chats without binary patching. CLI harness (codex exec) and manual prompt guidance are fully supported.'

    if ($proxyStatus.Running -and $catalogRegistered) {
        $integrationStatus = 'integrated'
        $integrationNotes = "Codex Desktop App integration active via composite model catalog and local responses proxy (http://127.0.0.1:$($proxyStatus.Port)). GPT-Adaptive available in model dropdown."
    }

    $effectiveMode = switch ($state.mode) {
        'off'    { 'off' }
        'shadow' { 'shadow' }
        'on'     {
            if ($integrationStatus -eq 'integrated') {
                'on'
            }
            else {
                # In GUI, since integration is unintegrated, effective application is bypassed
                'bypass'
            }
        }
        default  { 'off' }
    }

    $baselineDisplayModel = if ($null -ne $baseline.Model) { $baseline.Model } else { 'Sol' }
    $baselineDisplayEffort = if ($null -ne $baseline.Effort) { $baseline.Effort } else { 'medium' }

    $effectiveModel = if ($null -ne $activeLock) {
        [string]$activeLock.locked_model
    }
    else {
        $baselineDisplayModel
    }

    $effectiveEffort = if ($null -ne $activeLock) {
        [string]$activeLock.locked_effort
    }
    else {
        $baselineDisplayEffort
    }

    return [ordered]@{
        configured_mode     = [string]$state.mode
        effective_mode      = $effectiveMode
        target              = [string]$state.target
        integration_status  = $integrationStatus
        integration_notes   = $integrationNotes
        baseline_model      = $baseline.Model
        baseline_effort     = $baseline.Effort
        effective_model     = $effectiveModel
        effective_effort    = $effectiveEffort
        pending_change      = $false
        route_lock_scope    = $lockScope
        active_lock         = $activeLock
    }
}

function New-DevRouterContextProjection {
    param(
        [Parameter(Mandatory)][string]$Objective,
        [Parameter(Mandatory)][ValidateSet('alignment', 'workflow')][string]$Surface,
        [string]$WorkflowMode = $null,
        [Parameter(Mandatory)][string]$CurrentModel,
        [Parameter(Mandatory)][string]$CurrentEffort,
        [bool]$HasImages = $false,
        [string]$Target = 'effort_only'
    )

    # 1. Strict Privacy & Sanitization:
    # Strip potential secrets, code blocks, diffs, API keys, bearer tokens
    $clean = $Objective
    # Remove code blocks
    $clean = [regex]::Replace($clean, '(?s)```[a-zA-Z0-9_\-]*\r?\n.*?```|```.*?```', '[code block omitted]')
    # Remove bearer tokens, api keys, passwords, secrets
    $clean = [regex]::Replace($clean, '(?i)(?:api[_-]?key|bearer|token|secret|password)\s*[:=\s]\s*[''"]?[a-zA-Z0-9_\-\.]{8,}[''"]?', '[secret redacted]')
    # Remove file paths with sensitive structures
    $clean = [regex]::Replace($clean, '(?i)[a-z]:\\[^\s\r\n\t]+', '[path]')
    # Normalize whitespace
    $clean = [regex]::Replace($clean, '\s+', ' ').Trim()

    if ($clean.Length -gt 600) {
        $clean = $clean.Substring(0, 600) + '... [truncated]'
    }

    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = "General task assistance"
    }

    # 2. Build alternatives based on Target
    $availableModels = @('Luna', 'Sol', 'Astra')
    $availableEfforts = switch ($Target) {
        'effort_only' {
            Get-DevRouterModelEfforts -ModelNameOrId $CurrentModel
        }
        default {
            @('minimal', 'low', 'medium', 'high', 'xhigh')
        }
    }

    return [ordered]@{
        routing_objective = $clean
        surface           = $Surface
        workflow_mode     = if ($Surface -eq 'workflow') { $WorkflowMode } else { $null }
        current_model     = $CurrentModel
        current_effort    = $CurrentEffort
        has_images        = $HasImages
        target            = $Target
        available_models  = @($availableModels)
        available_efforts = @($availableEfforts)
    }
}

function Invoke-DevRouterJevChoice {
    param(
        [Parameter(Mandatory)][object]$Projection,
        [Parameter(Mandatory)][ValidateSet('effort_only', 'model_only', 'model_and_effort')][string]$Target,
        [Parameter(Mandatory)][string]$BaselineModel,
        [Parameter(Mandatory)][string]$BaselineEffort,
        [string]$ApiKey = $null,
        [int]$TimeoutSeconds = 15,
        [hashtable]$MockResponses = $null,
        [scriptblock]$HttpTransportMock = $null
    )

    $resolvedBaseline = Resolve-DevRouterModel -ModelNameOrId $BaselineModel -IncludeDisallowed
    $baselineModelName = if ($null -ne $resolvedBaseline) { $resolvedBaseline.Name } else { $BaselineModel }
    $baselineEffortVal = if (-not [string]::IsNullOrWhiteSpace($BaselineEffort)) { $BaselineEffort.Trim().ToLowerInvariant() } else { 'medium' }

    # Fallback result
    $fallback = [ordered]@{
        model              = $baselineModelName
        effort             = $baselineEffortVal
        status             = 'ok'
        is_fallback        = $false
        reason             = 'routed'
        confidence         = 1.0
        probabilities      = $null
        selected_raw       = $null
    }

    # Formulate question and criteria mapping based on Target
    $instructions = ''
    $options = @()
    $criteria = [ordered]@{}

    switch ($Target) {
        'effort_only' {
            $supportedEfforts = Get-DevRouterModelEfforts -ModelNameOrId $baselineModelName
            if ($supportedEfforts.Count -eq 0) {
                $supportedEfforts = @('low', 'medium', 'high')
            }
            $options = @($supportedEfforts)
            $instructions = "Select the appropriate reasoning effort for this task running on model '$baselineModelName'."
            foreach ($eff in $options) {
                $criteria[$eff] = switch ($eff) {
                    'none'    { 'No reasoning effort: direct response without chain-of-thought.' }
                    'minimal' { 'Minimal reasoning effort: trivial, simple tasks.' }
                    'low'     { 'Low reasoning effort: straightforward mechanical task, clear requirements.' }
                    'medium'  { 'Medium reasoning effort: standard implementation, balanced analysis.' }
                    'high'    { 'High reasoning effort: intricate algorithms, deep debugging, complex reasoning.' }
                    'xhigh'   { 'Extra high reasoning effort: critical architecture, subtle concurrency, high blast radius.' }
                    'max'     { 'Maximum reasoning effort: most demanding multi-step reasoning.' }
                    'ultra'   { 'Ultra reasoning effort: maximum computational budget.' }
                    default   { "Reasoning effort: $eff" }
                }
            }
        }
        'model_only' {
            # Allowlist: Luna, Sol, Astra (Terra strictly excluded from automatic routes)
            # Filter models compatible with the baseline effort if set
            $candidateModels = @()
            foreach ($m in @('Luna', 'Sol', 'Astra')) {
                if (Test-DevRouterEffortSupported -ModelNameOrId $m -Effort $baselineEffortVal) {
                    $candidateModels += $m
                }
            }
            if ($candidateModels.Count -eq 0) {
                # SECTION 7: In model_only, if no permitted model supports effort, return bypass/incompatible instead of re-opening all models
                return [ordered]@{
                    model        = $baselineModelName
                    effort       = $baselineEffortVal
                    status       = 'incompatible'
                    is_fallback  = $true
                    reason       = "No permitted model supports effort '$baselineEffortVal'."
                    confidence   = 0.0
                    probabilities= $null
                    selected_raw = $null
                }
            }
            $options = @($candidateModels)
            $instructions = "Select the best model from the allowlist for this task requiring reasoning effort '$baselineEffortVal'."
            foreach ($m in $options) {
                $mEntry = Resolve-DevRouterModel -ModelNameOrId $m
                $desc = if ($null -ne $mEntry) { $mEntry.Description } else { "Model $m" }
                $criteria[$m] = "$m - $desc"
            }
        }
        'model_and_effort' {
            # Candidate pairs of Model:Effort strictly from allowlist
            $pairs = @()
            foreach ($m in @('Luna', 'Sol', 'Astra')) {
                $efforts = Get-DevRouterModelEfforts -ModelNameOrId $m
                foreach ($eff in $efforts) {
                    if ($eff -in @('minimal', 'low', 'medium', 'high', 'xhigh')) {
                        $pairs += "$m`:$eff"
                    }
                }
            }
            $options = @($pairs)
            $instructions = "Select the optimal model and reasoning effort pair from the allowlist for this task."
            foreach ($p in $options) {
                $parts = $p.Split(':')
                $mName = $parts[0]
                $eName = $parts[1]
                $mEntry = Resolve-DevRouterModel -ModelNameOrId $mName
                $profile = if ($null -ne $mEntry) { $mEntry.Profile } else { $mName }
                $criteria[$p] = "Model $mName ($profile) paired with reasoning effort $eName."
            }
        }
    }

    # 1. Handle Mock Responses
    if ($null -ne $MockResponses) {
        $mockKey = if ($MockResponses.ContainsKey($Target)) { $Target }
                   elseif ($MockResponses.ContainsKey('*')) { '*' }
                   else { $null }

        if ($null -ne $mockKey) {
            $mVal = $MockResponses[$mockKey]
            if ($mVal -is [hashtable] -and $mVal.ContainsKey('error')) {
                return [ordered]@{
                    model        = $baselineModelName
                    effort       = $baselineEffortVal
                    status       = 'error'
                    is_fallback  = $true
                    reason       = [string]$mVal.error
                    confidence   = 0.0
                    probabilities= $null
                    selected_raw = $null
                }
            }
            $chosen = [string]$mVal
            return Parse-DevRouterChoice -Chosen $chosen -Target $Target -BaselineModel $baselineModelName -BaselineEffort $baselineEffortVal -Options $options
        }
    }

    # 2. Check API Key
    $resolvedKey = if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $ApiKey } else { $env:TYPESAFE_API_KEY }
    if ([string]::IsNullOrWhiteSpace($resolvedKey) -and $null -eq $HttpTransportMock) {
        return [ordered]@{
            model        = $baselineModelName
            effort       = $baselineEffortVal
            status       = 'unavailable'
            is_fallback  = $true
            reason       = 'TYPESAFE_API_KEY is not set.'
            confidence   = 0.0
            probabilities= $null
            selected_raw = $null
        }
    }

    # 3. Build Question Body with explicit criteria map per TypeSafe/Jev choice primitive schema
    $questions = [ordered]@{
        'q_route' = [ordered]@{
            type         = 'choice'
            instructions = $instructions
            criteria     = $criteria
        }
    }

    $statePayload = [ordered]@{
        task = [ordered]@{
            objective = $Projection.routing_objective
            surface   = $Projection.surface
            mode      = $Projection.workflow_mode
        }
    }

    $bodyObj = [ordered]@{
        model     = 'jev-latest'
        state     = ($statePayload | ConvertTo-Json -Compress -Depth 4)
        questions = $questions
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 6

    # 4. Invoke Transport
    $responseObj = $null
    if ($null -ne $HttpTransportMock) {
        try {
            $mockReq = [pscustomobject]@{
                Endpoint   = 'https://api.typesafe.ai/v1/systemone'
                Method     = 'POST'
                BodyJson   = $bodyJson
                BodyObject = $bodyObj
                Target     = $Target
            }
            $mockRes = & $HttpTransportMock $mockReq
            if ($mockRes -is [string]) {
                $responseObj = $mockRes | ConvertFrom-Json
            }
            else {
                $responseObj = $mockRes
            }
        }
        catch {
            return [ordered]@{
                model        = $baselineModelName
                effort       = $baselineEffortVal
                status       = 'error'
                is_fallback  = $true
                reason       = $_.Exception.Message
                confidence   = 0.0
                probabilities= $null
                selected_raw = $null
            }
        }
    }
    else {
        $endpoint = 'https://api.typesafe.ai/v1/systemone'
        $headers = @{
            'Authorization' = "Bearer $resolvedKey"
            'Content-Type'  = 'application/json'
        }
        try {
            $responseObj = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $bodyJson -TimeoutSec $TimeoutSeconds
        }
        catch {
            return [ordered]@{
                model        = $baselineModelName
                effort       = $baselineEffortVal
                status       = 'error'
                is_fallback  = $true
                reason       = $_.Exception.Message
                confidence   = 0.0
                probabilities= $null
                selected_raw = $null
            }
        }
    }

    # 5. Parse Response Answer
    if ($null -eq $responseObj -or -not ($responseObj.PSObject.Properties.Name -contains 'answers')) {
        return [ordered]@{
            model        = $baselineModelName
            effort       = $baselineEffortVal
            status       = 'invalid_response'
            is_fallback  = $true
            reason       = 'Missing answers property from Jev response.'
            confidence   = 0.0
            probabilities= $null
            selected_raw = $null
        }
    }

    $ans = $responseObj.answers.q_route
    if ($null -eq $ans) {
        return [ordered]@{
            model        = $baselineModelName
            effort       = $baselineEffortVal
            status       = 'invalid_response'
            is_fallback  = $true
            reason       = 'Missing q_route answer.'
            confidence   = 0.0
            probabilities= $null
            selected_raw = $null
        }
    }

    $rawChosen = $null
    $confidence = 1.0
    $probabilities = $null

    if ($ans -is [string]) {
        $rawChosen = $ans
    }
    else {
        if ($ans.PSObject.Properties.Name -contains 'choice') {
            $rawChosen = [string]$ans.choice
        }
        elseif ($ans.PSObject.Properties.Name -contains 'selected') {
            $rawChosen = [string]$ans.selected
        }
        elseif ($ans.PSObject.Properties.Name -contains 'value') {
            $rawChosen = [string]$ans.value
        }

        if ($ans.PSObject.Properties.Name -contains 'confidence' -and $null -ne $ans.confidence) {
            $confidence = [double]$ans.confidence
        }
        if ($ans.PSObject.Properties.Name -contains 'probabilities' -and $null -ne $ans.probabilities) {
            $probabilities = $ans.probabilities
        }
    }

    return Parse-DevRouterChoice `
        -Chosen $rawChosen `
        -Target $Target `
        -BaselineModel $baselineModelName `
        -BaselineEffort $baselineEffortVal `
        -Options $options `
        -Confidence $confidence `
        -Probabilities $probabilities
}

function Parse-DevRouterChoice {
    param(
        [Parameter()][string]$Chosen,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$BaselineModel,
        [Parameter(Mandatory)][string]$BaselineEffort,
        [Parameter(Mandatory)][string[]]$Options,
        [double]$Confidence = 1.0,
        [object]$Probabilities = $null
    )

    if ([string]::IsNullOrWhiteSpace($Chosen)) {
        return [ordered]@{
            model        = $BaselineModel
            effort       = $BaselineEffort
            status       = 'invalid_choice'
            is_fallback  = $true
            reason       = 'Empty choice returned by Jev.'
            confidence   = 0.0
            probabilities= $null
            selected_raw = $null
        }
    }

    $cleanChosen = $Chosen.Trim()

    # Must be in options
    $matchedOption = $null
    foreach ($opt in $Options) {
        if ($cleanChosen.Equals($opt, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedOption = $opt
            break
        }
    }

    if ($null -eq $matchedOption) {
        return [ordered]@{
            model        = $BaselineModel
            effort       = $BaselineEffort
            status       = 'invalid_choice'
            is_fallback  = $true
            reason       = "Choice '$cleanChosen' was not in permitted options: ($($Options -join ', '))."
            confidence   = 0.0
            probabilities= $null
            selected_raw = $cleanChosen
        }
    }

    switch ($Target) {
        'effort_only' {
            # STRICT AUTHORITY: Model is NEVER modified, even under high risk!
            return [ordered]@{
                model        = $BaselineModel
                effort       = $matchedOption.ToLowerInvariant()
                status       = 'ok'
                is_fallback  = $false
                reason       = 'jev_choice'
                confidence   = $Confidence
                probabilities= $Probabilities
                selected_raw = $matchedOption
            }
        }
        'model_only' {
            # STRICT AUTHORITY: Effort is NEVER modified!
            # Ensure model is strictly allowed (Luna, Sol, Astra)
            if (-not (Test-DevRouterModelAllowed -ModelNameOrId $matchedOption)) {
                return [ordered]@{
                    model        = $BaselineModel
                    effort       = $BaselineEffort
                    status       = 'disallowed_model'
                    is_fallback  = $true
                    reason       = "Model '$matchedOption' is not in allowlist."
                    confidence   = 0.0
                    probabilities= $null
                    selected_raw = $matchedOption
                }
            }
            return [ordered]@{
                model        = $matchedOption
                effort       = $BaselineEffort
                status       = 'ok'
                is_fallback  = $false
                reason       = 'jev_choice'
                confidence   = $Confidence
                probabilities= $Probabilities
                selected_raw = $matchedOption
            }
        }
        'model_and_effort' {
            $parts = $matchedOption.Split(':')
            if ($parts.Length -ne 2) {
                return [ordered]@{
                    model        = $BaselineModel
                    effort       = $BaselineEffort
                    status       = 'invalid_format'
                    is_fallback  = $true
                    reason       = "Invalid Model:Effort pair '$matchedOption'."
                    confidence   = 0.0
                    probabilities= $null
                    selected_raw = $matchedOption
                }
            }
            $m = $parts[0].Trim()
            $e = $parts[1].Trim().ToLowerInvariant()
            if (-not (Test-DevRouterModelAllowed -ModelNameOrId $m)) {
                return [ordered]@{
                    model        = $BaselineModel
                    effort       = $BaselineEffort
                    status       = 'disallowed_model'
                    is_fallback  = $true
                    reason       = "Model '$m' is not in allowlist."
                    confidence   = 0.0
                    probabilities= $null
                    selected_raw = $matchedOption
                }
            }
            return [ordered]@{
                model        = $m
                effort       = $e
                status       = 'ok'
                is_fallback  = $false
                reason       = 'jev_choice'
                confidence   = $Confidence
                probabilities= $Probabilities
                selected_raw = $matchedOption
            }
        }
    }
}

function Invoke-DevRouterTurn {
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [string]$TurnId = $null,
        [string]$ExecutionId = $null,
        [Parameter(Mandatory)][string]$Objective,
        [Parameter(Mandatory)][ValidateSet('alignment', 'workflow')][string]$Surface,
        [string]$WorkflowMode = $null,
        [string]$BaselineModel = $null,
        [string]$BaselineEffort = $null,
        [string]$CodexHome = $null,
        [hashtable]$MockResponses = $null,
        [scriptblock]$HttpTransportMock = $null,
        [ValidateSet('cli_harness', 'codex_app_gui')][string]$AdapterSurface = 'cli_harness'
    )

    $state = Get-DevRouterState -CodexHome $CodexHome
    $baselineConfig = Get-CodexBaselineConfig -CodexHome $CodexHome

    $resolvedBaselineModel = if (-not [string]::IsNullOrWhiteSpace($BaselineModel)) {
        $r = Resolve-DevRouterModel -ModelNameOrId $BaselineModel -IncludeDisallowed
        if ($null -ne $r) { $r.Name } else { $BaselineModel }
    }
    elseif ($null -ne $baselineConfig.Model) {
        $baselineConfig.Model
    }
    else {
        'Sol'
    }

    $resolvedBaselineEffort = if (-not [string]::IsNullOrWhiteSpace($BaselineEffort)) {
        $BaselineEffort.Trim().ToLowerInvariant()
    }
    elseif ($null -ne $baselineConfig.Effort) {
        $baselineConfig.Effort
    }
    else {
        'medium'
    }

    # 1. Check if Mode is OFF
    if ($state.mode -eq 'off') {
        return [ordered]@{
            conversation_id   = $ConversationId
            configured_mode   = 'off'
            effective_mode    = 'off'
            target            = [string]$state.target
            applied_model     = $resolvedBaselineModel
            applied_effort    = $resolvedBaselineEffort
            recommended_model = $null
            recommended_effort= $null
            status            = 'off'
            is_locked         = $false
            lock_scope        = 'none'
            reason            = 'router_off'
            jev_called        = $false
        }
    }

    # 2. Check Existing Active Lock for this conversation (Thread Isolation & Precedence)
    $existingLock = Get-DevRouterLock -ConversationId $ConversationId -CodexHome $CodexHome
    if ($null -ne $existingLock) {
        $lockValid = $true

        # Invalidate lock if mode or target changed
        if ($existingLock.PSObject.Properties.Name -contains 'mode' -and [string]$existingLock.mode -ne [string]$state.mode) {
            $lockValid = $false
        }
        if ($existingLock.PSObject.Properties.Name -contains 'target' -and [string]$existingLock.target -ne [string]$state.target) {
            $lockValid = $false
        }

        # Scope validation:
        if ($lockValid) {
            if ($Surface -eq 'workflow') {
                if ([string]$existingLock.scope -ne 'workflow') {
                    $lockValid = $false
                }
                elseif (-not [string]::IsNullOrWhiteSpace($ExecutionId) -and $existingLock.PSObject.Properties.Name -contains 'execution_id' -and [string]$existingLock.execution_id -ne $ExecutionId) {
                    $lockValid = $false
                }
            }
            else {
                # In alignment
                if ([string]$existingLock.scope -ne 'turn') {
                    $lockValid = $false
                }
                elseif (-not [string]::IsNullOrWhiteSpace($TurnId) -and $existingLock.PSObject.Properties.Name -contains 'turn_id' -and [string]$existingLock.turn_id -ne $TurnId) {
                    $lockValid = $false
                }
            }
        }

        if ($lockValid) {
            return [ordered]@{
                conversation_id   = $ConversationId
                configured_mode   = [string]$state.mode
                effective_mode    = [string]$state.mode
                target            = [string]$state.target
                applied_model     = [string]$existingLock.locked_model
                applied_effort    = [string]$existingLock.locked_effort
                recommended_model = [string]$existingLock.locked_model
                recommended_effort= [string]$existingLock.locked_effort
                status            = 'locked'
                is_locked         = $true
                lock_scope        = [string]$existingLock.scope
                reason            = 'reused_lock'
                jev_called        = $false
            }
        }
        else {
            [void](Release-DevRouterLock -ConversationId $ConversationId -CodexHome $CodexHome)
        }
    }

    # 3. Build Sanitized Context Projection
    $projection = New-DevRouterContextProjection `
        -Objective $Objective `
        -Surface $Surface `
        -WorkflowMode $WorkflowMode `
        -CurrentModel $resolvedBaselineModel `
        -CurrentEffort $resolvedBaselineEffort `
        -Target ([string]$state.target)

    # 4. Invoke Jev Evaluation
    $jevResult = Invoke-DevRouterJevChoice `
        -Projection $projection `
        -Target ([string]$state.target) `
        -BaselineModel $resolvedBaselineModel `
        -BaselineEffort $resolvedBaselineEffort `
        -MockResponses $MockResponses `
        -HttpTransportMock $HttpTransportMock

    $recommendedModel = [string]$jevResult.model
    $recommendedEffort = [string]$jevResult.effort

    # 5. Handle Shadow Mode
    if ($state.mode -eq 'shadow') {
        return [ordered]@{
            conversation_id   = $ConversationId
            configured_mode   = 'shadow'
            effective_mode    = 'shadow'
            target            = [string]$state.target
            applied_model     = $resolvedBaselineModel
            applied_effort    = $resolvedBaselineEffort
            recommended_model = $recommendedModel
            recommended_effort= $recommendedEffort
            status            = [string]$jevResult.status
            is_locked         = $false
            lock_scope        = 'none'
            reason            = 'shadow_observation'
            jev_called        = $true
        }
    }

    # 6. Revalidate Final Pair Compatibility
    $pairSupported = Test-DevRouterEffortSupported -ModelNameOrId $recommendedModel -Effort $recommendedEffort
    if (-not $pairSupported) {
        return [ordered]@{
            conversation_id   = $ConversationId
            configured_mode   = [string]$state.mode
            effective_mode    = 'bypass'
            target            = [string]$state.target
            applied_model     = $resolvedBaselineModel
            applied_effort    = $resolvedBaselineEffort
            recommended_model = $recommendedModel
            recommended_effort= $recommendedEffort
            status            = 'incompatible'
            is_locked         = $false
            lock_scope        = 'none'
            reason            = "Incompatible model and effort pair: $recommendedModel with $recommendedEffort."
            jev_called        = $true
        }
    }

    # 7. Check Desktop GUI Surface vs CLI Harness
    $statusInfo = Get-DevRouterStatus -CodexHome $CodexHome -ConversationId $ConversationId
    if ($AdapterSurface -eq 'codex_app_gui' -and $statusInfo.integration_status -ne 'integrated') {
        return [ordered]@{
            conversation_id   = $ConversationId
            configured_mode   = 'on'
            effective_mode    = 'bypass'
            target            = [string]$state.target
            applied_model     = $resolvedBaselineModel
            applied_effort    = $resolvedBaselineEffort
            recommended_model = $recommendedModel
            recommended_effort= $recommendedEffort
            status            = 'unintegrated_surface'
            is_locked         = $false
            lock_scope        = 'none'
            reason            = 'codex_desktop_app_unintegrated'
            jev_called        = $true
        }
    }

    # Active Route Applied:
    $appliedModel = $recommendedModel
    $appliedEffort = $recommendedEffort

    # Acquire Lock
    $scope = if ($Surface -eq 'workflow') { 'workflow' } else { 'turn' }
    [void](Acquire-DevRouterLock `
        -ConversationId $ConversationId `
        -Scope $scope `
        -ExecutionId $ExecutionId `
        -TurnId $TurnId `
        -Model $appliedModel `
        -Effort $appliedEffort `
        -Mode ([string]$state.mode) `
        -Target ([string]$state.target) `
        -Reason 'active_route' `
        -CodexHome $CodexHome)

    return [ordered]@{
        conversation_id   = $ConversationId
        configured_mode   = 'on'
        effective_mode    = 'on'
        target            = [string]$state.target
        applied_model     = $appliedModel
        applied_effort    = $appliedEffort
        recommended_model = $recommendedModel
        recommended_effort= $recommendedEffort
        status            = [string]$jevResult.status
        is_locked         = $true
        lock_scope        = $scope
        reason            = [string]$jevResult.reason
        jev_called        = $true
    }
}

function Get-DevRouterCliArguments {
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort
    )

    $resolved = Resolve-DevRouterModel -ModelNameOrId $Model -IncludeDisallowed
    $modelId = if ($null -ne $resolved) { $resolved.Id } else { $Model }

    return @(
        '-m', $modelId,
        '-c', "model_reasoning_effort=`"$Effort`""
    )
}

Export-ModuleMember -Function `
    Invoke-DevRouterSynchronized, `
    Get-DevRouterModelCatalog, `
    Resolve-DevRouterModel, `
    Test-DevRouterModelAllowed, `
    Get-DevRouterModelEfforts, `
    Test-DevRouterEffortSupported, `
    Get-DevRouterPaths, `
    Get-DevRouterState, `
    Set-DevRouterState, `
    Get-DevRouterLocks, `
    Get-DevRouterLock, `
    Acquire-DevRouterLock, `
    Release-DevRouterLock, `
    Clear-AllDevRouterLocks, `
    Get-CodexBaselineConfig, `
    Get-DevRouterStatus, `
    New-DevRouterContextProjection, `
    Invoke-DevRouterJevChoice, `
    Parse-DevRouterChoice, `
    Invoke-DevRouterTurn, `
    Get-DevRouterCliArguments, `
    Export-DevRouterModelCatalog, `
    Test-DevRouterCatalogRegistered, `
    Register-DevRouterCodexIntegration, `
    Unregister-DevRouterCodexIntegration, `
    Get-DevRouterProxyStatus, `
    Start-DevRouterProxy, `
    Stop-DevRouterProxy
