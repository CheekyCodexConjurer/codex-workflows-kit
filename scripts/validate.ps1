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
        [Parameter(Mandatory)][string[]]$Needles
    )

    foreach ($needle in $Needles) {
        if ($Text.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            throw "$Label is missing required text: $needle"
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
        '(?i)for every required job,? the parent must wait for a `?final response`? before `?synthesis or advancement`?',
        '(?i)while a job is `?running`?,? do not send an `?interruptive follow-up`? or `?replace`? it',
        '(?i)`?interrupted`?,? `?errored`?,? `?timed out`?,? or `?missing final response`? means unavailable: keep `?the gate`? `?open/BLOCKED`?; do not use a `?silent fallback`?',
        '(?i)(?:ap[o\u00f3]s timeout|aus[e\u00ea]ncia de fechamento|missing closure|timed? out).{0,120}(?:mesma trilha|same track)',
        '(?i)invent[a\u00e1]rio m[i\u00ed]nimo|minimal inventory',
        '(?i)closure slices pequenos|fatias pequenas de fechamento|small closure slices',
        '(?i)(?:proibid[oa]|nunca|never).{0,60}(?:repetir integralmente|repeat integrally|reabrir do zero)',
        '(?i)(?:proibid[oa]|nunca|never).{0,60}(?:abrir novo agente|open new agent|novo sub-agente)'
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
        '(?i)(?:synthesis|advancement|synthesize|advance|proceed|continue)[^.;]*(?:before|prior to|without|in the absence of)[^.;]*(?:final response|response|reply|answer|return)',
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
        '(?i)(?:m[a\u00e1]ximo|max).{0,30}(?:2|duas|two).{0,30}rodadas?',
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
        '(?i)sem ampliar autoridade|never broaden authority'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            throw "$Label is missing required delivery-review contract pattern: $pattern"
        }
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
        'múltiplos revisores independentes para o mesmo target'
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
        [string]$LabelPrefix = ''
    )

    $pfx = if ([string]::IsNullOrWhiteSpace($LabelPrefix)) { '' } else { "$LabelPrefix " }
    Assert-DeliveryReviewContract -Label "${pfx}delivery-review.md" -Text $DeliveryReviewText

    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($skillNorm, '(?i)operational proof|runtime proof|prova operacional')) {
        throw "${pfx}SKILL.md is missing operational proof gate pattern"
    }

    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($agentsNorm, '(?i)prova operacional|operational proof|runtime proof')) {
        throw "${pfx}codex AGENTS.md is missing operational proof gate pattern"
    }

    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($geminiNorm, '(?i)prova operacional|operational proof|runtime proof|delivery review')) {
        throw "${pfx}antigravity GEMINI.md is missing operational proof gate pattern"
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
        '(?i)wall-clock|wall time',
        '(?i)token offload|desonera[c\u00e7][a\u00e3]o de tokens',
        '(?i)deepseek_continue',
        '(?i)allow_respawn\s*=\s*true',
        '(?i)terminal result|resultado terminal',
        '(?i)aggressive.{0,80}(?:parent|orquestrador).{0,60}(?:arquiteto|decisor|integrador|gatekeeper|architect|decider|integrator|gatekeeper)',
        '(?i)pacote pequeno de evid[e\u00ea]ncia decis[o\u00f3]ria|decision evidence packet',
        '(?i)sem refazer bulk delegado|never redo delegated bulk|sem refazer trabalho delegado',
        '(?i)uma trilha persistente por frente coesa|trilha persistente por frente coesa|one persistent track per cohesive front',
        '(?i)sem microdelega[c\u00e7][a\u00e3]o|proibida microdelega[c\u00e7][a\u00e3]o|no microdelegation',
        '(?i)nova trilha apenas para deliverable independentemente aceit[a\u00e1]vel|new track only for independently acceptable deliverable',
        '(?i)instala[c\u00e7][a\u00e3]o global preserva/instala a flag selecionada como aggressive|global installation preserves/installs selected flag as aggressive',
        '(?i)n[a\u00e3]o injeta flags em repos consumidores|never inject flags into consumer repos|sem inje[c\u00e7][a\u00e3]o de flags em reposit[oó]rios consumidores'
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
        '(?i)\b(?:injetar flags em reposit[o\u00f3]rios|gravar flags no workspace do consumidor|inject flags into consumer repos)\b'
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
        '(?i)native.{0,180}gpt-5\.6-luna.{0,100}reasoning_effort.{0,80}normal/default',
        '(?i)deepseek.{0,120}deepseek_spawn.{0,100}deepseek_continue.{0,100}deepseek_follow',
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
        '(?i)deepseek_continue.{0,80}allow_respawn',
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
            Text = (New-TamperedText -Text $normalized -Old 'ledger' -New 'historico')
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
$agentsMd = Join-Path $repo 'codex\AGENTS.md'
$geminiTemplate = Join-Path $repo 'antigravity\GEMINI.md'
$skill = Read-RequiredText (Join-Path $workflowSource 'SKILL.md')
$delegationRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'delegation.md')
$deliveryReviewRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'delivery-review.md')
$validationRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'validation.md')
$commitRef = Read-RequiredText (Join-Path (Join-Path $workflowSource 'references') 'commit.md')
$designSpec = Read-RequiredText (Join-Path $repo 'docs\superpowers\specs\2026-08-26-workflow-rearchitecture-design.md')
$implPlan = Read-RequiredText (Join-Path $repo 'docs\superpowers\plans\2026-08-26-workflow-rearchitecture-implementation-plan.md')
$mcpSkill = Read-RequiredText (Join-Path $mcpSource 'SKILL.md')
$mcpLifecycle = Read-RequiredText (Join-Path (Join-Path $mcpSource 'references') 'lifecycle.md')
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
    'DEBUG', 'REWORK', 'R.A.F.V', 'TN.SKILL'
)
foreach ($mode in $allModes) {
    Assert-Contains -Label 'workflow skill' -Text $skill -Needles @($mode)
}

