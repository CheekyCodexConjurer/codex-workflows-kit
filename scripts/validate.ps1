[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [string]$AntigravityHome,
    [switch]$SkipInstalled,
    [switch]$SkipGateTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
Import-Module (Join-Path $repo 'scripts\backend-routing.psm1') -Force
$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$defaultAntigravityHome = if ($env:ANTIGRAVITY_HOME) { $env:ANTIGRAVITY_HOME } else { Join-Path $env:USERPROFILE '.gemini' }
$codexHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($CodexHome)) { $defaultCodexHome } else { $CodexHome }))
$agentsHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($AgentsHome)) { $defaultAgentsHome } else { $AgentsHome }))
$antigravityHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($AntigravityHome)) { $defaultAntigravityHome } else { $AntigravityHome }))

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
        [Parameter(Mandatory)][object[]]$Needles
    )

    foreach ($needle in $Needles) {
        if ($needle -is [System.Collections.IEnumerable] -and $needle -isnot [string]) {
            $options = @($needle | ForEach-Object { [string]$_ })
            $found = $false
            foreach ($opt in $options) {
                if ($Text.IndexOf($opt, [StringComparison]::Ordinal) -ge 0) {
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                throw "$Label is missing required text: ($($options -join ' | '))"
            }
        }
        elseif ([string]$needle -match '\|') {
            $options = [string]$needle -split '\|'
            $found = $false
            foreach ($opt in $options) {
                if ($Text.IndexOf($opt, [StringComparison]::Ordinal) -ge 0) {
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                throw "$Label is missing required text: $needle"
            }
        }
        else {
            if ($Text.IndexOf([string]$needle, [StringComparison]::Ordinal) -lt 0) {
                throw "$Label is missing required text: $needle"
            }
        }
    }
}

function Assert-Forbidden {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Tokens
    )

    foreach ($token in $Tokens) {
        if ($Text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "$Label retains forbidden terminology: $token"
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
        '(?i)(?:completion is dependency-scoped|dependency-scoped completion|for each dependency|for each dependency or wave).{0,120}(?:parent must wait for a `?final response`? before `?(?:dependent )?synthesis or advancement`?|wait for a `?final response`? before `?dependent synthesis or advancement`?)',
        '(?i)while a job is `?running`?,? do not send an `?interruptive follow-up`? or `?replace`? it',
        '(?i)`?interrupted`?,? `?errored`?,? `?timed out`?,? or `?missing final response`? means unavailable: keep `?the gate`? `?open/BLOCKED`?; do not use a `?silent fallback`?',
        '(?i)(?:ap[o\u00f3]s timeout|aus[e\u00ea]ncia de fechamento|missing closure|timed? out).{0,120}(?:mesma trilha|same track)',
        '(?i)invent[a\u00e1]rio m[i\u00ed]nimo|minimal inventory',
        '(?i)closure slices pequenos|fatias pequenas de fechamento|small closure slices',
        '(?i)(?:proibid[oa]|nunca|never).{0,60}(?:repetir integralmente|repeat integrally|reabrir do zero)',
        '(?i)(?:proibid[oa]|nunca|never).{0,60}(?:abrir novo agente|open new agent|novo sub-agente)',
        '(?i)(?:final `?DONE`? remains strictly (?:forbidden|impossible) until all required jobs are terminally consumed and all agents closed|commit/final requires closure)'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label has an incomplete or incorrectly ordered completion policy: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)for every required job,? the parent must wait for a `?final response`? before `?synthesis or advancement`?',
        '(?i)(?<!(?:no|sem|without|prohibits?|pro[ií]be|rejects?)\s+)\bglobal barrier\b(?!\s+(?:across[^\r\n.;]*\s+)?(?:is\s+)?(?:forbidden|prohibited|proibid[oa]))',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|pode|deve|permite|autoriza)\b[^.;\r\n]*\b(?:DONE|final response|commit)\b[^.;\r\n]*(?:without consuming all required jobs|with unconsumed jobs|while [^.;\r\n]*\bunconsumed\b|before closing all agents|with unclosed agents|incomplete final closure|obriga[c\u00e7][o\u00f5]es pendentes no DONE)\b',
        '(?i)\bincomplete final closure\b(?!\s+(?:is\s+)?(?:forbidden|prohibited|proibid[oa]))',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|has permission to|is permitted to|is allowed to|is free to)\b\s+(?!not\b|never\b)[^.;]*\b(?:interrupt|cancel|terminate|stop)\w*\b',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|has permission to|is permitted to|is allowed to|is free to)\b\s+(?!not\b|never\b)[^.;]*\b(?:replace|substitute|switch|delegate|assign)\b',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|has permission to|is permitted to|is allowed to|is free to)\b\s+(?!not\b|never\b)[^.;]*\b(?:use|allow|permit|select|choose|switch to|fall back|fallback|backup|alternate worker|backup worker|another worker|another agent)\b',
        '(?i)(?:dependent synthesis|advancement of dependent work|synthesize dependent results)[^.;]*(?:before|prior to|without|in the absence of)[^.;]*(?:final response|response|reply|answer|return)',
        '(?i)\b(?:may|can|should|must|authorized to|authorised to|pode|deve)\b[^.;]*\b(?:repetir integralmente|repeat integrally|abrir novo agente ap[o\u00f3]s timeout|open new agent on timeout)\b'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains a forbidden completion-policy exception: $pattern"
        }
    }
}

function Assert-RecoveryPolicy {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)allow_respawn\s*=\s*true',
        '(?i)terminal result',
        '(?i)same request.{0,40}scope.{0,40}cwd.{0,40}ownership',
        '(?i)no new consent prompt',
        '(?i)new session/agent with lineage',
        '(?i)never a fake continuation',
        '(?i)running jobs',
        '(?i)explicitly aborted fronts',
        '(?i)provider fallback stays forbidden',
        '(?i)jobs ativos s[o\u00f3] permitem recovery quando todos t[e\u00ea]m durable spool/recovery comprovado|active jobs only allow recovery when all have proven durable spool/recovery',
        '(?i)stale-running com daemon ausente (?:pode reconciliar|s[o\u00f3] reconcilia) apenas com capacidade durable instalada|stale-running with absent daemon reconciles only with installed durable capacity'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label has an incomplete or incorrectly ordered recovery policy: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)\b(?:may|can|should|must)\b[^.;]*\b(?:ask|request|prompt)\b[^.;]*\b(?:permission|consent)\b',
        '(?i)\b(?:may|can|should|must)\b[^.;]*\b(?:reuse|reopen|same session|original session)\b[^.;]*(?:continue|resume|recover)',
        '(?i)\b(?:may|can|should|must)\b[^.;]*\b(?:continue|resume|reopen|recover|allow_respawn)\b[^.;]*(?:running|aborted|in flight|in-flight|ongoing|missing final|without a final|divergent|different scope|new scope|beyond|outside|another|cwd|switch(?:ing)?|swap(?:ping)?|chang(?:e|ing|ed)|substitut\w*|provider|model)',
        '(?i)\b(?:may|can|should|must)\b[^.;]*\b(?:open a new session|new session)\b[^.;]*(?:new front|another front|different front|other front)',
        '(?i)\b(?:may|can|should|must|pode|deve)\b[^.;]*\b(?:repetir integralmente|repeat integrally|abrir novo agente ap[o\u00f3]s timeout)\b'
    )

    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains a forbidden recovery-policy exception: $pattern"
        }
    }
}

function Assert-McpFoundationSkill {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        'name:\s*mcp-foundation',
        'description:\s*Use when\b',
        '(?i)context7',
        '(?i)resolve',
        '(?i)query',
        '(?i)codegraph',
        '(?i)\.codegraph',
        '(?i)serena',
        '(?i)doctor',
        '(?i)read-only|somente leitura',
        '(?i)taskkill',
        '(?i)auto-init|auto_init',
        '(?i)nunca (?:restart|close|login|logout) Antigravity|proibido reiniciar,? fechar,? logar ou deslogar Antigravity|never restart,? close,? login,? or logout Antigravity',
        '(?i)nunca tocar auth,? profile,? cookies ou cache|proibido tocar auth,? profile,? cookies,? cache|never touch auth,? profile,? cookies,? or cache'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($Text, $pattern)) {
            throw "$Label is missing required pattern: $pattern"
        }
    }

    $forbiddenAutomations = @(
        '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:automate|auto-kill|auto-restart|auto-upgrade|auto-init)\b',
        '(?i)\b(?:permite|autoriza|deve|pode)\b\s+(?!n[a\u00e3]o\b|nunca\b)[^.;]*\b(?:automatizar|auto-kill|auto-restart|auto-upgrade|auto-init)\b',
        '(?i)\b(?:may|can|should|must|authorized to|pode|deve)\b\s+(?!not\b|never\b|n[a\u00e3]o\b|nunca\b)[^.;]*\b(?:reiniciar Antigravity|fechar Antigravity|restart Antigravity|close Antigravity|alterar cookies|limpar cache do antigravity|modificar auth|touch auth|touch profile|touch cookies|touch cache)\b'
    )
    foreach ($pattern in $forbiddenAutomations) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label declares forbidden automation: $pattern"
        }
    }
}

function Assert-DeepSeekDaemonRestartLifecycle {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    if ($Text -match '(?i)/v1/health') {
        throw "$Label contains forbidden endpoint /v1/health; actual bridge endpoint is /health"
    }

    $lifecycleNormalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $lifecycleRequired = @(
        '(?i)express (?:human|user) authorization|explicit user authorization',
        '(?i)dist/cli\.js restart --config <known-config> --json',
        '(?i)GET\s+[`]?/health',
        '(?i)PID,? command(?: line)?,? and data (?:dir|directory) ownership',
        '(?i)bridge\.sqlite',
        '(?i)bounded readiness',
        '(?i)fail-closed',
        '(?i)AntigravityProcessError',
        '(?i)taskkill',
        '(?i)Stop-Process',
        '(?i)Transport closed\s*\+\s*health ready|Transport closed e health ready',
        '(?i)\brecovering\b',
        '(?i)\babsent\b',
        '(?i)\bowned-unhealthy\b',
        '(?i)uma tentativa bounded|bounded single attempt|uma [u\u00fa]nica tentativa delimitada',
        '(?i)sem provider/model fallback|sem fallback de provedor ou modelo|no provider/model fallback',
        '(?i)nunca (?:restart|close|login|logout) Antigravity|proibido reiniciar,? fechar,? logar ou deslogar Antigravity|never restart,? close,? login,? or logout Antigravity',
        '(?i)nunca tocar auth,? profile,? cookies ou cache|proibido tocar auth,? profile,? cookies,? cache|never touch auth,? profile,? cookies,? or cache',
        '(?i)jobs ativos s[o\u00f3] permitem recovery quando todos t[e\u00ea]m durable spool/recovery comprovado|active jobs only allow recovery when all have proven durable spool/recovery',
        '(?i)stale-running com daemon ausente (?:pode reconciliar|s[o\u00f3] reconcilia) apenas com capacidade durable instalada|stale-running with absent daemon reconciles only with installed durable capacity'
    )
    foreach ($pattern in $lifecycleRequired) {
        if (-not [regex]::IsMatch($lifecycleNormalized, $pattern)) {
            throw "$Label is missing required DeepSeek daemon restart policy pattern: $pattern"
        }
    }

    # Forbidden un-gated generic automations
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:restart automatically|auto-restart without consent|restart on any error)\b')) {
        throw "$Label permits unauthorized automatic daemon restart"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:use taskkill|use Stop-Process|kill-all)\b')) {
        throw "$Label permits taskkill or Stop-Process"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:restart Serena|restart CodeGraph|restart Context7|restart Codex|restart Antigravity)\b')) {
        throw "$Label permits restarting other MCPs or host platforms"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:restart with active jobs|restart when jobs are running|ignore active jobs)\b')) {
        throw "$Label permits restarting while jobs are active in sqlite"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:trigger on AntigravityProcessError|triggered by agy failure|trigger on HTTP error alone)\b')) {
        throw "$Label permits restarting on non-trigger conditions"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to|pode|deve)\b\s+(?!not\b|never\b|n[a\u00e3]o\b|nunca\b)[^.;]*\b(?:reiniciar Antigravity|fechar Antigravity|restart Antigravity|close Antigravity|alterar cookies|limpar cache do antigravity|modificar auth|touch auth|touch profile|touch cookies|touch cache)\b')) {
        throw "$Label permits touching Antigravity lifecycle or auth/cookies/cache"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:may|can|should|must|authorized to|pode|deve)\b\s+(?!not\b|never\b|n[a\u00e3]o\b|nunca\b)[^.;]*\b(?:recovery com jobs sem spool|reconciliar stale-running sem capacidade durable|recover active jobs without durable spool)\b')) {
        throw "$Label permits recovery without proven durable spool or durable reconciliation capacity"
    }
    if ([regex]::IsMatch($lifecycleNormalized, '(?i)\b(?:m[u\u00fa]ltiplas tentativas de restart|tentativas infinitas|fallback para outro modelo na falha do daemon)\b')) {
        throw "$Label permits unbounded restart attempts or provider fallback"
    }
}

function Assert-DeepSeekDaemonRestartSkill {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    if ($Text -match '(?i)/v1/health') {
        throw "$Label contains forbidden endpoint /v1/health; actual bridge endpoint is /health"
    }

    $skillNormalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $skillRequired = @(
        '(?i)DeepSeek (?:Sub-Agent )?Daemon Restart Exception',
        '(?i)dist/cli\.js restart --config <known-config> --json',
        '(?i)/health',
        '(?i)bridge\.sqlite',
        '(?i)bounded readiness',
        '(?i)AntigravityProcessError',
        '(?i)Transport closed\s*\+\s*health ready|Transport closed e health ready',
        '(?i)\brecovering\b',
        '(?i)\babsent\b',
        '(?i)\bowned-unhealthy\b',
        '(?i)uma tentativa bounded|bounded single attempt|uma [u\u00fa]nica tentativa delimitada',
        '(?i)sem provider/model fallback|sem fallback de provedor ou modelo|no provider/model fallback',
        '(?i)nunca (?:restart|close|login|logout) Antigravity|never restart,? close,? login,? or logout Antigravity',
        '(?i)nunca tocar auth,? profile,? cookies ou cache|never touch auth,? profile,? cookies,? or cache',
        '(?i)jobs ativos s[o\u00f3] permitem recovery quando todos t[e\u00ea]m durable spool/recovery comprovado|active jobs only allow recovery when all have proven durable spool/recovery',
        '(?i)stale-running com daemon ausente (?:pode reconciliar|s[o\u00f3] reconcilia) apenas com capacidade durable instalada|stale-running with absent daemon reconciles only with installed durable capacity'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNormalized, $pattern)) {
            throw "$Label is missing required DeepSeek daemon restart policy pattern: $pattern"
        }
    }
}

function Assert-DeepSeekDaemonRestartAgents {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    if ($Text -match '(?i)/v1/health') {
        throw "$Label contains forbidden endpoint /v1/health; actual bridge endpoint is /health"
    }

    $agentsNormalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $agentsRequired = @(
        '(?i)daemon DeepSeek',
        '(?i)dist/cli\.js restart --config <known-config> --json',
        '(?i)/health',
        '(?i)bridge\.sqlite'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNormalized, $pattern)) {
            throw "$Label is missing required DeepSeek daemon restart policy pattern: $pattern"
        }
    }
}

function Assert-DeepSeekDaemonRestartGemini {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    if ($Text -match '(?i)/v1/health') {
        throw "$Label contains forbidden endpoint /v1/health; actual bridge endpoint is /health"
    }

    $geminiNormalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $geminiRequired = @(
        '(?i)daemon DeepSeek',
        '(?i)dist/cli\.js restart --config <known-config> --json',
        '(?i)/health',
        '(?i)bridge\.sqlite'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNormalized, $pattern)) {
            throw "$Label is missing required DeepSeek daemon restart policy pattern: $pattern"
        }
    }
}

function Assert-DeepSeekDaemonRestartPolicy {
    param(
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$LifecycleText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    Assert-DeepSeekDaemonRestartLifecycle -Label "${pfx}mcp-foundation lifecycle.md" -Text $LifecycleText
    Assert-DeepSeekDaemonRestartSkill -Label "${pfx}mcp-foundation SKILL.md" -Text $SkillText
    Assert-DeepSeekDaemonRestartAgents -Label "${pfx}codex AGENTS.md" -Text $AgentsText
    Assert-DeepSeekDaemonRestartGemini -Label "${pfx}antigravity GEMINI.md" -Text $GeminiText
}

function Assert-SerenaCodeGraphPolicy {
    param(
        [Parameter(Mandatory)][string]$McpSkillText,
        [Parameter(Mandatory)][string]$SerenaCodeGraphText,
        [Parameter(Mandatory)][string]$WorkflowSkillText,
        [Parameter(Mandatory)][string]$CommitRefText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    $mcpSkillNorm = [regex]::Replace($McpSkillText, '\s+', ' ').Trim()
    $scgNorm = [regex]::Replace($SerenaCodeGraphText, '\s+', ' ').Trim()
    $wfSkillNorm = [regex]::Replace($WorkflowSkillText, '\s+', ' ').Trim()
    $commitNorm = [regex]::Replace($CommitRefText, '\s+', ' ').Trim()
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()

    # 1. Dedicated reference references/serena-codegraph.md must define the centralized policy:
    $scgRequired = @(
        '(?i)preflight',
        '(?i)(?:todos os modos|all modes)',
        '(?i)(?:apenas verificam|status-only|only verify|verify only)',
        '(?i)(?:codegraph sync|sincroniza[cç][aã]o incremental)',
        '(?i)(?:stale|pending|atraso)',
        '(?i)(?:recheck|verificar novamente)',
        '(?i)(?:falha/unknown|failure/unknown|unknown).*(?:Serena|rg)',
        '(?i)(?:sem auto-init|never auto-init|n[aã]o reindexar automaticamente|sem reindexar automaticamente)',
        '(?i)(?:sem auto-upgrade|never auto-upgrade|n[aã]o fazer upgrade de pacote|sem upgrade de pacote)',
        '(?i)(?:sem auto-restart|never auto-restart|n[aã]o reiniciar MCPs|sem reiniciar MCPs)',
        '(?i)status --json',
        '(?i)codegraph_explore',
        '(?i)projectPath',
        '(?i)--project-from-cwd',
        '(?i)(?:uma inst[aâ]ncia por projeto|one instance per project)',
        '(?i)(?:confirma[cç][aã]o read-only|read-only confirmation)',
        '(?i)(?:sem singleton global|no global singleton)',
        '(?i)(?:sem taskkill|never taskkill|no generic taskkill)',
        '(?i)no-onboarding',
        '(?i)no-memories',
        '(?i)(?:edi[cç][aã]o somente em modos|edits only in explicit write modes)',
        '(?i)Get-CodexCommitCandidates',
        '(?i)Get-CodexCodeGraphMaintenanceDecision',
        '(?i)COMMIT.{0,80}(?:git-only|Git index)'
    )
    foreach ($pattern in $scgRequired) {
        if (-not [regex]::IsMatch($scgNorm, $pattern)) {
            throw "${pfx}serena-codegraph.md is missing required pattern: $pattern"
        }
    }

    # 2. mcp-foundation SKILL.md must route to references/serena-codegraph.md
    if ($mcpSkillText -notmatch '(?i)serena-codegraph\.md') {
        throw "${pfx}mcp-foundation SKILL.md is missing reference to serena-codegraph.md"
    }

    # 3. COMMIT contract in workflows SKILL.md and references/commit.md:
    $commitRequired = @(
        '(?i)git-only',
        '(?i)(?:nunca altera [`]?\.gitignore|never (?:modifies|alters) [`]?\.gitignore)',
        '(?i)(?:nunca atualiza [`]?[ií]ndices MCP|never updates [`]?(?:the )?MCP indexes)',
        '(?i)(?:classifi\w*).*(?:staged|unstaged|untracked)',
        '(?i)(?:bloqueia sem mudar o (?:git )?index|block without changing the (?:git )?index)'
    )
    foreach ($pattern in $commitRequired) {
        if (-not [regex]::IsMatch($commitNorm, $pattern)) {
            throw "${pfx}commit.md is missing required COMMIT contract pattern: $pattern"
        }
        if (-not [regex]::IsMatch($wfSkillNorm, $pattern)) {
            throw "${pfx}workflows SKILL.md is missing required COMMIT contract pattern: $pattern"
        }
    }

    # 4. Host templates (codex AGENTS.md and antigravity GEMINI.md) compact contracts:
    $templateRequired = @(
        '(?i)(?:preflight|codegraph sync|status --json)',
        '(?i)(?:--project-from-cwd|uma inst[aâ]ncia por projeto)',
        '(?i)(?:nunca altera \.gitignore|git-only)'
    )
    foreach ($pattern in $templateRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            throw "${pfx}codex AGENTS.md is missing required Serena/CodeGraph pattern: $pattern"
        }
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            throw "${pfx}antigravity GEMINI.md is missing required Serena/CodeGraph pattern: $pattern"
        }
    }
}

