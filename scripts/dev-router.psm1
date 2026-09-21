Set-StrictMode -Version Latest

# Dev Router Module (TypeSafe/Jev Autonomous Orchestrator Router)
# Controls parent orchestrator model and reasoning effort for Codex App / CLI.
# Supports ALINHAMENTO conversations and explicit workflows with thread isolation.

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

$script:DisallowedModels = @('gpt-5.6-terra', 'terra')
$script:AllValidEfforts = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh')

function Get-DevRouterModelCatalog {
    return [ordered]@{
        Models           = $script:DevRouterModelCatalog
        DisallowedModels = @($script:DisallowedModels)
        AllValidEfforts  = @($script:AllValidEfforts)
    }
}

function Resolve-DevRouterModel {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    $raw = $ModelNameOrId.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    # Explicit check for disallowed models
    foreach ($disallowed in $script:DisallowedModels) {
        if ($raw -eq $disallowed -or $raw -like "*$disallowed*") {
            return $null
        }
    }

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

    return $null
}

function Test-DevRouterModelAllowed {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    $resolved = Resolve-DevRouterModel -ModelNameOrId $ModelNameOrId
    return ($null -ne $resolved)
}

function Get-DevRouterModelEfforts {
    param([Parameter(Mandatory)][string]$ModelNameOrId)

    $resolved = Resolve-DevRouterModel -ModelNameOrId $ModelNameOrId
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
        CodexHome  = $fullCodexHome
        KitDir     = $kitDir
        StateFile  = Join-Path $kitDir 'dev-router-state.json'
        LocksFile  = Join-Path $kitDir 'dev-router-locks.json'
        InstallState = Join-Path $kitDir 'install-state.json'
        ConfigToml = Join-Path $fullCodexHome 'config.toml'
    }
}

function Get-DevRouterState {
    param([string]$CodexHome)

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
        catch {
            # Fallback to defaults or install-state.json
        }
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
        catch {
            # Fallback to default
        }
    }

    # 3. Default initial configuration
    return [ordered]@{
        version   = 1
        mode      = 'off'
        target    = 'effort_only'
        updatedAt = $null
    }
}

function Set-DevRouterState {
    param(
        [Parameter(Mandatory)][ValidateSet('off', 'shadow', 'on')][string]$Mode,
        [Parameter()][ValidateSet('effort_only', 'model_only', 'model_and_effort')][string]$Target = 'effort_only',
        [string]$CodexHome
    )

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
        # Backup before replacing
        $backupPath = $paths.StateFile + '.bak'
        Copy-Item -LiteralPath $paths.StateFile -Destination $backupPath -Force
    }
    Move-Item -LiteralPath $tempFile -Destination $paths.StateFile -Force

    # Also synchronize codexDevRouter in install-state.json if it exists
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
        catch {
            # Best effort sync with install-state.json; dev-router-state.json remains authoritative
        }
    }

    return $stateObj
}

function Get-DevRouterLocks {
    param([string]$CodexHome)

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
        [string]$Reason = 'routed',
        [string]$CodexHome
    )

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $paths.KitDir -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($paths.KitDir)
    }

    $locks = Get-DevRouterLocks -CodexHome $CodexHome
    $now = [datetime]::UtcNow.ToString('o')

    $lockRecord = [ordered]@{
        conversation_id = $ConversationId
        scope           = $Scope
        execution_id    = $ExecutionId
        turn_id         = $TurnId
        locked_model    = $Model
        locked_effort   = $Effort
        locked_at_utc   = $now
        reason          = $Reason
    }

    $locks[$ConversationId] = $lockRecord

    $json = ($locks | ConvertTo-Json -Depth 5) + [Environment]::NewLine
    $tempFile = Join-Path $paths.KitDir ("dev-router-locks-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tempFile -Destination $paths.LocksFile -Force

    return $lockRecord
}

function Release-DevRouterLock {
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [string]$CodexHome
    )

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

function Clear-AllDevRouterLocks {
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    if (Test-Path -LiteralPath $paths.LocksFile -PathType Leaf) {
        Remove-Item -LiteralPath $paths.LocksFile -Force
    }
}

