$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$codexHome = [IO.Path]::GetFullPath($defaultCodexHome)
$agentsHome = [IO.Path]::GetFullPath($defaultAgentsHome)
$openCodeModels = @{ go = 'opencode-go/deepseek-v4-flash'; zen = 'zenmux/deepseek/deepseek-v4-flash' }
$openCodeProvider = if ([string]::IsNullOrWhiteSpace($env:CODEX_WORKFLOWS_OPENCODE_PROVIDER)) { 'go' } else { $env:CODEX_WORKFLOWS_OPENCODE_PROVIDER }
if (-not $openCodeModels.ContainsKey($openCodeProvider)) {
    throw "Invalid CODEX_WORKFLOWS_OPENCODE_PROVIDER '$openCodeProvider': allowed values are go and zen."
}

function Read-RequiredText {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing required file: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Phrases
    )

    foreach ($phrase in $Phrases) {
        if ($Text.IndexOf($phrase, [StringComparison]::Ordinal) -lt 0) {
            throw "$Name is missing: $phrase"
        }
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Phrases
    )

    foreach ($phrase in $Phrases) {
        if ($Text.IndexOf($phrase, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "$Name contains a removed contract: $phrase"
        }
    }
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "Invalid PowerShell syntax in ${Path}: $($errors.Message -join '; ')"
    }
}

function Assert-SameFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Label
    )

    if (!(Test-Path -LiteralPath $Installed -PathType Leaf)) {
        throw "Installed $Label is missing: $Installed"
    }

    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
        throw "Installed $Label is stale: $Installed"
    }
}

function Assert-RenderedParity {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Label
    )

    if (!(Test-Path -LiteralPath $Installed -PathType Leaf)) {
        throw "Installed $Label is missing: $Installed"
    }

    $rawInstalled = Read-RequiredText $Installed
    if ($rawInstalled -match '__OPENCODE_[A-Z_]+__') {
        throw "Installed $Label still contains unrendered placeholders: $Installed"
    }

    $normalize = {
        param([string]$Text)
        $t = $Text.Replace("`r`n", "`n").TrimEnd()
        $t = [regex]::Replace($t, '(?m)^(command|AGENTS_DIR|JOB_DIR|PATH|AGENT_MODEL) = ".*"$', '$1 = "<RENDERED>"')
        return $t
    }
    $sourceText = & $normalize (Read-RequiredText $Source)
    $installedText = & $normalize $rawInstalled
    if ($sourceText -cne $installedText) {
        throw "Installed $Label is stale or unrendered: $Installed"
    }
}

function Assert-ManagedBlock {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Begin,
        [Parameter(Mandatory)][string]$End,
        [Parameter(Mandatory)][string]$Label
    )

    $sourceText = (Read-RequiredText $Source).Replace("`r`n", "`n").TrimEnd()
    $installedText = (Read-RequiredText $Installed).Replace("`r`n", "`n")
    $expected = "$Begin`n$sourceText`n$End"
    $beginIndex = $installedText.IndexOf($Begin, [StringComparison]::Ordinal)
    $endIndex = $installedText.IndexOf($End, $beginIndex, [StringComparison]::Ordinal)
    $actualBlock = if ($beginIndex -ge 0 -and $endIndex -ge $beginIndex) {
        $installedText.Substring($beginIndex, $endIndex + $End.Length - $beginIndex).TrimEnd()
    } else {
        ''
    }
    while ($actualBlock.Contains("`n`n$End")) {
        $actualBlock = $actualBlock.Replace("`n`n$End", "`n$End")
    }
    if ($actualBlock -ne $expected) {
        throw "Installed $Label does not contain the current managed block: $Installed"
    }
}