function Assert-McpTemplateRouting {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    if ($Text -notmatch '(?i)mcp-foundation') {
        throw "$Label does not route to mcp-foundation skill"
    }

    if ($Text -notmatch '(?i)GEMINI\.md') {
        throw "$Label does not reference GEMINI.md for MCP / PromptPad context"
    }

    $universalPatterns = @(
        '(?i)GEMINI\.md[^.;]*(?:todas as tarefas|all tasks|every task|anexado em todas|attached to all)',
        '(?i)(?:todas as tarefas|all tasks|every task)[^.;]*GEMINI\.md'
    )
    foreach ($pattern in $universalPatterns) {
        if ([regex]::IsMatch($Text, $pattern)) {
            throw "$Label wrongly claims GEMINI.md is attached to all tasks: $pattern"
        }
    }

    $forbiddenPatterns = @('taskkill\s+/', 'rm\s+-rf', 'format\s+[A-Za-z]:', 'drop\s+table', 'password\s*=', 'secret\s*=', 'api_key\s*=')
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            throw "$Label contains forbidden destructive command or secret pattern: $pattern"
        }
    }
}

function Assert-DeliveryReviewContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredModes = @('IMPL.AUTO', 'IMPL', 'IMPL.PHASE', 'DELIVER.AUTO', 'BUG.FIX', 'DEBUG')
    foreach ($mode in $requiredModes) {
        if ($normalized.IndexOf($mode, [StringComparison]::Ordinal) -lt 0) {
            throw "$Label is missing required mode: $mode"
        }
    }

    $requiredPatterns = @(
        '(?i)R\.A\.F\.V',
        '(?i)(?:manual|sob demanda|explicitamente|separate|explicit)',
        '(?i)(?:nunca|never).{0,40}(?:autom[a\u00e1]tic|auto-run)',
        '(?i)alvo congelado|frozen target',
        '(?i)baseline',
        '(?i)status',
        '(?i)diff|patch hash',
        '(?i)SHA256',
        '(?i)valida[c\u00e7][a\u00e3]o determin[i\u00ed]stica|deterministic validation',
        '(?i)revis[a\u00e3]o independente|independent review',
        '(?i)reconstru[c\u00e7]\w*.{0,30}(?:requisitos|pedido)|reconstruct.{0,30}requirements',
        '(?i)claim-map|mapa de alega[c\u00e7][o\u00f5]es',
        '(?i)(?:caminhos prim[a\u00e1]rios|primary).{0,60}(?:alternativos|alternate).{0,60}(?:hist[o\u00f3]ric|historical)',
        '(?i)(?:negativ|negative).{0,60}(?:falha|failure).{0,60}(?:concorr[e\u00ea]ncia|concurrency).{0,60}(?:seguran[c\u00e7]a|security)',
        '(?i)(?:falso-verde|false-green|false green)',
        '(?i)(?:integra[c\u00e7][a\u00e3]o|integration).{0,60}(?:invariantes|invariants).{0,60}(?:retrocompatibilidade|backcompat).{0,60}(?:escopo|scope)',
        '(?i)target_id',
        '(?i)target_id.{0,100}(?:digest determin[i\u00ed]stic|deterministic digest|SHA256)',
        '(?i)(?:n[a\u00e3]o|never|nunca).{0,40}(?:timestamp-only|apenas timestamp|somente timestamp)',
        '(?i)diff_sha256',
        '(?i)file_sha256',
        '(?i)(?:revisor independente|independent reviewer).{0,80}(?:n[a\u00e3]o-autor|non-author).{0,80}(?:contexto (?:novo|limpo|read-only|somente leitura)|fresh/read-only context|contexto de leitura)',
        '(?i)APPROVED',
        '(?i)BLOCKED',
        '(?i)required_fix',
        '(?i)(?:lote [u\u00fa]nico|consolidated|lote consolidado).{0,40}reparo',
        '(?i)(?:delta|re-revis[a\u00e3]o delta)',
        '(?i)(?:bloqueios|blockers).{0,60}(?:blast radius|raio de impacto|impacto afetado)',
        '(?i)(?:re-checa|reverifi|revalid|checagem|avalia).{0,60}(?:identidade|alvo|target).{0,60}(?:invariantes|invariants)',
        '(?i)(?:recomput|recalcul).{0,60}(?:target_id|identidade do alvo|target identity).{0,60}(?:igualdade exata|exact equality|coincid)',
        '(?i)pol[i\u00ed]tica de reparo orientada a evid[e\u00ea]ncia|evidence-based repair',
        '(?i)hip[o\u00f3]tese|hypothesis',
        '(?i)observa[c\u00e7][a\u00e3]o discriminante|expected discriminating observation',
        '(?i)delta observado|observed delta',
        '(?i)(?:admiss[a\u00e3]o|admission).{0,150}(?:hip[o\u00f3]tese|hypothesis).{0,150}(?:observa[c\u00e7][a\u00e3]o discriminante|expected discriminating observation)',
        '(?i)(?:admiss[a\u00e3]o|admission).{0,150}(?:delta.{0,40}(?:n[a\u00e3]o est[a\u00e1] dispon[i\u00ed]vel|not yet available|pendente|pending)|delta pendente)',
        '(?i)(?:p[o\u00f3]s-resultado|post-result).{0,120}(?:delta observado|observed delta|falsif)',
        '(?i)pr[o\u00f3]xima decis[a\u00e3]o|next decision',
        '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente|different diagnostic direction',
        '(?i)(?:sem|proibid[oa]|nunca).{0,50}(?:retentativa id[e\u00ea]ntica|duplicate retry|worker swarm)',
        '(?i)(?:terceir[ao]|subsequente).{0,50}(?:reparo|tentativa).{0,50}(?:permitid[ao]|avalan|avan[c\u00e7]a)|novas evid[e\u00ea]ncias [u\u00fa]teis e hip[o\u00f3]teses test[a\u00e1]veis',
        '(?i)bloqueio genu[i\u00ed]no de (?:autoridade|acesso|decis[a\u00e3]o do usu[a\u00e1]rio)',
        '(?i)sem caminho seguro acion[a\u00e1]vel|no safe actionable path',
        '(?i)(?:sem|proibid[oa]|nunca).{0,50}(?:limite num[e\u00e9]rico fixo|contador(?:es)? disfar[c\u00e7]ado|numerical stopping rule)',
        '(?i)falha fechado|fail closed',
        '(?i)zero (?:bloqueios|blockers)',
        '(?i)invariante a staging|staging-invariant',
        '(?i)code[- ]page|host-code-page|encoding do host|codifica[c\u00e7][a\u00e3]o do host',
        '(?i)head_status|relativo ao HEAD|HEAD-relative',
        '(?i)raw_porcelain|fora do digest|outside the digest|outside digest',
        '(?i)staged path set|conjunto de (?:arquivos|caminhos) no stage',
        '(?i)staged blob|conte[uú]do.{0,60}(?:aprovado|approved).{0,60}(?:index|stage)|(?:index|stage).{0,60}conte[uú]do.{0,60}(?:aprovado|approved)',
        '(?i)ortogonal [a\u00e0]s flags|orthogonal to flags',
        '(?i)(?:revisor independente [u\u00fa]nico|reviewer independente [u\u00fa]nico|single independent reviewer).{0,60}(?:alvo congelado|target congelado|frozen target)',
        '(?i)reparo consolidado no mesmo writer|consolidated repair in same writer',
        '(?i)closure review de delta|re-revis[a\u00e3]o de delta|delta closure review',
        '(?i)sem R\.A\.F\.V\. autom[a\u00e1]tico|never auto-run R\.A\.F\.V\.|never automatic R\.A\.F\.V\.',
        '(?i)prova operacional|operational proof|runtime proof',
        '(?i)processo,? daemon ou servi[cç]o ativo|live process/daemon/service',
        '(?i)persist[eê]ncia de dados ou migra[cç][aã]o|persistence or migration',
        '(?i)concorr[eê]ncia e sem[aâ]ntica exata|concurrency/exactly-once',
        '(?i)roteamento de provedores ou modelos|provider/model routing',
        '(?i)integra[cç][aã]o externa|external integration',
        '(?i)escala e volume|sens[ií]vel a escala|data volume/resource scale',
        '(?i)evid[eê]ncia observada|observed runtime evidence|observed evidence',
        '(?i)lat[eê]ncia|readiness|health',
        '(?i)falsos?-verdes? est[aá]ticos?|static-only.*false green|test-only.*false green',
        '(?i)nunca inventar|never invent',
        '(?i)sem ampliar autoridade|never broaden authority',
        '(?i)Gate de Adequa[c\u00e7][a\u00e3]o(?: da Corre[c\u00e7][a\u00e3]o)?',
        '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel(?:/delimitada)?',
        '(?i)LOCAL_FIX',
        '(?i)ROBUST_FIX',
        '(?i)REWORK',
        '(?i)RESEARCH',
        '(?i)RESEARCH_THEN_REWORK',
        '(?i)pre-first-edit|antes da primeira edi[c\u00e7][a\u00e3]o',
        '(?i)\bfalha\b|\bfailure\b',
        '(?i)causa estrutural|structural cause',
        '(?i)expans[a\u00e3]o de escopo|scope expansion',
        '(?i)pr[e\u00e9]-revis[a\u00e3]o|pre-review',
        '(?i)(?:nunca|sem|n[a\u00e3]o).{0,30}(?:a cada turno|per-turn)',
        '(?i)(?:sem|nunca|proibid[oa]).{0,40}troca(?:r)? autom[a\u00e1]tica(?:mente)? de modo',
        '(?i)transporte neutro|neutral transport'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required delivery-review contract pattern: $pattern"
        }
    }

    $staleMax2Pattern = '(?i)(?:(?:at\s+most|max(?:imum)?(?:\s+of)?|up\s+to)\s+(?:\d+|two)\s+(?:(?:consolidated\s+)?repair\s+)?rounds?|max(?:imum)?\s+two\b|(?:(?:no\s+)?m(?:[a\u00e1]|\u00c3\u00a1)x(?:imo|\u00c3\u00admo)?\.?(?:\s+de)?|at(?:[e\u00e9]|\u00c3\u00a9)|limite\s+(?:fixo\s+)?de)\s+(?:\d+|duas?|dois)\s+(?:rodadas?(?:\s+de\s+reparo)?|tentativas?)|m(?:[a\u00e1]|\u00c3\u00a1)x\.?\s*2(?:\s+rodadas?)?|\blimite\s+num(?:[e\u00e9]|\u00c3\u00a9)rico\s+fixo\s+de\s+\d+)'
    if ([regex]::IsMatch($normalized, $staleMax2Pattern)) {
        throw "$Label contains obsolete max2 repair rule: $staleMax2Pattern"
    }

    $forbidden = @(
        'Review-And-Fix-Vigorously',
        'Review and Fix Vigorously',
        'Review-And-Fix',
        'Review and Fix',
        'target-<hash-ou-timestamp>',
        'focada estritamente nos apontamentos',
        'exclusively delta',
        'auto-run RAFV',
        'RAFV automático',
        'múltiplos revisores independentes para o mesmo target',
        '"required_fix": "correção mínima exigida"',
        'correção mínima exigida'
    )
    foreach ($token in $forbidden) {
        if ($Text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "$Label contains forbidden phrase or obsolete template: $token"
        }
    }
}

function Assert-DeliveryReviewPolicy {
    param(
        [Parameter(Mandatory)][string]$DeliveryReviewText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [string]$ValidationText = '',
        [string]$CommitText = '',
        [string]$QualityRatchetText = '',
        [string]$DelegationText = '',
        [string]$ReadmeText = '',
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    Assert-DeliveryReviewContract -Label "${pfx}delivery-review.md" -Text $DeliveryReviewText

    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($skillNorm, '(?i)operational proof|runtime proof|prova operacional')) {
        throw "${pfx}SKILL.md is missing operational proof gate pattern"
    }
    if (-not [regex]::IsMatch($skillNorm, '(?i)Gate de Adequa[c\u00e7][a\u00e3]o|corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel')) {
        throw "${pfx}SKILL.md is missing correction adequacy gate pattern"
    }

    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($agentsNorm, '(?i)prova operacional|operational proof|runtime proof')) {
        throw "${pfx}codex AGENTS.md is missing operational proof gate pattern"
    }
    if (-not [regex]::IsMatch($agentsNorm, '(?i)Gate de Adequa[c\u00e7][a\u00e3]o|corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel')) {
        throw "${pfx}codex AGENTS.md is missing correction adequacy gate pattern"
    }

    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($geminiNorm, '(?i)prova operacional|operational proof|runtime proof|delivery review')) {
        throw "${pfx}antigravity GEMINI.md is missing operational proof gate pattern"
    }
    if (-not [regex]::IsMatch($geminiNorm, '(?i)Gate de Adequa[c\u00e7][a\u00e3]o|corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel')) {
        throw "${pfx}antigravity GEMINI.md is missing correction adequacy gate pattern"
    }
    if (-not [regex]::IsMatch($skillNorm, '(?i)(?:reparo orientad[ao] a evid[e\u00ea]ncia|evidence-based repair)|debug_ledger\.md')) {
        throw "${pfx}SKILL.md is missing evidence-based repair policy pattern"
    }
    if (-not [regex]::IsMatch($agentsNorm, '(?i)(?:reparo orientad[ao] a evid[e\u00ea]ncia|evidence-based repair)|debug_ledger\.md')) {
        throw "${pfx}codex AGENTS.md is missing evidence-based repair policy pattern"
    }
    if (-not [regex]::IsMatch($geminiNorm, '(?i)(?:reparo orientad[ao] a evid[e\u00ea]ncia|evidence-based repair)|debug_ledger\.md')) {
        throw "${pfx}antigravity GEMINI.md is missing evidence-based repair policy pattern"
    }

    $staleMax2Pattern = '(?i)(?:(?:at\s+most|max(?:imum)?(?:\s+of)?|up\s+to)\s+(?:\d+|two)\s+(?:(?:consolidated\s+)?repair\s+)?rounds?|max(?:imum)?\s+two\b|(?:(?:no\s+)?m(?:[a\u00e1]|\u00c3\u00a1)x(?:imo|\u00c3\u00admo)?\.?(?:\s+de)?|at(?:[e\u00e9]|\u00c3\u00a9)|limite\s+(?:fixo\s+)?de)\s+(?:\d+|duas?|dois)\s+(?:rodadas?(?:\s+de\s+reparo)?|tentativas?)|m(?:[a\u00e1]|\u00c3\u00a1)x\.?\s*2(?:\s+rodadas?)?|\blimite\s+num(?:[e\u00e9]|\u00c3\u00a9)rico\s+fixo\s+de\s+\d+)'
    $policyForbidden = @(
        '(?i)\b(?:pode|deve|autoriza|permite)\b\s+(?!n[a\u00e3]o\b|nunca\b|sem\b)[^.;]*\b(?:troca|trocar|transi[c\u00e7][a\u00e3]o)\s+autom[a\u00e1]tica(?:mente)?\s+de\s+modo\b',
        '(?i)\bbridge\b\s+(?:decide|aprova|rejeita)\b',
        '(?i)\b(?:regras de workflow|workflow rules)\s+residem\s+no\s+bridge\b',
        '(?i)\b(?:concede|permite|autoriza)\s+escrita\b[^.;]*(?:no ALINHAMENTO|em PLAN|em REWORK|em RESEARCH)',
        '(?i)"required_fix":\s*"corre(?:[c\u00e7]|\u00c3\u00a7)(?:[a\u00e3]|\u00c3\u00a3)o m(?:[i\u00ed]|\u00c3\u00ad)nima exigida"',
        '(?i)\bmeta de corre(?:[c\u00e7]|\u00c3\u00a7)(?:[a\u00e3]|\u00c3\u00a3)o m(?:[i\u00ed]|\u00c3\u00ad)nima\b',
        $staleMax2Pattern
    )
    $surfaces = @(
        @{ Name = "${pfx}delivery-review.md"; Text = $DeliveryReviewText },
        @{ Name = "${pfx}SKILL.md"; Text = $skillNorm },
        @{ Name = "${pfx}codex AGENTS.md"; Text = $agentsNorm },
        @{ Name = "${pfx}antigravity GEMINI.md"; Text = $geminiNorm }
    )
    if (-not [string]::IsNullOrWhiteSpace($ValidationText)) {
        $surfaces += @{ Name = "${pfx}validation.md"; Text = [regex]::Replace($ValidationText, '\s+', ' ').Trim() }
    }
    if (-not [string]::IsNullOrWhiteSpace($CommitText)) {
        $surfaces += @{ Name = "${pfx}commit.md"; Text = [regex]::Replace($CommitText, '\s+', ' ').Trim() }
    }
    if (-not [string]::IsNullOrWhiteSpace($QualityRatchetText)) {
        $surfaces += @{ Name = "${pfx}quality-ratchet.md"; Text = [regex]::Replace($QualityRatchetText, '\s+', ' ').Trim() }
    }
    if (-not [string]::IsNullOrWhiteSpace($DelegationText)) {
        $surfaces += @{ Name = "${pfx}delegation.md"; Text = [regex]::Replace($DelegationText, '\s+', ' ').Trim() }
    }
    if (-not [string]::IsNullOrWhiteSpace($ReadmeText)) {
        $surfaces += @{ Name = "${pfx}README.md"; Text = [regex]::Replace($ReadmeText, '\s+', ' ').Trim() }
    }

    foreach ($pat in $policyForbidden) {
        foreach ($s in $surfaces) {
            if ([regex]::IsMatch($s.Text, $pat)) {
                throw "$($s.Name) contains forbidden adequacy gate violation: $pat"
            }
        }
    }
}

