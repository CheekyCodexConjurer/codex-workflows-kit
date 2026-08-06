$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$codexHome = [IO.Path]::GetFullPath($defaultCodexHome)
$agentsHome = [IO.Path]::GetFullPath($defaultAgentsHome)

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
Assert-Contains 'AGENTS.md' $agentsMd @('evidence-first','observação','obs-gate')

Assert-Contains 'backend policy' $backendPolicy @(
    'internal_subagent_backend=opencode',
    'internal_subagent_transport=direct_mcp',
    'internal_subagent_policy=writer_only',
    'The GPT orchestrator',
    'never authors a code patch',
    'Use the exposed `opencode_worker` MCP directly',
    'PREFLIGHT -> W1 -> VERIFY',
    'W2 repair',
    'ORCHESTRATOR DIAGNOSE',
    'W3 fresh writer',
    'NESTED_REQUIRED=',
    'NESTED_DELEGATION=blocked',
    'get_agent_status(job_id)',
    'result_available=true',
    'NATIVE_ROUTE_BLOCKED'
)

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
        'internal_subagent_policy=aggressive',
        'internal_subagent_policy=conservative',
        'synchronous `run_agent` by default',
        'Optional delegation:'
    )
}

Assert-Contains 'workflow skill' $skill @(
    'The GPT orchestrator',
    'never authors a code patch',
    'OpenCode `worker`',
    'NESTED_REQUIRED=<fronts>',
    'NATIVE_ROUTE_BLOCKED',
    'get_agent_status',
    'Do not poll continuously'
)
Assert-Contains 'codex AGENTS.md' $agentsMd @(
    'O GPT orquestrador',
    'não escreve patches',
    'NATIVE_ROUTE_BLOCKED',
    'NESTED_REQUIRED=<frentes>',
    'get_agent_status'
)
Assert-Contains 'mode matrix' $modeMatrix @('`RESEARCH.DEEP`','`BUG.INV`','`REWORK`','NESTED_REQUIRED','opencode_worker MCP','writer loop')
Assert-Contains 'runtime adapters' $runtimeAdapters @('exposed `opencode_worker` MCP','claim-map','native relay')
Assert-Contains 'subagents reference' $subagents @('only implementation role','NESTED_REQUIRED','NESTED_DELEGATION=blocked','W1','W2','W3','job_id')
Assert-Contains 'validation reference' $validation @('direct MCP request','NESTED_REQUIRED','NESTED_DELEGATION=used','Do not use a native reviewer','isolated worktree')

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
    'Do not invoke another agent'
)

foreach ($file in 'scout.toml','researcher.toml','reviewer.toml','worker.toml') {
    $text = Read-RequiredText (Join-Path $repo "agents\$file")
    Assert-Contains "native profile $file" $text @('internal_subagent_backend=opencode','NATIVE_ROUTE_BLOCKED')
}
Assert-Contains 'native relay' $relay @('sandbox_mode = "read-only"','NATIVE_ROUTE_BLOCKED','[VISUAL_PACKET v1]','RELAY_VISUAL=blocked')
Assert-NotContains 'native relay' $relay @('opencode_worker MCP directly','Optional delegation:','run_agent for every')

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
    foreach ($file in 'relay.toml','scout.toml','researcher.toml','reviewer.toml','worker.toml') {
        Assert-SameFile (Join-Path $repo "agents\$file") (Join-Path $installedNativeRoot $file) "native agent $file"
    }
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
            'enabled_tools = ["run_agent", "start_agent", "get_agent_status", "get_agent_result", "cancel_agent"]',
            'AGENT_MODEL = "opencode-go/deepseek-v4-flash"',
            'AGENT_EFFORT = "max"',
            'SESSION_ENABLED = "false"',
            'JOB_DIR = '
        )
    }
}

Write-Host 'Codex Workflows validation passed.'