$paths = @{
    skill = Join-Path $repo 'skills\workflows\SKILL.md'
    workflowInterface = Join-Path $repo 'skills\workflows\agents\openai.yaml'
    evidenceSkill = Join-Path $repo 'skills\evidence-first\SKILL.md'
    agentsMd = Join-Path $repo 'codex\AGENTS.md'
    architecture = Join-Path $repo 'docs\architecture.md'
    bootstrap = Join-Path $repo 'docs\agent-bootstrap-prompt.md'
    security = Join-Path $repo 'docs\security.md'
    install = Join-Path $repo 'scripts\install.ps1'
    doctor = Join-Path $repo 'scripts\doctor.ps1'
    uninstall = Join-Path $repo 'scripts\uninstall.ps1'
    maintenance = Join-Path $repo 'plugins\mcp-foundation\scripts\maintain-mcps.ps1'
    wrapper = Join-Path $repo 'bin\opencode-worker.cmd'
    marketplace = Join-Path $repo '.agents\plugins\marketplace.json'
    pluginManifest = Join-Path $repo 'plugins\mcp-foundation\.codex-plugin\plugin.json'
    mcpManifest = Join-Path $repo 'plugins\mcp-foundation\.mcp.json'
    hook = Join-Path $repo 'plugins\mcp-foundation\hooks\hooks.json'
    ahk = Join-Path $repo 'ahk\codex_prompt_pad.ahk'
}

foreach ($path in $paths.Values) {
    Read-RequiredText -Path $path | Out-Null
}

foreach ($path in $paths.install, $paths.doctor, $paths.uninstall, $paths.maintenance) {
    Assert-PowerShellParses -Path $path
}

$skill = Read-RequiredText $paths.skill
$evidenceSkill = Read-RequiredText $paths.evidenceSkill
$agentsMd = Read-RequiredText $paths.agentsMd
$backendPolicy = Read-RequiredText (Join-Path $repo 'skills\workflows\references\backend-policy.md')
$dictionary = Read-RequiredText (Join-Path $repo 'skills\workflows\references\dictionary.md')
$modeMatrix = Read-RequiredText (Join-Path $repo 'skills\workflows\references\mode-matrix.md')
$runtimeAdapters = Read-RequiredText (Join-Path $repo 'skills\workflows\references\runtime-adapters.md')
$subagents = Read-RequiredText (Join-Path $repo 'skills\workflows\references\subagents.md')
$validation = Read-RequiredText (Join-Path $repo 'skills\workflows\references\validation.md')
$readme = Read-RequiredText (Join-Path $repo 'README.md')
$architecture = Read-RequiredText $paths.architecture
$bootstrap = Read-RequiredText $paths.bootstrap
$security = Read-RequiredText $paths.security
$relay = Read-RequiredText (Join-Path $repo 'agents\relay.toml')
$watcher = Read-RequiredText (Join-Path $repo 'agents\watcher.toml')

foreach ($reference in 'backend-policy.md','dictionary.md','mode-matrix.md','runtime-adapters.md','subagents.md','validation.md') {
    Read-RequiredText (Join-Path $repo "skills\workflows\references\$reference") | Out-Null
}

if ($skill -notmatch '(?s)^---\s*\r?\nname:\s*workflows\r?\ndescription:\s*.+?\r?\n---\s*\r?\n') {
    throw 'Invalid workflows SKILL.md frontmatter.'
}
if ($evidenceSkill -notmatch '(?s)^---\s*\r?\nname:\s*evidence-first\r?\ndescription:\s*.+?\r?\n---\s*\r?\n') {
    throw 'Invalid evidence-first SKILL.md frontmatter.'
}

Assert-Contains 'evidence-first skill' $evidenceSkill @('{claim, source, evidence, status}','Do not use model confidence or self-review alone as proof')
Assert-Contains 'AGENTS.md' $agentsMd @('evidence-first',('observa' + [char]0x00E7 + [char]0x00E3 + 'o'),'obs-gate')