function Assert-AlinhamentoPolicy {
    param(
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$DelegationText,
        [Parameter(Mandatory)][string]$ReadmeText,
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $delegationNorm = [regex]::Replace($DelegationText, '\s+', ' ').Trim()
    $readmeNorm = [regex]::Replace($ReadmeText, '\s+', ' ').Trim()

    $agentsRequired = @(
        '(?i)\bALINHAMENTO\b',
        '(?i)(?:sem modo ativo|aus[e\u00ea]ncia de modo|no active mode).{0,80}\bALINHAMENTO\b|\bALINHAMENTO\b.{0,80}(?:sem modo ativo|aus[e\u00ea]ncia de modo|no active mode)',
        '(?i)somente leitura',
        '(?i)(?:proibid[oa]|sem|nunca|no).{0,40}(?:criar|editar|apagar|modificar|alterar|gravar|create|edit|delete).{0,40}(?:arquivos?|c[o\u00f3]digo|files?)',
        '(?i)verbos imperativos nunca inferem modo|verbos imperativos n[a\u00e3]o inferem modo|imperative verbs never infer a mode',
        '(?i)conversa simples.{0,40}direta|conversa simples permanece direta',
        '(?i)(?:sem cerim[o\u00f4]nia|sem planos? formais?|sem todo list|no (?:workflow )?ceremony)',
        '(?i)(?:inspe[c\u00e7][a\u00e3]o|leitura).{0,80}(?:depender materialmente|depend[e\u00ea]ncia material|materially depends?)',
        '(?i)(?:pro[i\u00ed]bem-se|proibid[oa]|n[a\u00e3]o acionar|forbidden).{0,80}(?:metadados|metadata|estado local|local state).{0,80}(?:workspace|falha fechad|fail closed|sem ela)',
        '(?i)(?:consumo e encerramento|consumo e fechamento).{0,40}ledger',
        '(?i)(?:portugu[e\u00ea]s do brasil|pt-BR|portugu[e\u00ea]s).*compacto',
        '(?i)confirma[c\u00e7][a\u00e3]o (?:curta )?de entendimento|short understanding confirmation',
        '(?i)(?:transcri[c\u00e7][o\u00f5]es? de [a\u00e1]udio|[a\u00e1]udio|audio).{0,80}(?:ru[i\u00ed]do|premissas?|ambiguidade)',
        '(?i)(?:quando a[c\u00e7][a\u00e3]o for o pr[o\u00f3]ximo passo|quando for necess[a\u00e1]ria a[c\u00e7][a\u00e3]o|when action is the next step).{0,80}(?:recomende|recomendar|recommend).{0,80}(?:modo exato|modo expl[i\u00ed]cito|exact explicit workflow mode)',
        '(?i)(?:modo expl[i\u00ed]cito permanece ativo|modo ativo permanece ativo|permanece ativo na mesma execu[c\u00e7][a\u00e3]o|explicit mode remains active).{0,100}(?:gate de conclus[a\u00e3]o|done gate|cancelamento expl[i\u00ed]cito|explicit cancellation)',
        '(?i)(?:cancelamento n[a\u00e3]o autoriza|cancelamento pro[i\u00ed]be|cancellation does not authorize).{0,80}(?:kill|destrutiv|muta[c\u00e7][a\u00e3]o|destructive)',
        '(?i)(?:retorna|volta|retorno)\s+a[o]?\s+ALINHAMENTO|returns? to ALINHAMENTO'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            throw "${pfx}codex AGENTS.md is missing required ALINHAMENTO pattern: $pattern"
        }
    }

    $geminiRequired = @(
        '(?i)\bALINHAMENTO\b',
        '(?i)somente leitura',
        '(?i)verbos imperativos nunca inferem modo|verbos imperativos n[a\u00e3]o inferem modo|imperative verbs never infer a mode',
        '(?i)(?:sem cerim[o\u00f4]nia|sem planos? formais?|sem todo list|no (?:workflow )?ceremony)',
        '(?i)(?:inspe[c\u00e7][a\u00e3]o|leitura).{0,80}(?:depender materialmente|depend[e\u00ea]ncia material|materially depends?)',
        '(?i)(?:pro[i\u00ed]bem-se|proibid[oa]|n[a\u00e3]o acionar|forbidden).{0,80}(?:metadados|metadata|estado local|local state).{0,80}(?:workspace|falha fechad|fail closed|sem ela)',
        '(?i)confirma[c\u00e7][a\u00e3]o (?:curta )?de entendimento|short understanding confirmation',
        '(?i)modo expl[i\u00ed]cito|retorna a ALINHAMENTO|volta a ALINHAMENTO|returns? to ALINHAMENTO'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            throw "${pfx}antigravity GEMINI.md is missing required ALINHAMENTO pattern: $pattern"
        }
    }

    $skillRequired = @(
        '(?i)\bALINHAMENTO\b',
        '(?i)(?:without an active mode|absence of an active mode|sem modo ativo|no active mode).{0,80}\bALINHAMENTO\b|\bALINHAMENTO\b.{0,80}(?:without an active mode|absence of an active mode|sem modo ativo)',
        '(?i)(?:no (?:workflow )?ceremony|sem cerim[o\u00f4]nia|no formal plan|sem plano formal)',
        '(?i)(?:materially depends?|depender materialmente|depend[e\u00ea]ncia material).{0,80}(?:repository|repo|reposit[o\u00f3]rio|read|leitura|inspection)',
        '(?i)(?:forbidden|proibid[oa]|no).{0,80}(?:metadata|metadados|local state|estado local).{0,100}(?:workspace|fail closed|falha fechad|without it|sem ela)',
        '(?i)(?:remains active|permanece ativo).{0,100}(?:unprefixed|clarifications|esclarecimentos|done gate|cancellation)',
        '(?i)returns? to ALINHAMENTO|retorna a[o]? ALINHAMENTO'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNorm, $pattern)) {
            throw "${pfx}skills/workflows/SKILL.md is missing required ALINHAMENTO pattern: $pattern"
        }
    }

    $delegationRequired = @(
        '(?i)\bALINHAMENTO\b',
        '(?i)(?:under ALINHAMENTO|no ALINHAMENTO|em ALINHAMENTO|sob ALINHAMENTO|no estado.*?ALINHAMENTO).{0,120}(?:somente leitura|inspe[c\u00e7][a\u00e3]o|conversa simples)',
        '(?i)(?:sem cerim[o\u00f4]nia|no (?:workflow )?ceremony|sem planos? formais?|no formal plan)',
        '(?i)(?:depend[e\u00ea]ncia material|materially depends?|depender materialmente)',
        '(?i)somente leitura',
        '(?i)(?:metadados|metadata|estado|state).{0,80}(?:workspace|falha fechad|fail closed)',
        '(?i)(?:ciclo normal de ledger|ledger de requisi[c\u00e7][o\u00f5]es|consumo e fechamento|consumo e encerramento).{0,80}(?:ledger|lifecycle|fechamento|encerramento)',
        '(?i)(?:narrowing|estreitamento|exce[c\u00e7][a\u00e3]o|scoped).{0,80}(?:aggressive|delega[c\u00e7][a\u00e3]o agressiva)'
    )
    foreach ($pattern in $delegationRequired) {
        if (-not [regex]::IsMatch($delegationNorm, $pattern)) {
            throw "${pfx}skills/workflows/references/delegation.md is missing required ALINHAMENTO pattern: $pattern"
        }
    }

    $readmeRequired = @(
        '(?i)\bALINHAMENTO\b',
        '(?i)(?:sem modo ativo|aus[e\u00ea]ncia de modo|sem \$workflows).{0,100}\bALINHAMENTO\b|\bALINHAMENTO\b.{0,100}(?:sem modo ativo|somente leitura|discuss[a\u00e3]o)',
        '(?i)(?:sem cerim[o\u00f4]nia|sem planos? formais?|sem todo list|no (?:workflow )?ceremony)',
        '(?i)(?:depend[e\u00ea]ncia material|material dependency)',
        '(?i)verbos imperativos nunca inferem modo|verbos imperativos n[a\u00e3]o inferem modo|imperative verbs never infer a mode'
    )
    foreach ($pattern in $readmeRequired) {
        if (-not [regex]::IsMatch($readmeNorm, $pattern)) {
            throw "${pfx}README.md is missing required ALINHAMENTO pattern: $pattern"
        }
    }

    $forbidden = @(
        '(?i)\bmode\s*=\s*ALINHAMENTO\b',
        '(?i)\bmode\s*=\s*DISCUSS\b',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:criar|editar|escrever|alterar|modificar|gravar|write|edit|create)\b[^.;]*(?:arquivos?|c[o\u00f3]digo|files?)\b[^.;]*(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)',
        '(?i)(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)[^.;]*\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:criar|editar|escrever|alterar|modificar|gravar|write|edit|create)\b[^.;]*(?:arquivos?|c[o\u00f3]digo|files?)',
        '(?i)\b(?:verbos imperativos inferem modo|imperative verbs infer a mode|inferir modo por verbo imperativo)\b',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:matar processos|taskkill|Stop-Process|rollback destrutivo)\b[^.;]*(?:ao cancelar|no cancelamento|on cancellation|upon cancel)',
        '(?i)(?:ao cancelar|no cancelamento|on cancellation|upon cancel)[^.;]*\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:matar processos|taskkill|Stop-Process|rollback destrutivo)',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:criar planos? formais?|todo lists?|specs? formais?|formal plans?|classificar delivery)\b[^.;]*(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)',
        '(?i)(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)[^.;]*\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:criar planos? formais?|todo lists?|specs? formais?|formal plans?|classificar delivery)',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:inspecionar o repo|ler arquivos?|inspecionar o reposit[o\u00f3]rio|read files?)\b[^.;]*(?:sem depend[e\u00ea]ncia material|incondicionalmente|sempre|sem necessidade)\b[^.;]*(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)',
        '(?i)(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)[^.;]*\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:inspecionar o repo|ler arquivos?|inspecionar o reposit[o\u00f3]rio|read files?)\b[^.;]*(?:sem depend[e\u00ea]ncia material|incondicionalmente|sempre|sem necessidade)',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:criar metadados|gravar metadados|criar estado local|mutar workspace|create metadata|create state)\b[^.;]*(?:ao ler|em leitura|em ALINHAMENTO|no ALINHAMENTO|under ALINHAMENTO)',
        '(?i)(?:ao ler|em leitura|em ALINHAMENTO|no ALINHAMENTO|under ALINHAMENTO)[^.;]*\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:criar metadados|gravar metadados|criar estado local|mutar workspace|create metadata|create state)',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:ignorar o ledger|sem consumo|sem fechar subagentes?|manter subagentes? abertos?|ignorar fechamento|bypass ledger)\b[^.;]*(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)',
        '(?i)(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)[^.;]*\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:ignorar o ledger|sem consumo|sem fechar subagentes?|manter subagentes? abertos?|ignorar fechamento|bypass ledger)'
    )
    foreach ($pattern in $forbidden) {
        if ([regex]::IsMatch($agentsNorm, $pattern) -or [regex]::IsMatch($geminiNorm, $pattern) -or [regex]::IsMatch($skillNorm, $pattern) -or [regex]::IsMatch($delegationNorm, $pattern)) {
            throw "${pfx}contains forbidden ALINHAMENTO anti-pattern: $pattern"
        }
    }
}

function Assert-CriticalStrategyPolicy {
    param(
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$DelegationText,
        [Parameter(Mandatory)][string]$ReadmeText,
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $delegationNorm = [regex]::Replace($DelegationText, '\s+', ' ').Trim()
    $readmeNorm = [regex]::Replace($ReadmeText, '\s+', ' ').Trim()

    $agentsRequired = @(
        '(?i)subagent_strategy',
        '(?i)worker',
        '(?i)critical',
        '(?i)an[a\u00e1]lise independente',
        '(?i)adaptativa por profundidade',
        '(?i)evid[e\u00ea]ncias',
        '(?i)contradi[c\u00e7][o\u00f5]es.{0,30}lacunas',
        '(?i)s[i\u00ed]ntese GPT',
        '(?i)sem troca autom[a\u00e1]tica de rota|sem troca autom[a\u00e1]tica de provedor|sem fallback autom[a\u00e1]tico de rota',
        '(?i)sem edi[c\u00e7][a\u00e3]o concorrente',
        '(?i)estrat[e\u00e9]gia nunca concede escrita',
        '(?i)recibo',
        '(?i)evidence packet|pacote de evid[e\u00ea]ncia',
        '(?i)semantic progress|progresso sem[a\u00e1]ntico',
        '(?i)early-exit|sa[i\u00ed]da antecipada',
        '(?i)sem prometer capacidades que o bridge ainda n[a\u00e3]o exp[o\u00f5]e'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            throw "${pfx}codex AGENTS.md is missing required critical strategy pattern: $pattern"
        }
    }

    $geminiRequired = @(
        '(?i)critical',
        '(?i)an[a\u00e1]lise independente',
        '(?i)adaptativa por profundidade',
        '(?i)evid[e\u00ea]ncias',
        '(?i)contradi[c\u00e7][o\u00f5]es',
        '(?i)lacunas',
        '(?i)s[i\u00ed]ntese GPT',
        '(?i)sem edi[c\u00e7][a\u00e3]o concorrente',
        '(?i)sem troca autom[a\u00e1]tica de rota|sem troca autom[a\u00e1]tica de provedor',
        '(?i)estrat[e\u00e9]gia nunca concede escrita',
        '(?i)recibo',
        '(?i)evidence packet|pacote de evid[e\u00ea]ncia',
        '(?i)semantic progress|progresso sem[a\u00e1]ntico',
        '(?i)early-exit|sa[i\u00ed]da antecipada',
        '(?i)sem prometer capacidades que o bridge ainda n[a\u00e3]o exp[o\u00f5]e'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            throw "${pfx}antigravity GEMINI.md is missing required critical strategy pattern: $pattern"
        }
    }

    $skillRequired = @(
        '(?i)subagent_strategy',
        '(?i)worker',
        '(?i)critical',
        '(?i)an[a\u00e1]lise independente|independent analysis',
        '(?i)adaptativa por profundidade|adaptive.?by.?depth',
        '(?i)evid[e\u00ea]ncias|evidence',
        '(?i)contradi[c\u00e7][o\u00f5]es|contradictions',
        '(?i)lacunas|gaps',
        '(?i)s[i\u00ed]ntese GPT|GPT synthesis',
        '(?i)sem edi[c\u00e7][a\u00e3]o concorrente|no concurrent edit',
        '(?i)sem troca autom[a\u00e1]tica de rota|no automatic route|sem troca autom[a\u00e1]tica de provedor',
        '(?i)estrat[e\u00e9]gia nunca concede escrita|strategy never grants write',
        '(?i)recibo|receipt',
        '(?i)evidence packet',
        '(?i)semantic progress',
        '(?i)early-exit',
        '(?i)sem prometer capacidades que o bridge ainda n[a\u00e3]o exp[o\u00f5]e|capabilities that the bridge does not yet expose'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNorm, $pattern)) {
            throw "${pfx}skills/workflows/SKILL.md is missing required critical strategy pattern: $pattern"
        }
    }

    $delegationRequired = @(
        '(?i)subagent_strategy',
        '(?i)worker',
        '(?i)critical',
        '(?i)an[a\u00e1]lise independente|independent analysis',
        '(?i)adaptativa por profundidade|adaptive.?by.?depth',
        '(?i)contradi[c\u00e7][o\u00f5]es|contradictions',
        '(?i)lacunas|gaps',
        '(?i)s[i\u00ed]ntese GPT|GPT synthesis',
        '(?i)sem edi[c\u00e7][a\u00e3]o concorrente|no concurrent edit',
        '(?i)sem troca autom[a\u00e1]tica de rota|sem troca autom[a\u00e1]tica de provedor|no automatic route',
        '(?i)estrat[e\u00e9]gia nunca concede escrita|strategy never grants write',
        '(?i)recibo|receipt',
        '(?i)evidence packet',
        '(?i)semantic progress',
        '(?i)early-exit',
        '(?i)sem prometer capacidades que o bridge ainda n[a\u00e3]o exp[o\u00f5]e|capabilities that the bridge does not yet expose'
    )
    foreach ($pattern in $delegationRequired) {
        if (-not [regex]::IsMatch($delegationNorm, $pattern)) {
            throw "${pfx}skills/workflows/references/delegation.md is missing required critical strategy pattern: $pattern"
        }
    }

    $readmeRequired = @(
        '(?i)subagent_strategy',
        '(?i)worker',
        '(?i)critical',
        '(?i)adaptativa por profundidade|adaptive.?by.?depth'
    )
    foreach ($pattern in $readmeRequired) {
        if (-not [regex]::IsMatch($readmeNorm, $pattern)) {
            throw "${pfx}README.md is missing required critical strategy pattern: $pattern"
        }
    }

    $forbidden = @(
        '(?i)\b(?:estrat[e\u00e9]gia|critical)\b[^.;]*\b(?:concede|autoriza|permite|grants?)\b[^.;]*\bescrita\b[^.;]*(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)',
        '(?i)(?:no ALINHAMENTO|em ALINHAMENTO|under ALINHAMENTO)[^.;]*\b(?:estrat[e\u00e9]gia|critical)\b[^.;]*\b(?:concede|autoriza|permite|grants?)\b[^.;]*\bescrita',
        '(?i)\b(?:permite|autoriza|allows?)\b[^.;]*\bedi[c\u00e7][a\u00e3]o concorrente\b',
        '(?i)subagent_strategy\s*=\s*adaptive',
        '(?i)\bsubagent_strategy\b[^.;]*\badaptive\b[^.;]*(?:p[u\u00fa]blica|public|flag)',
        '(?i)worker\s*\|\s*critical\s*\|\s*adaptive',
        '(?i)\b(?:critical|estrat[e\u00e9]gia)\b[^.;]*\b(?:pode|autoriza|permite)\b[^.;]*(?:trocar de rota|trocar de provedor|fallback autom[a\u00e1]tico)\b',
        '(?i)\b(?:bridge|subagents?)\b[^.;]*\b(?:exp[o\u00f5]e|promete|suporta)\b[^.;]*(?:websocket|streaming push|push notifications?)\b'
    )
    foreach ($pattern in $forbidden) {
        if ([regex]::IsMatch($agentsNorm, $pattern) -or [regex]::IsMatch($geminiNorm, $pattern) -or [regex]::IsMatch($skillNorm, $pattern) -or [regex]::IsMatch($delegationNorm, $pattern)) {
            throw "${pfx}contains forbidden critical strategy anti-pattern: $pattern"
        }
    }
}

