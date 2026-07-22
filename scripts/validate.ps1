$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$skill = Join-Path $repo 'skills\codex-workflows\SKILL.md'
$evidenceSkill = Join-Path $repo 'skills\evidence-first\SKILL.md'
$evidenceSkillInterface = Join-Path $repo 'skills\evidence-first\agents\openai.yaml'
$workflowSkillInterface = Join-Path $repo 'skills\codex-workflows\agents\openai.yaml'
$agentsMd = Join-Path $repo 'codex\AGENTS.md'
$marketplacePath = Join-Path $repo '.agents\plugins\marketplace.json'
$mcpPluginRoot = Join-Path $repo 'plugins\mcp-foundation'
$mcpPluginManifestPath = Join-Path $mcpPluginRoot '.codex-plugin\plugin.json'
$mcpManifestPath = Join-Path $mcpPluginRoot '.mcp.json'
$mcpHookPath = Join-Path $mcpPluginRoot 'hooks\hooks.json'
$mcpMaintenancePath = Join-Path $mcpPluginRoot 'scripts\maintain-mcps.ps1'
$ahk = Join-Path $repo 'ahk\codex_prompt_pad.ahk'
$ahkExe = 'E:\Programs\AHK\v2\AutoHotkey64.exe'

$skillText = Get-Content -Raw -Encoding UTF8 $skill
if ($skillText -notmatch "(?s)^---\s*\r?\nname:\s*codex-workflows\r?\ndescription:\s*.+?\r?\n---\s*\r?\n") {
    throw 'Invalid codex-workflows SKILL.md frontmatter.'
}

$evidenceSkillText = Get-Content -Raw -Encoding UTF8 $evidenceSkill
if ($evidenceSkillText -notmatch "(?s)^---\s*\r?\nname:\s*evidence-first\r?\ndescription:\s*.+?\r?\n---\s*\r?\n") {
    throw 'Invalid evidence-first SKILL.md frontmatter.'
}

if (!(Test-Path $evidenceSkillInterface)) {
    throw 'Missing evidence-first interface metadata.'
}

if (!(Test-Path $workflowSkillInterface)) {
    throw 'Missing codex-workflows interface metadata.'
}

foreach ($instruction in 'current, external, or high-impact factual claims','{claim, source, evidence, status}','Do not use model confidence or self-review alone as proof') {
    if ($evidenceSkillText -notmatch [regex]::Escape($instruction)) {
        throw "evidence-first is missing required instruction: $instruction"
    }
}

$agentsMdText = Get-Content -Raw -Encoding UTF8 $agentsMd
foreach ($instruction in 'Evidence & uncertainty:','`evidence-first`') {
    if ($agentsMdText -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing evidence-first routing: $instruction"
    }
}

foreach ($instruction in 'Observability: default to no new instrumentation.','allowlist/redact fields','bound volume','sink-enforced retention and access','disable/removal','fail-open unless an explicitly approved audit/compliance contract','collector, hook, exporter, or external endpoint') {
    if ($agentsMdText -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing observability guidance: $instruction"
    }
}

foreach ($instruction in 'Every read-only spawn must select the exact custom role','Custom-role spawns must omit `fork_context`, `model`, and `reasoning_effort`','never combine `fork_context=true` with `agent_type`','never fall back to `default`','any required read-only gate remains blocked') {
    if ($agentsMdText -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing read-only role-lock guidance: $instruction"
    }
}

foreach ($instruction in 'MCP foundation:','`codegraph`, `context7`, and `openaiDeveloperDocs`','never auto-install an MCP outside this list','24-hour TTL','repository indexing is the user''s decision') {
    if ($agentsMdText -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing MCP foundation guidance: $instruction"
    }
}

$marketplace = Get-Content -Raw -Encoding UTF8 $marketplacePath | ConvertFrom-Json
if ($marketplace.name -ne 'codex-workflows-local') {
    throw 'Repo marketplace must be named codex-workflows-local.'
}

$mcpMarketplaceEntries = @($marketplace.plugins | Where-Object { $_.name -eq 'mcp-foundation' })
if ($mcpMarketplaceEntries.Count -ne 1) {
    throw 'Repo marketplace must contain exactly one mcp-foundation entry.'
}

$mcpMarketplaceEntry = $mcpMarketplaceEntries[0]
if ($mcpMarketplaceEntry.source.source -ne 'local' -or $mcpMarketplaceEntry.source.path -ne './plugins/mcp-foundation') {
    throw 'mcp-foundation marketplace source is invalid.'
}

if ($mcpMarketplaceEntry.policy.installation -ne 'INSTALLED_BY_DEFAULT') {
    throw 'mcp-foundation must be installed by default.'
}

$mcpPluginManifest = Get-Content -Raw -Encoding UTF8 $mcpPluginManifestPath | ConvertFrom-Json
if ($mcpPluginManifest.name -ne 'mcp-foundation' -or $mcpPluginManifest.mcpServers -ne './.mcp.json') {
    throw 'Invalid mcp-foundation plugin manifest.'
}

if ($mcpPluginManifest.interface.PSObject.Properties.Name -notcontains 'defaultPrompt') {
    throw 'mcp-foundation must declare an empty starter-prompt list for schema compatibility.'
}

if (@($mcpPluginManifest.interface.defaultPrompt).Count -ne 0) {
    throw 'mcp-foundation must not define starter prompts.'
}