Assert-Contains 'backend policy' $backendPolicy @(
    'internal_subagent_backend=opencode',
    'internal_subagent_transport=native_watcher_mcp',
    'internal_subagent_policy=writer_only',
    'The GPT orchestrator',
    'never authors a code patch',
    'native watcher',
    'agent_type=watcher',
    'directly for normal work',
    'PREFLIGHT -> W1 -> VERIFY',
    'W2 repair',
    'ORCHESTRATOR DIAGNOSE',
    'W3 fresh writer',
    'NESTED_REQUIRED=',
    'NESTED_DELEGATION=used',
    'NESTED_DELEGATION=blocked',
    'get_agent_status(job_id)',
    'result_available=true',
    'NATIVE_ROUTE_BLOCKED',
    'MAX_ACTIVE_CHILDREN_PER_CHAT=5',
    'RUNNING_LIVE=WAIT',
    'RESULT=CAPTURE_THEN_CLOSE',
    'CRASH_CONFIRMED=CLOSE_AND_RECOVER',
    'SLOT_FULL=TERMINAL_ONLY_RECLAIM',
    'OpenCode CLI preflight',
    'bounded direct OpenCode CLI smoke',
    'CLI_PREFLIGHT=passed',
    'blocks the MCP route',
    'diagnostic only',
    'never a direct CLI fallback',
    'OPEN_CODE_ROLE',
    'never guesses a role',
    'OPEN_CODE_MCP_AGENT',
    'sole role source',
    'front labels',
    '`explore` or `general`',
    'doom_loop',
    'runtime failure',
    'sanitized',
    'data URLs',
    'DeepSeek',
    'CODEX_WORKFLOWS_OPENCODE_PROVIDER',
    'never changes credentials'
)