function Assert-SubagentAutonomyPolicy {
    param(
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$DelegationText,
        [Parameter(Mandatory)][string]$DeliveryReviewText,
        [Parameter(Mandatory)][string]$ReadmeText,
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $delegationNorm = [regex]::Replace($DelegationText, '\s+', ' ').Trim()
    $deliveryNorm = [regex]::Replace($DeliveryReviewText, '\s+', ' ').Trim()
    $readmeNorm = [regex]::Replace($ReadmeText, '\s+', ' ').Trim()

    # 1. Delegation reference checks
    $delegationRequired = @(
        '(?i)subagent_continuation',
        '(?i)active_follow',
        '(?i)park_and_wake',
        '(?i)active_follow.*(?:[u\u00fa]nico modo|only mode).*(?:espera dentro da run|waits inside)',
        '(?i)park_and_wake.*(?:retorna imediatamente|returns immediately).*(?:ParkReceipt).*(?:encerra|ends).*(?:SUSPENDED)',
        '(?i)(?:lan[c\u00e7]ar em lote|despach|dispatch|dren|drain).*(?:trabalho local [u\u00fa]til|useful local (?:work|action))',
        '(?i)(?:predicados?.*(?:ANY|ALL|QUORUM|REQUIRED)|ANY,\s*ALL,\s*QUORUM(?:\(k\))?,\s*REQUIRED)',
        '(?i)(?:1\s*<=\s*k\s*<=|subconjunto n[a\u00e3]o vazio|non-empty subset)',
        '(?i)(?:mensagem vis[i\u00ed]vel de suspens[a\u00e3]o|user-visible suspension message).*(?:condi[c\u00e7][a\u00e3]o|condition)',
        '(?i)(?:uma (?:[u\u00fa]nica )?retomada por gera[c\u00e7][a\u00e3]o|one wake per (?:barrier )?generation|coalesc)',
        '(?i)(?:nova run|new run).*(?:CLI|Desktop Codex CLI).*(?:mesma task|exact same task)',
        '(?i)(?:active writer|deferred_active_writer).*(?:durable deferred|entrega diferida|diferida dur[a\u00e1]vel)',
        '(?i)(?:proibid[oa]|nunca|never).*(?:auto-archive|auto-unload|arquivar|descarregar)',
        '(?i)(?:encerrar o turno|end(?:s)? (?:its )?turn|end turn).*(?:obriga[c\u00e7][\u00f5o]es pendentes|open obligations).*(?:exclusivamente|only).*(?:SUSPENDED|ParkReceipt|externally armed)',
        '(?i)(?:deliveryMode\s*=\s*none|unarmed).*(?:permanecer ativ[oa]|remain active)',
        '(?i)(?:ap[o\u00f3]s acordar|after wake|ao acordar).*(?:subagents_follow).*(?:consumir apenas|consume only|consumir os jobs listados|consume listed jobs)',
        '(?i)(?:metadados confi[a\u00e1]veis|trusted metadata).*(?:nunca texto|never worker result text|sem texto de subagente)',
        '(?i)(?:goal|meta).*(?:separad[oa]|separate ownership)',
        '(?i)(?:DONE.*proibid[oa]|DONE.*forbidden|resposta final DONE)'
    )
    foreach ($pattern in $delegationRequired) {
        if (-not [regex]::IsMatch($delegationNorm, $pattern)) {
            throw "${pfx}skills/workflows/references/delegation.md is missing required subagent autonomy pattern: $pattern"
        }
    }

    # 2. SKILL.md checks
    $skillRequired = @(
        '(?i)subagent_continuation',
        '(?i)active_follow',
        '(?i)park_and_wake',
        '(?i)active_follow.*(?:only mode|[u\u00fa]nico modo).*(?:waits inside|espera dentro da run)',
        '(?i)park_and_wake.*(?:returns immediately|retorna imediatamente).*(?:ParkReceipt).*(?:SUSPENDED)',
        '(?i)(?:dispatch|drain|dren|despach).*(?:useful local work|trabalho local [u\u00fa]til)',
        '(?i)(?:ANY,\s*ALL,\s*QUORUM|predicates?.*ANY.*ALL.*QUORUM.*REQUIRED)',
        '(?i)(?:user-visible suspension message|mensagem vis[i\u00ed]vel de suspens[a\u00e3]o).*(?:condition|condi[c\u00e7][a\u00e3]o)',
        '(?i)(?:new run via CLI|nova run via CLI|compatible CLI).*(?:same task|mesma task)',
        '(?i)(?:active writer|deferred_active_writer).*(?:durable deferred|entrega diferida|deferred delivery)',
        '(?i)(?:proibid[oa]|never|nunca).*(?:auto-archive|auto-unload|arquivar|descarregar)',
        '(?i)(?:encerrar o turno|end(?:s)? (?:its )?turn|end turn).*(?:SUSPENDED|ParkReceipt|externally armed)',
        '(?i)(?:deliveryMode\s*=\s*none|unarmed).*(?:remain active|permanecer ativ[oa])',
        '(?i)(?:after wake|ao acordar|ap[o\u00f3]s wake).*(?:subagents_follow)',
        '(?i)(?:trusted metadata|metadados confi[a\u00e1]veis).*(?:never worker result text|sem texto de subagente|no synthetic user text)',
        '(?i)(?:goal|meta).*(?:separate|separad[oa])',
        '(?i)DONE.*(?:forbidden|proibid[oa]|strictly impossible)'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNorm, $pattern)) {
            throw "${pfx}skills/workflows/SKILL.md is missing required subagent autonomy pattern: $pattern"
        }
    }

    # 3. AGENTS.md checks
    $agentsRequired = @(
        '(?i)subagent_continuation',
        '(?i)active_follow',
        '(?i)park_and_wake',
        '(?i)active_follow.*(?:[u\u00fa]nico modo|espera dentro da run)',
        '(?i)park_and_wake.*(?:retorna imediatamente|ParkReceipt).*(?:SUSPENDED)',
        '(?i)(?:despach|dren).*(?:trabalho local [u\u00fa]til)',
        '(?i)(?:ANY,\s*ALL,\s*QUORUM|predicados?.*ANY.*ALL.*QUORUM.*REQUIRED)',
        '(?i)(?:mensagem vis[i\u00ed]vel de suspens[a\u00e3]o).*(?:condi[c\u00e7][a\u00e3]o)',
        '(?i)(?:nova run|retomada externa).*(?:CLI)',
        '(?i)(?:active writer|deferred_active_writer).*(?:entrega diferida dur[a\u00e1]vel|durable deferred)',
        '(?i)(?:proibid[oa]|nunca).*(?:arquivar|descarregar|auto-archive|auto-unload)',
        '(?i)(?:encerrar o turno|obriga[c\u00e7][\u00f5o]es pendentes).*(?:SUSPENDED|ParkReceipt|externally armed)',
        '(?i)(?:deliveryMode\s*=\s*none|unarmed).*(?:permanecer ativ[oa]|remain active)',
        '(?i)(?:subagents_follow)',
        '(?i)(?:metadados confi[a\u00e1]veis|trusted metadata).*(?:nunca texto|sem texto de subagente)',
        '(?i)(?:goal|meta).*(?:separad[oa]|separate)',
        '(?i)DONE.*(?:proibid[oa]|estritamente proibida)'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            throw "${pfx}codex AGENTS.md is missing required subagent autonomy pattern: $pattern"
        }
    }

    # 4. GEMINI.md checks
    $geminiRequired = @(
        '(?i)subagent_continuation',
        '(?i)active_follow',
        '(?i)park_and_wake',
        '(?i)active_follow.*(?:[u\u00fa]nico modo|espera dentro da run)',
        '(?i)park_and_wake.*(?:retorna imediatamente|ParkReceipt).*(?:SUSPENDED)',
        '(?i)(?:despach|dren).*(?:trabalho local [u\u00fa]til)',
        '(?i)(?:ANY,\s*ALL,\s*QUORUM|predicados?.*ANY.*ALL.*QUORUM.*REQUIRED)',
        '(?i)(?:mensagem vis[i\u00ed]vel de suspens[a\u00e3]o).*(?:condi[c\u00e7][a\u00e3]o)',
        '(?i)(?:nova run|retomada externa).*(?:CLI)',
        '(?i)(?:active writer|deferred_active_writer).*(?:entrega diferida dur[a\u00e1]vel|durable deferred)',
        '(?i)(?:proibid[oa]|nunca).*(?:arquivar|descarregar|auto-archive|auto-unload)',
        '(?i)(?:encerrar o turno|obriga[c\u00e7][\u00f5o]es pendentes).*(?:SUSPENDED|ParkReceipt|externally armed)',
        '(?i)(?:deliveryMode\s*=\s*none|unarmed).*(?:permanecer ativ[oa]|remain active)',
        '(?i)(?:subagents_follow)',
        '(?i)(?:metadados confi[a\u00e1]veis|trusted metadata).*(?:nunca texto|sem texto de subagente)',
        '(?i)(?:goal|meta).*(?:separad[oa]|separate)',
        '(?i)DONE.*(?:proibid[oa]|estritamente proibida)'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            throw "${pfx}antigravity GEMINI.md is missing required subagent autonomy pattern: $pattern"
        }
    }

    # 5. Delivery Review reference checks
    if (-not [regex]::IsMatch($deliveryNorm, '(?i)park_and_wake.*SUSPENDED.*ParkReceipt.*subagents_follow')) {
        throw "${pfx}skills/workflows/references/delivery-review.md is missing required park_and_wake SUSPENDED pattern"
    }

    # 6. Readme checks
    $readmeRequired = @(
        '(?i)subagent_continuation',
        '(?i)active_follow',
        '(?i)park_and_wake',
        '(?i)(?:active_follow.*(?:espera dentro da run|s[i\u00ed]ncrono))',
        '(?i)(?:park_and_wake.*(?:retorna imediatamente|SUSPENDED|nova run via CLI))',
        '(?i)(?:active writer|deferred_active_writer)'
    )
    foreach ($pattern in $readmeRequired) {
        if (-not [regex]::IsMatch($readmeNorm, $pattern)) {
            throw "${pfx}README.md is missing required subagent autonomy pattern: $pattern"
        }
    }

    # 7. Forbiddens / Anti-patterns
    $forbidden = @(
        '(?i)\bpark_and_wake\b[^.;]*(?:espera dentro da run|wait[s]? inside (?:the )?run|espera no turno|wait[s]? in-turn|aguarda no mesmo turno|open park tool call|task carregada[^.;]*suspende a infer[e\u00ea]ncia[^.;]*mesmo turno)',
        '(?i)\b(?:sem emitir mensagem|mensagem de suspens[a\u00e3]o [e\u00e9] opcional|suspension message is optional|encerra(?:r)? silenciosamente)\b[^.;]*(?:suspens|SUSPENDED)',
        '(?i)(?<!sem\s|proibid[oa]\s|proibida\s|estritamente proibida\s|never\s|without\s|zero\s)\b(?:wake\s+parcial|retomada\s+parcial|premature\s+(?:partial\s+)?wake|wake\s+prematur[oa])\b[^.;]*(?:antes|before).*(?:predicado|predicate|satisfeit[oa]|satisfied)',
        '(?i)\b(?:aceita|permite|allows?)\b[^.;]*(?:quorum|QUORUM)\b[^.;]*(?:inv[a\u00e1]lido|invalid|k\s*>\s*total|k\s*<\s*1)|(?i)\b(?:aceita|permite|allows?)\b[^.;]*(?:REQUIRED|required)\b[^.;]*(?:vazio|empty|fora dos jobs|n[a\u00e3]o estacionados)',
        '(?i)\b(?:m[u\u00fa]ltiplos wakes|duplicate wake|duplicar retomada)\b[^.;]*(?:mesma gera[c\u00e7][a\u00e3]o|same generation)',
        '(?i)\b(?:pode|autoriza|permite)\b[^.;]*(?:polling|loop de status)\b[^.;]*(?:estacionado|parked|aguarda)',
        '(?i)\b(?:active writer|active_writer)\b[^.;]*(?:autoriza|permite|pode)\b[^.;]*(?:arquivar|descarregar|archive|unload)',
        '(?i)\bbridge\b[^.;]*(?:injeta|injects?)\b[^.;]*(?:texto de resposta|texto do worker|worker text|synthetic user)',
        '(?i)\b(?:pode|autoriza|permite)\b[^.;]*(?:encerrar o turno|end turn)\b[^.;]*(?:sem recibo armado|deliveryMode\s*=\s*none|unarmed)',
        '(?i)(?<!nunca\s|jamais\s|n[a\u00e3]o\s|sem\s)\b(?:retoma|retomar)\s+automaticamente\b[^.;]*(?:goal pausado|paused goal)|(?<!never\s|without\s)\b(?:automatically\s+resumes?|auto-resumes?)\b[^.;]*(?:paused goal)',
        '(?i)(?<!sem\s|without\s|zero\s|proibid[oa]\s)(?:fallback silencioso|silent fallback).{0,40}(?:active_follow)'
    )
    foreach ($pattern in $forbidden) {
        if ([regex]::IsMatch($delegationNorm, $pattern) -or [regex]::IsMatch($skillNorm, $pattern) -or [regex]::IsMatch($agentsNorm, $pattern) -or [regex]::IsMatch($geminiNorm, $pattern)) {
            throw "${pfx}contains forbidden subagent autonomy anti-pattern: $pattern"
        }
    }
}

function Assert-AdaptiveSwarmPolicy {
    param(
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$DelegationText,
        [Parameter(Mandatory)][string]$ReadmeText,
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $delegationNorm = [regex]::Replace($DelegationText, '\s+', ' ').Trim()
    $readmeNorm = [regex]::Replace($ReadmeText, '\s+', ' ').Trim()

    # 1. Delegation reference checks
    $delegationRequired = @(
        '(?i)delegation_policy.*swarm',
        '(?i)GPT parent [e\u00e9] o [u\u00fa]nico orquestrador,\s*decisor,\s*integrador\s+e\s+gatekeeper|sole orchestrator,\s*decider,\s*integrator,\s*and\s*gatekeeper',
        '(?i)ondas do DAG|DAG waves',
        '(?i)pulveriza apenas fatias materialmente independentes|pulverizes only materially independent',
        '(?i)trabalho coeso(?:/|\s+e\s+)sequencial fica na mesma trilha|cohesive/sequential work stays on the same track',
        '(?i)fan-out l[o\u00f3]gico el[a\u00e1]stico|elastic logical fan-out',
        '(?i)sem m[i\u00ed]nimo(?:/|\s+nem\s+)m[a\u00e1]ximo de agentes na pol[i\u00ed]tica|no min/max agents in policy',
        '(?i)custo,\s*depend[e\u00ea]ncias,\s*exclusividade de recursos,\s*risco de integra[c\u00e7][a\u00e3]o\s+e\s+lat[e\u00ea]ncia',
        '(?i)readers podem fan-out|readers can fan out',
        '(?i)writers (?:s[o\u00f3]|apenas) com ownership disjunto(?:/|,\s*)worktrees(?:/|,\s*|\s+ou\s+)recursos exclusivos',
        '(?i)backpressure (?:e|\/) cr[e\u00e9]ditos f[i\u00ed]sicos pertencem ao bridge|backpressure/credits belong to bridge',
        '(?i)preflight swarm exige capability do batch scheduler|batch scheduler capability|preflight swarm operacionalmente inequ[i\u00ed]voco',
        '(?i)falha fechado se ausente|fails closed if absent|falha fechada',
        '(?i)(?:jamais|nunca|sem).{0,40}(?:rebaixa|fallback).{0,40}aggressive',
        '(?i)native.*respeita capacidade exposta|native.*respects exposed capacity',
        '(?i)REQUIRED.*QUORUM.*ALL.*ANY',
        '(?i)jobs que n[a\u00e3]o acordam continuam obriga[c\u00e7][o\u00f5]es|unawakened jobs remain obligations',
        '(?i)rollback seguro.*antes de instalar/downgrade.*trocar explicitamente para aggressive|safe rollback.*explicitly switch to aggressive',
        '(?i)n[a\u00e3]o aumente schemaVersion|no schemaVersion bump',
        '(?i)subagents_spawn_batch.*(?:tool can[o\u00f4]nica|canonical.*swarm|ondas do DAG)',
        '(?i)deepseek_spawn_batch',
        '(?i)spawn unit[a\u00e1]rio.*(?:fora de ondas|uma [u\u00fa]nica frente)|unitary.*outside waves',
        '(?i)subagents_spawn_batch.*(?:callable|invoc[a\u00e1]vel)',
        '(?i)(?:superf[i\u00ed]cie autoritativa de status/health|status/health).*batch_scheduler|batch_scheduler.*(?:superf[i\u00ed]cie autoritativa|status/health)',
        '(?i)helper PowerShell isolado.*(?:n[a\u00e3]o|alone).*prov.*daemon',
        '(?i)(?:estreitamento|exce[c\u00e7][a\u00e3]o).{0,250}balanced.{0,30}aggressive.{0,30}swarm',
        '(?i)pulveriza todas as fatias ready e independentes [u\u00fa]teis para menor wall-clock|pulverizes all ready and useful independent slices',
        '(?i)sem n[u\u00fa]mero fixo|no fixed number',
        '(?i)(?:remo[c\u00e7][a\u00e3]o de timeout r[i\u00ed]gido|remove rigid completion timeout|sem timeout r[i\u00ed]gido)',
        '(?i)job aceito e saud[a\u00e1]vel pode rodar indefinidamente|accepted and healthy jobs? (?:can )?run indefinitely',
        '(?i)nenhuma janela de 900s(?:[,\/]\s*|\s+ou\s+)20m(?:[,\/]\s*|\s+ou\s+)25m prova falha|no (?:900s|20m|25m|900s\/20m\/25m) window proves failure',
        '(?i)(?:graceful finalize|abort)',
        '(?i)sem deadline de modelo|no model deadline',
        '(?i)lease expirada sozinha n[a\u00e3]o prova morte|expired lease alone does not prove death',
        '(?i)(?:takeover|terminaliza[c\u00e7][a\u00e3]o).*(?:PID|heartbeat|fence|quiesc[e\u00ea]ncia)',
        '(?i)timeouts bounded de transporte,\s*handshake,\s*health\s+e\s+connect|bounded transport,\s*handshake,\s*health,\s*and\s*connect timeouts',
        '(?i)(?:diferenci(?:ad[oa]s|e-os)\s+explicitamente|explicitamente\s+diferenci(?:ad[oa]s|e-os))\s+do\s+execution\s+timeout|explicitly differentiat(?:ed)? from execution timeout',
        '(?i)(?:maximizar|maximize)\s+(?:o\s+)?(?:paralelismo [u\u00fa]til|useful parallelism)\b[^.;\r\n]*(?:sharding|estilha[c\u00e7]a|pulveriz).*(?:tarefas.*(?:fases|testes|revis)|tasks AND phases/tests/reviews)',
        '(?i)agentes\s+(?:s[a\u00e3]o\s+)?tratados como efetivamente gratuitos|agents are treated as effectively free',
        '(?i)(?:n[a\u00e3]o\s+(?:economiz[a-z]*|conserve\s+contagem\s+de\s+agentes)|do not conserve agent count)',
        '(?i)fan-out l[o\u00f3]gico\s+(?:n[a\u00e3]o\s+tem|sem)\s+(?:m[i\u00ed]nimo,\s*m[a\u00e1]ximo\s+nem\s+faixa|min/max/range)|logical fanout has no fixed min/max/range',
        '(?i)(?:dispara[r]?|lan[c\u00e7]a[r]?|spawn)\s+todas as frentes prontas e independentes em (?:uma\s+)?onda antes de esperar|spawn all ready independent fronts in a wave before waiting',
        '(?i)(?:precis[a\u00e3]o|precision).*(?:atomic ownership|propriedade at[o\u00f4]mica).*(?:restri[c\u00e7][o\u00f5]es.*depend[e\u00ea]ncia|dependency/resource constraints).*(?:s[i\u00ed]ntese exclusiva.*GPT|GPT-only synthesis).*(?:valida[c\u00e7][a\u00e3]o.*revis[a\u00e3]o|validation and independent review)',
        '(?i)(?:n[a\u00e3]o\s+dispara[r]?|proibid[oa]\s+disparar|do not spawn)\s+(?:trabalho duplicado|duplicate.*work).*(?:n[a\u00e3]o-acion[a\u00e1]vel|non-actionable)',
        '(?i)(?:n[a\u00e3]o\s+paralelizar|proibid[oa]\s+paralelizar|do not parallelize)\s+(?:depend[e\u00ea]ncias verdadeiras|depend[e\u00ea]ncias causais|true dependencies)',
        '(?i)(?:n[a\u00e3]o\s+(?:autorizar|permitir|realizar)|proibid[oa]\s+(?:permitir|autorizar|realizar)?|do not parallelize)\s+(?:escritas concorrentes|concurrent writes).*(?:mesm[oa] (?:propriedade|ownership|arquivo)|same ownership)'
    )
    foreach ($pattern in $delegationRequired) {
        if (-not [regex]::IsMatch($delegationNorm, $pattern)) {
            throw "${pfx}skills/workflows/references/delegation.md is missing required adaptive swarm pattern: $pattern"
        }
    }

    # 2. SKILL.md checks
    $skillRequired = @(
        '(?i)swarm',
        '(?i)ondas do DAG|DAG waves',
        '(?i)fan-out l[o\u00f3]gico el[a\u00e1]stico|elastic logical fan-out',
        '(?i)batch scheduler',
        '(?i)falha fechado se ausente|fails closed if absent',
        '(?i)REQUIRED.*QUORUM.*ALL.*ANY',
        '(?i)subagents_spawn_batch',
        '(?i)deepseek_spawn_batch',
        '(?i)subagents_spawn_batch.*callable|callable.*subagents_spawn_batch',
        '(?i)pulverizes all ready and useful independent slices|pulveriza todas as fatias ready e independentes',
        '(?i)sem n[u\u00fa]mero fixo|no fixed number',
        '(?i)remo[c\u00e7][a\u00e3]o de timeout r[i\u00ed]gido|accepted and healthy jobs can run indefinitely',
        '(?i)nenhuma janela de 900s(?:/|,|\s+ou\s+)20m(?:/|,|\s+ou\s+)25m prova falha|no 900s/20m/25m window proves failure',
        '(?i)lease expirada sozinha n[a\u00e3]o prova morte',
        '(?i)diferenciando-se explicitamente do execution timeout|explicitly differentiated from execution timeout',
        '(?i)sharding tasks AND phases/tests/reviews|tarefas quanto fases,\s*testes e revis[o\u00f5]es',
        '(?i)agents are treated as effectively free|agentes tratados como efetivamente gratuitos',
        '(?i)do not conserve agent count|n[a\u00e3]o conservar contagem de agentes',
        '(?i)logical fan-out has no fixed min/max/range|fan-out l[o\u00f3]gico sem m[i\u00ed]nimo,\s*m[a\u00e1]ximo nem faixa fixa',
        '(?i)spawn all ready independent fronts in a wave before waiting|dispara todas as frentes prontas e independentes em uma onda antes de esperar',
        '(?i)atomic ownership.*GPT-only synthesis|propriedade at[o\u00f4]mica.*s[i\u00ed]ntese exclusiva GPT-only',
        '(?i)do not spawn duplicate/non-actionable work|sem trabalho duplicado/n[a\u00e3]o-acion[a\u00e1]vel',
        '(?i)do not parallelize true dependencies|sem paralelizar depend[e\u00ea]ncias verdadeiras',
        '(?i)do not parallelize concurrent writes to same ownership|sem escritas concorrentes sob o mesmo ownership'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNorm, $pattern)) {
            throw "${pfx}skills/workflows/SKILL.md is missing required adaptive swarm pattern: $pattern"
        }
    }

    # 3. AGENTS.md checks
    $agentsRequired = @(
        '(?i)delegation_policy.*swarm',
        '(?i)ondas do DAG',
        '(?i)fan-out l[o\u00f3]gico el[a\u00e1]stico',
        '(?i)batch scheduler',
        '(?i)falha fechado se ausente|falha fechado bloqueando',
        '(?i)REQUIRED.*QUORUM.*ALL.*ANY',
        '(?i)subagents_spawn_batch',
        '(?i)deepseek_spawn_batch',
        '(?i)subagents_spawn_batch.*callable|callable.*subagents_spawn_batch',
        '(?i)status/health.*batch_scheduler',
        '(?i)pulveriza todas as fatias ready e independentes [u\u00fa]teis para menor wall-clock',
        '(?i)sem n[u\u00fa]mero fixo',
        '(?i)remo[c\u00e7][a\u00e3]o de timeout r[i\u00ed]gido de conclus[a\u00e3]o',
        '(?i)job aceito e saud[a\u00e1]vel pode rodar indefinidamente',
        '(?i)nenhuma janela de 900s/20m/25m prova falha ou dispara graceful finalize/abort',
        '(?i)lease expirada sozinha n[a\u00e3]o prova morte',
        '(?i)diferenciando-os explicitamente do execution timeout',
        '(?i)sharding tasks AND phases/tests/reviews|tanto tarefas quanto fases,\s*testes e revis[o\u00f5]es',
        '(?i)agentes s[a\u00e3]o tratados como efetivamente gratuitos|agents are treated as effectively free',
        '(?i)n[a\u00e3]o conserva contagem de agentes|do not conserve agent count',
        '(?i)sem m[i\u00ed]nimo,\s*m[a\u00e1]ximo nem faixa/range fixo|logical fanout has no fixed min/max/range',
        '(?i)dispara todas as frentes prontas e independentes em uma onda antes de esperar|spawn all ready independent fronts in a wave before waiting',
        '(?i)atomic ownership.*s[i\u00ed]ntese exclusiva GPT-only|atomic ownership.*GPT-only synthesis',
        '(?i)n[a\u00e3]o dispara trabalho duplicado|do not spawn duplicate/non-actionable work',
        '(?i)n[a\u00e3]o paraleliza depend[e\u00ea]ncias verdadeiras|do not parallelize true dependencies',
        '(?i)n[a\u00e3]o permite escritas concorrentes na mesma propriedade/ownership|do not parallelize concurrent writes to same ownership'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            throw "${pfx}codex AGENTS.md is missing required adaptive swarm pattern: $pattern"
        }
    }

    # 4. GEMINI.md checks
    $geminiRequired = @(
        '(?i)swarm',
        '(?i)ondas do DAG',
        '(?i)batch scheduler',
        '(?i)pulveriza todas as fatias ready e independentes [u\u00fa]teis para menor wall-clock',
        '(?i)sem n[u\u00fa]mero fixo',
        '(?i)remo[c\u00e7][a\u00e3]o de timeout r[i\u00ed]gido de conclus[a\u00e3]o',
        '(?i)job aceito e saud[a\u00e1]vel pode rodar indefinidamente',
        '(?i)nenhuma janela de 900s/20m/25m prova falha ou dispara graceful finalize/abort',
        '(?i)lease expirada sozinha n[a\u00e3]o prova morte',
        '(?i)diferenciando-os explicitamente do execution timeout',
        '(?i)tarefas E fases/testes/revis[o\u00f5]es|tarefas quanto fases,\s*testes e revis[o\u00f5]es',
        '(?i)efetivamente gratuitos sem conservar contagem|agents are treated as effectively free',
        '(?i)dispara todas as frentes prontas e independentes em onda antes de esperar|spawn all ready independent fronts in a wave before waiting',
        '(?i)pro[i\u00ed]be trabalho duplicado/n[a\u00e3]o-acion[a\u00e1]vel|proibido disparar trabalho duplicado',
        '(?i)pro[i\u00ed]be paralelizar depend[e\u00ea]ncias verdadeiras|proibido paralelizar depend[e\u00ea]ncias verdadeiras',
        '(?i)pro[i\u00ed]be escritas concorrentes sob mesmo ownership|proibido escritas concorrentes sob mesmo ownership'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            throw "${pfx}antigravity GEMINI.md is missing required adaptive swarm pattern: $pattern"
        }
    }

    # 5. README.md checks
    $readmeRequired = @(
        '(?i)delegation_policy.*swarm',
        '(?i)switch-subagent-policy\.ps1 -Policy swarm',
        '(?i)\^Numpad6',
        '(?i)`?delegation_policy`?\s*\(`balanced`\s*\|\s*`aggressive`\s*\|\s*`swarm`\)',
        '(?i)equil[i\u00ed]brio operacional.*(?:balanced|aggressive|swarm).*(?:ondas do DAG|pulveriza[c\u00e7][a\u00e3]o|swarm)',
        '(?i)pulveriza[c\u00e7][a\u00e3]o din[a\u00e2]mica em ondas do DAG de todas as fatias ready e independentes [u\u00fa]teis para menor wall-clock',
        '(?i)sem n[u\u00fa]mero fixo de agentes',
        '(?i)remove-se o timeout r[i\u00ed]gido de conclus[a\u00e3]o',
        '(?i)nenhuma janela de 900s/20m/25m prova falha ou dispara graceful finalize/abort',
        '(?i)lease expirada sozinha n[a\u00e3]o prova morte',
        '(?i)diferenciados do execution timeout',
        '(?i)sharding tasks AND phases/tests/reviews|estilha[c\u00e7]amento de tarefas E fases/testes/revis[o\u00f5]es',
        '(?i)efetivamente gratuitos sem conservar contagem|agents are treated as effectively free',
        '(?i)disparando todas as frentes prontas e independentes em onda antes de esperar|disparando ondas antes de esperar',
        '(?i)proibindo trabalho duplicado/n[a\u00e3]o-acion[a\u00e1]vel|sem trabalho duplicado',
        '(?i)proibindo paralelizar depend[e\u00ea]ncias verdadeiras|proibindo paralelizar depend[e\u00ea]ncias',
        '(?i)proibindo escritas concorrentes sob o mesmo ownership|escritas concorrentes no mesmo ownership'
    )
    foreach ($pattern in $readmeRequired) {
        if (-not [regex]::IsMatch($readmeNorm, $pattern)) {
            throw "${pfx}README.md is missing required adaptive swarm pattern: $pattern"
        }
    }

    # 6. Forbiddens / Anti-patterns
    $forbidden = @(
        '(?i)\b(?:pool fixo|fixed pool|m[i\u00ed]nimo de \d+|m[a\u00e1]ximo de \d+)\b[^.;]*(?:agentes|workers|subagents)',
        '(?i)(?<!jamais\s|nunca\s|sem\s|proibid[oa]\s)\b(?:rebaixa|rebaixar|fallback)\s+silencioso\s+para\s+aggressive\b',
        '(?i)\bwriters\b[^.;]*(?:concorrente|mesmo arquivo|shared files)[^.;]*(?:sem worktree|sem exclusividade)',
        '(?i)\b(?:subagente|worker)\b[^.;]*(?:faz o commit|decide aprova[c\u00e7][a\u00e3]o|dispensa o parent)',
        '(?i)\$workflows mode=SWARM\b',
        '(?i)\b(?:downgrade|vers[a\u00e3]o legada)\b[^.;]*(?:suporta swarm diretamente|sem trocar para aggressive)',
        '(?i)(?<!nenhum[a-z]*\s+(?:janela\s+de\s+)?[^.;\r\n]*)\b(?:900s|20m|25m)\b[^.;\r\n]*(?:prova falha|dispara graceful finalize|dispara abort|finaliza o job)',
        '(?i)\blease expirada\b[^.;]*(?:sozinha prova morte|autoriza takeover sem checar PID)',
        '(?i)\b(?:timeout r[i\u00ed]gido de conclus[a\u00e3]o|rigid completion timeout)\b\s+(?:de \d+|obrigat[o\u00f3]rio)',
        '(?i)\b(?:economizar agentes|conservar contagem de agentes|conserve agent count)\b[^.;]*(?:mesmo com|mesmo havendo|quando houver|artificialmente|por parcim[o\u00f4]nia)',
        '(?i)(?<!(?:n[a\u00e3]o|sem|nunca|jamais|proibid[oa]|never|do not)\s+)\b(?:pode|deve|autoriza|permite|allows?|is allowed to)\s+(?:disparar|criar|spawn)\s+(?:trabalho duplicado|tarefas duplicadas|duplicate work|non-actionable work|trabalho n[a\u00e3]o-acion[a\u00e1]vel)\b',
        '(?i)(?<!(?:n[a\u00e3]o|sem|nunca|jamais|proibid[oa]|never|do not)\s+)\b(?:pode|deve|autoriza|permite|allows?|is allowed to)\s+(?:paraleliz(?:ar|e)|iniciar juntos?|run in parallel)[^.;\r\n]*(?:depend[e\u00ea]ncias verdadeiras|depend[e\u00ea]ncias reais|true dependencies)\b',
        '(?i)(?<!(?:n[a\u00e3]o|sem|nunca|jamais|proibid[oa]|never|do not)\s+)\b(?:pode|deve|autoriza|permite|allows?|is allowed to)\s+(?:escritas concorrentes|concurrent writes)[^.;\r\n]*(?:mesm[oa] (?:ownership|propriedade|arquivo)|same ownership)\b'
    )
    foreach ($pattern in $forbidden) {
        if ([regex]::IsMatch($delegationNorm, $pattern) -or [regex]::IsMatch($skillNorm, $pattern) -or [regex]::IsMatch($agentsNorm, $pattern) -or [regex]::IsMatch($geminiNorm, $pattern) -or [regex]::IsMatch($readmeNorm, $pattern)) {
            throw "${pfx}contains forbidden adaptive swarm anti-pattern: $pattern"
        }
    }
}

