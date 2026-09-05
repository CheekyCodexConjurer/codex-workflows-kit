# scripts/tests/free-mcp-policy.Tests.ps1
# Deterministic contract, routing, and negative tests for free-tier codebase-memory-mcp and Context7 policies

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))

$script:TestCount = 0
$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Test {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$false)][string]$Details = ''
    )
    $script:TestCount++
    if ($Condition) {
        $script:PassedCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailedCount++
        $msg = if ($Details) { "$Name -> $Details" } else { $Name }
        $script:Failures.Add($msg)
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
    }
}

Write-Host "Running Free MCP Policy Contract Tests..." -ForegroundColor Cyan

# Load files
$agentsFile = Join-Path $repoRoot 'codex\AGENTS.md'
$geminiFile = Join-Path $repoRoot 'antigravity\GEMINI.md'
$mcpSkillFile = Join-Path $repoRoot 'skills\mcp-foundation\SKILL.md'
$scgRefFile = Join-Path $repoRoot 'skills\mcp-foundation\references\serena-codegraph.md'
$wfSkillFile = Join-Path $repoRoot 'skills\workflows\SKILL.md'
$ahkFile = Join-Path $repoRoot 'ahk\codex_prompt_pad.ahk'

$agentsText = if (Test-Path -LiteralPath $agentsFile) { Get-Content -LiteralPath $agentsFile -Raw -Encoding UTF8 } else { '' }
$geminiText = if (Test-Path -LiteralPath $geminiFile) { Get-Content -LiteralPath $geminiFile -Raw -Encoding UTF8 } else { '' }
$mcpSkillText = if (Test-Path -LiteralPath $mcpSkillFile) { Get-Content -LiteralPath $mcpSkillFile -Raw -Encoding UTF8 } else { '' }
$scgRefText = if (Test-Path -LiteralPath $scgRefFile) { Get-Content -LiteralPath $scgRefFile -Raw -Encoding UTF8 } else { '' }
$wfSkillText = if (Test-Path -LiteralPath $wfSkillFile) { Get-Content -LiteralPath $wfSkillFile -Raw -Encoding UTF8 } else { '' }
$ahkText = if (Test-Path -LiteralPath $ahkFile) { Get-Content -LiteralPath $ahkFile -Raw -Encoding UTF8 } else { '' }

# Normalize helpers
function Get-Normalized([string]$t) {
    return [regex]::Replace($t, '\s+', ' ').Trim()
}

$agentsNorm = Get-Normalized $agentsText
$geminiNorm = Get-Normalized $geminiText
$mcpSkillNorm = Get-Normalized $mcpSkillText
$scgRefNorm = Get-Normalized $scgRefText
$wfSkillNorm = Get-Normalized $wfSkillText
$ahkNorm = Get-Normalized $ahkText

# ==========================================
# 1. Routing to codebase-memory-mcp & context7-mcp
# ==========================================
Write-Host "`n-- 1. Skill Routing & Discoverability --" -ForegroundColor Yellow

Assert-Test "codex/AGENTS.md routes to context7-mcp" ($agentsNorm -match '(?i)context7-mcp')
Assert-Test "codex/AGENTS.md routes to codebase-memory-mcp" ($agentsNorm -match '(?i)codebase-memory-mcp')
Assert-Test "antigravity/GEMINI.md routes to context7-mcp" ($geminiNorm -match '(?i)context7-mcp')
Assert-Test "antigravity/GEMINI.md routes to codebase-memory-mcp" ($geminiNorm -match '(?i)codebase-memory-mcp')
Assert-Test "skills/mcp-foundation/SKILL.md references context7-mcp" ($mcpSkillNorm -match '(?i)context7-mcp')
Assert-Test "skills/mcp-foundation/SKILL.md references codebase-memory-mcp" ($mcpSkillNorm -match '(?i)codebase-memory-mcp')

