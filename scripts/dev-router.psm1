Set-StrictMode -Version Latest

# Dev Router Module (TypeSafe/Jev Autonomous Orchestrator Router)
# Controls parent orchestrator model and reasoning effort for Codex App / CLI.
# Supports ALINHAMENTO conversations and explicit workflows with thread isolation.
# Implements real Codex Desktop App model selector dropdown integration via GPT-Adaptive.

# UTF-8 WITHOUT a byte order mark. Codex parses `model_catalog_json` and the
# Dev Router proxy parses its state file as strict JSON, so a leading BOM
# (which [System.Text.Encoding]::UTF8 emits on Windows PowerShell 5.1) makes
# them fail with "expected value at line 1 column 1". Every machine-readable
# artifact this module writes must use this encoding.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Canonical routing policy DATA lives in dev-router-policy.json; the pure LOGIC
# lives in dev-router-policy.mjs and is consumed through dev-router-policy-cli.mjs.
# PowerShell never re-declares model ids, efforts, aliases or profiles.
$script:DevRouterModelCatalog = [ordered]@{}
$script:ManualPassThroughModels = [ordered]@{}
$script:DisallowedModels = @()
$script:AllValidEfforts = @()

function Import-DevRouterPolicyData {
    $policyPath = Join-Path (Split-Path -Parent $PSCommandPath) 'dev-router-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        throw "Dev Router policy data not found at '$policyPath'. The canonical policy JSON must ship next to dev-router.psm1."
    }

    $raw = [IO.File]::ReadAllText($policyPath)
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }

    $data = $raw | ConvertFrom-Json
    $catalog = [ordered]@{}
    $manual = [ordered]@{}

    foreach ($model in @($data.models)) {
        $entry = [ordered]@{
            Id               = [string]$model.id
            Name             = [string]$model.name
            Aliases          = @($model.aliases)
            SupportedEfforts = @($model.supported_efforts)
            Profile          = [string]$model.profile
            Description      = [string]$model.description
        }
        if ([bool]$model.automatic) {
            $catalog[[string]$model.name] = $entry
        }
        else {
            $manual[[string]$model.name] = $entry
        }
    }

    $script:DevRouterModelCatalog = $catalog
    $script:ManualPassThroughModels = $manual
    $script:DisallowedModels = @($data.disallowed_for_automatic_routing)
    $script:AllValidEfforts = @($data.all_valid_efforts)
}

Import-DevRouterPolicyData

function ConvertFrom-DevRouterPolicyValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $map[$prop.Name] = ConvertFrom-DevRouterPolicyValue -Value $prop.Value
        }
        return $map
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $list.Add((ConvertFrom-DevRouterPolicyValue -Value $item))
        }
        return , $list.ToArray()
    }
    return $Value
}

$script:DevRouterPolicyCache = @{}
$script:DevRouterCacheableOperations = @('resolveModel', 'modelEfforts', 'isEffortSupported', 'isModelAllowedForAutomaticRouting')