function Assert-DelegationContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)subagent_backend',
        '(?i)delegation_policy',
        '(?i)balanced',
        '(?i)aggressive',
        '(?i)swarm',
        '(?i)ondas do DAG|DAG waves',
        '(?i)fan-out l[o\u00f3]gico el[a\u00e1]stico|elastic logical fan-out',
        '(?i)batch scheduler',
        '(?i)wall-clock|wall time',
        '(?i)token offload|desonera[c\u00e7][a\u00e3]o de tokens',
        '(?i)(?:subagents_continue|deepseek_continue)',
        '(?i)allow_respawn\s*=\s*true',
        '(?i)terminal result|resultado terminal',
        '(?i)aggressive.{0,80}(?:parent|orquestrador).{0,60}(?:arquiteto|decisor|integrador|gatekeeper|architect|decider|integrator|gatekeeper)',
        '(?i)pacote pequeno de evid[e\u00ea]ncia decis[o\u00f3]ria|decision evidence packet',
        '(?i)sem refazer bulk delegado|never redo delegated bulk|sem refazer trabalho delegado',
        '(?i)uma trilha persistente por frente coesa|trilha persistente por frente coesa|one persistent track per cohesive front',
        '(?i)sem microdelega[c\u00e7][a\u00e3]o|proibida microdelega[c\u00e7][a\u00e3]o|no microdelegation',
        '(?i)nova trilha apenas para deliverable independentemente aceit[a\u00e1]vel|new track only for independently acceptable deliverable',
        '(?i)instala[c\u00e7][a\u00e3]o global preserva/instala a flag selecionada como aggressive|global installation preserves/installs selected flag as aggressive',
        '(?i)n[a\u00e3]o injeta flags em repos consumidores|never inject flags into consumer repos|sem inje[c\u00e7][a\u00e3]o de flags em reposit[oó]rios consumidores',
        '(?i)sharding tasks AND phases/tests/reviews|estilha[c\u00e7]amento.*tarefas.*(?:fases|testes|revis)',
        '(?i)agents are treated as effectively free|agentes.*efetivamente gratuitos',
        '(?i)spawn all ready independent fronts in a wave before waiting|disparar todas as frentes prontas e independentes em (?:uma )?onda antes de esperar'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required delegation contract pattern: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)Review-And-Fix-Vigorously',
        '(?i)\b(?:not the repository workforce|n[a\u00e3]o a for[c\u00e7]a de trabalho)\b',
        '(?i)allow_respawn\s*=\s*true[^.;]*(?:rotineir|rotina|normalmente|routine|habitual)',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:refazer bulk|refazer trabalho delegado|redo delegated bulk)\b',
        '(?i)\b(?:pode|deve|autorizado a|is allowed to|may)\b[^.;]*\b(?:microdelegar|micro-delegar|microdelegation)\b',
        '(?i)\b(?:injetar flags em reposit[o\u00f3]rios|gravar flags no workspace do consumidor|inject flags into consumer repos)\b',
        '(?i)(?<!(?:n[a\u00e3]o|sem|nunca|jamais|proibid[oa]|never|do not)\s+)\b(?:pode|deve|autoriza|permite|allows?|is allowed to)\s+(?:economizar agentes|conservar contagem de agentes|conserve agent count)\b',
        '(?i)(?<!(?:n[a\u00e3]o|sem|nunca|jamais|proibid[oa]|never|do not)\s+)\b(?:pode|deve|autoriza|permite|allows?|is allowed to)\s+(?:paralelizar depend[e\u00ea]ncias verdadeiras|parallelize true dependencies)\b',
        '(?i)(?<!(?:n[a\u00e3]o|sem|nunca|jamais|proibid[oa]|never|do not)\s+)\b(?:pode|deve|autoriza|permite|allows?|is allowed to)\s+(?:escritas concorrentes|concurrent writes)[^.;\r\n]*(?:mesmo ownership|same ownership|mesmo arquivo|mesma propriedade)\b'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains forbidden pattern: $pattern"
        }
    }
}

function Assert-DeliveryGateWiring {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $requiredPatterns = @(
        '(?i)alvo congelado|frozen target',
        '(?i)revis[a\u00e3]o independente|independent review',
        '(?i)APPROVED',
        '(?i)zero (?:bloqueios|blockers)',
        '(?i)staging-invariant|invariante a staging',
        '(?i)code[- ]page|host-code-page|encoding do host|codifica[c\u00e7][a\u00e3]o do host',
        '(?i)staged path set|conjunto de (?:arquivos|caminhos) no stage',
        '(?i)staged blob|conte[uú]do.{0,60}(?:aprovado|approved).{0,60}(?:index|stage)|(?:index|stage).{0,60}conte[uú]do.{0,60}(?:aprovado|approved)'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required delivery gate wiring pattern: $pattern"
        }
    }

    if ($Text.IndexOf('Review-And-Fix-Vigorously', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$Label contains invented RAFV acronym expansion"
    }
}

function Assert-DesignSpecContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $requiredPatterns = @(
        '(?i)subagent_backend',
        '(?i)delegation_policy',
        '(?i)balanced',
        '(?i)aggressive',
        '(?i)wall time|wall-clock',
        '(?i)desonera[c\u00e7][a\u00e3]o de tokens|token offload',
        '(?i)alvo congelado|frozen target',
        '(?i)revis[a\u00e3]o independente|independent review',
        '(?i)APPROVED',
        '(?i)BLOCKED',
        '(?i)R\.A\.F\.V',
        '(?i)invariante a staging|staging-invariant',
        '(?i)code[- ]page|host-code-page|encoding do host|codifica[c\u00e7][a\u00e3]o do host',
        '(?i)staged path set|conjunto de arquivos no stage',
        '(?i)staged blob|conte[uú]do.{0,60}(?:aprovado|approved).{0,60}(?:index|stage)|(?:index|stage).{0,60}conte[uú]do.{0,60}(?:aprovado|approved)',
        '(?i)drift.{0,100}proje[c\u00e7][o\u00f5]es gerenciadas.{0,80}(?:fail-closed|falha fechad)',
        '(?i)n[a\u00e3]o relacionados.{0,120}preservados e reconciliados'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required spec contract pattern: $pattern"
        }
    }

    if ($Text.IndexOf('Review-And-Fix-Vigorously', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$Label contains invented RAFV acronym expansion"
    }
}

function Assert-CorrectionAdequacySpecContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $required = @(
        '(?i)Gate de Adequa[c\u00e7][a\u00e3]o da Corre[c\u00e7][a\u00e3]o|Correction Adequacy Gate',
        '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel(?:/delimitada)?',
        '(?i)N[a\u00e3]o-Objetivos|Non-Goals',
        '(?i)Modelo de Dados|Data Model',
        '(?i)Eventos de Acionamento|Event Triggers',
        '(?i)Hard Gates',
        '(?i)Matriz (?:de Integra[c\u00e7][a\u00e3]o )?por Modo|Mode Matrix',
        '(?i)critical.*worker|worker.*critical',
        '(?i)Fronteira do.*Bridge|transporte neutro|neutral transport',
        '(?i)Valida[c\u00e7][a\u00e3]o e Crit[e\u00e9]rios de Aceita[c\u00e7][a\u00e3]o|Acceptance Criteria',
        '(?i)LOCAL_FIX',
        '(?i)ROBUST_FIX',
        '(?i)REWORK',
        '(?i)RESEARCH',
        '(?i)RESEARCH_THEN_REWORK',
        '(?i)BLOCKED',
        '(?i)required_fix'
    )
    foreach ($pattern in $required) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required spec pattern: $pattern"
        }
    }

    if ($Text.IndexOf('Review-And-Fix-Vigorously', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$Label contains invented RAFV acronym expansion"
    }
}

function Assert-PlanContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    if ($Text.IndexOf('Review-And-Fix-Vigorously', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$Label contains invented RAFV acronym expansion"
    }
}

function Assert-SecurityDocContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)subagent_backend',
        '(?i)delegation_policy',
        '(?i)native',
        '(?i)deepseek',
        '(?i)balanced',
        '(?i)aggressive',
        '(?i)wall-clock|wall time',
        '(?i)desonera[c\u00e7][a\u00e3]o de tokens|token offload',
        '(?i)sem fallback|no fallback|fallback proibido|bloqueia.{0,40}fallback',
        '(?i)alvo congelado|frozen target',
        '(?i)revis[a\u00e3]o independente|independent review',
        '(?i)APPROVED'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required security contract pattern: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)executor principal [e\u00e9] o DeepSeek Sub-Agent MCP',
        '(?i)orquestra[c\u00e7][a\u00e3]o (?:passa a ser )?exclusivamente via DeepSeek'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains outdated architecture claim: $pattern"
        }
    }
}

function Assert-OpenAiAgentContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    if ($normalized -notmatch '(?i)display_name:\s*"Workflows"') {
        throw "$Label is missing display_name"
    }
    if ($normalized -notmatch '(?i)short_description:\s*"[^"]+"') {
        throw "$Label is missing short_description"
    }

    $forbiddenPatterns = @(
        '(?i)deepseek',
        '(?i)\bnative\b',
        '(?i)\bbalanced\b',
        '(?i)\baggressive\b'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label short_description is not backend/policy neutral: $pattern"
        }
    }
}

function Assert-InstallerOutputContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)Subagent backend:',
        '(?i)Delegation policy:',
        '(?i)Backend matrix:'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required selector-aware output pattern: $pattern"
        }
    }

    if ($Text -match '(?i)Multi-agent route:\s*disabled via\s*\[features\]\s*multi_agent\s*=\s*false') {
        throw "$Label contains unconditional multi_agent disabled output message"
    }
}

function Assert-DoctorOutputContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)Active subagent backend:',
        '(?i)Active delegation policy:'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label detailed output is missing selector-aware pattern: $pattern"
        }
    }

    if ($Text -match '(?i)safe profile requires\s+(?:\[features\]\s+)?multi_agent\s*=\s*false') {
        throw "$Label detailed output contains obsolete unconditional multi_agent=false requirement"
    }
}

function Assert-SupersededSpecContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    $requiredPatterns = @(
        '(?i)SUPERSEDED',
        '(?i)2026-08-26-workflow-rearchitecture-design\.md',
        '(?i)hist[o\u00f3]rico|historical'
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required superseded marker pattern: $pattern"
        }
    }
}

function Assert-ReadmeContract {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $required = @(
        '(?i)\^Numpad1|Ctrl\s*\+\s*Numpad1',
        '(?i)\^Numpad2|Ctrl\s*\+\s*Numpad2',
        '(?i)\^Numpad4|Ctrl\s*\+\s*Numpad4',
        '(?i)\^Numpad5|Ctrl\s*\+\s*Numpad5',
        '(?i)\^Numpad0|Ctrl\s*\+\s*Numpad0',
        '(?i)checkout root|raiz do checkout|diret[o\u00f3]rio raiz do reposit[o\u00f3]rio',
        '(?i)subagent_backend',
        '(?i)delegation_policy',
        '(?i)controle de seletores',
        '(?i)drift.{0,100}proje[c\u00e7][a\u00e3]o gerenciada.{0,80}falham fechado',
        '(?i)n[a\u00e3]o relacionados.{0,120}preservados e reconciliados'
    )
    foreach ($pattern in $required) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required documentation pattern: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)orquestra[c\u00e7][a\u00e3]o (?:passa a ser )?exclusivamente via DeepSeek',
        '(?i)executor principal [e\u00e9] o DeepSeek Sub-Agent MCP'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains outdated DeepSeek-only architecture text: $pattern"
        }
    }
}