$mcpManifest = Get-Content -Raw -Encoding UTF8 $mcpManifestPath | ConvertFrom-Json
$mcpServerNames = @($mcpManifest.mcpServers.PSObject.Properties.Name)
$expectedMcpServerNames = @('codegraph','context7','openaiDeveloperDocs')
if (Compare-Object $mcpServerNames $expectedMcpServerNames) {
    throw "mcp-foundation MCP allowlist mismatch: $($mcpServerNames -join ', ')"
}

if ($mcpManifest.mcpServers.codegraph.command -ne 'codegraph') {
    throw 'CodeGraph MCP must use the maintained codegraph command.'
}

if ($mcpManifest.mcpServers.context7.url -ne 'https://mcp.context7.com/mcp') {
    throw 'Context7 MCP URL is invalid.'
}

if ($mcpManifest.mcpServers.openaiDeveloperDocs.url -ne 'https://developers.openai.com/mcp') {
    throw 'OpenAI Developer Docs MCP URL is invalid.'
}

$mcpHooks = Get-Content -Raw -Encoding UTF8 $mcpHookPath | ConvertFrom-Json
if (@($mcpHooks.hooks.SessionStart).Count -ne 1) {
    throw 'mcp-foundation must define one SessionStart audit hook.'
}

$mcpHookCommand = [string]$mcpHooks.hooks.SessionStart[0].hooks[0].command
foreach ($fragment in 'maintain-mcps.ps1','-Mode Audit','-MaxAgeHours 24','-Hook') {
    if ($mcpHookCommand -notmatch [regex]::Escape($fragment)) {
        throw "mcp-foundation hook is missing: $fragment"
    }
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $mcpMaintenancePath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "Invalid MCP maintenance PowerShell: $($parseErrors.Message -join '; ')"
}

foreach ($file in 'commit.md','dictionary.md','mode-matrix.md','observability.md','quality-ratchet.md','research.md','subagents.md','validation.md') {
    $path = Join-Path $repo "skills\codex-workflows\references\$file"
    if (!(Test-Path $path)) {
        throw "Missing reference: $file"
    }
}

foreach ($file in 'scout.toml','researcher.toml','reviewer.toml','worker.toml') {
    $path = Join-Path $repo "agents\$file"
    $text = Get-Content -Raw -Encoding UTF8 $path
    if ($text -notmatch 'name\s*=' -or $text -notmatch 'developer_instructions\s*=') {
        throw "Invalid agent profile: $file"
    }
}

Get-ChildItem -File (Join-Path $repo 'agents') -Filter '*.toml' | ForEach-Object {
    $text = Get-Content -Raw -Encoding UTF8 $_.FullName
    if ($text -notmatch '(?m)^model\s*=\s*"gpt-5\.6-sol"\s*$') {
        throw "Agent must use gpt-5.6-sol: $($_.Name)"
    }

    if ($text -notmatch '(?m)^model_reasoning_effort\s*=\s*"medium"\s*$') {
        throw "Base agent must use medium reasoning: $($_.Name)"
    }
}

$modelCatalogPath = 'C:\Users\mathe\.codex\super-app-manager\custom_model_catalog.json'
if (!(Test-Path $modelCatalogPath)) {
    throw "Missing Codex model catalog: $modelCatalogPath"
}

$modelCatalog = Get-Content -Raw -Encoding UTF8 $modelCatalogPath | ConvertFrom-Json
$modelSlugs = @($modelCatalog.models | ForEach-Object { [string]$_.slug })
if ($modelSlugs -notcontains 'gpt-5.6-sol') {
    throw 'Configured agent model is absent from the Codex model catalog: gpt-5.6-sol'
}

$solModel = @($modelCatalog.models | Where-Object { $_.slug -eq 'gpt-5.6-sol' })[0]
$supportedEfforts = @($solModel.supported_reasoning_levels | ForEach-Object { [string]$_.effort })
foreach ($effort in 'low', 'medium', 'high', 'xhigh', 'max') {
    if ($supportedEfforts -notcontains $effort) {
        throw "gpt-5.6-sol does not support required reasoning effort: $effort"
    }
}

$installerText = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'scripts\install.ps1')
foreach ($fragment in '$agentEfforts = @(''low'', ''high'', ''xhigh'', ''max'')', 'function Install-AgentEffortVariants', 'model_reasoning_effort = `"$effort`"') {
    if ($installerText -notmatch [regex]::Escape($fragment)) {
        throw "Agent installer is missing effort-variant support: $fragment"
    }
}

$dictionary = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\codex-workflows\references\dictionary.md')
$modeMatrix = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\codex-workflows\references\mode-matrix.md')
$qualityRatchet = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\codex-workflows\references\quality-ratchet.md')
$qualityRatchetNormalized = $qualityRatchet -replace '\s+', ' '
$observability = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills/codex-workflows/references/observability.md')
$observabilityNormalized = $observability -replace '\s+', ' '
$validationReference = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills/codex-workflows/references/validation.md')
$subagents = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\codex-workflows\references\subagents.md')
$commitReference = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\codex-workflows\references\commit.md')
$research = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\codex-workflows\references\research.md')
$researcher = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents\researcher.toml')
$worker = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents/worker.toml')
$reviewer = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents/reviewer.toml')
$workflowSkillInterfaceText = Get-Content -Raw -Encoding UTF8 $workflowSkillInterface
$ahkText = Get-Content -Raw -Encoding UTF8 $ahk
$readmeText = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'README.md')
$readmeTextNormalized = $readmeText -replace '\s+', ' '
$planSyncSkill = (($skillText -split '\r?\n' | Where-Object { $_ -match 'plan-sync' }) -join ' ')
$planSyncSkillSurface = $skillText
$planSyncAgents = (($agentsMdText -split '\r?\n' | Where-Object { $_ -match 'checklist synchronized' }) -join ' ')
$planSyncAgentsSurface = $agentsMdText
$planSyncReadmeMatch = [regex]::Match($readmeText, '(?ms)^## Sincronização do plano no Codex App\s.*?(?=^## |\z)')
if (!$planSyncReadmeMatch.Success) {
    throw 'README is missing the isolated plan-sync section.'
}
$planSyncReadmeNormalized = $planSyncReadmeMatch.Value -replace '\s+', ' '
$planSyncValidation = (($validationReference -split '\r?\n' | Where-Object { $_ -match 'Codex checklist' }) -join ' ')
$planSyncValidationSurface = $validationReference