function Invoke-DevRouterPolicyCli {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Request = @{}
    )

    $cacheable = $script:DevRouterCacheableOperations -contains $Operation
    $cacheKey = $null
    if ($cacheable) {
        $parts = foreach ($key in ($Request.Keys | Sort-Object)) {
            "$key=$($Request[$key])"
        }
        $cacheKey = "$Operation|$($parts -join '&')"
        if ($script:DevRouterPolicyCache.ContainsKey($cacheKey)) {
            return $script:DevRouterPolicyCache[$cacheKey]
        }
    }

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $nodeCmd) {
        throw "Dev Router policy CLI '$Operation' requires Node.js ('node') on PATH. Refusing to evaluate routing policy without the canonical module."
    }

    $cliPath = Join-Path (Split-Path -Parent $PSCommandPath) 'dev-router-policy-cli.mjs'
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        throw "Dev Router policy CLI not found at '$cliPath'. The canonical policy module must ship next to dev-router.psm1."
    }

    $payload = [ordered]@{ op = $Operation }
    foreach ($key in $Request.Keys) {
        $payload[$key] = $Request[$key]
    }
    $json = $payload | ConvertTo-Json -Depth 12 -Compress

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodeCmd.Source
    $psi.Arguments = "`"$cliPath`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        throw "Dev Router policy CLI '$Operation' could not be started."
    }

    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Write($json)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
    }
    finally {
        $proc.Dispose()
    }

    if ($exitCode -ne 0) {
        throw "Dev Router policy CLI '$Operation' failed (exit $($exitCode)): $($stderr.Trim()) $($stdout.Trim())"
    }

    $parsed = $null
    try {
        $parsed = $stdout | ConvertFrom-Json
    }
    catch {
        throw "Dev Router policy CLI '$Operation' returned unparseable output: $($stdout.Trim())"
    }
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'ok') -or -not [bool]$parsed.ok) {
        $message = if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'error') { [string]$parsed.error } else { $stdout.Trim() }
        throw "Dev Router policy CLI '$Operation' returned an error: $message"
    }

    $result = ConvertFrom-DevRouterPolicyValue -Value $parsed.result
    if ($cacheable -and $null -ne $cacheKey) {
        $script:DevRouterPolicyCache[$cacheKey] = $result
    }
    return $result
}

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

    if ([string]::IsNullOrWhiteSpace($ModelNameOrId)) {
        return $null
    }

    $resolved = Invoke-DevRouterPolicyCli -Operation 'resolveModel' -Request @{
        nameOrId          = $ModelNameOrId
        includeDisallowed = [bool]$IncludeDisallowed
    }
    if ($null -eq $resolved) {
        return $null
    }

    return [ordered]@{
        Id               = [string]$resolved.id
        Name             = [string]$resolved.name
        Aliases          = @($resolved.aliases)
        SupportedEfforts = @($resolved.supportedEfforts)
        Profile          = [string]$resolved.profile
        Description      = [string]$resolved.description
    }
}

function Test-DevRouterModelAllowed {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    # Strictly verifies model is in allowed catalog and NOT disallowed
    return [bool](Invoke-DevRouterPolicyCli -Operation 'isModelAllowedForAutomaticRouting' -Request @{
            model = $ModelNameOrId
        })
}

function Get-DevRouterModelEfforts {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    $efforts = Invoke-DevRouterPolicyCli -Operation 'modelEfforts' -Request @{
        modelOrName = $ModelNameOrId
    }
    if ($null -eq $efforts) {
        return @()
    }
    return @($efforts)
}

function Test-DevRouterEffortSupported {
    param(
        [Parameter(Mandatory)][string]$ModelNameOrId,
        [Parameter(Mandatory)][string]$Effort
    )

    return [bool](Invoke-DevRouterPolicyCli -Operation 'isEffortSupported' -Request @{
            model  = $ModelNameOrId
            effort = $Effort
        })
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

        # The proxy reads manual_base_model/manual_base_effort from this file.
        # Switching mode/target must never wipe the operator's manual base.
        if (Test-Path -LiteralPath $paths.StateFile -PathType Leaf) {
            try {
                $existingRaw = Get-Content -LiteralPath $paths.StateFile -Raw -Encoding UTF8
                $existingState = $existingRaw | ConvertFrom-Json
                if ($null -ne $existingState -and $existingState.PSObject.Properties.Name -contains 'manual_base_model' -and -not [string]::IsNullOrWhiteSpace([string]$existingState.manual_base_model)) {
                    $stateObj['manual_base_model'] = [string]$existingState.manual_base_model
                }
                if ($null -ne $existingState -and $existingState.PSObject.Properties.Name -contains 'manual_base_effort' -and -not [string]::IsNullOrWhiteSpace([string]$existingState.manual_base_effort)) {
                    $stateObj['manual_base_effort'] = [string]$existingState.manual_base_effort
                }
            }
            catch {}
        }

        $json = ($stateObj | ConvertTo-Json -Depth 4) + [Environment]::NewLine
        $tempFile = Join-Path $paths.KitDir ("dev-router-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))

        # Atomic write to dev-router-state.json
        [IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBom)
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
                    [IO.File]::WriteAllText($tempIstate, $istateJson, $script:Utf8NoBom)
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
        [IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBom)
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
        [IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBom)
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

function Get-CodexTopLevelConfig {
    <#
    .SYNOPSIS
    Raw top-level string keys from config.toml that the Dev Router must inspect.

    Unlike Get-CodexBaselineConfig this does NOT canonicalize model names: it
    reports exactly what the file says so provider selection and rollback can be
    exact. No secret value is read.
    #>
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $result = [ordered]@{
        Model             = $null
        ModelProvider     = $null
        ModelCatalogJson  = $null
        ModelEffort       = $null
        PreferredAuthMethod = $null
        ChatgptBaseUrl    = $null
    }

    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        try {
            $lines = Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8
            $inTopLevel = $true
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed.StartsWith('#') -or $trimmed.Length -eq 0) { continue }
                if ($trimmed.StartsWith('[')) { $inTopLevel = $false; continue }
                if (-not $inTopLevel) { continue }
                foreach ($pair in @(
                    @{ Key = 'model'; Field = 'Model' },
                    @{ Key = 'model_provider'; Field = 'ModelProvider' },
                    @{ Key = 'model_catalog_json'; Field = 'ModelCatalogJson' },
                    @{ Key = 'model_reasoning_effort'; Field = 'ModelEffort' },
                    @{ Key = 'preferred_auth_method'; Field = 'PreferredAuthMethod' },
                    @{ Key = 'chatgpt_base_url'; Field = 'ChatgptBaseUrl' }
                )) {
                    $m = [regex]::Match($trimmed, '^' + [regex]::Escape($pair.Key) + '\s*=\s*"([^"]*)"')
                    if ($m.Success) {
                        $result[$pair.Field] = $m.Groups[1].Value.Trim()
                    }
                }
            }
        }
        catch {
            # Preserve nulls; the caller fails closed when it needs a value.
        }
    }

    return $result
}

function Test-DevRouterProviderSelected {
    <#
    .SYNOPSIS
    True only when config.toml selects the Dev Router as the ACTIVE model provider.

    Declaring `[model_providers.dev-router]` is not the same as selecting it: the
    original Desktop bug was `model = "gpt-adaptive"` with
    `model_provider = "openai"`, so the alias was sent to the ChatGPT backend.
    #>
    param([string]$CodexHome)

    $top = Get-CodexTopLevelConfig -CodexHome $CodexHome
    return ([string]$top.ModelProvider).Trim().ToLowerInvariant() -eq 'dev-router'
}

function Get-DevRouterUpstream {
    <#
    .SYNOPSIS
    Resolves the upstream base the proxy must forward to, using the shared
    canonical policy module (never guessed locally).
    #>
    param(
        [string]$CodexHome,
        [string]$EnvOverride = $null
    )

    $top = Get-CodexTopLevelConfig -CodexHome $CodexHome
    $resolved = Invoke-DevRouterPolicyCli -Operation 'deriveUpstream' -Request @{
        envOverride         = if ([string]::IsNullOrWhiteSpace($EnvOverride)) { $null } else { $EnvOverride }
        chatgptBaseUrl      = $top.ChatgptBaseUrl
        preferredAuthMethod = $top.PreferredAuthMethod
        codexHome           = $CodexHome
    }
    if ($null -eq $resolved -or [string]::IsNullOrWhiteSpace([string]$resolved.upstream)) {
        throw "Dev Router could not resolve an upstream base for Codex home '$CodexHome'."
    }
    return [ordered]@{
        Upstream = [string]$resolved.upstream
        Source   = [string]$resolved.source
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
        foreach ($policyFile in @('dev-router-policy.json', 'dev-router-policy.mjs', 'dev-router-policy-cli.mjs')) {
            $policySrc = Join-Path (Split-Path -Parent $PSCommandPath) $policyFile
            if (Test-Path -LiteralPath $policySrc -PathType Leaf) {
                Copy-Item -LiteralPath $policySrc -Destination (Join-Path $paths.KitDir $policyFile) -Force
            }
        }
    }
    elseif (-not (Test-Path -LiteralPath $targetProxyScript -PathType Leaf)) {
        throw "Dev Router proxy script not found at '$targetProxyScript' or '$repoProxyScript'."
    }

    $args = @(
        "`"$targetProxyScript`"",
        "--port", [string]$Port,
        "--codex-home", "`"$($paths.CodexHome)`""
    )

    # The proxy must SURVIVE the launcher (the Desktop keeps running after the
    # registering shell exits), so it is started without inheriting the caller's
    # console/job. Output goes to bounded log files for diagnostics.
    $logPath = Join-Path $paths.KitDir 'dev-router-proxy.log'
    $errPath = Join-Path $paths.KitDir 'dev-router-proxy.err.log'
    $proc = Start-Process -FilePath $nodeCmd.Source -ArgumentList ($args -join ' ') `
        -WorkingDirectory $paths.KitDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $logPath -RedirectStandardError $errPath
    if ($null -ne $proc) {
        [IO.File]::WriteAllText($paths.ProxyPid, [string]$proc.Id, $script:Utf8NoBom)
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

# Codex >= 0.145 deserializes `model_catalog_json` as a SEQUENCE OF SEQUENCES of
# ModelInfo objects. The shape was verified empirically against codex-cli
# 0.145.0 by probing its deserializer: a flat array of models, the older
# `id`/`supported_reasoning_efforts`/`default_reasoning_effort` keys, or string
# entries all fail configuration loading with
# "invalid type: map, expected a sequence" / "missing field ...".
$script:DevRouterReasoningEffortOrder = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')

function ConvertTo-DevRouterReasoningLevels {
    param(
        [string[]]$Efforts,
        [string]$DefaultEffort = 'medium'
    )
    $levels = New-Object System.Collections.Generic.List[object]
    foreach ($effort in $Efforts) {
        if ([string]::IsNullOrWhiteSpace($effort)) { continue }
        $description = if ($effort -eq $DefaultEffort) { "$effort (default)" } else { $effort }
        $levels.Add([ordered]@{ effort = $effort; description = $description })
    }
    return , $levels.ToArray()
}

$script:DevRouterShellTypes = @('default', 'local', 'unified_exec', 'disabled', 'shell_command')
$script:DevRouterVisibility = @('list', 'hide', 'none')

# The 12 fields Codex >= 0.145 REQUIRES on every ModelInfo. `base_instructions`
# and `supports_parallel_tool_calls` are absent from models_cache.json and must
# come from the bundled official catalog; they are never synthesized.
$script:DevRouterRequiredCatalogFields = @('slug', 'display_name', 'supported_reasoning_levels', 'shell_type', 'visibility', 'supported_in_api', 'priority', 'base_instructions', 'support_verbosity', 'truncation_policy', 'supports_parallel_tool_calls', 'experimental_supported_tools')

# Process-scoped memo for `codex debug models --bundled` (resolved at most once).
$script:DevRouterBundledCatalog = $null

# Slugs the last Export-DevRouterModelCatalog call omitted (and why).
$script:DevRouterLastCatalogOmissions = @()

# Neutral operational text for the Dev Router's OWN local alias. This is not an
# official provider model, so the text is ours on purpose; it carries no
# workflow/AGENTS behaviour and no provider model instructions.
$script:DevRouterAdaptiveBaseInstructions = 'GPT-Adaptive is a local routing alias registered by the Codex Workflows Dev Router. It is not a model and defines no persona, workflow, or repository behaviour: requests addressed to this alias are forwarded by the local Dev Router to a concrete Codex model chosen for the turn. Behave as that model and answer the user directly.'

function Get-DevRouterBundledCatalog {
    <#
    .SYNOPSIS
    Returns the official compiled-in Codex model catalog, resolved once per process.

    `models_cache.json` omits `base_instructions` and
    `supports_parallel_tool_calls` (both REQUIRED by Codex >= 0.145), so the
    bundled catalog printed by `codex debug models --bundled` is the ONLY
    non-invented source for them. Fails closed (throws) when the catalog cannot
    be obtained, so callers never fall back to synthesized model instructions.
    #>
    param()

    if ($null -ne $script:DevRouterBundledCatalog) {
        return , $script:DevRouterBundledCatalog
    }

    if ($null -eq (Get-Command -Name 'codex' -ErrorAction SilentlyContinue)) {
        throw 'the codex CLI was not found on PATH; cannot read the bundled official model catalog (refusing to synthesize model instructions)'
    }

    # Native stderr (e.g. a leading "WARNING: ..." banner) must never become a
    # terminating error just because the caller runs with -ErrorAction Stop.
    $previousErrorActionPreference = $ErrorActionPreference
    $output = $null
    $exitCode = 0
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& codex debug models --bundled 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    }
    catch {
        throw "failed to run 'codex debug models --bundled': $($_.Exception.Message)"
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "'codex debug models --bundled' exited with code $exitCode (refusing to synthesize model instructions)"
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        throw "'codex debug models --bundled' produced no output"
    }

    # Some builds prefix stdout with a "WARNING: ..." banner; the JSON object
    # starts at the first '{'.
    $jsonStart = $output.IndexOf('{')
    if ($jsonStart -lt 0) {
        throw "'codex debug models --bundled' produced no JSON object"
    }
    $parsed = $null
    try {
        $parsed = ($output.Substring($jsonStart) | ConvertFrom-Json)
    }
    catch {
        throw "'codex debug models --bundled' returned unparsable JSON: $($_.Exception.Message)"
    }

    $candidates = @()
    if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
        $candidates = @($parsed)
    }
    elseif (@($parsed.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'models') {
        $candidates = @($parsed.models)
    }

    $bundledModels = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { continue }
        $candidateProps = @($candidate.PSObject.Properties | ForEach-Object { $_.Name })
        if ($candidateProps -notcontains 'slug') { continue }
        if ([string]::IsNullOrWhiteSpace([string]$candidate.slug)) { continue }
        $bundledModels.Add($candidate)
    }
    if ($bundledModels.Count -eq 0) {
        throw "'codex debug models --bundled' returned an empty model catalog"
    }

    $script:DevRouterBundledCatalog = $bundledModels.ToArray()
    return , $script:DevRouterBundledCatalog
}