function Test-OrchestrationPolicy {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)seletor global de backend.{0,120}autorit(?:[a\u00e1]rio|ativa|ativo)',
        '(?i)matriz ausente,? inv[a\u00e1]lida ou inconsistente bloqueia.{0,80}fallback silencioso',
        '(?i)native.{0,180}gpt-6-luna.{0,100}reasoning_effort.{0,80}normal/default',
        '(?i)deepseek.{0,120}(?:subagents_spawn|deepseek_spawn).{0,100}(?:subagents_continue|deepseek_continue).{0,100}(?:subagents_follow|deepseek_follow)',
        '(?i)delegation_policy',
        '(?i)balanced',
        '(?i)aggressive',
        '(?i)nunca refazer localmente uma frente material delegada',
        '(?i)consuma todo job aceito antes de um gate dependente ou da resposta final',
        '(?i)feche explicitamente todo agente terminado',
        '(?i)sem obriga[c\u00e7][o\u00f5]es pendentes ou em aberto',
        '(?i)o writer fica aberto.{0,80}at[\u00e9e] a revis[\u00e3a]o independente',
        '(?i)defeitos provados voltam [a\u00e1\u00e0] mesma frente',
        '(?i)feche s[o\u00f3] depois',
        '(?i)n[\u00e3a]o est[\u00e1a] terminado antes de revis[\u00e3a]o e corre[c\u00e7][o\u00f5]es conclu[\u00ed\u00ec]das',
        '(?i)falha fechado',
        '(?i)visual_context',
        '(?i)antes de esperar,? mapeie frentes independentes,? depend[e\u00ea]ncias e recursos exclusivos ou compartilhados',
        '(?i)(?:quando a pol[i\u00ed]tica eleger delega[c\u00e7][a\u00e3]o|se a pol[i\u00ed]tica eleger delega[c\u00e7][a\u00e3]o|ap[o\u00f3]s a pol[i\u00ed]tica eleger delega[c\u00e7][a\u00e3]o|ap[o\u00f3]s eleger delega[c\u00e7][a\u00e3]o),? lance em lote todas as frentes materiais independentes antes do primeiro follow',
        '(?i)apenas trilhas com depend[e\u00ea]ncia real ou recurso compartilhado ficam seriais',
        '(?i)enquanto aguarda,? fa[c\u00e7]a orquestra[c\u00e7][\u00e3a]o independente [u\u00fa]til',
        '(?i)ledger est[a\u00e1]vel de request_id.{0,60}frente,? agente,? job,? estado,? consumido e fechado',
        '(?i)consuma cada job e feche cada agente ap[o\u00f3]s a integra[c\u00e7][\u00e3a]o',
        '(?i)(?:subagents_continue|deepseek_continue).{0,80}allow_respawn',
        '(?i)sem pedir nova permiss[\u00e3a]o',
        '(?i)cria sess[\u00e3a]o.{0,60}lineage',
        '(?i)nunca recupere job running',
        '(?i)abortad[oa] explicitamente',
        '(?i)sem fallback',
        '(?i)fora do pedido original',
        '(?i)aggressive.{0,100}(?:parent|orquestrador).{0,60}(?:arquiteto|decisor|integrador|gatekeeper)',
        '(?i)pacote pequeno de evid[e\u00ea]ncia decis[o\u00f3]ria|evid[e\u00ea]ncia decis[o\u00f3]ria',
        '(?i)sem refazer bulk delegado|nunca refazer bulk delegado',
        '(?i)uma trilha persistente por frente coesa|trilha persistente por frente coesa',
        '(?i)sem microdelega[c\u00e7][a\u00e3]o',
        '(?i)nova trilha apenas para deliverable independentemente aceit[a\u00e1]vel',
        '(?i)mesma trilha.{0,40}invent[a\u00e1]rio m[i\u00ed]nimo.{0,40}closure slices pequenos',
        '(?i)proibido repetir integralmente',
        '(?i)proibido abrir novo agente'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            return "missing required orchestration policy pattern: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)Review-And-Fix-Vigorously',
        '(?i)\bR\.A\.F\.V\b\s*\(',
        '(?i)pedir explicitamente sub-agentes',
        '(?i)usu[a\u00e1]rio pedir explicitamente',
        '(?i)n[a\u00e3]o\s+(?:[e\u00e9]\s+)?a\s+for[c\u00e7]a\s+de\s+trabalho',
        '(?i)trabalho local do parent [e\u00e9] at[o\u00f3\u00f4]mico',
        '(?i)\b(?:pode|poderia|poder[a\u00e1]|deve|deveria)\b[^.;]*\b(?:refazer|repetir|duplicar)\b',
        '(?i)(?:n[a\u00e3]o precisa|sem precisar|sem a necessidade)\b[^.;]*\bdelegar\b',
        '(?i)\b(?:pode|poderia|poder[a\u00e1]|deve|deveria)\b[^.;]*\b(?:fechar|encerrar)\b[^.;]*(?:writer|agente|frente)',
        '(?i)\b(?=[^.;]*\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam|s[a\u00e3]o autorizad[ao]s? a|est[a\u00e3]o autorizad[ao]s? a|usam)\b)(?=[^.;]*\b(?:spawn_agent|wait_agent|multi_agent_v1__spawn_agent)\b)(?=[^.;]*\b(?:supervis[a\u00e3]o|guardian)\b)[^.;]+',
        '(?i)\b(?:pode|deve|autorizado a)\b[^.;]*\b(?:refazer bulk|refazer trabalho delegado)\b',
        '(?i)\b(?:pode|deve|autorizado a)\b[^.;]*\b(?:microdelegar|micro-delegar)\b',
        '(?i)\b(?:pode|deve|autorizado a)\b[^.;]*\b(?:repetir integralmente|abrir novo agente ap[o\u00f3]s timeout)\b'
    )

    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            return "forbidden direct-local-work carve-out: $pattern"
        }
    }

    $recoveryForbiddenPatterns = @(
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:job running|running|em execu[c\u00e7][a\u00e3]o|em andamento|em curso|ativos?|andamento)',
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:sem resposta final|resposta final persistida|sem resultado final|resultado final persistido|sem resultado terminal)',
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:abortad[oa]|abortados)',
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:escopo novo|outro escopo|escopo diferente|frente nova|fora do pedido|mudan[c\u00e7]a material|pedido divergiu|pedido divergente|outro pedido|mudan[c\u00e7]a de cwd|cwd diferente|mudando de cwd|outro cwd|cwd divergente)',
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar|allow_respawn)\b[^.;]*\b(?:fallback|outro provedor|outro modelo|troc\w*|substitu\w*)\b',
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:reabrir a sess[a\u00e3]o|mesma sess[a\u00e3]o|sess[a\u00e3]o antiga|continuar a sess[a\u00e3]o|abrir nova sess[a\u00e3]o|sess[a\u00e3]o nova)\b',
        '(?i)\b(?:usa|usar|utiliza|utilizar|adota|adotar)\s+(?:rotineir\w*|normalmente|de rotina)\b[^.;]*allow_respawn|allow_respawn\b[^.;]*(?:[e\u00e9]|como|para)\s+(?:persist[e\u00ea]ncia|uso|opera[c\u00e7][\u00e3a]o)\s+(?:rotineir\w*|normal|habitual)'
    )

    foreach ($pattern in $recoveryForbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            return "forbidden recovery-policy carve-out: $pattern"
        }
    }

    return $null
}

function New-TamperedText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Old,
        [string]$New = ''
    )

    $index = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($index -lt 0) {
        throw "Tamper fixture source text is missing: $Old"
    }
    return $Text.Remove($index, $Old.Length).Insert($index, $New)
}

function Assert-OrchestrationPolicySelfCheck {
    param([Parameter(Mandatory)][string]$Canonical)

    $normalized = [regex]::Replace($Canonical, '\s+', ' ').Trim()
    $samples = @(
        [pscustomobject]@{
            Name = 'parent permitted to redo a delegated front locally'
            Text = (New-TamperedText -Text $normalized -Old 'nunca refazer localmente' -New 'pode refazer localmente')
        }
        [pscustomobject]@{
            Name = 'supervisory agents may use native tools to manage lifecycle'
            Text = ($normalized + ' Os agentes de supervisao do sistema podem usar spawn_agent para gerenciar o ciclo de vida.')
        }
        [pscustomobject]@{
            Name = 'supervisory agents authorized to use native tools'
            Text = ($normalized + ' Os agentes de supervisao do sistema estao autorizados a usar wait_agent.')
        }
        [pscustomobject]@{
            Name = 'supervisory agents use native tools freely'
            Text = ($normalized + ' Os agentes de supervisao do sistema usam spawn_agent livremente.')
        }
        [pscustomobject]@{
            Name = 'fail-closed behavior removed'
            Text = $normalized.Replace('falha fechado', 'rota aberta')
        }
        [pscustomobject]@{
            Name = 'user-mention default-delegation clause removed'
            Text = (New-TamperedText -Text $normalized -Old 'O seletor global de backend' -New 'O seletor local de backend')
        }
        [pscustomobject]@{
            Name = '$workflows made a condition for MCP selection'
            Text = (New-TamperedText -Text $normalized -Old 'matriz ausente' -New 'matriz aberta')
        }
        [pscustomobject]@{
            Name = 'writer close-before-review exemption added'
            Text = ($normalized + ' O parent pode fechar o writer antes da revisao independente.')
        }
        [pscustomobject]@{
            Name = 'map-before-wait removed'
            Text = (New-TamperedText -Text $normalized -Old 'Antes de esperar' -New 'Antes de agir')
        }
        [pscustomobject]@{
            Name = 'batch launch before first follow removed'
            Text = (New-TamperedText -Text $normalized -Old 'lance em lote todas as frentes materiais independentes' -New 'lance as frentes uma a uma')
        }
        [pscustomobject]@{
            Name = 'serial-only-real-dependencies removed'
            Text = (New-TamperedText -Text $normalized -Old 'apenas trilhas com' -New 'todas as trilhas com')
        }
        [pscustomobject]@{
            Name = 'useful orchestration while waiting removed'
            Text = (New-TamperedText -Text $normalized -Old 'enquanto aguarda' -New 'enquanto dorme')
        }
        [pscustomobject]@{
            Name = 'request_id ledger removed'
            Text = (New-TamperedText -Text $normalized -Old 'ledger estável' -New 'historico estavel')
        }
        [pscustomobject]@{
            Name = 'consume-and-close-after-integration removed'
            Text = (New-TamperedText -Text $normalized -Old 'consuma cada job' -New 'ignore cada job')
        }
        [pscustomobject]@{
            Name = 'recovery respawn authorized for a running job'
            Text = ($normalized + ' O parent pode recuperar job running com allow_respawn.')
        }
        [pscustomobject]@{
            Name = 'recovery respawn authorized for an explicitly aborted job'
            Text = ($normalized + ' O parent pode reabrir job abortado com allow_respawn.')
        }
        [pscustomobject]@{
            Name = 'recovery respawn authorizes scope expansion'
            Text = ($normalized + ' O parent pode recuperar com allow_respawn em escopo novo.')
        }
        [pscustomobject]@{
            Name = 'recovery respawn allows a provider fallback'
            Text = ($normalized + ' O parent pode recuperar com allow_respawn usando fallback de provedor.')
        }
        [pscustomobject]@{
            Name = 'recovery as a fake continuation of the original session'
            Text = ($normalized + ' O parent pode reabrir a sessao antiga em vez de criar sessao nova.')
        }
        [pscustomobject]@{
            Name = 'recovery via continue authorized for a job in progress'
            Text = ($normalized + ' O parent pode continuar com allow_respawn para job em andamento.')
        }
        [pscustomobject]@{
            Name = 'recovery of a job without a persisted final response'
            Text = ($normalized + ' O parent pode recuperar job sem resposta final persistida.')
        }
        [pscustomobject]@{
            Name = 'recovery authorized after the request diverged'
            Text = ($normalized + ' O parent pode usar allow_respawn quando o pedido divergiu.')
        }
        [pscustomobject]@{
            Name = 'recovery authorized while changing cwd'
            Text = ($normalized + ' O parent pode recuperar com allow_respawn mudando de cwd.')
        }
        [pscustomobject]@{
            Name = 'recovery opens a new session for a new front'
            Text = ($normalized + ' O parent pode abrir nova sessao para frente nova.')
        }
        [pscustomobject]@{
            Name = 'recovery respawn allowed while switching model/provider'
            Text = ($normalized + ' O parent pode retomar com allow_respawn trocando de modelo/provedor.')
        }
        [pscustomobject]@{
            Name = 'recovery respawn allowed while substituting the provider'
            Text = ($normalized + ' O parent pode retomar com allow_respawn substituindo o provedor.')
        }
        [pscustomobject]@{
            Name = 'routine allow_respawn persistence tamper'
            Text = ($normalized + ' O parent usa rotineiramente allow_respawn=true como persistencia.')
        }
        [pscustomobject]@{
            Name = 'legacy native prompt requirement tamper'
            Text = ($normalized + ' O parent deve pedir explicitamente sub-agentes nativos.')
        }
        [pscustomobject]@{
            Name = 'invented RAFV acronym expansion tamper'
            Text = ($normalized + ' O modo R.A.F.V (Review-And-Fix-Vigorously) e executado.')
        }
        [pscustomobject]@{
            Name = 'unconditional not workforce tamper'
            Text = ($normalized + ' O parent nao e a forca de trabalho do repositorio.')
        }
        [pscustomobject]@{
            Name = 'unconditional atomic local work tamper'
            Text = ($normalized + ' O trabalho local do parent e atomico.')
        }
        [pscustomobject]@{
            Name = 'parent permitted to redo bulk delegated work tamper'
            Text = ($normalized + ' O parent pode refazer bulk delegado localmente.')
        }
        [pscustomobject]@{
            Name = 'microdelegation allowed tamper'
            Text = ($normalized + ' O parent pode microdelegar tarefas pequenas.')
        }
        [pscustomobject]@{
            Name = 'timeout repeat integrally tamper'
            Text = ($normalized + ' O parent pode repetir integralmente a tarefa apos timeout.')
        }
    )

    foreach ($sample in $samples) {
        if ($null -eq (Test-OrchestrationPolicy -Text $sample.Text)) {
            throw "Orchestration policy self-check failed to detect tampering: $($sample.Name)"
        }
    }
}

function Assert-OrchestrationPolicy {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $reason = Test-OrchestrationPolicy -Text $Text
    if ($null -ne $reason) {
        throw "$Label fails the default-delegation orchestration policy ($reason)"
    }

    Assert-OrchestrationPolicySelfCheck -Canonical $Text
}

function Assert-ModeMatrix {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Text
    )

    $canonical = [ordered]@{
        'PLAN.AUTO'       = @{ capabilities = @('read'); permission = 'no-write' }
        'PLAN'            = @{ capabilities = @('read'); permission = 'no-write' }
        'P.DEEP'          = @{ capabilities = @('read', 'research'); permission = 'no-write' }
        'RESEARCH.DEEP'   = @{ capabilities = @('research'); permission = 'no-write' }
        'IMPL.AUTO'       = @{ capabilities = @('read', 'write', 'test', 'review', 'commit'); permission = 'write' }
        'IMPL'            = @{ capabilities = @('read', 'write', 'test', 'review', 'commit'); permission = 'write' }
        'IMPL.PHASE'      = @{ capabilities = @('read', 'write', 'test', 'review', 'commit'); permission = 'write' }
        'DELIVER.AUTO'    = @{ capabilities = @('read', 'write', 'test', 'review', 'commit'); permission = 'write' }
        'REVIEW'          = @{ capabilities = @('review'); permission = 'no-write' }
        'COMMIT'          = @{ capabilities = @('read', 'verify', 'index', 'commit'); permission = 'git-only' }
        'BUG.INV'         = @{ capabilities = @('read', 'test'); permission = 'no-write' }
        'BUG.FIX'         = @{ capabilities = @('read', 'write', 'test', 'review', 'commit'); permission = 'write' }
        'DEBUG'           = @{ capabilities = @('read', 'test', 'write', 'review', 'commit'); permission = 'write' }
        'REWORK'          = @{ capabilities = @('read', 'research'); permission = 'no-write' }
        'R.A.F.V'         = @{ capabilities = @('review', 'write', 'test', 'commit'); permission = 'write' }
        'TN.SKILL'        = @{ capabilities = @('read', 'review'); permission = 'no-write' }
        'CONSULT'         = @{ capabilities = @('read'); permission = 'no-write' }
    }
    $allowedCapabilities = @('read', 'research', 'write', 'test', 'review', 'verify', 'index', 'commit')
    $nativeProfiles = @('scout', 'researcher', 'writer', 'reviewer', 'worker')
    $allowedPermissions = @('no-write', 'write', 'git-only')

    $rows = @([regex]::Matches($Text, '(?m)^\| `([A-Z][A-Z.]*)` \| ([^|]+?) \| ([^|]+?) \| ([^|]+?) \|\r?$'))
    if ($rows.Count -ne $canonical.Count) {
        throw "$Label does not declare exactly $($canonical.Count) mode rows: found $($rows.Count)"
    }

    $declared = @{}
    foreach ($row in $rows) {
        $mode = $row.Groups[1].Value
        $capabilities = @($row.Groups[2].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $permission = $row.Groups[3].Value.Trim()
        $doneGate = $row.Groups[4].Value.Trim()

        if (-not $canonical.Contains($mode)) {
            throw "$Label declares an unknown mode row: $mode"
        }
        if ($declared.ContainsKey($mode)) {
            throw "$Label declares mode $mode more than once"
        }
        $declared[$mode] = $true
        if ([string]::IsNullOrWhiteSpace($doneGate)) {
            throw "$Label mode $mode has an empty done gate"
        }

        foreach ($capability in $capabilities) {
            if ($capability -notin $allowedCapabilities) {
                throw "$Label mode $mode declares a capability outside the vocabulary ($($allowedCapabilities -join ', ')): $capability"
            }
            if ($capability -in $nativeProfiles) {
                throw "$Label mode $mode declares a native profile as a capability: $capability"
            }
        }

        if ($permission -notin $allowedPermissions) {
            throw "$Label mode $mode has an unsupported change permission: $permission"
        }
        if (($permission -eq 'no-write' -or $permission -eq 'git-only') -and $capabilities -contains 'write') {
            throw "$Label mode $mode has a no-write or git-only permission but grants write"
        }
        if ($capabilities -contains 'commit' -and $permission -notin @('write', 'git-only')) {
            throw "$Label mode $mode grants commit outside write or git-only permissions"
        }

        $expected = $canonical[$mode]
        if (($capabilities -join ',') -cne ($expected.capabilities -join ',')) {
            throw "$Label mode $mode capabilities differ from the canonical matrix: got '$($capabilities -join ',')', expected '$($expected.capabilities -join ',')'"
        }
        if ($permission -cne $expected.permission) {
            throw "$Label mode $mode change permission differs from the canonical matrix: got '$permission', expected '$($expected.permission)'"
        }
    }

    if (($canonical['IMPL.AUTO'].capabilities -join ',') -cne 'read,write,test,review,commit') {
        throw "$Label canonical IMPL.AUTO does not grant read,write,test,review,commit"
    }
}