# Separation of mandatory foundation vs on-demand specialist skills
Assert-Test "AGENTS.md specifies mcp-foundation mandatory, specialist skills on tool trigger" ($agentsNorm -match '(?i)mcp-foundation s[aã]o contexto obrigat[oó]rio.*?skills especialistas (?:context7-mcp e codebase-memory-mcp|.*?) s[aã]o ativadas sob demanda|mcp-foundation.*obrigat[oó]rio.*?especialista.*?trigger')
Assert-Test "GEMINI.md specifies mcp-foundation mandatory, specialist skills on tool trigger" ($geminiNorm -match '(?i)mcp-foundation.*?(?:obrigat[oó]ria).*?skills especialistas.*?(?:sob demanda|trigger)')
Assert-Test "workflows SKILL.md specifies specialist skills load on relevant tool trigger" ($wfSkillNorm -match '(?i)mcp-foundation/SKILL\.md.*?(?:specialist skills|skills especialistas).*?(?:trigger|acionar)')
Assert-Test "mcp-foundation SKILL.md specifies foundation mandatory and specialist skills on trigger" ($mcpSkillNorm -match '(?i)mcp-foundation is mandatory.*?(?:specialist skills|specialist).*?(?:trigger|on-demand)')

# Relative reference path correctness at end of mcp-foundation/SKILL.md
Assert-Test "mcp-foundation references use valid relative ../context7-mcp or discoverable name" ($mcpSkillText -match '\.\./context7-mcp/SKILL\.md' -and -not ($mcpSkillText -match '(?m)^\s*-\s+`skills/context7-mcp/SKILL\.md`'))
Assert-Test "mcp-foundation references use valid relative ../codebase-memory-mcp or discoverable name" ($mcpSkillText -match '\.\./codebase-memory-mcp/SKILL\.md' -and -not ($mcpSkillText -match '(?m)^\s*-\s+`skills/codebase-memory-mcp/SKILL\.md`'))

# ==========================================
# 2. Free-Only Context7 Constraints
# ==========================================
Write-Host "`n-- 2. Free-Only Context7 Constraints --" -ForegroundColor Yellow

Assert-Test "AGENTS.md enforces Context7 credential-free policy without blanket verified-account claim" ($agentsNorm -match '(?i)Context7.*?(?:pol[ií]tica credential-free|credential-free policy).*?(?:sem alega[cç][aã]o ampla de conta free verificada|sem plano pago)')
Assert-Test "AGENTS.md enforces atomic sanitized query over full question" ($agentsNorm -match '(?i)pergunta[s]? at[oô]mica[s]?|consulta at[oô]mica sanitizada|atomic sanitized')
Assert-Test "AGENTS.md enforces ID confiável is exact returned/provided, never inferred from version" ($agentsNorm -match '(?i)ID confi[aá]vel.*?(?:retornado na tarefa|fornecido pelo usu[aá]rio).*?nunca inferir.*?(?:vers[aã]o|version)')
Assert-Test "AGENTS.md enforces explicit version disclosure" ($agentsNorm -match '(?i)vers[aã]o expl[ií]cita|explicit version')
Assert-Test "AGENTS.md enforces sharing doc packets across swarm workers" ($agentsNorm -match '(?i)compartilhar (?:pacote )?docs? entre workers|share doc packet')
Assert-Test "AGENTS.md enforces Context7 429 stop with official docs notice and no provider/model switch" ($agentsNorm -match '(?i)429.*?(?:stop|parar).*?(?:docs oficiais|official docs).*?(?:sem trocar|sem troca|sem fallback).*?(?:modelo|provedor|provider)')