$wrapper = Read-RequiredText $paths.wrapper
Assert-Contains 'opencode-worker wrapper' $wrapper @(
    'set OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow","doom_loop":"allow","external_directory":{"%CFG_AGENTS_DIR%":"allow","%CFG_SKILLS_DIR%":"allow"},"question":"deny","plan_enter":"deny","plan_exit":"deny"}}',
    'set "CFG_AGENTS_DIR=%AGENTS_DIR%"',
    'if "%CFG_AGENTS_DIR%"=="" if not "%CODEX_HOME%"=="" set "CFG_AGENTS_DIR=%CODEX_HOME%\opencode-agents"',
    'if "%CFG_AGENTS_DIR%"=="" set "CFG_AGENTS_DIR=%USERPROFILE%\.codex\opencode-agents"',
    'set "CFG_AGENTS_DIR=%CFG_AGENTS_DIR:\=\\%"',
    'set "CFG_SKILLS_DIR=%USERPROFILE%\.agents\skills\workflows"',
    'if not "%AGENTS_HOME%"=="" set "CFG_SKILLS_DIR=%AGENTS_HOME%\skills\workflows"',
    'set "CFG_SKILLS_DIR=%CFG_SKILLS_DIR:\=\\%"',
    'doom_loop":"allow',
    '"question":"deny"',
    '"plan_enter":"deny"',
    '"plan_exit":"deny"',
    'set "AGENT_EFFORT=max"',
    'CODEX_WORKFLOWS_OPENCODE_PROVIDER',
    'opencode-go/deepseek-v4-flash',
    'zenmux/deepseek/deepseek-v4-flash',
    'Invalid CODEX_WORKFLOWS_OPENCODE_PROVIDER',
    'call npx.cmd %*',
    'exit /b %ERRORLEVEL%'
)
Assert-NotContains 'opencode-worker wrapper' $wrapper @('"external_directory":"allow"', 'OPENCODE_PERMISSION', 'setlocal enabledelayedexpansion')
$configLine = [regex]::Match($wrapper, '(?m)^set OPENCODE_CONFIG_CONTENT=(?<json>\{.*\})\r?$')
if (-not $configLine.Success) {
    throw 'opencode-worker wrapper must set OPENCODE_CONFIG_CONTENT to a single-line JSON object.'
}
$configText = $configLine.Groups['json'].Value.Replace('%CFG_AGENTS_DIR%', 'C:\\dummy\\agents').Replace('%CFG_SKILLS_DIR%', 'C:\\dummy\\skills')
try {
    $permission = ($configText | ConvertFrom-Json).permission
}
catch {
    throw "opencode-worker OPENCODE_CONFIG_CONTENT is not valid JSON: $($_.Exception.Message)"
}
$permissionProps = $permission.PSObject.Properties
if ($permissionProps['*'].Value -ne 'allow' -or $permissionProps['doom_loop'].Value -ne 'allow') {
    throw 'opencode-worker wrapper must keep the wildcard tool and doom_loop allows.'
}
if ($permissionProps['question'].Value -ne 'deny' -or $permissionProps['plan_enter'].Value -ne 'deny' -or $permissionProps['plan_exit'].Value -ne 'deny') {
    throw 'opencode-worker wrapper must keep question/plan denies.'
}
$external = $permissionProps['external_directory'].Value
if ($external -isnot [PSCustomObject] -or @($external.PSObject.Properties).Count -ne 2) {
    throw 'opencode-worker wrapper must scope external_directory to exactly two path allow rules.'
}
foreach ($rule in $external.PSObject.Properties) {
    if ($rule.Value -ne 'allow') {
        throw "opencode-worker external_directory rule for $($rule.Name) must be allow."
    }
}
if ($wrapper -match '(?m)^\s*set "AGENT_MODEL=') {
    throw 'opencode-worker wrapper still hardcodes an unconditional AGENT_MODEL override.'
}
if ($wrapper -match '(?m)^\s*if "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="" set "CODEX_WORKFLOWS_OPENCODE_PROVIDER=go"') {
    throw 'opencode-worker wrapper still defaults the absent provider flag to go, overriding a rendered AGENT_MODEL.'
}
if ($wrapper -notmatch '(?m)^\s*if "%AGENT_MODEL%"=="" set "AGENT_MODEL=opencode-go/deepseek-v4-flash"') {
    throw 'opencode-worker wrapper must default to go only when no AGENT_MODEL was inherited.'
}
if ($wrapper -notmatch '(?m)^\s*if /I "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="go" set "AGENT_MODEL=opencode-go/deepseek-v4-flash"') {
    throw 'opencode-worker wrapper must map the explicit go provider flag to the go model.'
}
if ($wrapper -notmatch '(?m)^\s*if /I "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="zen" set "AGENT_MODEL=zenmux/deepseek/deepseek-v4-flash"') {
    throw 'opencode-worker wrapper must map the explicit zen provider flag to the zen model.'
}
if ($wrapper -notmatch 'if not "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="" \(\s*echo Invalid CODEX_WORKFLOWS_OPENCODE_PROVIDER[^\r\n]*\s*exit /b 1\s*\)') {
    throw 'opencode-worker wrapper must exit 1 when an explicit provider flag is outside the go/zen enum.'
}
if (Test-Path -LiteralPath (Join-Path $repo 'bin\opencode.cmd') -PathType Leaf) {
    throw 'Rejected bin\opencode.cmd shim must not exist.'
}

foreach ($surface in @(
    [pscustomobject]@{ Name = 'workflows skill'; Text = $skill }
    [pscustomobject]@{ Name = 'AGENTS.md'; Text = $agentsMd }
    [pscustomobject]@{ Name = 'README'; Text = $readme }
    [pscustomobject]@{ Name = 'architecture'; Text = $architecture }
    [pscustomobject]@{ Name = 'bootstrap'; Text = $bootstrap }
    [pscustomobject]@{ Name = 'security'; Text = $security }
    [pscustomobject]@{ Name = 'subagents reference'; Text = $subagents }
    [pscustomobject]@{ Name = 'validation reference'; Text = $validation }
)) {
    Assert-NotContains $surface.Name $surface.Text @(
        'internal_subagent_transport=native_relay',
        'internal_subagent_transport=direct_mcp',
        'internal_subagent_policy=aggressive',
        'internal_subagent_policy=conservative',
        'synchronous `run_agent` by default',
        'Optional delegation:',
        'opencode_worker` MCP directly',
        'MCP directly for text sidecars',
        'use diretamente o MCP',
        'usam diretamente o MCP',
        'direct `opencode_worker` MCP'
    )
}