function Assert-NoManagedAgentsBlock {
    param([Parameter(Mandatory)][string]$Path)

    $text = (Read-RequiredText $Path) -replace '\r\n', "`n"
    if ($text.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: agents', [StringComparison]::Ordinal) -ge 0) {
        throw "Installed configuration retains the managed agents defaults block: $Path"
    }
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

function Assert-FeaturesMultiAgentDisabled {
    param([Parameter(Mandatory)][string]$Path)

    $text = Read-RequiredText $Path
    $info = Get-FeaturesTableInfo -Text $text
    if ($info.Index -lt 0 -or $info.MultiAgentLine -lt 0) {
        throw "Safe profile requires multi_agent = false under [features]: $Path"
    }
    if ($info.MultiAgentValue -cne 'false') {
        throw "Safe profile requires multi_agent = false but found '$($info.MultiAgentValue)': $Path"
    }
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
        [Parameter(Mandatory)][string]$Label,
        [string]$CanonicalHelper = $null
    )

    $sourceFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName)
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\', '/')
        Assert-SameFile -Source $file.FullName -Installed (Join-Path $Installed $relative) -Label $Label
    }

    $expected = @{}
    foreach ($file in $sourceFiles) {
        $rel = $file.FullName.Substring($Source.Length).TrimStart('\', '/').Replace('/', '\')
        $expected[$rel] = $true
    }

    $isWorkflows = (Split-Path -Leaf $Source) -eq 'workflows'
    if ($isWorkflows) {
        $helperRel = 'scripts\invoke-safe-powershell.ps1'
        $resolvedHelper = if (-not [string]::IsNullOrWhiteSpace($CanonicalHelper)) {
            $CanonicalHelper
        } else {
            $candidateRepo = Split-Path -Parent (Split-Path -Parent $Source)
            $candidateHelper = Join-Path $candidateRepo $helperRel
            if (Test-Path -LiteralPath $candidateHelper -PathType Leaf) {
                $candidateHelper
            } elseif (Get-Variable -Name repo -Scope 1 -ErrorAction SilentlyContinue -and (Test-Path -LiteralPath (Join-Path $repo $helperRel) -PathType Leaf)) {
                Join-Path $repo $helperRel
            } else {
                $candidateHelper
            }
        }

        if (-not (Test-Path -LiteralPath $resolvedHelper -PathType Leaf)) {
            throw "Canonical safe PowerShell helper is missing: $resolvedHelper"
        }

        $installedHelper = Join-Path $Installed $helperRel
        Assert-SameFile -Source $resolvedHelper -Installed $installedHelper -Label $Label
        $expected[$helperRel] = $true
        $expected['scripts/invoke-safe-powershell.ps1'] = $true
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Installed -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($Installed.Length).TrimStart('\', '/')
        $normRelative = $relative.Replace('/', '\')
        if (-not $expected.ContainsKey($relative) -and -not $expected.ContainsKey($normRelative)) {
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
    if ($schemaText -notin @('1', '2', '3', '4', '5')) {
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
    if ($schema -ge 3) {
        if (-not ($State.PSObject.Properties.Name -contains 'pendingFiles') -or $null -eq $State.pendingFiles -or -not ($State.pendingFiles -is [System.Array])) {
            throw "Schema $schema installed state is missing pendingFiles."
        }
        $entries += @($State.pendingFiles)
    }
    elseif ($State.PSObject.Properties.Name -contains 'pendingFiles') {
        throw 'Only schema 3 and later installed state may contain pendingFiles.'
    }

    if ($schema -ge 4) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or $null -eq $State.codexFeaturesPrior) {
            throw "Schema $schema installed state is missing codexFeaturesPrior."
        }
        if (-not ($State.codexFeaturesPrior.PSObject.Properties.Name -contains 'multi_agent')) {
            throw "Schema $schema installed state is missing the multi_agent feature record."
        }
        $featureRecord = $State.codexFeaturesPrior.multi_agent
        if ($null -eq $featureRecord -or -not ($featureRecord.PSObject.Properties.Name -contains 'present') -or -not ($featureRecord.PSObject.Properties.Name -contains 'value')) {
            throw "Schema $schema installed state contains an invalid multi_agent feature record."
        }
        if ($featureRecord.present -notin @($true, $false)) {
            throw "Schema $schema installed state has an invalid multi_agent presence flag."
        }
        if ([bool]$featureRecord.present -and $null -eq $featureRecord.value) {
            throw "Schema $schema installed state has a present multi_agent record without a value."
        }
        if (-not [bool]$featureRecord.present -and $null -ne $featureRecord.value) {
            throw "Schema $schema installed state has an absent multi_agent record with a value."
        }
    }

    if ($State.PSObject.Properties.Name -contains 'codexBackend') {
        if ($null -eq $State.codexBackend) {
            throw "Installed state contains an invalid codexBackend property."
        }
        Assert-CodexBackendState -BackendState $State.codexBackend
    }
    if ($State.PSObject.Properties.Name -contains 'codexDelegation') {
        if ($null -eq $State.codexDelegation) {
            throw "Installed state contains an invalid codexDelegation property."
        }
        Assert-CodexDelegationState -DelegationState $State.codexDelegation
    }
    if ($State.PSObject.Properties.Name -contains 'codexStrategy') {
        if ($null -eq $State.codexStrategy) {
            throw "Installed state contains an invalid codexStrategy property."
        }
        Assert-CodexStrategyState -StrategyState $State.codexStrategy
    }
    if ($State.PSObject.Properties.Name -contains 'codexContinuation') {
        if ($null -eq $State.codexContinuation) {
            throw "Installed state contains an invalid codexContinuation property."
        }
        Assert-CodexContinuationState -ContinuationState $State.codexContinuation
    }

    if ($schema -ge 5) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexBackend') -or $null -eq $State.codexBackend) {
            throw "Schema $schema installed state is missing required codexBackend."
        }
        Assert-CodexBackendState -BackendState $State.codexBackend
        if (-not ($State.PSObject.Properties.Name -contains 'codexDelegation') -or $null -eq $State.codexDelegation) {
            throw "Schema $schema installed state is missing required codexDelegation."
        }
        Assert-CodexDelegationState -DelegationState $State.codexDelegation
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

    if ($schema -ge 3) {
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
$mcpSource = Join-Path $repo 'skills\mcp-foundation'
$codebaseMemorySource = Join-Path $repo 'skills\codebase-memory-mcp'
$context7Source = Join-Path $repo 'skills\context7-mcp'
$safePowerShellSource = Join-Path $repo 'scripts\invoke-safe-powershell.ps1'

if (-not (Test-Path -LiteralPath $safePowerShellSource -PathType Leaf)) {
    throw "Canonical safe PowerShell helper is missing: $safePowerShellSource"
}
$safeHelperContent = [System.IO.File]::ReadAllText($safePowerShellSource, [System.Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($safeHelperContent)) {
    throw "Canonical safe PowerShell helper is empty: $safePowerShellSource"
}

if (-not (Test-Path -LiteralPath $codebaseMemorySource -PathType Container)) {
    throw "Canonical codebase-memory-mcp skill is missing: $codebaseMemorySource"
}
if (-not (Test-Path -LiteralPath (Join-Path $codebaseMemorySource 'SKILL.md') -PathType Leaf)) {
    throw "Canonical codebase-memory-mcp skill is missing SKILL.md: $codebaseMemorySource"
}

if (-not (Test-Path -LiteralPath $context7Source -PathType Container)) {
    throw "Canonical context7-mcp skill is missing: $context7Source"
}
if (-not (Test-Path -LiteralPath (Join-Path $context7Source 'SKILL.md') -PathType Leaf)) {
    throw "Canonical context7-mcp skill is missing SKILL.md: $context7Source"
}

$agentsMd = Join-Path $repo 'codex\AGENTS.md'
$geminiTemplate = Join-Path $repo 'antigravity\GEMINI.md'
$skill = Read-RequiredText (Join-Path $workflowSource 'SKILL.md')
$delegationRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'delegation.md')
$deliveryReviewRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'delivery-review.md')
$validationRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'validation.md')
$commitRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'commit.md')
$qualityRatchetPath = Join-Path (Join-Path $workflowSource 'references') 'quality-ratchet.md'
$qualityRatchetRef = if (Test-Path -LiteralPath $qualityRatchetPath) { Read-RequiredText $qualityRatchetPath } else { '' }
$designSpec = Read-RequiredText (Join-Path $repo 'docs\superpowers\specs\2026-08-26-workflow-rearchitecture-design.md')
$adequacySpec = Read-RequiredText (Join-Path $repo 'docs\superpowers\specs\2026-09-03-correction-adequacy-gate-design.md')
$implPlan = Read-RequiredText (Join-Path $repo 'docs\superpowers\plans\2026-08-26-workflow-rearchitecture-implementation-plan.md')
$mcpSkill = Read-RequiredText (Join-Path $mcpSource 'SKILL.md')
$mcpLifecycle = Read-RequiredText (Join-Path (Join-Path $mcpSource 'references') 'lifecycle.md')
$mcpSerenaCodeGraph = Read-RequiredText (Join-Path (Join-Path $mcpSource 'references') 'serena-codegraph.md')
$agentsText = Read-RequiredText $agentsMd
$geminiText = Read-RequiredText $geminiTemplate
$readmeText = Read-RequiredText (Join-Path $repo 'README.md')
$installer = Read-RequiredText (Join-Path $repo 'scripts\install.ps1')
$doctorText = Read-RequiredText (Join-Path $repo 'scripts\doctor.ps1')
$securityDoc = Read-RequiredText (Join-Path $repo 'docs\security.md')
$openaiYaml = Read-RequiredText (Join-Path (Join-Path $workflowSource 'agents') 'openai.yaml')
$supersededSpec = Read-RequiredText (Join-Path $repo 'docs\superpowers\specs\2026-08-19-promptpad-superpowers-compatibility-design.md')
$promptPad = Read-RequiredText (Join-Path $repo 'ahk\codex_prompt_pad.ahk')

$allModes = @(
    'PLAN.AUTO', 'PLAN', 'P.DEEP', 'RESEARCH.DEEP', 'IMPL.AUTO', 'IMPL',
    'IMPL.PHASE', 'DELIVER.AUTO', 'REVIEW', 'COMMIT', 'BUG.INV', 'BUG.FIX',
    'DEBUG', 'REWORK', 'R.A.F.V', 'TN.SKILL', 'CONSULT'
)
foreach ($mode in $allModes) {
    Assert-Contains -Label 'workflow skill' -Text $skill -Needles @($mode)
}

Assert-Contains -Label 'workflow skill' -Text $skill -Needles @(
    'name: workflows',
    'FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE',
    'subagents_spawn|deepseek_spawn',
    'subagents_continue|deepseek_continue',
    'subagents_follow|deepseek_follow',
    'subagents_consult|deepseek_consult',
    'subagents_abort|deepseek_abort',
    'subagents_close|deepseek_close',
    'subagents_recover_result|deepseek_recover_result',
    'allow_respawn',
    'capabilities | change permission | done gate',
    'visual_context',
    'Final audit',
    'Delivery commit gate',
    'local commit series',
    'never push',
    'Git index',
    'No-edit',
    'balanced',
    'aggressive',
    'references/delegation.md',
    'references/delivery-review.md'
)
Assert-ModeMatrix -Label 'workflow skill' -Text $skill
$implAutoRow = [regex]::Match($skill, '(?m)^\| `IMPL\.AUTO` \|[^\r\n]+')
if (-not $implAutoRow.Success -or $implAutoRow.Value -notmatch '\| write \|') {
    throw "Workflow skill does not grant IMPL.AUTO write permission"
}

$skillWithoutAutonomy = [regex]::Replace($skill, '(?i)\b(?:active writer|deferred_active_writer|idle open writer(?:s)?|integrated reviewer)\b', '')
Assert-Forbidden -Label 'workflow skill' -Text $skillWithoutAutonomy -Tokens @(
    'AGENTS.md',
    'subagents=',
    'sidecar',
    'read-only',
    'scout',
    'researcher',
    'writer',
    'reviewer',
    'Review-And-Fix-Vigorously',
    'not the repository workforce'
)
Assert-Forbidden -Label 'codex AGENTS.md' -Text $agentsText -Tokens @(
    'subagents=',
    'scout',
    'researcher',
    'Review-And-Fix-Vigorously',
    (-join [char[]]@(110, 227, 111, 32, 97, 32, 102, 111, 114, 231, 97, 32, 100, 101, 32, 116, 114, 97, 98, 97, 108, 104, 111, 32, 100, 111, 32, 114, 101, 112, 111, 115, 105, 116, 243, 114, 105, 111)),
    'pedir explicitamente sub-agentes'
)

Assert-Contains -Label 'codex AGENTS.md' -Text $agentsText -Needles @(
    'ALINHAMENTO',
    '$workflows',
    'SKILL.md',
    'Preserve',
    'DeepSeek',
    'MCP',
    'delega',
    'job',
    'visual_context',
    'subagents_spawn|deepseek_spawn',
    'subagents_continue|deepseek_continue',
    'subagents_follow|deepseek_follow',
    'multi_agent_v1__spawn_agent',
    'spawn_agent',
    'wait_agent',
    'workers',
    'readers',
    'writers',
    'explorers',
    'reviewers',
    'nativo',
    (-join [char[]]@(110, 227, 111, 32, 233, 32, 99, 111, 110, 100, 105, 231, 227, 111)),
    'falha fechado',
    'resultado terminal',
    'balanced',
    'aggressive',
    'subagent_backend',
    'delegation_policy',
    'APPROVED',
    'BLOCKED',
    'alvo congelado'
)
$agentsBytes = (Get-Item (Join-Path $repo 'codex\AGENTS.md')).Length
if ($agentsBytes -ge 20000) {
    throw "codex AGENTS.md exceeds the measured byte budget: $agentsBytes bytes (limit: < 20000 bytes)"
}
$geminiBytes = (Get-Item (Join-Path $repo 'antigravity\GEMINI.md')).Length
if ($geminiBytes -ge 14000) {
    throw "antigravity GEMINI.md exceeds the measured byte budget: $geminiBytes bytes (limit: < 14000 bytes)"
}
if ($agentsText.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: runtime', [StringComparison]::Ordinal) -ge 0) {
    throw 'Source template codex/AGENTS.md must not contain active runtime block values.'
}

function Assert-AllContractRules {
    param(
        [Parameter(Mandatory)][scriptblock[]]$Checks
    )

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($check in $Checks) {
        try {
            & $check
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }

    if ($failures.Count -gt 0) {
        throw ("Contract validation failures ({0}):`n- {1}" -f $failures.Count, ($failures -join "`n- "))
    }
}

Assert-AllContractRules -Checks @(
    { Assert-CompletionPolicy -Label 'workflow skill' -Text $skill },
    { Assert-RecoveryPolicy -Label 'workflow skill' -Text $skill },
    { Assert-OrchestrationPolicy -Label 'codex AGENTS.md' -Text $agentsText },
    { Assert-DelegationContract -Label 'delegation reference' -Text $delegationRef },
    { Assert-DeliveryReviewContract -Label 'delivery-review reference' -Text $deliveryReviewRef },
    { Assert-DeliveryGateWiring -Label 'validation reference' -Text $validationRef },
    { Assert-DeliveryGateWiring -Label 'commit reference' -Text $commitRef },
    { Assert-DesignSpecContract -Label 'design spec' -Text $designSpec },
    { Assert-CorrectionAdequacySpecContract -Label 'correction adequacy gate design spec' -Text $adequacySpec },
    { Assert-PlanContract -Label 'implementation plan' -Text $implPlan },
    { Assert-ReadmeContract -Label 'README.md' -Text $readmeText },
    { Assert-SecurityDocContract -Label 'docs/security.md' -Text $securityDoc },
    { Assert-OpenAiAgentContract -Label 'skills/workflows/agents/openai.yaml' -Text $openaiYaml },
    { Assert-InstallerOutputContract -Label 'scripts/install.ps1' -Text $installer },
    { Assert-DoctorOutputContract -Label 'scripts/doctor.ps1' -Text $doctorText },
    { Assert-SupersededSpecContract -Label 'docs/superpowers/specs/2026-08-19-promptpad-superpowers-compatibility-design.md' -Text $supersededSpec },
    { Assert-McpFoundationSkill -Label 'mcp-foundation skill' -Text $mcpSkill },
    { Assert-DeepSeekDaemonRestartPolicy -SkillText $mcpSkill -LifecycleText $mcpLifecycle -AgentsText $agentsText -GeminiText $geminiText },
    { Assert-DeliveryReviewPolicy -DeliveryReviewText $deliveryReviewRef -SkillText $skill -AgentsText $agentsText -GeminiText $geminiText -ValidationText $validationRef -CommitText $commitRef -QualityRatchetText $qualityRatchetRef -DelegationText $delegationRef -ReadmeText $readmeText },
    { Assert-AlinhamentoPolicy -AgentsText $agentsText -GeminiText $geminiText -SkillText $skill -DelegationText $delegationRef -ReadmeText $readmeText },
    { Assert-McpTemplateRouting -Label 'codex AGENTS.md' -Text $agentsText },
    { Assert-McpTemplateRouting -Label 'antigravity GEMINI.md' -Text $geminiText },
    { Assert-CriticalStrategyPolicy -AgentsText $agentsText -GeminiText $geminiText -SkillText $skill -DelegationText $delegationRef -ReadmeText $readmeText },
    { Assert-SubagentAutonomyPolicy -AgentsText $agentsText -GeminiText $geminiText -SkillText $skill -DelegationText $delegationRef -DeliveryReviewText $deliveryReviewRef -ReadmeText $readmeText },
    { Assert-AdaptiveSwarmPolicy -AgentsText $agentsText -GeminiText $geminiText -SkillText $skill -DelegationText $delegationRef -ReadmeText $readmeText }
)

$legacyPaths = @(
    'scripts\native-profile-contract.ps1',
    'agents',
    'skills\workflows\references\backend-policy.md',
    'skills\workflows\references\subagents.md',
    'skills\workflows\references\mode-matrix.md',
    'skills\workflows\references\dictionary.md',
    'docs\architecture.md',
    'docs\agent-bootstrap-prompt.md'
)
foreach ($relativePath in $legacyPaths) {
    $legacyTarget = Join-Path $repo $relativePath
    $legacyFiles = @(
        if (Test-Path -LiteralPath $legacyTarget) {
            Get-ChildItem -LiteralPath $legacyTarget -File -Recurse -Force
        }
    )
    if ($legacyFiles.Count -gt 0) {
        throw "Legacy path still exists: $relativePath"
    }
}

$legacyTokens = @(
    'backend-policy',
    'native-profile-contract',
    'mode-matrix',
    'dictionary.md',
    'subagents.md',
    'scout',
    'researcher',
    'writer',
    'reviewer',
    'worker'
)
$contractTokens = @(
    'subagents=',
    '\bsidecar\b'
)

function Test-PermittedLegacyRoleSurface {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Token
    )

    # Permitted role surface exceptions for 'writer', 'reviewer', 'worker':
    # - scripts/, docs/superpowers/, README.md, docs/security.md: tooling, design, and security docs
    # - codex/AGENTS.md, antigravity/GEMINI.md: host routing rules and delegation contract
    # - skills/workflows/SKILL.md, skills/workflows/references/delegation.md, skills/workflows/references/delivery-review.md: delivery review, swarm, active writer, and delegation policies
    # - skills/codebase-memory-mcp/SKILL.md, skills/codebase-memory-mcp/references/scenarios.md: CBM peer worker lock and graph reuse protocol
    # - skills/context7-mcp/SKILL.md: Context7 multi-worker deduplication and evidence packet sharing
    $isPermittedRoleSurface = (
        $RelativePath.StartsWith('scripts/') -or
        $RelativePath.StartsWith('ahk/') -or
        $RelativePath.StartsWith('docs/superpowers/') -or
        $RelativePath.StartsWith('docs/free-mcps-') -or
        $RelativePath -eq 'codex/AGENTS.md' -or
        $RelativePath -eq 'antigravity/GEMINI.md' -or
        $RelativePath -eq 'README.md' -or
        $RelativePath -eq 'docs/security.md' -or
        $RelativePath -eq 'skills/workflows/SKILL.md' -or
        $RelativePath -eq 'skills/workflows/references/delegation.md' -or
        $RelativePath -eq 'skills/workflows/references/delivery-review.md' -or
        $RelativePath -eq 'skills/workflows/references/commit.md' -or
        $RelativePath -eq 'skills/workflows/references/validation.md' -or
        $RelativePath -eq 'skills/workflows/references/skill-routing.md' -or
        $RelativePath -eq 'skills/workflows/references/context-reranking.md' -or
        $RelativePath.StartsWith('skills/workflows/scripts/') -or
        $RelativePath -eq 'skills/codebase-memory-mcp/SKILL.md' -or
        $RelativePath -eq 'skills/codebase-memory-mcp/references/scenarios.md' -or
        $RelativePath -eq 'skills/context7-mcp/SKILL.md'
    )
    if ($isPermittedRoleSurface -and $Token -in @('writer', 'reviewer', 'worker')) {
        return $true
    }
    # Permitted script surface exceptions for legacy migration sanitizers and negative tests ('scout', 'researcher'):
    # - scripts/backend-routing.psm1, scripts/migrate-legacy-gemini.ps1: detect/remove legacy conflicting rules
    # - scripts/tests/gemini-legacy-migration.Tests.ps1, scripts/tests/promptpad-optimization.Tests.ps1: unit tests exercising legacy migration sanitizers and negative rejection tests
    $permittedLegacyScoutResearcherPaths = @(
        'scripts/backend-routing.psm1',
        'scripts/migrate-legacy-gemini.ps1',
        'scripts/tests/gemini-legacy-migration.Tests.ps1',
        'scripts/tests/promptpad-optimization.Tests.ps1',
        'scripts/tests/swarm-doctor-contract.Tests.ps1'
    )
    if ($Token -in @('scout', 'researcher') -and $permittedLegacyScoutResearcherPaths -contains $RelativePath) {
        return $true
    }
    return $false
}

foreach ($relativePath in @(git -C $repo ls-files)) {
    $path = Join-Path $repo $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8

    if ($relativePath -ne 'CHANGELOG.md' -and $relativePath -ne 'scripts/validate.ps1') {
        foreach ($token in $legacyTokens) {
            if (Test-PermittedLegacyRoleSurface -RelativePath $relativePath -Token $token) {
                continue
            }
            if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "Retained reference to removed surface in ${relativePath}: $token"
            }
        }

        foreach ($token in $contractTokens) {
            if ($relativePath -eq 'codex/AGENTS.md' -and $token -eq '\bnative\b') {
                continue
            }
            if ($relativePath -eq 'scripts/tests/swarm-doctor-contract.Tests.ps1') {
                continue
            }
            if ([regex]::IsMatch($text, $token, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                throw "Active text retains removed routing terminology in ${relativePath}: $token"
            }
        }

        $forbiddenGlobalTokens = @(
            'Review-And-Fix-Vigorously',
            'Review and Fix Vigorously',
            'Review-And-Fix'
        )
        foreach ($token in $forbiddenGlobalTokens) {
            if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "Active text retains invented RAFV acronym expansion in ${relativePath}: $token"
            }
        }

        $forbiddenObsoletePatterns = @(
            '(?i)executor principal [e\u00e9] o DeepSeek Sub-Agent MCP',
            '(?i)orquestra[c\u00e7][a\u00e3]o (?:passa a ser )?exclusivamente via DeepSeek',
            '(?i)safe profile requires\s+(?:\[features\]\s+)?multi_agent\s*=\s*false'
        )
        $historicalPaths = @(
            'CHANGELOG.md',
            'CONTRIBUTING.md',
            'scripts/validate.ps1',
            'docs/superpowers/specs/2026-08-19-promptpad-superpowers-compatibility-design.md'
        )
        if ($relativePath -notin $historicalPaths) {
            foreach ($pattern in $forbiddenObsoletePatterns) {
                if ([regex]::IsMatch($text, $pattern)) {
                    throw "Active text retains obsolete architecture claim in ${relativePath}: $pattern"
                }
            }
        }
    }

    if ($relativePath -match '\.md$') {
        $links = @([regex]::Matches($text, '\]\((?<target>[^)#]+\.md)\)'))
        foreach ($link in $links) {
            $target = $link.Groups['target'].Value
            if ($target -match '^https?://') {
                continue
            }
            $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $path) $target))
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw "Broken reference in ${relativePath}: $target"
            }
        }
    }
}