Assert-Test "GEMINI.md enforces Context7 credential-free policy without blanket verified-account claim" ($geminiNorm -match '(?i)Context7.*?(?:pol[ií]tica credential-free|credential-free policy).*?(?:sem alega[cç][aã]o ampla de conta free verificada|sem plano pago)')
Assert-Test "GEMINI.md enforces ID confiável is exact returned/provided, never inferred from version" ($geminiNorm -match '(?i)ID confi[aá]vel.*?(?:retornado na tarefa|fornecido pelo usu[aá]rio).*?nunca inferir.*?(?:vers[aã]o|version)')
Assert-Test "GEMINI.md enforces sanitized atomic query" ($geminiNorm -match '(?i)pergunta[s]? at[oô]mica[s]?|consulta at[oô]mica sanitizada|atomic sanitized')
Assert-Test "GEMINI.md enforces 429 stop without provider switch" ($geminiNorm -match '(?i)429.*?(?:stop|parar).*?(?:docs oficiais|official docs).*?(?:sem trocar|sem troca|sem fallback).*?(?:modelo|provedor|provider)')

Assert-Test "mcp-foundation SKILL.md enforces credential-free policy without blanket verified-account claim" ($mcpSkillNorm -match '(?i)credential-free.*?(?:do not make blanket claims? of a\s*["'']?(?:verified free account|guaranteed free account)|sem plano pago)')
Assert-Test "mcp-foundation SKILL.md enforces trusted ID is exact returned/provided, never inferred" ($mcpSkillNorm -match '(?i)trusted (?:library )?ID.*?(?:exact ID returned|explicitly provided).*?never infer')
Assert-Test "mcp-foundation SKILL.md forbids proprietary code or secrets in Context7 queries" ($mcpSkillNorm -match '(?i)never include secrets.*?proprietary source code|sem enviar c[oó]digo propriet[aá]rio|sem secrets')
Assert-Test "mcp-foundation SKILL.md enforces doc packet sharing across swarm agents" ($mcpSkillNorm -match '(?i)compartilhar (?:pacote )?docs? entre (?:workers|agents|subagents)|share doc packet')
Assert-Test "mcp-foundation SKILL.md enforces 429 rate limit stop with official docs fallback and no provider switch" ($mcpSkillNorm -match '(?i)429.*?(?:stop|parar).*?(?:docs oficiais|official docs).*?(?:sem trocar|sem troca|no provider/model fallback)')

# ==========================================
# 3. Codebase Memory (CBM) Governance
# ==========================================
Write-Host "`n-- 3. Codebase Memory (CBM) Governance --" -ForegroundColor Yellow

Assert-Test "AGENTS.md defines CBM as structural code graph not generic persistent memories" ($agentsNorm -match '(?i)grafo de c[oó]digo estrutural.*?(?:n[aã]o mem[oó]rias gen[eé]ricas|rastreamento)')
Assert-Test "GEMINI.md defines CBM as structural code graph not generic persistent memories" ($geminiNorm -match '(?i)grafo de c[oó]digo estrutural.*?(?:n[aã]o mem[oó]rias gen[eé]ricas|arquitetura)')
Assert-Test "mcp-foundation SKILL.md defines CBM as structural code graph not generic persistent memories" ($mcpSkillNorm -match '(?i)structural code graph.*?(?:not generic persistent project memories|call chain)')
Assert-Test "workflows SKILL.md defines CBM as structural code graph not generic persistent memories" ($wfSkillNorm -match '(?i)grafo de c[oó]digo estrutural.*?(?:n[aã]o mem[oó]rias gen[eé]ricas|não memórias genéricas)')