function ConvertTo-DevRouterCatalogModel {
    <#
    .SYNOPSIS
    Merges a models-cache entry with its bundled official catalog entry.

    The cache entry is preserved VERBATIM: every original key/value is kept
    (Codex tolerates unknown keys and they may carry behaviour). Only the two
    fields Codex >= 0.145 REQUIRES but the cache omits are overlaid from the
    bundled catalog: `base_instructions` and `supports_parallel_tool_calls`.
    Neither is ever synthesized from `description`, `model_messages`, or a
    placeholder; a slug whose bundled entry lacks them is rejected so the
    caller can omit it.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$BundledEntry
    )

    $cacheProps = New-Object System.Collections.Generic.List[string]
    foreach ($property in $Model.PSObject.Properties) { $cacheProps.Add($property.Name) }

    # `description` and `model_messages` are NOT substitutes for
    # `base_instructions`, so nothing here may fall back to them.
    $slug = if ($cacheProps -contains 'slug') { [string]$Model.slug } else { '' }
    if ([string]::IsNullOrWhiteSpace($slug)) { throw 'catalog model entry is missing a slug' }

    $bundledProps = New-Object System.Collections.Generic.List[string]
    foreach ($property in $BundledEntry.PSObject.Properties) { $bundledProps.Add($property.Name) }

    if ($bundledProps -notcontains 'base_instructions') {
        throw "bundled official catalog has no 'base_instructions' for slug '$slug'"
    }
    $baseInstructions = [string]$BundledEntry.base_instructions
    if ([string]::IsNullOrWhiteSpace($baseInstructions)) {
        throw "bundled official catalog has empty 'base_instructions' for slug '$slug'"
    }
    if ($bundledProps -notcontains 'supports_parallel_tool_calls' -or $BundledEntry.supports_parallel_tool_calls -isnot [bool]) {
        throw "bundled official catalog has no boolean 'supports_parallel_tool_calls' for slug '$slug'"
    }

    # Verbatim copy of the cache entry.
    $entry = [ordered]@{}
    foreach ($property in $Model.PSObject.Properties) {
        $entry[$property.Name] = $property.Value
    }
    $entry['base_instructions'] = $baseInstructions
    $entry['supports_parallel_tool_calls'] = [bool]$BundledEntry.supports_parallel_tool_calls

    # Any other required field missing from the cache comes from the bundled
    # official entry when available; it is never invented.
    foreach ($field in $script:DevRouterRequiredCatalogFields) {
        if ($entry.Contains($field)) { continue }
        if ($bundledProps -notcontains $field) {
            throw "slug '$slug' has no cache value and no bundled value for required field '$field'"
        }
        $entry[$field] = $BundledEntry.$field
    }

    return [pscustomobject]$entry
}

function Get-DevRouterAdaptiveEfforts {
    <#
    .SYNOPSIS
    Returns the efforts GPT-Adaptive may advertise.

    The intersection of the eligible concrete models (Luna/Sol/Astra), so the
    alias never offers an effort no real model supports.
    #>
    param()

    $sets = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('Luna', 'Sol', 'Astra')) {
        if (-not $script:DevRouterModelCatalog.Contains($name)) { continue }
        $sets.Add(@($script:DevRouterModelCatalog[$name].SupportedEfforts))
    }
    if ($sets.Count -eq 0) {
        throw 'no eligible concrete models are configured; cannot derive GPT-Adaptive efforts'
    }
    $intersection = New-Object System.Collections.Generic.List[string]
    foreach ($effort in @($sets[0])) {
        $supportedByAll = $true
        for ($i = 1; $i -lt $sets.Count; $i++) {
            if (@($sets[$i]) -notcontains $effort) { $supportedByAll = $false; break }
        }
        if ($supportedByAll -and -not $intersection.Contains($effort)) { $intersection.Add($effort) }
    }
    if ($intersection.Count -eq 0) {
        throw 'the eligible concrete models share no reasoning effort; cannot build GPT-Adaptive'
    }
    return $intersection.ToArray()
}

function New-DevRouterAdaptiveCatalogModel {
    <#
    .SYNOPSIS
    Builds the `gpt-adaptive` entry: the Dev Router's OWN local alias.

    Unlike official models this entry is ours, so its operational text is
    written here on purpose. It carries no workflow/AGENTS behaviour and no
    provider model instructions; the Dev Router proxy rewrites the alias to a
    concrete model before the upstream call.
    #>
    param()

    $entry = [ordered]@{
        slug                         = 'gpt-adaptive'
        display_name                 = 'GPT-Adaptive'
        description                  = 'Adaptive intelligent model routing powered by TypeSafe/Jev'
        supported_reasoning_levels   = (ConvertTo-DevRouterReasoningLevels -Efforts (Get-DevRouterAdaptiveEfforts) -DefaultEffort 'medium')
        shell_type                   = 'default'
        visibility                   = 'list'
        supported_in_api             = $true
        priority                     = 0
        base_instructions            = $script:DevRouterAdaptiveBaseInstructions
        support_verbosity            = $true
        truncation_policy            = [ordered]@{ mode = 'tokens'; limit = 10000 }
        supports_parallel_tool_calls = $true
    }
    # An empty array literal inside a hashtable literal collapses to $null, which
    # Codex rejects ("invalid type: null, expected a sequence"). Assign a real
    # typed array through the indexer instead.
    $entry['experimental_supported_tools'] = (New-Object System.Collections.Generic.List[string]).ToArray()
    $entry['model_provider_id'] = 'dev-router'
    return [pscustomobject]$entry
}