$expectedPromptMap = [ordered]@{
    'Numpad0'  = '$workflows mode=PLAN.AUTO'
    'Numpad1'  = '$workflows mode=DELIVER.AUTO'
    'Numpad2'  = '$workflows mode=REVIEW'
    'Numpad3'  = '$workflows mode=COMMIT'
    'Numpad4'  = '$workflows mode=BUG.INV'
    'Numpad5'  = '$workflows mode=BUG.FIX'
    'Numpad6'  = '$workflows mode=DEBUG'
    'Numpad7'  = '$workflows mode=R.A.F.V'
    'Numpad8'  = '$workflows mode=REWORK'
    'Numpad9'  = '$workflows mode=RESEARCH.DEEP'
    'NumpadDot'  = '$workflows mode=CONSULT'
    '^Numpad1' = '.\scripts\switch-subagent-backend.ps1 -Backend native'
    '^Numpad2' = '.\scripts\switch-subagent-backend.ps1 -Backend deepseek'
    '^Numpad3' = '.\scripts\switch-subagent-continuation.ps1 -Continuation active_follow'
    '^Numpad4' = '.\scripts\switch-subagent-policy.ps1 -Policy balanced'
    '^Numpad5' = '.\scripts\switch-subagent-policy.ps1 -Policy aggressive'
    '^Numpad6' = '.\scripts\switch-subagent-policy.ps1 -Policy swarm'
    '^Numpad7' = '.\scripts\switch-subagent-strategy.ps1 -Strategy worker'
    '^Numpad8' = '.\scripts\switch-subagent-strategy.ps1 -Strategy critical'
    '^Numpad9' = '.\scripts\switch-subagent-continuation.ps1 -Continuation park_and_wake'
    '^Numpad0' = '.\scripts\switch-subagent-backend.ps1 -Status'
}

$promptBindings = @([regex]::Matches($promptPad, '(?m)^([^^;\r\n:]+|\^[^\r\n:]+)::PastePrompt\("([^\"]+)"\)'))
if ($promptBindings.Count -ne $expectedPromptMap.Count) {
    throw "Prompt pad does not contain exactly $($expectedPromptMap.Count) bindings: found $($promptBindings.Count)"
}

$foundBindings = @{}
foreach ($binding in $promptBindings) {
    $hotkey = $binding.Groups[1].Value.Trim()
    $command = $binding.Groups[2].Value.Trim()

    if (-not $expectedPromptMap.Contains($hotkey)) {
        throw "Prompt pad contains unauthorized hotkey binding: $hotkey"
    }
    $expectedCommand = $expectedPromptMap[$hotkey]
    if ($command -ne $expectedCommand) {
        throw "Prompt pad binding for $hotkey has unexpected command '$command' (expected '$expectedCommand')"
    }
    if ($foundBindings.ContainsKey($hotkey)) {
        throw "Prompt pad contains duplicate binding for hotkey: $hotkey"
    }
    $foundBindings[$hotkey] = $true
}

$allHotkeys = @([regex]::Matches($promptPad, '(?m)^([^;\r\n#{}]+)::'))
foreach ($hk in $allHotkeys) {
    $keyName = $hk.Groups[1].Value.Trim()
    if ($keyName -ne 'ScrollLock' -and -not $expectedPromptMap.Contains($keyName)) {
        throw "Prompt pad contains an unauthorized hotkey definition: $keyName"
    }
}

$promptPadLines = @($promptPad -split '\r?\n')
$braceDepth = 0
foreach ($line in $promptPadLines) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith(';') -or $trimmed -eq '') {
        continue
    }
    $openCount = ([regex]::Matches($trimmed, '\{')).Count
    $closeCount = ([regex]::Matches($trimmed, '\}')).Count
    $braceDepth += ($openCount - $closeCount)

    if ($braceDepth -le 0 -and $trimmed -match '^[A-Za-z0-9_]+\s*:?=') {
        throw "Prompt pad contains forbidden active state assignment outside functions: $trimmed"
    }
}

$promptPadWithoutStrategy = [regex]::Replace($promptPad, '(?i)-Strategy worker', '')
Assert-Forbidden -Label 'prompt pad' -Text $promptPadWithoutStrategy -Tokens @(
    'reader',
    'writer',
    'scout',
    'researcher',
    'reviewer',
    'worker'
)

$forbidden = @(
    (-join [char[]]@(111, 112, 101, 110, 99, 111, 100, 101)),
    (-join [char[]]@(114, 101, 108, 97, 121)),
    (-join [char[]]@(119, 97, 116, 99, 104, 101, 114))
)
foreach ($relativePath in @(git -C $repo ls-files)) {
    if ($relativePath -eq 'CHANGELOG.md' -or $relativePath -eq 'scripts/validate.ps1' -or $relativePath.StartsWith('.opencode/')) {
        continue
    }
    $path = Join-Path $repo $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($token in $forbidden) {
        # Forbidden watcher token is rejected across all surfaces, except specific canonical CBM skill files
        # where background daemon watchers are explicitly prohibited:
        # - skills/codebase-memory-mcp/SKILL.md
        # - skills/codebase-memory-mcp/references/scenarios.md
        $isPermittedWatcherSurface = (
            $relativePath -eq 'skills/codebase-memory-mcp/SKILL.md' -or
            $relativePath -eq 'skills/codebase-memory-mcp/references/scenarios.md' -or
            $relativePath.StartsWith('docs/free-mcps-') -or
            $relativePath.StartsWith('docs/superpowers/plans/2026-09-05-free-mcps-') -or
            $relativePath.StartsWith('scripts/tests/free-mcp') -or
            $relativePath -eq 'scripts/tests/swarm-doctor-contract.Tests.ps1'
        )
        if ($isPermittedWatcherSurface -and $relativePath -eq 'scripts/tests/swarm-doctor-contract.Tests.ps1') {
            continue
        }
        if ($token -eq (-join [char[]]@(119, 97, 116, 99, 104, 101, 114)) -and $isPermittedWatcherSurface) {
            continue
        }
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
    if ($state.PSObject.Properties.Name -contains 'codexBackend') {
        $installedBackendText = Read-RequiredText (Join-Path $codexHome 'config.toml')
        Assert-CodexBackendMatrix -Text $installedBackendText -Backend ([string]$state.codexBackend.selected) -BackendState $state.codexBackend | Out-Null
        Write-Host ("Installed backend matrix: {0}" -f [string]$state.codexBackend.selected)
    }

    $workflowsDest = Join-Path $agentsHome 'skills\workflows'
    $evidenceDest = Join-Path $agentsHome 'skills\evidence-first'
    $mcpDest = Join-Path $agentsHome 'skills\mcp-foundation'
    $codebaseMemoryDest = Join-Path $agentsHome 'skills\codebase-memory-mcp'
    $context7Dest = Join-Path $agentsHome 'skills\context7-mcp'

    $agWorkflows1 = Join-Path $antigravityHome 'antigravity\skills\workflows'
    $agEvidence1 = Join-Path $antigravityHome 'antigravity\skills\evidence-first'
    $agMcp1 = Join-Path $antigravityHome 'antigravity\skills\mcp-foundation'
    $agCodebaseMemory1 = Join-Path $antigravityHome 'antigravity\skills\codebase-memory-mcp'
    $agContext7_1 = Join-Path $antigravityHome 'antigravity\skills\context7-mcp'

    $agWorkflows2 = Join-Path $antigravityHome 'config\skills\workflows'
    $agEvidence2 = Join-Path $antigravityHome 'config\skills\evidence-first'
    $agMcp2 = Join-Path $antigravityHome 'config\skills\mcp-foundation'
    $agCodebaseMemory2 = Join-Path $antigravityHome 'config\skills\codebase-memory-mcp'
    $agContext7_2 = Join-Path $antigravityHome 'config\skills\context7-mcp'

    # DeepSeek restart-policy semantic assertions on all installed mcp-foundation skill & lifecycle mirrors (fail-closed on missing/unreadable)
    $installedSkillAgents = Read-RequiredText (Join-Path $mcpDest 'SKILL.md')
    $installedLifecycleAgents = Read-RequiredText (Join-Path (Join-Path $mcpDest 'references') 'lifecycle.md')
    Assert-DeepSeekDaemonRestartSkill -Label 'installed mcp-foundation SKILL.md (agents)' -Text $installedSkillAgents
    Assert-DeepSeekDaemonRestartLifecycle -Label 'installed mcp-foundation lifecycle.md (agents)' -Text $installedLifecycleAgents

    $installedSkillAg1 = Read-RequiredText (Join-Path $agMcp1 'SKILL.md')
    $installedLifecycleAg1 = Read-RequiredText (Join-Path (Join-Path $agMcp1 'references') 'lifecycle.md')
    Assert-DeepSeekDaemonRestartSkill -Label 'installed mcp-foundation SKILL.md (antigravity 1)' -Text $installedSkillAg1
    Assert-DeepSeekDaemonRestartLifecycle -Label 'installed mcp-foundation lifecycle.md (antigravity 1)' -Text $installedLifecycleAg1

    $installedSkillAg2 = Read-RequiredText (Join-Path $agMcp2 'SKILL.md')
    $installedLifecycleAg2 = Read-RequiredText (Join-Path (Join-Path $agMcp2 'references') 'lifecycle.md')
    Assert-DeepSeekDaemonRestartSkill -Label 'installed mcp-foundation SKILL.md (antigravity 2)' -Text $installedSkillAg2
    Assert-DeepSeekDaemonRestartLifecycle -Label 'installed mcp-foundation lifecycle.md (antigravity 2)' -Text $installedLifecycleAg2

    # Delivery review contract assertions on installed workflows delivery-review.md mirrors
    $installedDeliveryAgents = Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'delivery-review.md')
    $installedDeliveryAg1 = Read-RequiredText (Join-Path (Join-Path $agWorkflows1 'references') 'delivery-review.md')
    $installedDeliveryAg2 = Read-RequiredText (Join-Path (Join-Path $agWorkflows2 'references') 'delivery-review.md')
    Assert-DeliveryReviewContract -Label 'installed delivery-review.md (agents)' -Text $installedDeliveryAgents
    Assert-DeliveryReviewContract -Label 'installed delivery-review.md (antigravity 1)' -Text $installedDeliveryAg1
    Assert-DeliveryReviewContract -Label 'installed delivery-review.md (antigravity 2)' -Text $installedDeliveryAg2

    if ([string]$state.profile -eq 'safe') {
        Assert-NoManagedAgentsBlock -Path (Join-Path $codexHome 'config.toml')
        if (-not ($state.PSObject.Properties.Name -contains 'codexBackend')) {
            Assert-FeaturesMultiAgentDisabled -Path (Join-Path $codexHome 'config.toml')
        }

        $installedAgents = Read-RequiredText (Join-Path $codexHome 'AGENTS.md')
        Assert-OrchestrationPolicy -Label 'installed AGENTS.md' -Text $installedAgents
        Assert-DeepSeekDaemonRestartAgents -Label 'installed AGENTS.md' -Text $installedAgents
        Assert-McpTemplateRouting -Label 'installed AGENTS.md' -Text $installedAgents

        $expectedBackend = if ($state.PSObject.Properties.Name -contains 'codexBackend') { [string]$state.codexBackend.selected } else { 'deepseek' }
        $expectedPolicy = if ($state.PSObject.Properties.Name -contains 'codexDelegation') { [string]$state.codexDelegation.selected } else { 'balanced' }
        $expectedStrategy = if ($state.PSObject.Properties.Name -contains 'codexStrategy') { [string]$state.codexStrategy.selected } else { 'worker' }
        $expectedContinuation = if ($state.PSObject.Properties.Name -contains 'codexContinuation') { [string]$state.codexContinuation.selected } else { 'active_follow' }
        Assert-CodexAgentsRuntimeBlock -Text $installedAgents -Backend $expectedBackend -Policy $expectedPolicy -Strategy $expectedStrategy -Continuation $expectedContinuation

        $installedGemini = Read-RequiredText (Join-Path (Join-Path $antigravityHome 'config') 'GEMINI.md')
        Assert-DeepSeekDaemonRestartGemini -Label 'installed GEMINI.md' -Text $installedGemini
        Assert-McpTemplateRouting -Label 'installed GEMINI.md' -Text $installedGemini

        Assert-DeepSeekDaemonRestartPolicy -SkillText $installedSkillAgents -LifecycleText $installedLifecycleAgents -AgentsText $installedAgents -GeminiText $installedGemini -LabelPrefix 'installed (safe profile)'
        $installedValidation = if (Test-Path -LiteralPath (Join-Path (Join-Path $workflowsDest 'references') 'validation.md')) { Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'validation.md') } else { '' }
        $installedCommit = if (Test-Path -LiteralPath (Join-Path (Join-Path $workflowsDest 'references') 'commit.md')) { Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'commit.md') } else { '' }
        $installedQuality = if (Test-Path -LiteralPath (Join-Path (Join-Path $workflowsDest 'references') 'quality-ratchet.md')) { Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'quality-ratchet.md') } else { '' }
        $installedDelegation = if (Test-Path -LiteralPath (Join-Path (Join-Path $workflowsDest 'references') 'delegation.md')) { Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'delegation.md') } else { '' }
        Assert-DeliveryReviewPolicy -DeliveryReviewText $installedDeliveryAgents -SkillText (Read-RequiredText (Join-Path $workflowsDest 'SKILL.md')) -AgentsText $installedAgents -GeminiText $installedGemini -ValidationText $installedValidation -CommitText $installedCommit -QualityRatchetText $installedQuality -DelegationText $installedDelegation -ReadmeText $readmeText -LabelPrefix 'installed (safe profile)'
        Assert-AlinhamentoPolicy -AgentsText $installedAgents -GeminiText $installedGemini -SkillText (Read-RequiredText (Join-Path $workflowsDest 'SKILL.md')) -DelegationText (Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'delegation.md')) -ReadmeText $readmeText -LabelPrefix 'installed (safe profile)'
        Assert-CriticalStrategyPolicy -AgentsText $installedAgents -GeminiText $installedGemini -SkillText (Read-RequiredText (Join-Path $workflowsDest 'SKILL.md')) -DelegationText (Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'delegation.md')) -ReadmeText $readmeText -LabelPrefix 'installed (safe profile)'
        Assert-SubagentAutonomyPolicy -AgentsText $installedAgents -GeminiText $installedGemini -SkillText (Read-RequiredText (Join-Path $workflowsDest 'SKILL.md')) -DelegationText (Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'delegation.md')) -DeliveryReviewText $installedDeliveryAgents -ReadmeText $readmeText -LabelPrefix 'installed (safe profile)'
        Assert-AdaptiveSwarmPolicy -AgentsText $installedAgents -GeminiText $installedGemini -SkillText (Read-RequiredText (Join-Path $workflowsDest 'SKILL.md')) -DelegationText (Read-RequiredText (Join-Path (Join-Path $workflowsDest 'references') 'delegation.md')) -ReadmeText $readmeText -LabelPrefix 'installed (safe profile)'
    }

    Assert-MirrorTree -Source $workflowSource -Installed $workflowsDest -Label 'workflows skill (agents)' -CanonicalHelper $safePowerShellSource
    Assert-MirrorTree -Source $evidenceSource -Installed $evidenceDest -Label 'evidence skill (agents)'
    Assert-MirrorTree -Source $mcpSource -Installed $mcpDest -Label 'mcp-foundation skill (agents)'

    Assert-MirrorTree -Source $workflowSource -Installed $agWorkflows1 -Label 'workflows skill (antigravity 1)' -CanonicalHelper $safePowerShellSource
    Assert-MirrorTree -Source $evidenceSource -Installed $agEvidence1 -Label 'evidence skill (antigravity 1)'
    Assert-MirrorTree -Source $mcpSource -Installed $agMcp1 -Label 'mcp-foundation skill (antigravity 1)'

    Assert-MirrorTree -Source $workflowSource -Installed $agWorkflows2 -Label 'workflows skill (antigravity 2)' -CanonicalHelper $safePowerShellSource
    Assert-MirrorTree -Source $evidenceSource -Installed $agEvidence2 -Label 'evidence skill (antigravity 2)'
    Assert-MirrorTree -Source $mcpSource -Installed $agMcp2 -Label 'mcp-foundation skill (antigravity 2)'

    Assert-MirrorTree -Source $codebaseMemorySource -Installed $codebaseMemoryDest -Label 'codebase-memory-mcp skill (agents)'
    Assert-MirrorTree -Source $codebaseMemorySource -Installed $agCodebaseMemory1 -Label 'codebase-memory-mcp skill (antigravity 1)'
    Assert-MirrorTree -Source $codebaseMemorySource -Installed $agCodebaseMemory2 -Label 'codebase-memory-mcp skill (antigravity 2)'

    Assert-MirrorTree -Source $context7Source -Installed $context7Dest -Label 'context7-mcp skill (agents)'
    Assert-MirrorTree -Source $context7Source -Installed $agContext7_1 -Label 'context7-mcp skill (antigravity 1)'
    Assert-MirrorTree -Source $context7Source -Installed $agContext7_2 -Label 'context7-mcp skill (antigravity 2)'
}

if (-not $SkipGateTests) {
    & (Join-Path $repo 'scripts\test-safe-profile-gate.ps1')
}

Write-Host 'Validation OK.'