Assert-Contains -Label 'workflow skill' -Text $skill -Needles @(
    'name: workflows',
    'FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE',
    'deepseek_spawn',
    'deepseek_continue',
    'deepseek_follow',
    'deepseek_consult',
    'deepseek_abort',
    'deepseek_close',
    'deepseek_recover_result',
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

Assert-Forbidden -Label 'workflow skill' -Text $skill -Tokens @(
    'AGENTS.md',
    'subagents=',
    'sidecar',
    'read-only',
    'scout',
    'researcher',
    'writer',
    'reviewer',
    'worker',
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
    '$workflows',
    'SKILL.md',
    'Preserve',
    'DeepSeek',
    'MCP',
    'delega',
    'job',
    'visual_context',
    'deepseek_spawn',
    'deepseek_continue',
    'deepseek_follow',
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
$agentsLines = @(($agentsText -split '\r?\n') | Where-Object { $_.Trim() -ne '' })
if ($agentsLines.Count -gt 40) {
    throw "codex AGENTS.md exceeds the compact budget: $($agentsLines.Count) non-empty lines"
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
    { Assert-PlanContract -Label 'implementation plan' -Text $implPlan },
    { Assert-ReadmeContract -Label 'README.md' -Text $readmeText },
    { Assert-SecurityDocContract -Label 'docs/security.md' -Text $securityDoc },
    { Assert-OpenAiAgentContract -Label 'skills/workflows/agents/openai.yaml' -Text $openaiYaml },
    { Assert-InstallerOutputContract -Label 'scripts/install.ps1' -Text $installer },
    { Assert-DoctorOutputContract -Label 'scripts/doctor.ps1' -Text $doctorText },
    { Assert-SupersededSpecContract -Label 'docs/superpowers/specs/2026-08-19-promptpad-superpowers-compatibility-design.md' -Text $supersededSpec },
    { Assert-McpFoundationSkill -Label 'mcp-foundation skill' -Text $mcpSkill },
    { Assert-DeepSeekDaemonRestartPolicy -SkillText $mcpSkill -LifecycleText $mcpLifecycle -AgentsText $agentsText -GeminiText $geminiText },
    { Assert-DeliveryReviewPolicy -DeliveryReviewText $deliveryReviewRef -SkillText $skill -AgentsText $agentsText -GeminiText $geminiText },
    { Assert-McpTemplateRouting -Label 'codex AGENTS.md' -Text $agentsText },
    { Assert-McpTemplateRouting -Label 'antigravity GEMINI.md' -Text $geminiText }
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
foreach ($relativePath in @(git -C $repo ls-files)) {
    $path = Join-Path $repo $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8

    if ($relativePath -ne 'CHANGELOG.md' -and $relativePath -ne 'scripts/validate.ps1') {
        foreach ($token in $legacyTokens) {
            if (($relativePath -eq 'codex/AGENTS.md' -or $relativePath -eq 'skills/workflows/references/delivery-review.md') -and $token -in @('writer', 'reviewer', 'worker')) {
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
    '^Numpad1' = '.\scripts\switch-subagent-backend.ps1 -Backend native'
    '^Numpad2' = '.\scripts\switch-subagent-backend.ps1 -Backend deepseek'
    '^Numpad4' = '.\scripts\switch-subagent-policy.ps1 -Policy balanced'
    '^Numpad5' = '.\scripts\switch-subagent-policy.ps1 -Policy aggressive'
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

Assert-Forbidden -Label 'prompt pad' -Text $promptPad -Tokens @(
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
    if ($state.PSObject.Properties.Name -contains 'codexBackend') {
        $installedBackendText = Read-RequiredText (Join-Path $codexHome 'config.toml')
        Assert-CodexBackendMatrix -Text $installedBackendText -Backend ([string]$state.codexBackend.selected) -BackendState $state.codexBackend | Out-Null
        Write-Host ("Installed backend matrix: {0}" -f [string]$state.codexBackend.selected)
    }

    $workflowsDest = Join-Path $agentsHome 'skills\workflows'
    $evidenceDest = Join-Path $agentsHome 'skills\evidence-first'
    $mcpDest = Join-Path $agentsHome 'skills\mcp-foundation'
    $agWorkflows1 = Join-Path $antigravityHome 'antigravity\skills\workflows'
    $agEvidence1 = Join-Path $antigravityHome 'antigravity\skills\evidence-first'
    $agMcp1 = Join-Path $antigravityHome 'antigravity\skills\mcp-foundation'
    $agWorkflows2 = Join-Path $antigravityHome 'config\skills\workflows'
    $agEvidence2 = Join-Path $antigravityHome 'config\skills\evidence-first'
    $agMcp2 = Join-Path $antigravityHome 'config\skills\mcp-foundation'

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
        Assert-CodexAgentsRuntimeBlock -Text $installedAgents -Backend $expectedBackend -Policy $expectedPolicy

        $installedGemini = Read-RequiredText (Join-Path (Join-Path $antigravityHome 'config') 'GEMINI.md')
        Assert-DeepSeekDaemonRestartGemini -Label 'installed GEMINI.md' -Text $installedGemini
        Assert-McpTemplateRouting -Label 'installed GEMINI.md' -Text $installedGemini

        Assert-DeepSeekDaemonRestartPolicy -SkillText $installedSkillAgents -LifecycleText $installedLifecycleAgents -AgentsText $installedAgents -GeminiText $installedGemini -LabelPrefix 'installed (safe profile)'
        Assert-DeliveryReviewPolicy -DeliveryReviewText $installedDeliveryAgents -SkillText (Read-RequiredText (Join-Path $workflowsDest 'SKILL.md')) -AgentsText $installedAgents -GeminiText $installedGemini -LabelPrefix 'installed (safe profile)'
    }

    Assert-MirrorTree -Source $workflowSource -Installed $workflowsDest -Label 'workflows skill (agents)'
    Assert-MirrorTree -Source $evidenceSource -Installed $evidenceDest -Label 'evidence skill (agents)'
    Assert-MirrorTree -Source $mcpSource -Installed $mcpDest -Label 'mcp-foundation skill (agents)'

    Assert-MirrorTree -Source $workflowSource -Installed $agWorkflows1 -Label 'workflows skill (antigravity 1)'
    Assert-MirrorTree -Source $evidenceSource -Installed $agEvidence1 -Label 'evidence skill (antigravity 1)'
    Assert-MirrorTree -Source $mcpSource -Installed $agMcp1 -Label 'mcp-foundation skill (antigravity 1)'

    Assert-MirrorTree -Source $workflowSource -Installed $agWorkflows2 -Label 'workflows skill (antigravity 2)'
    Assert-MirrorTree -Source $evidenceSource -Installed $agEvidence2 -Label 'evidence skill (antigravity 2)'
    Assert-MirrorTree -Source $mcpSource -Installed $agMcp2 -Label 'mcp-foundation skill (antigravity 2)'
}

if (-not $SkipGateTests) {
    & (Join-Path $repo 'scripts\test-safe-profile-gate.ps1')
}

Write-Host 'Validation OK.'