function Get-CodexBaselineConfig {
    param([string]$CodexHome)

    $paths = Get-DevRouterPaths -CodexHome $CodexHome
    $baselineModel = 'Sol'
    $baselineEffort = 'medium'

    if (Test-Path -LiteralPath $paths.ConfigToml -PathType Leaf) {
        try {
            $lines = Get-Content -LiteralPath $paths.ConfigToml -Encoding UTF8
            foreach ($line in $lines) {
                $mMatch = [regex]::Match($line, '^\s*model\s*=\s*"([^"]+)"')
                if ($mMatch.Success) {
                    $mVal = $mMatch.Groups[1].Value.Trim()
                    $resolved = Resolve-DevRouterModel -ModelNameOrId $mVal
                    if ($null -ne $resolved) {
                        $baselineModel = $resolved.Name
                    }
                    else {
                        $baselineModel = $mVal
                    }
                }
                $eMatch = [regex]::Match($line, '^\s*model_reasoning_effort\s*=\s*"([^"]+)"')
                if ($eMatch.Success) {
                    $baselineEffort = $eMatch.Groups[1].Value.Trim()
                }
            }
        }
        catch {
            # Preserve defaults
        }
    }

    return [ordered]@{
        Model  = $baselineModel
        Effort = $baselineEffort
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

    # Integration Status:
    # Codex Desktop App (GUI) does not expose an external dynamic IPC endpoint to swap active chat models.
    # Therefore, Desktop App adapter is marked 'unintegrated' per Section 2 specification.
    # CLI harness (codex exec / headless runner) is fully supported.
    $integrationStatus = 'unintegrated'
    $integrationNotes = 'Codex Desktop GUI does not expose a native dynamic model-switching IPC; adapter is unintegrated for GUI chats without binary patching. CLI harness (codex exec) and manual prompt guidance are fully supported.'

    $effectiveMode = switch ($state.mode) {
        'off'    { 'off' }
        'shadow' { 'shadow' }
        'on'     {
            if ($integrationStatus -eq 'unintegrated') {
                # In GUI, since integration is unintegrated, effective application is bypassed
                'bypass'
            }
            else {
                'on'
            }
        }
        default  { 'off' }
    }

    $effectiveModel = if ($null -ne $activeLock) {
        [string]$activeLock.locked_model
    }
    else {
        $baseline.Model
    }

    $effectiveEffort = if ($null -ne $activeLock) {
        [string]$activeLock.locked_effort
    }
    else {
        $baseline.Effort
    }

    $pendingChange = $false

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
        pending_change      = $pendingChange
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

    $resolvedBaseline = Resolve-DevRouterModel -ModelNameOrId $BaselineModel
    $baselineModelName = if ($null -ne $resolvedBaseline) { $resolvedBaseline.Name } else { 'Sol' }
    $baselineEffortVal = if (-not [string]::IsNullOrWhiteSpace($BaselineEffort)) { $BaselineEffort.Trim().ToLowerInvariant() } else { 'medium' }

    # Fallback result
    $fallback = [ordered]@{
        model              = $baselineModelName
        effort             = $baselineEffortVal
        status             = 'ok'
        is_fallback        = $false
        reason             = 'routed'
        confidence         = 1.0
        selected_raw       = $null
    }

    # Formulate question based on Target
    $instructions = ''
    $options = @()

    switch ($Target) {
        'effort_only' {
            $supportedEfforts = Get-DevRouterModelEfforts -ModelNameOrId $baselineModelName
            if ($supportedEfforts.Count -eq 0) {
                $supportedEfforts = @('low', 'medium', 'high')
            }
            $options = @($supportedEfforts)
            $instructions = "Select the appropriate reasoning effort for this task running on model '$baselineModelName'. Options: $($options -join ', ')."
        }
        'model_only' {
            # Allowlist: Luna, Sol, Astra (Terra strictly excluded)
            # Filter models compatible with the baseline effort if set
            $candidateModels = @()
            foreach ($m in @('Luna', 'Sol', 'Astra')) {
                if (Test-DevRouterEffortSupported -ModelNameOrId $m -Effort $baselineEffortVal) {
                    $candidateModels += $m
                }
            }
            if ($candidateModels.Count -eq 0) {
                $candidateModels = @('Luna', 'Sol', 'Astra')
            }
            $options = @($candidateModels)
            $instructions = "Select the best model for this task requiring reasoning effort '$baselineEffortVal'. Options: $($options -join ', ')."
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
            $instructions = "Select the optimal model and reasoning effort pair for this task. Options: $($options -join ', ')."
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
                    model       = $baselineModelName
                    effort      = $baselineEffortVal
                    status      = 'error'
                    is_fallback = $true
                    reason      = [string]$mVal.error
                    confidence  = 0.0
                    selected_raw= $null
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
            model       = $baselineModelName
            effort      = $baselineEffortVal
            status      = 'unavailable'
            is_fallback = $true
            reason      = 'TYPESAFE_API_KEY is not set.'
            confidence  = 0.0
            selected_raw= $null
        }
    }

    # 3. Build Question Body
    $questions = [ordered]@{
        'q_route' = [ordered]@{
            type         = 'choice'
            instructions = $instructions
            options      = $options
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
                model       = $baselineModelName
                effort      = $baselineEffortVal
                status      = 'error'
                is_fallback = $true
                reason      = $_.Exception.Message
                confidence  = 0.0
                selected_raw= $null
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
                model       = $baselineModelName
                effort      = $baselineEffortVal
                status      = 'error'
                is_fallback = $true
                reason      = $_.Exception.Message
                confidence  = 0.0
                selected_raw= $null
            }
        }
    }

    # 5. Parse Response Answer
    if ($null -eq $responseObj -or -not ($responseObj.PSObject.Properties.Name -contains 'answers')) {
        return [ordered]@{
            model       = $baselineModelName
            effort      = $baselineEffortVal
            status      = 'invalid_response'
            is_fallback = $true
            reason      = 'Missing answers property from Jev response.'
            confidence  = 0.0
            selected_raw= $null
        }
    }

    $ans = $responseObj.answers.q_route
    if ($null -eq $ans) {
        return [ordered]@{
            model       = $baselineModelName
            effort      = $baselineEffortVal
            status      = 'invalid_response'
            is_fallback = $true
            reason      = 'Missing q_route answer.'
            confidence  = 0.0
            selected_raw= $null
        }
    }

    $rawChosen = $null
    if ($ans -is [string]) {
        $rawChosen = $ans
    }
    elseif ($ans.PSObject.Properties.Name -contains 'choice') {
        $rawChosen = [string]$ans.choice
    }
    elseif ($ans.PSObject.Properties.Name -contains 'selected') {
        $rawChosen = [string]$ans.selected
    }
    elseif ($ans.PSObject.Properties.Name -contains 'value') {
        $rawChosen = [string]$ans.value
    }

    return Parse-DevRouterChoice -Chosen $rawChosen -Target $Target -BaselineModel $baselineModelName -BaselineEffort $baselineEffortVal -Options $options
}