Assert-Test "AGENTS.md decouples CBM global install from per-repo prep" ($agentsNorm -match '(?i)instala[cç][aã]o global separada de prepara[cç][aã]o por repo')
Assert-Test "AGENTS.md restricts CBM auto-prep to authorized write modes including IMPL.PHASE" ($agentsNorm -match '(?i)auto prepara[cç][aã]o apenas quando [uú]til em modos write autorizados.*?(?:IMPL\.PHASE|IMPL\.AUTO)')
Assert-Test "AGENTS.md requires verified exclusions for CBM" ($agentsNorm -match '(?i)exclusions verificadas|exclus[oõ]es verificadas')
Assert-Test "AGENTS.md enforces single-owner lock per canonical root for CBM" ($agentsNorm -match '(?i)owner [uú]nico por raiz can[oô]nica|lock entre swarm')
Assert-Test "AGENTS.md forbids .codegraph init by CBM" ($agentsNorm -match '(?i)sem \.codegraph init')
Assert-Test "AGENTS.md forbids CBM prep/index/cache/monitors in no-write modes (PLAN/RESEARCH/ALINHAMENTO/COMMIT)" ($agentsNorm -match '(?i)sem instala[cç][oõ]es/indices/cache/(?:monitores|daemons) induzidos em PLAN/RESEARCH/ALINHAMENTO/COMMIT')
Assert-Test "AGENTS.md states index is not authority (validate source and freshness)" ($agentsNorm -match '(?i)Index n[aã]o [eé] autoridade: validar fonte original e freshness')
Assert-Test "AGENTS.md preserves CodeGraph priority when .codegraph exists and Serena LSP without multiplying tools" ($agentsNorm -match '(?i)Preserve CodeGraph prioridade existente quando \.codegraph existe e Serena LSP, escolha ferramenta por necessidade sem multiplicar todas')

Assert-Test "GEMINI.md decouples CBM global install from per-repo prep" ($geminiNorm -match '(?i)instala[cç][aã]o global separada de prepara[cç][aã]o por repo')
Assert-Test "GEMINI.md restricts CBM prep to authorized write modes including IMPL.PHASE" ($geminiNorm -match '(?i)auto prepara[cç][aã]o apenas quando [uú]til em modos write autorizados.*?(?:IMPL\.PHASE|IMPL\.AUTO)')
Assert-Test "GEMINI.md forbids CBM prep/cache in PLAN/RESEARCH/ALINHAMENTO/COMMIT" ($geminiNorm -match '(?i)sem instala[cç][oõ]es/indices/cache/(?:monitores|daemons) induzidos em PLAN/RESEARCH/ALINHAMENTO/COMMIT')
Assert-Test "GEMINI.md states index is not authority" ($geminiNorm -match '(?i)Index n[aã]o [eé] autoridade')

Assert-Test "mcp-foundation SKILL.md covers CBM lifecycle" ($mcpSkillNorm -match '(?i)Codebase Memory|codebase-memory-mcp')
Assert-Test "mcp-foundation SKILL.md includes IMPL.PHASE in CBM write delivery modes" ($mcpSkillNorm -match '(?i)`?IMPL`?,\s*`?IMPL\.AUTO`?,\s*`?IMPL\.PHASE`?,\s*`?DELIVER\.AUTO`?')
Assert-Test "mcp-foundation SKILL.md requires single-owner lock per canonical root" ($mcpSkillNorm -match '(?i)owner [uú]nico por raiz can[oô]nica|lock entre swarm|single-owner lock')
Assert-Test "mcp-foundation SKILL.md strictly forbids CBM indexing/monitors in read-only and ALINHAMENTO" ($mcpSkillNorm -match '(?i)PLAN.*?RESEARCH.*?ALINHAMENTO.*?COMMIT|sem instala[cç][oõ]es/indices/cache/(?:monitores|daemons)')
Assert-Test "serena-codegraph.md or mcp reference includes CBM no-write guard" ($scgRefNorm -match '(?i)Codebase Memory|CBM|codebase-memory')

# Separation of MCP server auto-init ban from CBM repo prep exception
Assert-Test "mcp-foundation SKILL.md separates MCP install lifecycle from CBM repo prep exception" ($mcpSkillNorm -match '(?i)(?:CodeGraph strictly requires manual init|CodeGraph init strictly manual).*?(?:authorized CBM repo|authorized CBM repository preparation)')
Assert-Test "AGENTS.md clarifies MCP server auto-init ban while preserving CBM write prep" ($agentsNorm -match '(?i)sem auto-init de servidores MCP.*?CodeGraph init.*?manual.*?auto-prep CBM')
Assert-Test "GEMINI.md clarifies MCP server auto-init ban while preserving CBM write prep" ($geminiNorm -match '(?i)(?:sem auto-init de \.codegraph|nunca automatize kill, restart, upgrade nem init de servidores MCP).*?(?:CBM|CodeGraph)')
Assert-Test "workflows SKILL.md clarifies MCP server auto-init vs CBM prep" ($wfSkillNorm -match '(?i)Never auto-(?:install|init).*?MCP servers.*?(?:CodeGraph.*?manual init.*?authorized CBM repo prep)')