Assert-Contains 'workflow skill' $skill @(
    'The GPT orchestrator',
    'never authors a code patch',
    'OpenCode `worker`',
    'agent_type=watcher',
    'NESTED_REQUIRED=<fronts>',
    'NESTED_DELEGATION=used',
    'NATIVE_ROUTE_BLOCKED',
    'get_agent_status',
    'Do not poll continuously',
    'CLI_PREFLIGHT=passed',
    'bounded direct OpenCode CLI smoke',
    'never a direct CLI fallback'
)
Assert-Contains 'dictionary' $dictionary @(
    'sidecar-gate',
    'native_watcher_mcp',
    'SIDECAR=REQUIRED',
    'OPEN_CODE_ROLE',
    'never guesses a role',
    'sanitized',
    'data URLs',
    'DeepSeek'
)
Assert-Contains 'codex AGENTS.md' $agentsMd @(
    'O GPT orquestrador',
    ('n' + [char]0x00E3 + 'o escreve patches'),
    'NATIVE_ROUTE_BLOCKED',
    'agent_type=watcher',
    'NESTED_REQUIRED=<frentes>',
    'get_agent_status',
    'MAX_ACTIVE_CHILDREN_PER_CHAT=5'
)

$allModes = @('PLAN.AUTO', 'PLAN', 'P.DEEP', 'RESEARCH.DEEP', 'IMPL.AUTO', 'IMPL', 'IMPL.PHASE', 'DELIVER.AUTO', 'REVIEW', 'COMMIT', 'BUG.INV', 'BUG.FIX', 'DEBUG', 'REWORK', 'R.A.F.V', 'TN.SKILL')
foreach ($mode in $allModes) {
    $modeToken = '`' + $mode + '`'
    if ($modeMatrix.IndexOf($modeToken, [StringComparison]::Ordinal) -lt 0) {
        throw "Mode matrix is missing coverage for mode: $mode"
    }
}
$modeRowMatches = @([regex]::Matches($modeMatrix, '(?m)^\|\s*`[A-Z.]+`\s*\|') | ForEach-Object { $_.Value })
if ($modeRowMatches.Count -ne $allModes.Count) {
    throw "Mode matrix must have exactly $($allModes.Count) mode rows; found $($modeRowMatches.Count)."
}
Assert-Contains 'mode matrix' $modeMatrix @('`RESEARCH.DEEP`','`BUG.INV`','`REWORK`','NESTED_REQUIRED','opencode_worker MCP','writer loop','sidecar-gate','writer-free','Fan-out required','parent-owned','OPEN_CODE_ROLE','sanitized')
Assert-Contains 'runtime adapters' $runtimeAdapters @('exposed `opencode_worker` MCP','agent_type=watcher','claim-map','native relay','OPEN_CODE_ROLE')
Assert-Contains 'subagents reference' $subagents @('only implementation role','agent_type=watcher','NESTED_REQUIRED','NESTED_DELEGATION=blocked','W1','W2','W3','job_id','MAX_ACTIVE_CHILDREN_PER_CHAT=5','RESULT=CAPTURE_THEN_CLOSE','OPEN_CODE_ROLE','never guesses','OPEN_CODE_MCP_AGENT','sole role source','sanitized','DeepSeek')
Assert-Contains 'validation reference' $validation @('direct MCP request','NESTED_REQUIRED','NESTED_DELEGATION=used','Do not use a native reviewer','isolated worktree','CLI_PREFLIGHT=passed','bounded direct OpenCode CLI smoke','diagnostic only','OPEN_CODE_ROLE','never guesses','sanitized','data URLs','DeepSeek')
Assert-Contains 'README' $readme @('CODEX_WORKFLOWS_OPENCODE_PROVIDER','opencode-go/deepseek-v4-flash','zenmux/deepseek/deepseek-v4-flash','OPEN_CODE_ROLE','sanitizado')
Assert-Contains 'architecture' $architecture @('CODEX_WORKFLOWS_OPENCODE_PROVIDER','OPEN_CODE_ROLE','sanitizado','DeepSeek')
Assert-Contains 'security' $security @('CODEX_WORKFLOWS_OPENCODE_PROVIDER','DeepSeek','nunca altera credenciais')