function Parse-DevRouterChoice {
    param(
        [Parameter()][string]$Chosen,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$BaselineModel,
        [Parameter(Mandatory)][string]$BaselineEffort,
        [Parameter(Mandatory)][string[]]$Options
    )

    if ([string]::IsNullOrWhiteSpace($Chosen)) {
        return [ordered]@{
            model       = $BaselineModel
            effort      = $BaselineEffort
            status      = 'invalid_choice'
            is_fallback = $true
            reason      = 'Empty choice returned by Jev.'
            confidence  = 0.0
            selected_raw= $null
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
            model       = $BaselineModel
            effort      = $BaselineEffort
            status      = 'invalid_choice'
            is_fallback = $true
            reason      = "Choice '$cleanChosen' was not in permitted options: ($($Options -join ', '))."
            confidence  = 0.0
            selected_raw= $cleanChosen
        }
    }

    switch ($Target) {
        'effort_only' {
            # STRICT AUTHORITY: Model is NEVER modified, even if high risk!
            return [ordered]@{
                model       = $BaselineModel
                effort      = $matchedOption.ToLowerInvariant()
                status      = 'ok'
                is_fallback = $false
                reason      = 'jev_choice'
                confidence  = 1.0
                selected_raw= $matchedOption
            }
        }
        'model_only' {
            # STRICT AUTHORITY: Effort is NEVER modified!
            # Ensure model is allowed (Luna, Sol, Astra)
            if (-not (Test-DevRouterModelAllowed -ModelNameOrId $matchedOption)) {
                return [ordered]@{
                    model       = $BaselineModel
                    effort      = $BaselineEffort
                    status      = 'disallowed_model'
                    is_fallback = $true
                    reason      = "Model '$matchedOption' is not in allowlist."
                    confidence  = 0.0
                    selected_raw= $matchedOption
                }
            }
            return [ordered]@{
                model       = $matchedOption
                effort      = $BaselineEffort
                status      = 'ok'
                is_fallback = $false
                reason      = 'jev_choice'
                confidence  = 1.0
                selected_raw= $matchedOption
            }
        }
        'model_and_effort' {
            $parts = $matchedOption.Split(':')
            if ($parts.Length -ne 2) {
                return [ordered]@{
                    model       = $BaselineModel
                    effort      = $BaselineEffort
                    status      = 'invalid_format'
                    is_fallback = $true
                    reason      = "Invalid Model:Effort pair '$matchedOption'."
                    confidence  = 0.0
                    selected_raw= $matchedOption
                }
            }
            $m = $parts[0].Trim()
            $e = $parts[1].Trim().ToLowerInvariant()
            if (-not (Test-DevRouterModelAllowed -ModelNameOrId $m)) {
                return [ordered]@{
                    model       = $BaselineModel
                    effort      = $BaselineEffort
                    status      = 'disallowed_model'
                    is_fallback = $true
                    reason      = "Model '$m' is not in allowlist."
                    confidence  = 0.0
                    selected_raw= $matchedOption
                }
            }
            return [ordered]@{
                model       = $m
                effort      = $e
                status      = 'ok'
                is_fallback = $false
                reason      = 'jev_choice'
                confidence  = 1.0
                selected_raw= $matchedOption
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
        $r = Resolve-DevRouterModel -ModelNameOrId $BaselineModel
        if ($null -ne $r) { $r.Name } else { $BaselineModel }
    }
    else {
        $baselineConfig.Model
    }

    $resolvedBaselineEffort = if (-not [string]::IsNullOrWhiteSpace($BaselineEffort)) {
        $BaselineEffort.Trim().ToLowerInvariant()
    }
    else {
        $baselineConfig.Effort
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

    # 2. Check Existing Active Lock for this conversation (Thread Isolation)
    $existingLock = Get-DevRouterLock -ConversationId $ConversationId -CodexHome $CodexHome
    if ($null -ne $existingLock) {
        $lockMatches = $false
        if ($Surface -eq 'workflow') {
            # In workflow: locked for the entire workflow execution
            if ([string]::IsNullOrWhiteSpace($ExecutionId) -or [string]$existingLock.execution_id -eq $ExecutionId) {
                $lockMatches = $true
            }
        }
        else {
            # In alignment: locked for the current turn
            if ([string]::IsNullOrWhiteSpace($TurnId) -or [string]$existingLock.turn_id -eq $TurnId) {
                $lockMatches = $true
            }
        }

        if ($lockMatches) {
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
    }

    # 3. Build Sanitized Context Projection
    $projection = New-DevRouterContextProjection -Objective $Objective -Surface $Surface -WorkflowMode $WorkflowMode -CurrentModel $resolvedBaselineModel -CurrentEffort $resolvedBaselineEffort -Target ([string]$state.target)

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
        # Execution remains strictly on baseline; recommendation is logged
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

    # 6. Handle Mode = ON
    # Check Adapter Surface:
    # If Codex Desktop App GUI, per specification Section 2, mark unintegrated & bypass application
    if ($AdapterSurface -eq 'codex_app_gui') {
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

    # CLI Harness / Supported Execution:
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

    $resolved = Resolve-DevRouterModel -ModelNameOrId $Model
    $modelId = if ($null -ne $resolved) { $resolved.Id } else { $Model }

    return @(
        '-m', $modelId,
        '-c', "model_reasoning_effort=`"$Effort`""
    )
}

Export-ModuleMember -Function `
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
    Get-DevRouterCliArguments