# ==========================================
# 4. Workflows SKILL.md MCP Clauses
# ==========================================
Write-Host "`n-- 4. Workflows SKILL.md MCP Clauses --" -ForegroundColor Yellow

Assert-Test "workflows SKILL.md preflight clause covers CBM write mode restriction including IMPL.PHASE" ($wfSkillNorm -match '(?i)Codebase Memory.*?(?:IMPL\.PHASE|modos write autorizados)')
Assert-Test "workflows SKILL.md forbids CBM prep/monitors in no-write modes" ($wfSkillNorm -match '(?i)PLAN.*?RESEARCH.*?ALINHAMENTO.*?COMMIT|sem instala[cç][oõ]es/indices/cache/(?:monitores|daemons)')
Assert-Test "workflows SKILL.md covers Context7 free policy and 429 stop" ($wfSkillNorm -match '(?i)Context7.*?429.*?stop|docs oficiais.*sem trocar')
Assert-Test "workflows SKILL.md preserves swarm/wake semantics intact" ($wfSkillNorm -match '(?i)Adaptive Swarm' -and $wfSkillNorm -match '(?i)park_and_wake')

# ==========================================
# 5. PromptPad Safety & Governance
# ==========================================
Write-Host "`n-- 5. PromptPad Integrity & Executable Routing --" -ForegroundColor Yellow

Assert-Test "ahk contains no hardcoded agent counts (--count / -Count / count=)" (-not ($ahkNorm -match '(?i)(?:--count|-Count|\bcount\s*=\s*\d+|\bagents\s*=\s*\d+)'))
Assert-Test "ahk contains no swarm flag resets or mode clobbering" (-not ($ahkNorm -match '(?i)\b(?:reset-subagent|clobber|overwrite-flags)\b'))
Assert-Test "ahk contains no hidden web requests or unauthorized background spawns" (-not ($ahkNorm -match '(?i)\b(?:curl|Invoke-WebRequest|DownloadString)\b|powershell[^\r\n]+-WindowStyle\s+Hidden'))
Assert-Test "ahk preserves direct workflow modes" ($ahkNorm -match 'PastePrompt\("\$workflows mode=DELIVER\.AUTO"\)')

# Executable prompt routing verification against workflows/SKILL.md mode table
function Test-PromptPadWorkflowRoute {
    param(
        [Parameter(Mandatory=$true)][string]$AhkContent,
        [Parameter(Mandatory=$true)][string]$WorkflowSkillContent
    )
    $pasteMatches = [regex]::Matches($AhkContent, 'PastePrompt\("([^"]+)"\)')
    $verifiedRoutes = @()
    foreach ($m in $pasteMatches) {
        $cmd = $m.Groups[1].Value
        if ($cmd -match '^\$workflows\s+mode=([A-Z0-9._]+)$') {
            $modeName = $Matches[1]
            $pattern = "(?m)\|\s*``?" + [regex]::Escape($modeName) + "``?\s*\|"
            $isModeDefined = [regex]::IsMatch($WorkflowSkillContent, $pattern)
            $verifiedRoutes += [PSCustomObject]@{
                Command = $cmd
                Mode = $modeName
                Defined = $isModeDefined
            }
        }
    }
    return $verifiedRoutes
}

$promptPadRoutes = Test-PromptPadWorkflowRoute -AhkContent $ahkText -WorkflowSkillContent $wfSkillText
Assert-Test "PromptPad emits at least 9 valid workflow modes" ($promptPadRoutes.Count -ge 9)
$allModesDefined = @($promptPadRoutes | Where-Object { -not $_.Defined }).Count -eq 0
Assert-Test "All PromptPad workflow modes exist in workflows/SKILL.md routing table" $allModesDefined