$opencodeRoot = Join-Path $repo 'agents\opencode'
$readerFiles = @('scout.md','researcher.md','reviewer.md')
foreach ($file in $readerFiles) {
    $text = Read-RequiredText (Join-Path $opencodeRoot $file)
    Assert-Contains "OpenCode reader $file" $text @(
        'mode: subagent',
        'edit: deny',
        'bash: deny',
        'task: allow',
        'NESTED_REQUIRED=',
        'NESTED_DELEGATION=blocked',
        'NESTED_DELEGATION=used',
        '`explore` or `general`',
        'front-label-derived value',
        '[VISUAL_PACKET v1]'
    )
}

$writer = Read-RequiredText (Join-Path $opencodeRoot 'worker.md')
Assert-Contains 'OpenCode worker' $writer @(
    'mode: subagent',
    'edit: allow',
    'bash: deny',
    'task: deny',
    'external_directory: deny',
    'WRITER_WORKTREE',
    'WRITER_BASELINE',
    'WRITER_STATUS=success|blocked',
    'Do not invoke another agent',
    '[VISUAL_PACKET v1]',
    'sanitized',
    'data URLs',
    'DeepSeek',
    'native watcher',
    'not an implementation agent'
)

foreach ($file in 'scout.toml','researcher.toml','reviewer.toml','worker.toml') {
    $text = Read-RequiredText (Join-Path $repo "agents\$file")
    Assert-Contains "native profile $file" $text @('internal_subagent_backend=opencode','NATIVE_ROUTE_BLOCKED')
}
Assert-Contains 'native relay' $relay @('sandbox_mode = "read-only"','NATIVE_ROUTE_BLOCKED','[VISUAL_PACKET v1]','RELAY_VISUAL=blocked')
Assert-NotContains 'native relay' $relay @('opencode_worker MCP directly','Optional delegation:','run_agent for every')
Assert-Contains 'native watcher' $watcher @(
    'name = "watcher"',
    'model = "gpt-5.6-luna"',
    'model_reasoning_effort = "high"',
    'sandbox_mode = "read-only"',
    'opencode_worker',
    'run_agent',
    'OPEN_CODE_ROLE',
    '{scout, researcher, reviewer, worker}',
    'Never guess a role',
    'OPEN_CODE_MCP_AGENT',
    'sole role source',
    'front labels',
    '`explore` or `general`',
    'WATCHER_STATUS=success|blocked',
    'WATCHER_ROLE=missing|invalid',
    'WATCHER_ROUTE_BLOCKED',
    'send follow-ups',
    'steer',
    'interrupt',
    'enabled_tools = ["run_agent", "start_agent", "get_agent_status", "get_agent_result", "cancel_agent"]',
    'command = "__OPENCODE_WORKER_COMMAND__"',
    'AGENTS_DIR = "__OPENCODE_AGENTS_DIR__"',
    'AGENT_MODEL = "__OPENCODE_AGENT_MODEL__"',
    'JOB_DIR = "__OPENCODE_JOBS_DIR__"',
    'PATH = "__OPENCODE_PATH__"'
)
Assert-NotContains 'native watcher' $watcher @('NATIVE_ROUTE_BLOCKED')
if ($watcher -match 'OPEN_CODE_ROLE=(watcher|reader)') {
    throw 'Native watcher must never accept the guessed roles watcher or reader.'
}