function Test-DevRouterModelCatalogShape {
    <#
    .SYNOPSIS
    Structural validation for `model_catalog_json` artifacts.

    Fails closed so an incompatible catalog is never registered in config.toml:
    a bad catalog makes the Codex CLI unable to load ANY configuration.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ valid = $false; reason = "catalog file not found: $Path" }
    }
    try {
        $text = [IO.File]::ReadAllText($Path)
    }
    catch {
        return @{ valid = $false; reason = "catalog could not be read: $($_.Exception.Message)" }
    }
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) {
        return @{ valid = $false; reason = 'catalog is UTF-8 with a BOM; Codex and the proxy require BOM-free JSON' }
    }
    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        return @{ valid = $false; reason = "catalog is not valid JSON: $($_.Exception.Message)" }
    }

    # Root nesting must be checked on the RAW TEXT: PowerShell's ConvertFrom-Json
    # unrolls a single-element outer array, so the object graph cannot tell
    # `[[...]]` (required) apart from `[...]` (rejected by Codex).
    $cursor = 0
    while ($cursor -lt $text.Length -and [char]::IsWhiteSpace($text[$cursor])) { $cursor++ }
    if ($cursor -ge $text.Length -or $text[$cursor] -ne '[') {
        return @{ valid = $false; reason = 'catalog root must be a JSON array' }
    }
    $cursor++
    while ($cursor -lt $text.Length -and [char]::IsWhiteSpace($text[$cursor])) { $cursor++ }
    if ($cursor -ge $text.Length -or $text[$cursor] -ne '[') {
        return @{ valid = $false; reason = 'catalog root must be a sequence of sequences: expected a nested "[" group after the root "[" (Codex 0.145+ rejects a flat model array)' }
    }

    if ($parsed -is [string] -or -not ($parsed -is [System.Collections.IEnumerable])) {
        return @{ valid = $false; reason = 'catalog model group must be a JSON array' }
    }
    # ConvertFrom-Json enumerates the single-element outer array on PowerShell 7
    # but keeps it wrapped on Windows PowerShell 5.1, so both shapes must unwrap
    # to the flat model list.
    $models = @($parsed)
    if ($models.Count -eq 1 -and $null -ne $models[0] -and $models[0] -is [System.Collections.IEnumerable] -and -not ($models[0] -is [string])) {
        $models = @($models[0])
    }
    if ($models.Count -eq 0) {
        return @{ valid = $false; reason = 'catalog model group is empty' }
    }
    $required = $script:DevRouterRequiredCatalogFields
    $seenSlugs = New-Object System.Collections.Generic.List[string]
    foreach ($model in $models) {
        $props = @($model.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($field in $required) {
            if ($props -notcontains $field) {
                return @{ valid = $false; reason = "model entry is missing required field '$field'" }
            }
        }
        if ($props -contains 'supported_reasoning_efforts' -or $props -contains 'default_reasoning_effort' -or $props -contains 'id') {
            return @{ valid = $false; reason = "model entry uses the legacy catalog keys (id/supported_reasoning_efforts); Codex 0.145+ rejects them" }
        }
        foreach ($level in @($model.supported_reasoning_levels)) {
            $levelProps = @($level.PSObject.Properties | ForEach-Object { $_.Name })
            if ($levelProps -notcontains 'effort' -or $levelProps -notcontains 'description') {
                return @{ valid = $false; reason = "reasoning level must contain 'effort' and 'description'" }
            }
        }
        if ($model.visibility -notin @('list', 'hide', 'none')) {
            return @{ valid = $false; reason = "unsupported visibility '$($model.visibility)' (expected list|hide|none)" }
        }
        if ($model.shell_type -notin @('default', 'local', 'unified_exec', 'disabled', 'shell_command')) {
            return @{ valid = $false; reason = "unsupported shell_type '$($model.shell_type)'" }
        }
        $seenSlugs.Add([string]$model.slug)
    }
    if ($seenSlugs -notcontains 'gpt-adaptive') {
        return @{ valid = $false; reason = "catalog does not expose the 'gpt-adaptive' entry" }
    }
    return @{ valid = $true; reason = "catalog exposes $($models.Count) models: $($seenSlugs -join ', ')" }
}

function Restore-DevRouterCatalogFile {
    <#
    .SYNOPSIS
    Fail-closed recovery for a `model_catalog_json` artifact.

    Never leaves an incompatible catalog behind: restores the previous
    `.invalid-backup` when present, otherwise removes the file. A catalog that
    still passes structural validation is left untouched.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $shape = Test-DevRouterModelCatalogShape -Path $Path
    if ($shape.valid) { return }

    $backup = "$Path.invalid-backup"
    if (Test-Path -LiteralPath $backup -PathType Leaf) {
        Move-Item -LiteralPath $backup -Destination $Path -Force
    }
    else {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Export-DevRouterModelCatalog {
    <#
    .SYNOPSIS
    Writes the composite `model_catalog_json` artifact (GPT-Adaptive + official models).

    Official models are never normalized or synthesized: each models-cache entry
    is preserved verbatim and only `base_instructions` /
    `supports_parallel_tool_calls` are taken from the bundled official catalog.
    Cache slugs absent from the bundled catalog are omitted and recorded. When
    the bundled catalog cannot be obtained the export fails closed (throws)
    without writing anything.
    #>
    [CmdletBinding()]
    param(
        [string]$CodexHome,
        [string]$OutputPath,
        [switch]$PassThru
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $targetPath = if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath } else { $paths.CatalogFile }
    $targetDir = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($targetDir)
    }

    $omissions = New-Object System.Collections.Generic.List[object]

    # Fail closed BEFORE writing anything: without the bundled official catalog
    # there is no non-invented source for `base_instructions` /
    # `supports_parallel_tool_calls`, and synthesized instructions silently
    # change model behaviour.
    try {
        $bundledCatalog = Get-DevRouterBundledCatalog
    }
    catch {
        $script:DevRouterLastCatalogOmissions = $omissions.ToArray()
        Restore-DevRouterCatalogFile -Path $targetPath
        throw "Dev Router model catalog export aborted (fail closed): $($_.Exception.Message)"
    }

    $bundledBySlug = [ordered]@{}
    foreach ($bundled in $bundledCatalog) {
        $slug = [string]$bundled.slug
        if (-not [string]::IsNullOrWhiteSpace($slug) -and -not $bundledBySlug.Contains($slug)) {
            $bundledBySlug[$slug] = $bundled
        }
    }

    # Official models come from the Codex models cache. Each entry is preserved
    # VERBATIM (unknown keys may matter); only the two REQUIRED fields the cache
    # omits are overlaid from the bundled catalog. A cache slug absent from the
    # bundled catalog is OMITTED and recorded: its instructions cannot be
    # honestly produced.
    $cacheEntries = New-Object System.Collections.Generic.List[object]
    $cacheSlugs = New-Object System.Collections.Generic.List[string]
    $modelsCachePath = Join-Path $paths.CodexHome 'models_cache.json'
    if (Test-Path -LiteralPath $modelsCachePath -PathType Leaf) {
        try {
            $cacheObj = (Get-Content -LiteralPath $modelsCachePath -Raw -Encoding UTF8) | ConvertFrom-Json
            $rawEntries = @()
            if ($cacheObj -is [System.Collections.IEnumerable] -and -not ($cacheObj -is [string])) {
                $rawEntries = @($cacheObj)
            }
            elseif (@($cacheObj.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'models') {
                $rawEntries = @($cacheObj.models)
            }
            else {
                $rawEntries = @($cacheObj)
            }
            foreach ($raw in $rawEntries) {
                if ($null -eq $raw) { continue }
                $slug = if (@($raw.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'slug') { [string]$raw.slug } else { '' }
                if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'gpt-adaptive') { continue }
                $cacheEntries.Add($raw)
                if (-not $cacheSlugs.Contains($slug)) { $cacheSlugs.Add($slug) }
            }
        }
        catch {
            $reason = "models cache could not be parsed: $($_.Exception.Message)"
            $omissions.Add([pscustomobject]@{ slug = '(models_cache.json)'; reason = $reason })
            Write-Warning "Dev Router model catalog: ignoring unreadable models cache - $reason"
        }
    }

    $officialModels = New-Object System.Collections.Generic.List[object]
    foreach ($cacheEntry in $cacheEntries) {
        $slug = [string]$cacheEntry.slug
        if (-not $bundledBySlug.Contains($slug)) {
            $reason = "not present in the bundled official catalog ('codex debug models --bundled'); refusing to synthesize base_instructions"
            $omissions.Add([pscustomobject]@{ slug = $slug; reason = $reason })
            Write-Warning "Dev Router model catalog: omitting '$slug' - $reason"
            continue
        }
        try {
            $officialModels.Add((ConvertTo-DevRouterCatalogModel -Model $cacheEntry -BundledEntry $bundledBySlug[$slug]))
        }
        catch {
            $omissions.Add([pscustomobject]@{ slug = $slug; reason = [string]$_.Exception.Message })
            Write-Warning "Dev Router model catalog: omitting '$slug' - $($_.Exception.Message)"
        }
    }

    # Bundled models missing from the cache are still official: export them
    # verbatim instead of leaving them out of the selector.
    foreach ($bundled in $bundledCatalog) {
        $slug = [string]$bundled.slug
        if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'gpt-adaptive') { continue }
        if ($cacheSlugs.Contains($slug)) { continue }
        $officialModels.Add($bundled)
        Write-Verbose "Dev Router model catalog: added bundled official model '$slug' (absent from the models cache)"
    }

    # Virtual model: GPT-Adaptive routes through the loopback Dev Router proxy.
    $adaptiveEntry = New-DevRouterAdaptiveCatalogModel

    $group = New-Object System.Collections.Generic.List[object]
    $group.Add($adaptiveEntry)
    foreach ($m in $officialModels) {
        if ($m.slug -ne 'gpt-adaptive') { $group.Add($m) }
    }

    # Nested sequence: Codex expects Vec<Vec<ModelInfo>>, not a flat Vec<ModelInfo>.
    # -InputObject with a single-element outer array is required; piping would
    # flatten the nesting and Codex would reject the catalog.
    $json = (ConvertTo-Json -InputObject @(, @($group.ToArray())) -Depth 100) + [Environment]::NewLine
    $tempFile = Join-Path $targetDir ("model-catalog-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBom)
    Move-Item -LiteralPath $tempFile -Destination $targetPath -Force

    $shape = Test-DevRouterModelCatalogShape -Path $targetPath
    if (-not $shape.valid) {
        # Never leave an incompatible catalog behind: restore the previous one or
        # remove the file so Codex can still load its configuration.
        Restore-DevRouterCatalogFile -Path $targetPath
        throw "Dev Router model catalog failed structural validation: $($shape.reason)"
    }

    $script:DevRouterLastCatalogOmissions = $omissions.ToArray()
    if ($omissions.Count -gt 0) {
        Write-Verbose ("Dev Router model catalog omitted: " + ((@($omissions | ForEach-Object { $_.slug })) -join ', '))
    }

    if ($PassThru) {
        return [pscustomobject]@{
            Path      = $targetPath
            Omissions = $omissions.ToArray()
            Models    = $group.ToArray()
        }
    }
    return $targetPath
}

function Get-DevRouterRawState {
    <#
    .SYNOPSIS
    Full state object including manual_base_model / manual_base_effort.
    Get-DevRouterState intentionally narrows the shape; integration and baseline
    decisions need the raw record.
    #>
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $paths.StateFile -PathType Leaf)) {
        return [ordered]@{ mode = 'off'; target = 'effort_only'; manual_base_model = $null; manual_base_effort = $null }
    }
    try {
        $state = (Get-Content -LiteralPath $paths.StateFile -Raw -Encoding UTF8) | ConvertFrom-Json
        $model = $null
        $effort = $null
        if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'manual_base_model') { $model = [string]$state.manual_base_model }
        if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'manual_base_effort') { $effort = [string]$state.manual_base_effort }
        return [ordered]@{
            mode               = if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'mode') { [string]$state.mode } else { 'off' }
            target             = if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'target') { [string]$state.target } else { 'effort_only' }
            manual_base_model  = if ([string]::IsNullOrWhiteSpace($model)) { $null } else { $model }
            manual_base_effort = if ([string]::IsNullOrWhiteSpace($effort)) { $null } else { $effort }
        }
    }
    catch {
        return [ordered]@{ mode = 'off'; target = 'effort_only'; manual_base_model = $null; manual_base_effort = $null }
    }
}