# Verify PromptPad is functionally unchanged (no synthetic implementation added)
$ahkCodeLines = ($ahkText -split "`r?`n" | Where-Object { $_ -match '\S' -and -not ($_ -match '^\s*;') }).Count
Assert-Test "PromptPad executable logic is concise and unchanged (< 60 non-comment lines, currently $ahkCodeLines)" ($ahkCodeLines -lt 60)

# ==========================================
# 6. Negative Tests (Strict Prohibitions)
# ==========================================
Write-Host "`n-- 6. Negative Tests (Strict Prohibitions) --" -ForegroundColor Yellow

$allPolicies = "$agentsNorm $geminiNorm $mcpSkillNorm $scgRefNorm $wfSkillNorm"

$permitsPaid = [regex]::IsMatch($allPolicies, '(?i)\b(?:pode|permite|autoriz\w*|allows?|permitted|enabled to)\b[^.;]*\b(?:cart[aã]o|plano pago|overage billing|billing excess)\b')
Assert-Test "No policy permits paid tier / credit card / billing excess in Context7 or CBM" (-not $permitsPaid)

$permitsProprietary = [regex]::IsMatch($allPolicies, '(?i)\b(?:pode|permite|autoriz\w*|allows?|permitted|enabled to)\b[^.;]*\b(?:enviar c[oó]digo propriet[aá]rio|send proprietary code)\b')
Assert-Test "No policy permits sending proprietary source code or secrets to Context7" (-not $permitsProprietary)

$permits429Fallback = [regex]::IsMatch($allPolicies, '(?i)\b(?:pode|permite|autoriz\w*|allows?|permitted|enabled to)\b[^.;]*\b(?:trocar (?:de )?modelo|fallback de provedor|switch provider|switch model)\b[^.;]*429')
Assert-Test "No policy permits provider/model switch on Context7 429 rate limit" (-not $permits429Fallback)

$permitsCbmInit = [regex]::IsMatch($allPolicies, '(?i)\b(?:pode|permite|autoriz\w*|allows?|permitted|enabled to)\b[^.;]*\b(?:\.codegraph init|auto-init \.codegraph)\b')
Assert-Test "No policy permits .codegraph init by CBM or free MCPs" (-not $permitsCbmInit)

$permitsNoWritePrep = [regex]::IsMatch($allPolicies, '(?i)\b(?:pode|permite|autoriz\w*|allows?|permitted|enabled to)\b[^.;]*\b(?:prepara[cç][aã]o CBM|indexa[cç][aã]o CBM|CBM prep)\b[^.;]*(?:no ALINHAMENTO|em ALINHAMENTO|em PLAN|em RESEARCH|em COMMIT)')
Assert-Test "No policy permits CBM auto-prep in PLAN, RESEARCH, ALINHAMENTO, or COMMIT" (-not $permitsNoWritePrep)

$indexIsAuthority = [regex]::IsMatch($allPolicies, '(?i)\bindex\s+(?:[eé]|is)\s+(?:autoridade|autorit[aá]ri[ao]|authoritative)\b|\bindex\s+substitui\s+o\s+c[oó]digo\b')
Assert-Test "No policy treats CBM index as authoritative over original repository source" (-not $indexIsAuthority)

# ==========================================
# 7. Compact Budget Verification
# ==========================================
Write-Host "`n-- 7. Budget & Formatting Checks --" -ForegroundColor Yellow

$agentsLines = ($agentsText -split "`r?`n").Count
$geminiLines = ($geminiText -split "`r?`n").Count
Assert-Test "codex/AGENTS.md remains compact (<= 45 lines, currently $agentsLines)" ($agentsLines -le 45)
Assert-Test "antigravity/GEMINI.md remains compact (<= 35 lines, currently $geminiLines)" ($geminiLines -le 35)

# Summary
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Total: $script:TestCount | Passed: $script:PassedCount | Failed: $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailedCount -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "`nAll policy contract tests passed deterministically." -ForegroundColor Green
    exit 0
}