$install = Read-RequiredText $paths.install
Assert-Contains 'installer' $install @(
    'enabled_tools = ["get_agent_status", "get_agent_result", "cancel_agent"]',
    'max_concurrent_threads_per_session = 5',
    "'relay.toml', 'watcher.toml'",
    'CODEX_WORKFLOWS_OPENCODE_PROVIDER',
    'opencode-go/deepseek-v4-flash',
    'zenmux/deepseek/deepseek-v4-flash',
    'allowed values are go and zen',
    '__OPENCODE_AGENT_MODEL__'
)
Assert-NotContains 'installer' $install @('enabled_tools = ["run_agent"', 'enabled_tools = ["start_agent"')
Assert-NotContains 'installer' $install @('bin\opencode.cmd', 'shimSource', 'shimDest')

$mcp = Get-Content -LiteralPath $paths.mcpManifest -Raw -Encoding UTF8 | ConvertFrom-Json
$mcpNames = @($mcp.mcpServers.PSObject.Properties.Name | Sort-Object)
if (($mcpNames -join ',') -ne 'codegraph,context7,openaiDeveloperDocs') {
    throw "MCP allowlist mismatch: $($mcpNames -join ', ')"
}
if ($mcp.mcpServers.codegraph.command -ne 'codegraph') {
    throw 'CodeGraph MCP must use the maintained codegraph command.'
}
if ($mcp.mcpServers.context7.url -ne 'https://mcp.context7.com/mcp') {
    throw 'Context7 MCP URL is invalid.'
}
if ($mcp.mcpServers.openaiDeveloperDocs.url -ne 'https://developers.openai.com/mcp') {
    throw 'OpenAI Developer Docs MCP URL is invalid.'
}

$marketplace = Get-Content -LiteralPath $paths.marketplace -Raw -Encoding UTF8 | ConvertFrom-Json
if ($marketplace.name -ne 'codex-workflows-local') {
    throw 'Local marketplace has an unexpected name.'
}
$foundation = @($marketplace.plugins | Where-Object { $_.name -eq 'mcp-foundation' })
if ($foundation.Count -ne 1 -or $foundation[0].source.path -ne './plugins/mcp-foundation') {
    throw 'Local marketplace is missing the mcp-foundation entry.'
}

$plugin = Get-Content -LiteralPath $paths.pluginManifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plugin.name -ne 'mcp-foundation' -or $plugin.mcpServers -ne './.mcp.json') {
    throw 'Invalid mcp-foundation plugin manifest.'
}
$hooks = Get-Content -LiteralPath $paths.hook -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($hooks.hooks.SessionStart).Count -ne 1) {
    throw 'mcp-foundation must define one SessionStart hook.'
}

foreach ($surface in @(
    [pscustomobject]@{ Name = 'README'; Text = $readme }
    [pscustomobject]@{ Name = 'architecture'; Text = $architecture }
    [pscustomobject]@{ Name = 'bootstrap'; Text = $bootstrap }
    [pscustomobject]@{ Name = 'security'; Text = $security }
    [pscustomobject]@{ Name = 'AGENTS.md'; Text = $agentsMd }
)) {
    if ($surface.Text -match '(?i)C:\\Users\\|[A-Z]:\\Repositories\\|[A-Z]:\\Programs\\AHK|2026-07-01') {
        throw "$($surface.Name) contains a machine-specific path or stale date."
    }
}

if ($skill -match '(?i)opencode_hybrid_worker|opencode-hybrid|HYBRID_ROUTE|HYBRID_WORKTREE|HYBRID_MAIN_CHECKOUT') {
    throw 'Workflow skill still contains removed hybrid routing.'
}
if ((Read-RequiredText $paths.install) -match '(?i)opencodeHybrid|opencode-hybrid|opencode_hybrid_worker|HYBRID_ROUTE') {
    throw 'Installer still contains removed hybrid routing.'
}