function Set-DevRouterManualBase {
    <#
    .SYNOPSIS
    Seeds the concrete manual base the proxy falls back to for the local alias.

    GPT-Adaptive is NOT a concrete model: the proxy needs a real model for OFF,
    shadow, Jev timeout/error and missing TYPESAFE_API_KEY. This never invents
    one; the caller must supply a concrete allowed model.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$Effort,
        [string]$CodexHome
    )

    return Invoke-DevRouterSynchronized -LockName 'State' -ScriptBlock {
        $paths = Get-DevRouterPaths -CodexHome $CodexHome
        if (-not (Test-Path -LiteralPath $paths.KitDir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($paths.KitDir)
        }
        $raw = Get-DevRouterRawState -CodexHome $CodexHome
        $now = [datetime]::UtcNow.ToString('o')
        $stateObj = [ordered]@{
            version            = 1
            product            = 'codex-workflows-kit'
            component          = 'dev-router'
            mode               = $raw.mode
            target             = $raw.target
            manual_base_model  = $Model
            manual_base_effort = if ([string]::IsNullOrWhiteSpace($Effort)) { $null } else { $Effort }
            updatedAt          = $now
        }
        $json = ($stateObj | ConvertTo-Json -Depth 4) + [Environment]::NewLine
        $tempFile = Join-Path $paths.KitDir ("dev-router-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBom)
        Move-Item -LiteralPath $tempFile -Destination $paths.StateFile -Force
        return $stateObj
    }
}

function Set-DevRouterTopLevelValues {
    <#
    .SYNOPSIS
    Rewrites TOP-LEVEL config.toml keys, preserving every other line, comment and
    section verbatim. A $null value removes the key.

    Only keys before the first `[section]` header are touched, so custom providers
    and profiles owned by the user are never disturbed. Written UTF-8 without BOM
    (a BOM breaks Codex config loading).
    #>
    param(
        [string]$CodexHome,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $lines = @()
    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8)
    }

    $out = New-Object System.Collections.Generic.List[string]
    $handled = @{}
    $inTopLevel = $true

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[')) { $inTopLevel = $false }
        if ($inTopLevel -and $trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')) {
            $matched = $false
            foreach ($key in @($Values.Keys)) {
                if ($trimmed -match ('^' + [regex]::Escape([string]$key) + '\s*=')) {
                    if ($null -ne $Values[$key]) {
                        $out.Add([string]$key + ' = "' + [string]$Values[$key] + '"')
                    }
                    $handled[[string]$key] = $true
                    $matched = $true
                    break
                }
            }
            if ($matched) { continue }
        }
        $out.Add($line)
    }

    foreach ($key in @($Values.Keys)) {
        if ($null -eq $Values[$key]) { continue }
        if ($handled.ContainsKey([string]$key)) { continue }
        $insertIdx = 0
        while ($insertIdx -lt $out.Count -and ($out[$insertIdx].Trim().StartsWith('#') -or $out[$insertIdx].Trim().Length -eq 0)) {
            $insertIdx++
        }
        $out.Insert($insertIdx, [string]$key + ' = "' + [string]$Values[$key] + '"')
        $handled[[string]$key] = $true
    }

    $tomlContent = (($out -join [Environment]::NewLine).TrimEnd()) + [Environment]::NewLine
    $tempConfig = Join-Path $paths.CodexHome ("config-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempConfig, $tomlContent, $script:Utf8NoBom)
    Move-Item -LiteralPath $tempConfig -Destination $paths.ConfigToml -Force
}

function Test-DevRouterProviderBlockDeclared {
    param([string]$CodexHome)
    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf)) { return $false }
    try {
        return ((Get-Content -LiteralPath $paths.ConfigToml -Raw -Encoding UTF8) -match '\[model_providers\.dev-router\]')
    }
    catch { return $false }
}

function Set-DevRouterProviderBlock {
    <#
    .SYNOPSIS
    Installs the local Dev Router provider section, replacing any existing one.

    The block is appended at the end so user sections keep their positions.
    #>
    param(
        [string]$CodexHome,
        [int]$Port = 4040
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $lines = @()
    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8)
    }

    $out = New-Object System.Collections.Generic.List[string]
    $skipping = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '[model_providers.dev-router]') { $skipping = $true; continue }
        if ($skipping) {
            if ($trimmed.StartsWith('[')) { $skipping = $false }
            else { continue }
        }
        $out.Add($line)
    }

    # NOTE: the concatenation MUST be parenthesized. Inside an @() array literal
    # PowerShell binds the comma tighter than `+`, so a bare
    # `'prefix' + $Port + 'suffix'` element is parsed as THREE elements (with
    # unary plus), which silently corrupts the emitted TOML.
    $baseUrlLine = 'base_url = "http://127.0.0.1:' + $Port + '/v1"'
    $block = @(
        '',
        '[model_providers.dev-router]',
        'name = "Dev Router"',
        $baseUrlLine,
        'wire_api = "responses"',
        'requires_openai_auth = true'
    )
    foreach ($b in $block) { $out.Add($b) }

    $tomlContent = (($out -join [Environment]::NewLine).TrimEnd()) + [Environment]::NewLine
    $tempConfig = Join-Path $paths.CodexHome ("config-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempConfig, $tomlContent, $script:Utf8NoBom)
    Move-Item -LiteralPath $tempConfig -Destination $paths.ConfigToml -Force
}

function Remove-DevRouterProviderBlock {
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf)) { return $false }

    $lines = @(Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8)
    $out = New-Object System.Collections.Generic.List[string]
    $skipping = $false
    $removed = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '[model_providers.dev-router]') { $skipping = $true; $removed = $true; continue }
        if ($skipping) {
            if ($trimmed.StartsWith('[')) { $skipping = $false }
            else { continue }
        }
        $out.Add($line)
    }
    if (-not $removed) { return $false }

    $tomlContent = (($out -join [Environment]::NewLine).TrimEnd()) + [Environment]::NewLine
    $tempConfig = Join-Path $paths.CodexHome ("config-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempConfig, $tomlContent, $script:Utf8NoBom)
    Move-Item -LiteralPath $tempConfig -Destination $paths.ConfigToml -Force
    return $true
}