foreach ($instruction in 'Treat `mode=<MODE>` as the complete default execution contract.','`references/quality-ratchet.md`: for every workflow mode','`references/observability.md`: for code-facing planning','never split for line count alone','`references/validation.md`: for every workflow mode','when mode is `PLAN.AUTO`') {
    if ($skillText -notmatch [regex]::Escape($instruction)) {
        throw "codex-workflows skill is missing mode-only internal routing: $instruction"
    }
}

 $dictionaryCadenceDefinitions = @($dictionary -split '\r?\n' | Where-Object { $_ -match '^\s*- `proportional-cadence`:' }).Count
 $allCadenceDefinitions = @(
    foreach ($surface in $dictionary, $skillText, $agentsMdText, $readmeText) {
        $surface -split '\r?\n' | Where-Object { $_ -match '^\s*- `proportional-cadence`:' }
    }
).Count
if ($dictionaryCadenceDefinitions -ne 1 -or $allCadenceDefinitions -ne 1) {
    throw 'proportional-cadence must have exactly one definition in the dictionary and no duplicate definition elsewhere.'
}

foreach ($instruction in '`proportional-cadence`','start with the smallest route that can answer the current question or prove the requested behavior','expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open','parallelize already-approved independent work only when it saves wall-clock time','before repeating a step that produced no new evidence','when one exists, take one materially different cheapest action','if no such action exists or it fails to produce progress or close a required gate','report blocked or use the mode''s replan path','finish at the current mode''s own done/clean gate','functional-gate','code delivery','defer unrelated work with `tn-defer`','never cancel active subA solely for slowness','keep a required subA wait as an explicit gate') {
    if ($dictionary -notmatch [regex]::Escape($instruction)) {
        throw "Dictionary is missing proportional-cadence guardrail: $instruction"
    }
}

foreach ($instruction in 'Apply `proportional-cadence` to every mode','start with the smallest route','expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open','parallelize approved independent work only when it saves wall-clock','checkpoint before repeating no-progress work','when a materially different cheapest action exists, take it once','take it once before using the mode''s own done, blocked, or replan outcome','scale validation by impact','do not impose fixed timeouts on active subagents') {
    if ($skillText -notmatch [regex]::Escape($instruction)) {
        throw "codex-workflows skill is missing proportional-cadence routing: $instruction"
    }
}

foreach ($instruction in 'Use proportional cadence:','start with the smallest route that can prove the request','expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open','parallelize approved independent work only when it saves wall-clock','checkpoint before repeating no-progress work','when a materially different cheapest action exists, take it once','before using the mode''s own done, blocked, or replan outcome','scale validation by impact') {
    if ($agentsMdText -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing proportional-cadence guidance: $instruction"
    }
}

foreach ($instruction in '## Cadência proporcional','menor caminho capaz de responder à dúvida ou provar o comportamento pedido','amplia escopo ou profundidade quando uma evidência existente ou um risco material revela incerteza, ou quando há um gate obrigatório ainda aberto','paraleliza trabalho independente já aprovado somente quando isso economiza tempo','quando houver uma,','tenta uma única ação diferente e mais barata','se ela falhar ou não existir','reporta bloqueio ou replaneja','Cada modo tem seu próprio critério de encerramento','Não há prazo fixo para interromper subagents ativos') {
    if ($readmeTextNormalized -notmatch [regex]::Escape($instruction)) {
        throw "README is missing proportional-cadence guidance: $instruction"
    }
}

$planSyncDefinitions = @($dictionary -split '\r?\n' | Where-Object { $_ -match '^\s*- `plan-sync`:' }).Count
if ($planSyncDefinitions -ne 1) {
    throw 'plan-sync must have exactly one canonical definition in the dictionary.'
}

$planSyncDefinition = @($dictionary -split '\r?\n' | Where-Object { $_ -match '^\s*- `plan-sync`:' })[0]