# Validate installed mirrors only when their roots already exist. This keeps
# source-only validation useful before installation while catching stale
# mirrors after `install.ps1 -Profile safe`.
$installedWorkflowRoot = Join-Path $agentsHome 'skills\workflows'
if (Test-Path -LiteralPath $installedWorkflowRoot -PathType Container) {
    Get-ChildItem -LiteralPath (Join-Path $repo 'skills\workflows') -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring((Join-Path $repo 'skills\workflows').Length).TrimStart('\')
        Assert-SameFile $_.FullName (Join-Path $installedWorkflowRoot $relative) "workflow mirror $relative"
    }
}

$installedOpenCodeRoot = Join-Path $codexHome 'opencode-agents'
if (Test-Path -LiteralPath $installedOpenCodeRoot -PathType Container) {
    Get-ChildItem -LiteralPath $opencodeRoot -File | ForEach-Object {
        Assert-SameFile $_.FullName (Join-Path $installedOpenCodeRoot $_.Name) "OpenCode agent $($_.Name)"
    }
}

$installedNativeRoot = Join-Path $codexHome 'agents'
if (Test-Path -LiteralPath $installedNativeRoot -PathType Container) {
    foreach ($file in 'relay.toml','watcher.toml','scout.toml','researcher.toml','reviewer.toml','worker.toml') {
        $sourceFile = Join-Path $repo "agents\$file"
        $installedFile = Join-Path $installedNativeRoot $file
        if ($file -eq 'watcher.toml') {
            Assert-RenderedParity $sourceFile $installedFile "native agent $file"
            $installedWatcher = Read-RequiredText $installedFile
            if ($installedWatcher -notmatch '(?m)^AGENT_MODEL = "(opencode-go/deepseek-v4-flash|zenmux/deepseek/deepseek-v4-flash)"') {
                throw "Installed watcher AGENT_MODEL is outside the provider enum: $installedFile"
            }
        }
        else {
            Assert-SameFile $sourceFile $installedFile "native agent $file"
        }
    }
}

$installedBinRoot = Join-Path $codexHome 'bin'
if (Test-Path -LiteralPath $installedBinRoot -PathType Container) {
    Assert-SameFile $paths.wrapper (Join-Path $installedBinRoot 'opencode-worker.cmd') 'worker wrapper'
}

$installedAgentsMd = Join-Path $codexHome 'AGENTS.md'
if (Test-Path -LiteralPath $installedAgentsMd -PathType Leaf) {
    Assert-ManagedBlock $paths.agentsMd $installedAgentsMd '# BEGIN CODEX-WORKFLOWS-KIT' '# END CODEX-WORKFLOWS-KIT' 'Codex AGENTS.md'
}

$configPath = Join-Path $codexHome 'config.toml'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $config = Read-RequiredText $configPath
    if ($config -match '(?m)^\[mcp_servers\.opencode_worker\]') {
        Assert-Contains 'configured opencode_worker MCP' $config @(
            'enabled_tools = ["get_agent_status", "get_agent_result", "cancel_agent"]',
            'AGENT_EFFORT = "max"',
            'SESSION_ENABLED = "false"',
            'JOB_DIR = '
        )
        Assert-NotContains 'configured opencode_worker MCP' $config @('enabled_tools = ["run_agent"', 'enabled_tools = ["start_agent"')
        if ($config -notmatch '(?m)^AGENT_MODEL = "(opencode-go/deepseek-v4-flash|zenmux/deepseek/deepseek-v4-flash)"') {
            throw 'Configured opencode_worker MCP has an AGENT_MODEL outside the provider enum.'
        }
        $pathMatch = [regex]::Match($config, '(?m)^PATH\s*=\s*"(?<path>[^"]*)"')
        if (-not $pathMatch.Success) {
            throw 'Configured opencode_worker MCP is missing its PATH line.'
        }
    }
    if ($config -match '# BEGIN CODEX-WORKFLOWS-KIT: agents') {
        Assert-Contains 'configured agents cap' $config @('[agents]', 'max_concurrent_threads_per_session = 5')
    }
}

Write-Host 'Codex Workflows validation passed.'