function Test-DevRouterCodexConfigLoadable {
    <#
    .SYNOPSIS
    Real-Codex validation: the generated configuration must actually load.

    Uses a read-only command that parses config.toml (and therefore
    model_catalog_json). No model request is made. Fails closed when the codex
    binary is unavailable so we never claim a config is valid without proof.
    #>
    param(
        [string]$CodexHome,
        [int]$TimeoutMs = 30000
    )

    $codexCmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $codexCmd) {
        return [ordered]@{ Validated = $false; Reason = "codex binary not found on PATH; cannot prove the generated config loads." }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $codexCmd.Source
    $psi.Arguments = 'debug models'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
            return [ordered]@{ Validated = $false; Reason = "codex config validation timed out after ${TimeoutMs}ms." }
        }
        if ($proc.ExitCode -ne 0) {
            $detail = ($stderr + ' ' + $stdout).Trim()
            if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
            return [ordered]@{ Validated = $false; Reason = "codex rejected the generated configuration: " + $detail }
        }
        return [ordered]@{ Validated = $true; Reason = 'codex loaded the generated configuration.' }
    }
    catch {
        return [ordered]@{ Validated = $false; Reason = "codex config validation failed: " + $_.Exception.Message }
    }
}

function Get-DevRouterIntegrationBackupPath {
    param([string]$CodexHome)
    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    return (Join-Path $paths.KitDir 'dev-router-integration-backup.json')
}

function Register-DevRouterCodexIntegration {
    <#
    .SYNOPSIS
    Transactionally activates the Dev Router as Codex's EFFECTIVE provider.

    Declaring `[model_providers.dev-router]` is not enough: the original Desktop
    bug was `model = "gpt-adaptive"` with `model_provider = "openai"`, so the
    local alias was sent to the ChatGPT backend and rejected with "The
    'gpt-adaptive' model is not supported when using Codex with a ChatGPT
    account." This function also SELECTS the provider, guarantees the proxy is
    alive, proves the generated config loads in the real Codex, and restores the
    previous configuration on any failure.
    #>
    param(
        [string]$CodexHome,
        [int]$Port = 4040,
        [string]$ManualBaseModel = $null,
        [string]$ManualBaseEffort = $null,
        [switch]$SkipProxyStart,
        [switch]$SkipCodexValidation
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $paths.KitDir -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($paths.KitDir)
    }

    # --- Snapshot for rollback BEFORE any mutation -------------------------
    $previous = Get-CodexTopLevelConfig -CodexHome $CodexHome
    $hadProviderBlock = Test-DevRouterProviderBlockDeclared -CodexHome $CodexHome
    $previousState = Get-DevRouterRawState -CodexHome $CodexHome

    $backupPath = Get-DevRouterIntegrationBackupPath -CodexHome $CodexHome
    $proxyWasRunning = (Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $Port -TimeoutMs 400).Running

    # Resolve the concrete base the proxy will fall back to. GPT-Adaptive is an
    # alias, never a base: prefer an explicit override, then an existing manual
    # base, then a concrete top-level model.
    $baseModel = $null
    $baseEffort = $null
    $effectiveModel = $previous.Model
    if (-not [string]::IsNullOrWhiteSpace($ManualBaseModel)) {
        $baseModel = $ManualBaseModel.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($previousState.manual_base_model)) {
        $baseModel = $previousState.manual_base_model
    }
    elseif (-not [string]::IsNullOrWhiteSpace($previous.Model) -and $previous.Model -ne 'gpt-adaptive') {
        $baseModel = $previous.Model
    }
    if (-not [string]::IsNullOrWhiteSpace($ManualBaseEffort)) {
        $baseEffort = $ManualBaseEffort.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($previousState.manual_base_effort)) {
        $baseEffort = $previousState.manual_base_effort
    }
    elseif (-not [string]::IsNullOrWhiteSpace($previous.ModelEffort)) {
        $baseEffort = $previous.ModelEffort
    }

    $resolvedBase = $null
    if (-not [string]::IsNullOrWhiteSpace($baseModel)) {
        $resolvedBase = Resolve-DevRouterModel -ModelNameOrId $baseModel -IncludeDisallowed
    }

    if ($null -eq $resolvedBase) {
        # Fail closed BEFORE touching config.toml. Never silently invent Sol.
        throw ("Dev Router cannot activate: no concrete manual base model is available. " +
            "GPT-Adaptive is a local alias and is never used as a base. " +
            "Select a concrete model in the Desktop, or pass -ManualBaseModel (e.g. gpt-5.6-sol).")
    }

    $result = [ordered]@{
        CatalogPath        = $null
        ConfigToml         = $paths.ConfigToml
        Port               = $Port
        Provider           = 'dev-router'
        ProviderSelected   = $false
        ProxyRunning       = $false
        ProxyHealth        = $false
        Upstream           = $null
        UpstreamSource     = $null
        ManualBaseModel    = $resolvedBase.Name
        ManualBaseEffort   = $baseEffort
        RollbackPerformed  = $false
    }

    $mutationStarted = $false
    try {
        # 1. Build + validate the catalog (fails closed internally).
        $catalogPath = Export-DevRouterModelCatalog -CodexHome $CodexHome
        $result.CatalogPath = $catalogPath

        # 2. Persist the rollback snapshot.
        $backup = [ordered]@{
            schemaVersion            = 1
            createdAt                = [datetime]::UtcNow.ToString('o')
            model                    = $previous.Model
            model_provider           = $previous.ModelProvider
            model_catalog_json       = $previous.ModelCatalogJson
            model_reasoning_effort   = $previous.ModelEffort
            hadDevRouterProviderBlock = $hadProviderBlock
            manual_base_model        = $previousState.manual_base_model
            manual_base_effort       = $previousState.manual_base_effort
        }
        [IO.File]::WriteAllText($backupPath, (($backup | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $script:Utf8NoBom)

        # 3. Deploy proxy + canonical policy files.
        $repoDir = Split-Path -Parent $PSCommandPath
        foreach ($file in @('dev-router-proxy.mjs', 'dev-router-policy.json', 'dev-router-policy.mjs', 'dev-router-policy-cli.mjs')) {
            $src = Join-Path $repoDir $file
            if (Test-Path -LiteralPath $src -PathType Leaf) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $paths.KitDir $file) -Force
            }
        }
        if (-not (Test-Path -LiteralPath $paths.ProxyScript -PathType Leaf)) {
            throw "Dev Router proxy script is not deployed at '$($paths.ProxyScript)'."
        }

        # 4/5. The proxy MUST be alive before the provider is selected, otherwise
        # the config would point at a dead port.
        $mutationStarted = $true
        if (-not $SkipProxyStart) {
            $proxyStatus = Start-DevRouterProxy -CodexHome $CodexHome -Port $Port
            if (-not $proxyStatus.Running) {
                throw "Dev Router proxy did not become healthy on port $Port; refusing to activate the provider."
            }
            $result.ProxyRunning = $true
            $result.ProxyHealth = $true
        }

        # 6. Select the provider and register the catalog.
        # Suppress the helper's return value: anything written to the output
        # stream here would be prepended to this function's own result.
        $null = Set-DevRouterManualBase -Model $resolvedBase.Name -Effort $baseEffort -CodexHome $CodexHome
        Set-DevRouterTopLevelValues -CodexHome $CodexHome -Values @{
            model_provider    = 'dev-router'
            model_catalog_json = ($catalogPath -replace '\\', '/')
        }
        Set-DevRouterProviderBlock -CodexHome $CodexHome -Port $Port

        $integration = Get-DevRouterUpstream -CodexHome $CodexHome -EnvOverride $env:DEV_ROUTER_UPSTREAM
        $result.Upstream = $integration.Upstream
        $result.UpstreamSource = $integration.Source

        # 7. Prove the generated config actually loads in the real Codex.
        if (-not $SkipCodexValidation) {
            $validation = Test-DevRouterCodexConfigLoadable -CodexHome $CodexHome
            if (-not $validation.Validated) {
                throw ("Dev Router activation aborted: " + $validation.Reason)
            }
        }

        # 8. Mark active.
        $result.ProviderSelected = Test-DevRouterProviderSelected -CodexHome $CodexHome
        if (-not $result.ProviderSelected) {
            throw "Dev Router activation aborted: model_provider was not applied."
        }
        return $result
    }
    catch {
        $failure = $_
        if ($mutationStarted) {
            # Automatic rollback: restore the exact previous config and stop the
            # proxy we may have started, so Codex is never left unusable.
            try {
                $restoreValues = @{
                    model_catalog_json = $previous.ModelCatalogJson
                    model_provider     = $previous.ModelProvider
                }
                if ([string]::IsNullOrWhiteSpace($previous.ModelCatalogJson)) {
                    $restoreValues['model_catalog_json'] = $null
                }
                if ([string]::IsNullOrWhiteSpace($previous.ModelProvider)) {
                    $restoreValues['model_provider'] = $null
                }
                Set-DevRouterTopLevelValues -CodexHome $CodexHome -Values $restoreValues
                if (-not $hadProviderBlock) {
                    [void](Remove-DevRouterProviderBlock -CodexHome $CodexHome)
                }
                else {
                    Set-DevRouterProviderBlock -CodexHome $CodexHome -Port $Port
                }
                if (-not $proxyWasRunning) {
                    [void](Stop-DevRouterProxy -CodexHome $CodexHome -Port $Port)
                }
            }
            catch {}
            $result.RollbackPerformed = $true
        }
        throw $failure
    }
}