function Assert-NoPlanSyncContradiction {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Text
    )

    $normalized = ($Text -replace '\s+', ' ').Trim()
    foreach ($sentence in $normalized -split '[.;!?]') {
        $sentence = $sentence.Trim()
        if ([string]::IsNullOrWhiteSpace($sentence)) {
            continue
        }

        $mentionsSimpleWork = $sentence -match '(?i)(simple|one[- ]step|one[- ]phase|uma fase|uma etapa|tarefas simples|trabalho simples|de uma fase|de uma etapa)'
        $mentionsChecklist = $sentence -match '(?i)\b(checklist|check\s+list|lista(?:\s+de\s+passos)?)\b'
        $hasChecklistObligation = $sentence -match '(?i)\b(?:must|should|required|require|requires|need|needs|use|uses|keep|create|have|has|mandatory|obrigat\w*|deve\w*|precis\w*|receb\w*|usar|manten\w*|cri\w*|sempre|inclu\w*|given|provided|dado\w*)\b'
        $hasNeverSkip = $sentence -match '(?i)\bnever\s+skip\b'
        $exemptsSimpleChecklist = $sentence -match '(?i)(?:do not|does not|don''t|doesn''t)\s+(?:need|require|use)|need\s+not\s+(?:use|have|keep)|not\s+(?:required|needed)|without\s+(?:a\s+)?checklist|(?:não|nao)\s+(?:recebem|precisam|precisa)\b|sem\s+(?:uma\s+)?lista|skip it for (?:one[- ]step|simple)|skip (?:the )?plan-sync'
        $hasButContradiction = $sentence -match '(?i)(?:do not|does not|don''t|doesn''t|need\s+not|not\s+(?:required|needed))[^.;!?]{0,120}\b(?:but|mas)\b[^.;!?]{0,120}\b(?:must|should|required|require|requires|use|uses|deve\w*|precis\w*)\b[^.;!?]{0,80}\b(checklist|check\s+list|lista)\b'
        if ($mentionsSimpleWork -and $mentionsChecklist -and (($hasChecklistObligation -or $hasNeverSkip) -and (!$exemptsSimpleChecklist -or $hasButContradiction))) {
            throw "$Name contains a contradictory checklist requirement for simple work: $sentence"
        }

        foreach ($clause in $sentence -split '\bbut\b|\bmas\b') {
            $candidate = $clause.Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            $updatesEveryCommand = ($candidate -match '(?i)(?:update|updated|updates|updating|atualiz\w*)\b[^,]{0,120}(?:(?:after|before)\s+(?:every|each)\s+command|(?:depois|antes)\s+de\s+cada\s+comando)') -or ($candidate -match '(?i)(?:every|each)\s+command[^,]{0,80}(?:update|updated|updates|updating|atualiz\w*)\b') -or ($candidate -match '(?i)cada\s+comando[^,]{0,80}atualiz\w*\b')
            $hasCadenceNegation = $candidate -match '(?i)\b(?:never|do not|does not|don''t|doesn''t|not|não|nao)\b'
            if ($updatesEveryCommand -and !$hasCadenceNegation) {
                throw "$Name contains a contradictory per-command plan update: $candidate"
            }
        }
    }
}

$planSyncSurfaces = @(
    [pscustomobject]@{ Name = 'dictionary plan-sync'; Text = $planSyncDefinition }
    [pscustomobject]@{ Name = 'codex-workflows plan-sync'; Text = $planSyncSkillSurface }
    [pscustomobject]@{ Name = 'AGENTS.md plan-sync'; Text = $planSyncAgentsSurface }
    [pscustomobject]@{ Name = 'README plan-sync'; Text = $planSyncReadmeMatch.Value }
    [pscustomobject]@{ Name = 'validation plan-sync'; Text = $planSyncValidationSurface }
)
foreach ($surface in $planSyncSurfaces) {
    Assert-NoPlanSyncContradiction -Name $surface.Name -Text $surface.Text
}

$planSyncNegativeProbes = @(
    [pscustomobject]@{ Name = 'active after-every update'; Text = 'Update the checklist after every command.' }
    [pscustomobject]@{ Name = 'passive after-every update'; Text = 'The checklist must be updated after every command.' }
    [pscustomobject]@{ Name = 'active before-every update'; Text = 'Update the checklist before every command.' }
    [pscustomobject]@{ Name = 'passive before-each update'; Text = 'The checklist must be updated before each command.' }
    [pscustomobject]@{ Name = 'each-command update'; Text = 'Every command updates the checklist.' }
    [pscustomobject]@{ Name = 'but-joined update'; Text = 'Do not change files, but update the checklist after every command.' }
    [pscustomobject]@{ Name = 'never-skip simple checklist'; Text = 'Never skip the checklist for simple tasks.' }
    [pscustomobject]@{ Name = 'simple-task checklist'; Text = 'Simple tasks must use a checklist.' }
    [pscustomobject]@{ Name = 'but-joined simple checklist'; Text = 'Simple tasks do not need extra validation, but must use a checklist.' }
)
foreach ($probe in $planSyncNegativeProbes) {
    $contradictionDetected = $false
    try {
        Assert-NoPlanSyncContradiction -Name $probe.Name -Text $probe.Text
    } catch {
        $contradictionDetected = $true
    }
    if (!$contradictionDetected) {
        throw "Plan-sync contradiction probe was not rejected: $($probe.Name)"
    }
}

$planSyncAllowedProbes = @(
    [pscustomobject]@{ Name = 'negated per-command update'; Text = 'Never update the checklist after every command.' }
    [pscustomobject]@{ Name = 'simple-task exemption'; Text = 'One-step work does not need a checklist.' }
    [pscustomobject]@{ Name = 'generic plan language'; Text = 'Plan simple validation before implementation.' }
    [pscustomobject]@{ Name = 'descriptive checklist language'; Text = 'The checklist for simple tasks is described below.' }
)
foreach ($probe in $planSyncAllowedProbes) {
    try {
        Assert-NoPlanSyncContradiction -Name $probe.Name -Text $probe.Text
    } catch {
        throw "Plan-sync allowed probe was rejected: $($probe.Name)"
    }
}