function Unregister-DevRouterCodexIntegration {
    <#
    .SYNOPSIS
    Reverses Register-DevRouterCodexIntegration exactly.

    Restores the previous top-level model_provider / model_catalog_json /
    model_reasoning_effort from the managed backup, removes only Dev Router
    artifacts, and stops only the proxy this kit owns (pid file). Custom
    providers, profiles and unrelated MCP definitions are preserved.
    #>
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $backupPath = Get-DevRouterIntegrationBackupPath -CodexHome $CodexHome

    # Stop only OUR proxy: Stop-DevRouterProxy uses the kit pid file.
    [void](Stop-DevRouterProxy -CodexHome $CodexHome)

    $restored = $false
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        try {
            $backup = (Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8) | ConvertFrom-Json
            $values = @{}
            $values['model_provider'] = [string]$backup.model_provider
            $values['model_catalog_json'] = [string]$backup.model_catalog_json
            $values['model_reasoning_effort'] = [string]$backup.model_reasoning_effort
            foreach ($key in @('model_provider', 'model_catalog_json', 'model_reasoning_effort')) {
                if ([string]::IsNullOrWhiteSpace($values[$key])) { $values[$key] = $null }
            }
            Set-DevRouterTopLevelValues -CodexHome $CodexHome -Values $values

            # Restore the manual base only if Register seeded it (i.e. it was absent before).
            if ([string]::IsNullOrWhiteSpace($backup.manual_base_model)) {
                $raw = Get-DevRouterRawState -CodexHome $CodexHome
                if (-not [string]::IsNullOrWhiteSpace($raw.manual_base_model)) {
                    $restore = Get-DevRouterRawState -CodexHome $CodexHome
                    $stateObj = [ordered]@{
                        version            = 1
                        product            = 'codex-workflows-kit'
                        component          = 'dev-router'
                        mode               = $restore.mode
                        target             = $restore.target
                        manual_base_model  = $backup.manual_base_model
                        manual_base_effort = $backup.manual_base_effort
                        updatedAt          = [datetime]::UtcNow.ToString('o')
                    }
                    $tempFile = Join-Path $paths.KitDir ("dev-router-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
                    [IO.File]::WriteAllText($tempFile, (($stateObj | ConvertTo-Json -Depth 4) + [Environment]::NewLine), $script:Utf8NoBom)
                    Move-Item -LiteralPath $tempFile -Destination $paths.StateFile -Force
                }
            }
            $restored = $true
        }
        catch {
            # Fall through to the structural cleanup below; never leave the alias
            # as the active provider.
        }
    }

    # Remove the Dev Router provider block only.
    [void](Remove-DevRouterProviderBlock -CodexHome $CodexHome)

    # Safety net: if the catalog line still points at our artifact and no backup
    # was available, clear it so Codex does not keep loading a removed file.
    if (-not $restored) {
        $top = Get-CodexTopLevelConfig -CodexHome $CodexHome
        if (-not [string]::IsNullOrWhiteSpace($top.ModelCatalogJson) -and $top.ModelCatalogJson -match 'codex-workflows-kit[/\\]model-catalog\.json') {
            Set-DevRouterTopLevelValues -CodexHome $CodexHome -Values @{ model_catalog_json = $null }
        }
    }

    if (Test-Path -LiteralPath $paths.CatalogFile -PathType Leaf) {
        Remove-Item -LiteralPath $paths.CatalogFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Get-DevRouterIntegrationReadiness {
    <#
    .SYNOPSIS
    Machine-checkable readiness of the Desktop integration.

    Status ladder (never reports ready without proof):
      inactive           - no catalog and no provider selection
      catalog_only       - catalog registered but the provider is NOT selected
                           (the exact original Desktop bug: GPT-Adaptive visible
                           in the dropdown but requests sent to the default
                           provider)
      provider_registered- provider selected but the proxy is not healthy
      degraded           - provider + proxy ok, but no concrete manual base
      ready              - catalog valid + provider SELECTED + proxy healthy +
                           concrete manual base available
    #>
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $top = Get-CodexTopLevelConfig -CodexHome $CodexHome
    $raw = Get-DevRouterRawState -CodexHome $CodexHome

    $catalogRegistered = -not [string]::IsNullOrWhiteSpace($top.ModelCatalogJson)
    $catalogValid = $false
    $catalogPresent = $false
    if (Test-Path -LiteralPath $paths.CatalogFile -PathType Leaf) {
        $catalogPresent = $true
        $shape = Test-DevRouterModelCatalogShape -Path $paths.CatalogFile
        $catalogValid = [bool]$shape.valid
    }
    $providerRegistered = Test-DevRouterProviderBlockDeclared -CodexHome $CodexHome
    $providerSelected = Test-DevRouterProviderSelected -CodexHome $CodexHome

    $configuredPort = 4040
    try {
        $toml = Get-Content -LiteralPath $paths.ConfigToml -Raw -Encoding UTF8
        $pMatch = [regex]::Match($toml, '(?i)base_url\s*=\s*"http://127\.0\.0\.1:(\d+)/v1"')
        if ($pMatch.Success) { $configuredPort = [int]$pMatch.Groups[1].Value }
    }
    catch {}

    $proxyStatus = Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $configuredPort -TimeoutMs 600
    $proxyRunning = [bool]$proxyStatus.Running
    $proxyHealth = $false
    $upstreamHost = $null
    $upstreamPath = $null
    $upstreamSource = $null
    if ($proxyRunning) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$configuredPort/health")
            $req.Timeout = 600
            $req.ReadWriteTimeout = 600
            $res = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($res.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Close(); $res.Close()
            $health = $body | ConvertFrom-Json
            $proxyHealth = ([string]$health.status -eq 'ok')
            $upstreamHost = [string]$health.upstream_host
            $upstreamPath = [string]$health.upstream_path
            $upstreamSource = [string]$health.upstream_source
        }
        catch {}
    }

    $manualBaseAvailable = -not [string]::IsNullOrWhiteSpace($raw.manual_base_model)
    $resolvedBase = $null
    if ($manualBaseAvailable) {
        $resolvedBase = Resolve-DevRouterModel -ModelNameOrId $raw.manual_base_model -IncludeDisallowed
        if ($null -eq $resolvedBase) { $manualBaseAvailable = $false }
    }

    $integrationStatus = 'inactive'
    if ($providerSelected -and $proxyHealth -and $catalogValid -and $manualBaseAvailable) {
        $integrationStatus = 'ready'
    }
    elseif ($providerSelected -and $proxyRunning) {
        $integrationStatus = 'degraded'
    }
    elseif ($providerSelected) {
        $integrationStatus = 'provider_registered'
    }
    elseif ($providerRegistered -or $catalogRegistered) {
        $integrationStatus = 'catalog_only'
    }

    $notes = switch ($integrationStatus) {
        'ready' { "Dev Router is the effective Codex provider; the proxy is healthy on 127.0.0.1:$configuredPort and forwards to $upstreamHost$upstreamPath (source=$upstreamSource)." }
        'degraded' { 'Dev Router is selected as provider but the integration is incomplete (proxy health or concrete manual base missing).' }
        'provider_registered' { 'Dev Router provider is selected but the proxy is not responding; requests would fail.' }
        'catalog_only' { 'GPT-Adaptive is visible in the model catalog but the Dev Router provider is NOT selected, so requests go to the default provider and the alias is rejected by the ChatGPT backend.' }
        default { 'Dev Router integration is not active.' }
    }

    return [ordered]@{
        integration_status   = $integrationStatus
        integration_notes    = $notes
        catalog_registered   = $catalogRegistered
        catalog_present      = $catalogPresent
        catalog_valid        = $catalogValid
        provider_registered  = $providerRegistered
        provider_selected    = $providerSelected
        proxy_running        = $proxyRunning
        proxy_health         = $proxyHealth
        proxy_port           = $configuredPort
        manual_base_available = $manualBaseAvailable
        manual_base_model    = $raw.manual_base_model
        upstream_host        = $upstreamHost
        upstream_path        = $upstreamPath
        upstream_source      = $upstreamSource
        model                = $top.Model
    }
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

    # Integration Status check. Readiness (not just "proxy + catalog") is
    # required: declaring a provider is not the same as selecting it, and the
    # original Desktop bug was exactly catalog-without-provider-selection.
    $readiness = Get-DevRouterIntegrationReadiness -CodexHome $CodexHome
    $configuredPort = [int]$readiness.proxy_port
    $proxyStatus = Get-DevRouterProxyStatus -CodexHome $CodexHome -Port $configuredPort -TimeoutMs 500
    $catalogRegistered = [bool]$readiness.catalog_registered

    $integrationStatus = [string]$readiness.integration_status
    $integrationNotes = [string]$readiness.integration_notes

    $effectiveMode = switch ($state.mode) {
        'off'    { 'off' }
        'shadow' { 'shadow' }
        'on'     {
            if ($integrationStatus -eq 'ready') {
                'on'
            }
            else {
                # The route cannot be applied until the provider is selected and
                # the proxy is healthy; report bypass instead of a false "on".
                'bypass'
            }
        }
        default  { 'off' }
    }

    # Display the CONCRETE model that will actually be used. Showing the alias
    # here is what made the original catalog-only bug look healthy.
    $baselineDisplayModel = if ($readiness.manual_base_available) {
        [string]$readiness.manual_base_model
    }
    elseif (-not [string]::IsNullOrWhiteSpace($baseline.Model) -and $baseline.Model -ne 'gpt-adaptive') {
        [string]$baseline.Model
    }
    else {
        '(none - set a manual base)'
    }
    $baselineDisplayEffort = if (-not [string]::IsNullOrWhiteSpace($baseline.Effort)) {
        [string]$baseline.Effort
    }
    else {
        'medium'
    }

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
        readiness           = $readiness
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

    # Formulate question, options and criteria through the canonical policy module
    $optionSet = Invoke-DevRouterPolicyCli -Operation 'buildOptionSet' -Request @{
        target         = $Target
        baselineModel  = $baselineModelName
        baselineEffort = $baselineEffortVal
    }

    if ([bool]$optionSet.incompatible) {
        return [ordered]@{
            model        = $baselineModelName
            effort       = $baselineEffortVal
            status       = 'incompatible'
            is_fallback  = $true
            reason       = [string]$optionSet.reason
            confidence   = 0.0
            probabilities= $null
            selected_raw = $null
        }
    }

    $instructions = [string]$optionSet.instructions
    $options = @($optionSet.options)
    $criteria = $optionSet.criteria

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
    $jevEndpoint = if (-not [string]::IsNullOrWhiteSpace($env:DEV_ROUTER_JEV_ENDPOINT)) { $env:DEV_ROUTER_JEV_ENDPOINT } else { 'https://api.typesafe.ai/v1/systemone' }
    $responseObj = $null
    if ($null -ne $HttpTransportMock) {
        try {
            $mockReq = [pscustomobject]@{
                Endpoint   = $jevEndpoint
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
        $endpoint = $jevEndpoint
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

    $result = Invoke-DevRouterPolicyCli -Operation 'parseChoice' -Request @{
        choice         = $Chosen
        target         = $Target
        baselineModel  = $BaselineModel
        baselineEffort = $BaselineEffort
    }

    $status = if ([bool]$result.ok) { 'ok' } else { [string]$result.status }
    if ($status -eq 'pair_incompatible') {
        $status = 'incompatible'
    }

    $resolvedModel = if ([string]::IsNullOrWhiteSpace([string]$result.model)) { $BaselineModel } else { [string]$result.model }
    $resolvedEffort = if ([string]::IsNullOrWhiteSpace([string]$result.effort)) { $BaselineEffort } else { [string]$result.effort }
    $selectedRaw = if ($null -eq $result.selectedRaw) { $null } else { [string]$result.selectedRaw }

    return [ordered]@{
        model        = $resolvedModel
        effort       = $resolvedEffort
        status       = $status
        is_fallback  = -not [bool]$result.ok
        reason       = [string]$result.reason
        confidence   = if ([bool]$result.ok) { $Confidence } else { 0.0 }
        probabilities= if ([bool]$result.ok) { $Probabilities } else { $null }
        selected_raw = $selectedRaw
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
        $offDecision = Invoke-DevRouterPolicyCli -Operation 'decideRoute' -Request @{
            mode            = 'off'
            target          = [string]$state.target
            baseline        = @{ model = $resolvedBaselineModel; effort = $resolvedBaselineEffort }
            requestedEffort = $resolvedBaselineEffort
        }
        return [ordered]@{
            conversation_id   = $ConversationId
            configured_mode   = 'off'
            effective_mode    = 'off'
            target            = [string]$state.target
            applied_model     = [string]$offDecision.model
            applied_effort    = [string]$offDecision.effort
            recommended_model = $null
            recommended_effort= $null
            status            = [string]$offDecision.status
            is_locked         = $false
            lock_scope        = 'none'
            reason            = [string]$offDecision.reason
            jev_called        = [bool]$offDecision.jevCalled
        }
    }

    # 2. Check Existing Active Lock for this conversation (Thread Isolation & Precedence)
    $existingLock = Get-DevRouterLock -ConversationId $ConversationId -CodexHome $CodexHome
    if ($null -ne $existingLock) {
        $lockValid = [bool](Invoke-DevRouterPolicyCli -Operation 'isLockValid' -Request @{
                lock        = $existingLock
                mode        = [string]$state.mode
                target      = [string]$state.target
                surface     = $Surface
                executionId = $ExecutionId
                turnId      = $TurnId
            })

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

    # 5. Take the routing decision from the canonical policy module
    $decision = Invoke-DevRouterPolicyCli -Operation 'decideRoute' -Request @{
        mode            = [string]$state.mode
        target          = [string]$state.target
        baseline        = @{ model = $resolvedBaselineModel; effort = $resolvedBaselineEffort }
        requestedEffort = $resolvedBaselineEffort
        jevChoice       = $jevResult.selected_raw
        jevStatus       = [string]$jevResult.status
    }
    $decisionModel = if ([string]::IsNullOrWhiteSpace([string]$decision.model)) { $resolvedBaselineModel } else { [string]$decision.model }
    $decisionEffort = if ([string]::IsNullOrWhiteSpace([string]$decision.effort)) { $resolvedBaselineEffort } else { [string]$decision.effort }

    # 6. Handle Shadow Mode
    if ($state.mode -eq 'shadow') {
        return [ordered]@{
            conversation_id   = $ConversationId
            configured_mode   = 'shadow'
            effective_mode    = 'shadow'
            target            = [string]$state.target
            applied_model     = $decisionModel
            applied_effort    = $decisionEffort
            recommended_model = $recommendedModel
            recommended_effort= $recommendedEffort
            status            = [string]$decision.status
            is_locked         = $false
            lock_scope        = 'none'
            reason            = [string]$decision.reason
            jev_called        = [bool]$decision.jevCalled
        }
    }

    # 7. Revalidate Final Pair Compatibility through the canonical policy
    $pairSupported = $true
    if (-not [string]::IsNullOrWhiteSpace($decisionEffort)) {
        $pairSupported = Test-DevRouterEffortSupported -ModelNameOrId $decisionModel -Effort $decisionEffort
    }
    if (-not $pairSupported -or ([bool]$decision.isFallback -and [string]$decision.status -eq 'incompatible')) {
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
            reason            = [string]$decision.reason
            jev_called        = [bool]$decision.jevCalled
        }
    }

    # 8. Check Desktop GUI Surface vs CLI Harness
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
            jev_called        = [bool]$decision.jevCalled
        }
    }

    # Active Route Applied (decision from the canonical policy module):
    $appliedModel = $decisionModel
    $appliedEffort = $decisionEffort

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
        status            = [string]$decision.status
        is_locked         = $true
        lock_scope        = $scope
        reason            = [string]$decision.reason
        jev_called        = [bool]$decision.jevCalled
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
    Test-DevRouterModelCatalogShape, `
    Test-DevRouterCatalogRegistered, `
    Register-DevRouterCodexIntegration, `
    Unregister-DevRouterCodexIntegration, `
    Get-DevRouterIntegrationReadiness, `
    Test-DevRouterProviderSelected, `
    Test-DevRouterProviderBlockDeclared, `
    Get-DevRouterUpstream, `
    Get-CodexTopLevelConfig, `
    Set-DevRouterManualBase, `
    Get-DevRouterProxyStatus, `
    Start-DevRouterProxy, `
    Stop-DevRouterProxy