foreach ($instruction in 'for nontrivial work with 2+ phases','create 2-5 short observable steps in `update_plan`','start the first as `in_progress` and the rest as `pending`','before the first command of the next phase','mark it `completed`','mark only the next phase `in_progress`','leave future phases `pending`','after proving the last phase','mark every step `completed`','leave none `in_progress`','update the checklist before continuing when scope changes','main agent owns the checklist','never update it after every command') {
    if ($planSyncDefinition -notmatch [regex]::Escape($instruction)) {
        throw "Dictionary is missing plan-sync contract: $instruction"
    }
}

foreach ($instruction in 'Apply `plan-sync` to nontrivial work with two or more phases','initialize the real `update_plan` checklist','first step `in_progress` and the rest `pending`','before the first command of the next phase','only after proof','current phase `completed`','next phase `in_progress`','future phases `pending`','update it before continuing after scope changes','after the last proof','every step `completed`','none `in_progress`','never update it after every command','single owner','Skip it for one-step or simple work') {
    if ($planSyncSkill -notmatch [regex]::Escape($instruction)) {
        throw "codex-workflows skill is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in '`update_plan`','For nontrivial work with two or more phases','2-5 short observable steps','start the first as `in_progress` and the rest as `pending`','before the first command of the next phase','only after proof','current phase `completed`','next phase `in_progress`','future phases `pending`','after the last proof','every step `completed`','no `in_progress`','before continuing after scope changes','never after every command','One-step or simple tasks do not need a checklist','subagents report to the main agent') {
    if ($planSyncAgents -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in '## Sincronização do plano no Codex App','update_plan','tarefas não triviais com duas ou mais fases','2 a 5 passos curtos','primeiro começa em andamento','demais ficam pendentes','Depois de comprovar uma fase e antes do primeiro comando da próxima','completed','in_progress','futuras como pendentes','Se o escopo mudar, atualiza o plano antes de continuar','Ao provar a última fase','todos os passos como concluídos','nenhum passo em andamento','Não atualiza a lista depois de cada comando','Tarefas simples ou de uma fase não recebem uma lista artificial') {
    if ($planSyncReadmeNormalized -notmatch [regex]::Escape($instruction)) {
        throw "README is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in 'with two or more phases','at the start, the first phase is `in_progress` and future phases are `pending`','before the first command of the next phase','previous phase is proven and `completed`','exactly one next phase is `in_progress`','future phases remain `pending`','after the last phase is proven','every phase is `completed` and none is `in_progress`','scope changes update the checklist before work continues','routine commands do not trigger updates','One-step or simple work does not need a checklist') {
    if ($planSyncValidation -notmatch [regex]::Escape($instruction)) {
        throw "Validation reference is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in 'AHK launchers paste only `$codex-workflows mode=<MODE>`','canonical default execution contract') {
    if ($modeMatrix -notmatch [regex]::Escape($instruction)) {
        throw "Mode matrix is missing the mode-only launcher contract: $instruction"
    }
}

if ($workflowSkillInterfaceText -notmatch '(?m)^\s*default_prompt:\s*"\$codex-workflows mode=PLAN\.AUTO"\s*$') {
    throw 'codex-workflows interface must use the minimal PLAN.AUTO prompt.'
}

if ($skillText -notmatch [regex]::Escape('references/research.md')) {
    throw 'RESEARCH.DEEP reference is not registered in SKILL.md.'
}

if ($skillText -notmatch [regex]::Escape('references/commit.md')) {
    throw 'COMMIT reference is not registered in SKILL.md.'
}

foreach ($alias in '`obs-gate`','`obs-contract`','`obs-lifecycle`','`obs-no-external`','`obs-output`') {
    if ($dictionary -notmatch [regex]::Escape($alias)) {
        throw "Dictionary is missing observability alias: $alias"
    }
}

foreach ($instruction in 'The default is no new log.','`obs-gate`','`obs-contract`','Allowlist small, structured fields.','Never emit secrets, credentials, raw prompts','State an event/byte cap or sampling rule.','uses a sink with an enforceable TTL.','actual access control for the sink','`off/removal` identifies the disable switch and removal owner/window','`failure-behavior` is `fail-open` by default.','Logging must not make the primary flow fail, block, retry, or persist state differently, unless an explicitly approved audit/compliance contract says otherwise.','No new collector, hook, exporter, external endpoint, or dependency') {
    if ($observabilityNormalized -notmatch [regex]::Escape($instruction)) {
        throw "Observability reference is missing required guardrail: $instruction"
    }
}

$obsContractSchema = '{question,event,correlation,allowed-fields,redaction,level,cap/sampling,sink+TTL,access,off/removal,failure-behavior,validation}'
foreach ($surface in @(
    @{ Name = 'Observability reference'; Text = $observability },
    @{ Name = 'Dictionary'; Text = $dictionary }
)) {
    if ($surface.Text -notmatch [regex]::Escape($obsContractSchema)) {
        throw "$($surface.Name) is missing the complete obs-contract schema."
    }
}

foreach ($instruction in 'retention/rotation and access are enforced','`fail-open` by default','`fail-closed` needs an explicitly approved audit/compliance contract') {
    if ($dictionary -notmatch [regex]::Escape($instruction)) {
        throw "Dictionary is missing observability lifecycle guardrail: $instruction"
    }
}

foreach ($instruction in '## Observability','No-edit modes record','`obs-contract`','Do not add a collector, hook, exporter') {
    if ($modeMatrix -notmatch [regex]::Escape($instruction)) {
        throw "Mode matrix is missing observability routing: $instruction"
    }
}

foreach ($instruction in 'unmanaged debug logs','obs-contract','canonical project path','field, cap, retention, access, removal, and failure-behavior constraints','fail-open by default','explicitly approved audit/compliance contract') {
    if ($worker -notmatch [regex]::Escape($instruction)) {
        throw "Worker is missing observability constraint: $instruction"
    }
}

foreach ($instruction in 'When observability is in scope','field controls, volume bound, sink access, retention, disable/removal path','failure-behavior: fail-open by default','explicitly approved audit/compliance contract') {
    if ($reviewer -notmatch [regex]::Escape($instruction)) {
        throw "Reviewer is missing observability lens: $instruction"
    }
}

foreach ($instruction in '## Observability','por padrão, não cria log.','pergunta diagnóstica','caminho já existente no projeto','campos seguros','limite de volume','retenção e acesso aplicados pelo destino','forma de desligar ou','remover e falha segura que não interrompe o fluxo principal','`contrato audit/compliance` explicitamente aprovado','coletor, hook, exportador ou serviço externo sem escopo explícito') {
    if ($readmeTextNormalized -notmatch [regex]::Escape($instruction)) {
        throw "README is missing observability guidance: $instruction"
    }
}

foreach ($instruction in 'field allowlist/redaction','volume cap or sampling','sink-enforced retention and access','disable/removal path','`failure-behavior`: fail-open by default, with fail-closed only under an explicitly approved audit/compliance contract') {
    if ($validationReference -notmatch [regex]::Escape($instruction)) {
        throw "Validation reference is missing observability guardrail: $instruction"
    }
}

foreach ($alias in '`tn-ratchet`','`tn-observe`','`tn-enforce`','`tn-verify`','`tn-audit`','`tn-none`','`tn-paydown-gate`','`tn-defer`','`quality-delta`') {
    if ($dictionary -notmatch [regex]::Escape($alias)) {
        throw "Dictionary is missing passive TN alias: $alias"
    }
}

if ($dictionary -notmatch [regex]::Escape('quality-obligations?')) {
    throw 'delivery-contract is missing optional quality-obligations.'
}

foreach ($instruction in 'Do not load the full remote TN skill during ordinary work','Treat line count as an inspection trigger, never a split instruction','execute at most one opportunistic bounded paydown unit per primary task unit','delegate to `tn-observe`','Read the complete file before splitting it.','Preserve behavior, public API, exports, schemas, ordering, and external contracts.','does not obscure or dominate the primary task.','prove the root cause first','Finish code-changing work with `quality-delta`') {
    if ($qualityRatchetNormalized -notmatch [regex]::Escape($instruction)) {
        throw "TN quality ratchet is missing a required guardrail: $instruction"
    }
}

$modeQualityProfiles = @(
    @{ Mode = 'PLAN.AUTO'; Profile = 'tn-observe' }
    @{ Mode = 'PLAN'; Profile = 'tn-observe' }
    @{ Mode = 'P.DEEP'; Profile = 'tn-observe' }
    @{ Mode = 'RESEARCH.DEEP'; Profile = 'tn-none' }
    @{ Mode = 'IMPL.AUTO'; Profile = 'tn-enforce' }
    @{ Mode = 'IMPL'; Profile = 'tn-enforce' }
    @{ Mode = 'IMPL.PHASE'; Profile = 'tn-enforce' }
    @{ Mode = 'DELIVER.AUTO'; Profile = 'tn-enforce' }
    @{ Mode = 'REVIEW'; Profile = 'tn-verify' }
    @{ Mode = 'COMMIT'; Profile = 'tn-verify' }
    @{ Mode = 'BUG.INV'; Profile = 'tn-observe' }
    @{ Mode = 'BUG.FIX'; Profile = 'tn-enforce' }
    @{ Mode = 'DEBUG'; Profile = 'tn-enforce' }
    @{ Mode = 'REWORK'; Profile = 'tn-observe' }
    @{ Mode = 'R.A.F.V'; Profile = 'tn-enforce' }
    @{ Mode = 'TN.SKILL'; Profile = 'tn-audit' }
)

foreach ($entry in $modeQualityProfiles) {
    $modeToken = '- `' + $entry.Mode + '`:'
    $profileToken = '`' + $entry.Profile + '`'
    $pattern = '(?m)^' + [regex]::Escape($modeToken) + '[^\r\n]*' + [regex]::Escape($profileToken)
    if ($modeMatrix -notmatch $pattern) {
        throw "Mode $($entry.Mode) is missing passive TN profile $($entry.Profile)."
    }
}

foreach ($instruction in 'carrying relevant `quality-obligations`','execute only approved `quality-obligations`','broad discoveries trigger `replan-gate`','never start feature or structural refactoring here','after the root cause is proven','validate the primary fix before optional paydown','use `tn-audit`','do not edit or split here') {
    if ($modeMatrix -notmatch [regex]::Escape($instruction)) {
        throw "Mode matrix is missing a passive TN routing guardrail: $instruction"
    }
}

if ($dictionary -notmatch [regex]::Escape('`RESEARCH.DEEP`')) {
    throw 'RESEARCH.DEEP is not registered in dictionary.md.'
}

foreach ($alias in '`academic=screen`','`literature`','`institutional`','`citations{inline|ledger}`','`source-ledger`','`citation-integrity`') {
    if ($dictionary -notmatch [regex]::Escape($alias)) {
        throw "Dictionary is missing research alias: $alias"
    }
}

if ($modeMatrix -notmatch [regex]::Escape('`RESEARCH.DEEP`')) {
    throw 'RESEARCH.DEEP is not registered in mode-matrix.md.'
}

if ($researcher -notmatch '(?m)^name\s*=\s*"researcher"\s*$') {
    throw 'Invalid researcher agent profile.'
}

if ($researcher -notmatch '(?m)^sandbox_mode\s*=\s*"read-only"\s*$') {
    throw 'Researcher agent must be read-only.'
}

foreach ($instruction in '`academic=screen`','report that result rather than padding the answer with weak or tangential papers.','never filter by country, top-level domain, or institution prestige.','Grade sources by relevance, directness, methodological quality, and review status.','Prefer a publication version of record over the equivalent preprint, not as a separate evidence class.','Label every preprint, including arXiv, as `preprint` unless publication status is verified.','A DOI is a persistent identifier, not proof of publication status.','Never infer methods or results beyond an `abstract-only` source.','Only `evidence` sources may support the recommendation.','`source-ledger`','`citation-integrity`','with inline `[S#]` citations','List `discovery` sources separately') {
    if ($research -notmatch [regex]::Escape($instruction)) {
        throw "RESEARCH.DEEP is missing academic research guidance: $instruction"
    }
}

foreach ($instruction in 'never rank evidence by country, top-level domain, or university prestige.','Grade academic sources by relevance, directness, methodology, and review status.','Prefer a publication version of record over its equivalent preprint','Label every preprint, including arXiv, as `preprint` unless publication status is verified.','A DOI alone does not prove publication status;','role (evidence, discovery, or excluded)','source ledger','Do not infer methods or results beyond an abstract-only source.','distinguish evidence from discovery-only material') {
    if ($researcher -notmatch [regex]::Escape($instruction)) {
        throw "Researcher agent is missing academic source guidance: $instruction"
    }
}

foreach ($instruction in 'Read-only. Do not edit files','assigned, non-overlapping research front') {
    if ($researcher -notmatch [regex]::Escape($instruction)) {
        throw "Researcher agent is missing required instruction: $instruction"
    }
}

$workflowBindings = @(
    @{ Key = 'Numpad1'; Shortcut = 'NUM1'; Prompt = '$codex-workflows mode=PLAN.AUTO'; Label = 'PLAN.AUTO' }
    @{ Key = 'Numpad2'; Shortcut = 'NUM2'; Prompt = '$codex-workflows mode=DELIVER.AUTO'; Label = 'DELIVER.AUTO' }
    @{ Key = 'Numpad0 & Numpad3'; Shortcut = 'NUM0+3'; Prompt = '$codex-workflows mode=RESEARCH.DEEP'; Label = 'RESEARCH.DEEP' }
    @{ Key = 'Numpad3'; Shortcut = 'NUM3'; Prompt = '$codex-workflows mode=COMMIT'; Label = 'COMMIT' }
    @{ Key = 'Numpad4'; Shortcut = 'NUM4'; Prompt = '$codex-workflows mode=BUG.INV'; Label = 'BUG.INV' }
    @{ Key = 'Numpad5'; Shortcut = 'NUM5'; Prompt = '$codex-workflows mode=BUG.FIX'; Label = 'BUG.FIX' }
    @{ Key = 'Numpad6'; Shortcut = 'NUM6'; Prompt = '$codex-workflows mode=DEBUG'; Label = 'DEBUG' }
    @{ Key = 'Numpad7'; Shortcut = 'NUM7'; Prompt = '$codex-workflows mode=REWORK'; Label = 'REWORK' }
    @{ Key = 'Numpad8'; Shortcut = 'NUM8'; Prompt = '$codex-workflows mode=R.A.F.V'; Label = 'R.A.F.V' }
    @{ Key = 'Numpad9'; Shortcut = 'NUM9'; Prompt = '$codex-workflows mode=TN.SKILL'; Label = 'TN.SKILL' }
)
$audiobookMapPrompt = '$audiobook-codex stage=MAP native-only source{PDF|EPUB} library-root{E:\Pessoal\e-books} output{book-map.json|assets-manifest.json} visual-fallback{pdf|computer} swarm{bounded}'
$audiobookTranscribePrompt = '$audiobook-codex stage=TRANSCRIBE native-only input{book-map.json|assets-manifest.json} output{text/source|epub-manifest.json} fidelity=strict ledger=required epub-profile{antique-paper}'
$audiobookRenderPrompt = '$audiobook-codex stage=RENDER native-only input{text/source|epub-manifest.json} output{text/locutor|audio|epub|publish-root} tts{chatterbox-pt-br} voice-profile{feminina-v1} locutor{line-delimited-v1|max=320} language=pt-BR epub-profile{antique-paper} epub-images{original|approved-restored} restoration=review-required'

$modifierBindings = @(
    @{ Key = 'Numpad0 & Numpad7'; Shortcut = 'NUM0+7'; Prompt = $audiobookMapPrompt; Label = 'audiobook MAP' }
    @{ Key = 'Numpad0 & Numpad8'; Shortcut = 'NUM0+8'; Prompt = $audiobookTranscribePrompt; Label = 'audiobook TRANSCRIBE' }
    @{ Key = 'Numpad0 & Numpad9'; Shortcut = 'NUM0+9'; Prompt = $audiobookRenderPrompt; Label = 'audiobook RENDER' }
)

foreach ($text in $skillText, $dictionary, $modeMatrix) {
    if ($text -notmatch [regex]::Escape('DELIVER.AUTO')) {
        throw 'DELIVER.AUTO is not registered across the workflow skill.'
    }
}

foreach ($alias in '`delivery-contract`','`preflight-subA`','`implementation-wave`','`integrated-freeze`','`review-batch`','`fix-batch`','`delta-closure`','`early-review-exception`','`review-fix-loop`','`finding-gate`','`clean-gate`','`replan-gate`') {
    if ($dictionary -notmatch [regex]::Escape($alias)) {
        throw "Dictionary is missing delivery alias: $alias"
    }
}

foreach ($instruction in 'phase validation does not spawn reviewers','do not spawn reviewers per phase, finding, or individual fix','repeat full reviewer lenses only after a material risk-surface change') {
    if ($modeMatrix -notmatch [regex]::Escape($instruction)) {
        throw "DELIVER.AUTO is missing implementation-first review guidance: $instruction"
    }
}

foreach ($instruction in '`subA-role-lock`','`subA-custom-spawn`','`subA-effort`','`subA-retry`','`subA-retry-block`','never use `default` or omit the role','Never combine `fork_context=true` with `agent_type`','omit `fork_context`, `model`, and `reasoning_effort`','one fresh retry with the same exact role','any required read-only gate remains blocked','`review-embargo`','`subA-reuse`','`fix-embargo`','one fresh read-only reviewer checks the correction delta') {
    if ($subagents -notmatch [regex]::Escape($instruction)) {
        throw "Subagent guidance is missing role-lock or delivery anti-spam instruction: $instruction"
    }
}

foreach ($alias in '`subA-role-lock`','`subA-custom-spawn`','`subA-effort`','`subA-same-role-retry`') {
    if ($dictionary -notmatch [regex]::Escape($alias)) {
        throw "Dictionary is missing read-only role-lock alias: $alias"
    }
}

foreach ($instruction in 'Every read-only spawn uses its exact custom role','omits `fork_context`, `model`, and `reasoning_effort`','never combine `fork_context=true` with `agent_type`','never a fallback to `default`','unavailable required reviewer leaves the review gate blocked') {
    if ($modeMatrix -notmatch [regex]::Escape($instruction)) {
        throw "DELIVER.AUTO is missing read-only retry/fallback guidance: $instruction"
    }
}

foreach ($alias in '`commit-map`','`commit-unit`','`commit-series`','`operator`','`commit-gate`','`push=current`') {
    if ($dictionary -notmatch [regex]::Escape($alias)) {
        throw "Dictionary is missing commit alias: $alias"
    }
}

if ($modeMatrix -notmatch [regex]::Escape('`DELIVER.AUTO`')) {
    throw 'DELIVER.AUTO is not registered in mode-matrix.md.'
}

if ($modeMatrix -notmatch [regex]::Escape('`COMMIT`')) {
    throw 'COMMIT is not registered in mode-matrix.md.'
}

foreach ($instruction in 'type(scope): imperative summary','Context: factual behavior and reason.','Validation: checks run and result.','Operator: Codex','Classify all staged, unstaged, and untracked candidate paths and content.','Block without changing the index when a staged candidate looks secret, generated, cache, or local.','existing ignore rule hides likely source, documentation, or configuration','Verify that `refs/heads/<current-branch>` already exists on the selected remote before any push.','Do not set upstream automatically.','Never use `--force`','Never reset, amend, rebase, or force-push to recover.') {
    if ($commitReference -notmatch [regex]::Escape($instruction)) {
        throw "Commit reference is missing required instruction: $instruction"
    }
}

foreach ($binding in $workflowBindings) {
    $bindingText = "$($binding.Key)::PastePrompt(`"$($binding.Prompt)`")"
    if ($ahkText -notmatch [regex]::Escape($bindingText)) {
        throw "Missing minimal $($binding.Label) binding."
    }

    $readmePattern = "(?m)^$([regex]::Escape($binding.Shortcut))\s+$([regex]::Escape($binding.Prompt))\s*$"
    if ($readmeText -notmatch $readmePattern) {
        throw "README is missing the minimal $($binding.Label) shortcut."
    }
}

$workflowPromptCount = [regex]::Matches($ahkText, [regex]::Escape('$codex-workflows mode=')).Count
if ($workflowPromptCount -ne $workflowBindings.Count) {
    throw "AHK must contain exactly $($workflowBindings.Count) minimal codex-workflows prompts; found $workflowPromptCount."
}

if ($ahkText -match '(?m)^Numpad0::') {
    throw 'Numpad0 must remain a modifier-only key.'
}

foreach ($binding in $modifierBindings) {
    $bindingText = "$($binding.Key)::PastePrompt(`"$($binding.Prompt)`")"
    if ($ahkText -notmatch [regex]::Escape($bindingText)) {
        throw "Missing $($binding.Label) modifier binding."
    }
}

foreach ($binding in $modifierBindings) {
    if ($readmeText -notmatch [regex]::Escape($binding.Shortcut)) {
        throw "README is missing the $($binding.Label) modifier shortcut."
    }
}

if (Test-Path $ahkExe) {
    & $ahkExe /ErrorStdOut /Validate $ahk
} else {
    Write-Warning "AHK executable not found: $ahkExe"
}

if (Get-Command codegraph -ErrorAction SilentlyContinue) {
    codegraph --version
} else {
    Write-Warning 'codegraph command not found.'
}

Write-Host 'Validation OK.'
