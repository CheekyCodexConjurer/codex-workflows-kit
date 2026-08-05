$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$codexHome = [IO.Path]::GetFullPath($defaultCodexHome)
$agentsHome = [IO.Path]::GetFullPath($defaultAgentsHome)
$skill = Join-Path $repo 'skills\workflows\SKILL.md'
$evidenceSkill = Join-Path $repo 'skills\evidence-first\SKILL.md'
$evidenceSkillInterface = Join-Path $repo 'skills\evidence-first\agents\openai.yaml'
$workflowSkillInterface = Join-Path $repo 'skills\workflows\agents\openai.yaml'
$agentsMd = Join-Path $repo 'codex\AGENTS.md'
$marketplacePath = Join-Path $repo '.agents\plugins\marketplace.json'
$mcpPluginRoot = Join-Path $repo 'plugins\mcp-foundation'
$mcpPluginManifestPath = Join-Path $mcpPluginRoot '.codex-plugin\plugin.json'
$mcpManifestPath = Join-Path $mcpPluginRoot '.mcp.json'
$mcpHookPath = Join-Path $mcpPluginRoot 'hooks\hooks.json'
$mcpMaintenancePath = Join-Path $mcpPluginRoot 'scripts\maintain-mcps.ps1'
$installScriptPath = Join-Path $repo 'scripts\install.ps1'
$doctorScriptPath = Join-Path $repo 'scripts\doctor.ps1'
$uninstallScriptPath = Join-Path $repo 'scripts\uninstall.ps1'
$workerWrapperPath = Join-Path $repo 'bin\opencode-worker.cmd'
$ahk = Join-Path $repo 'ahk\codex_prompt_pad.ahk'
$opencodeAgentsRoot = Join-Path $repo 'agents\opencode'
$ahkExe = if ($env:AUTOHOTKEY_EXE) {
    $env:AUTOHOTKEY_EXE
} else {
    $detectedAhk = Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue
    if ($detectedAhk) { $detectedAhk.Source } else { '__AHK_NOT_DETECTED__' }
}

$skillText = Get-Content -Raw -Encoding UTF8 $skill
$installScriptText = Get-Content -Raw -Encoding UTF8 $installScriptPath
foreach ($requiredPath in $doctorScriptPath, $uninstallScriptPath, $workerWrapperPath, (Join-Path $repo 'LICENSE'), (Join-Path $repo 'CONTRIBUTING.md'), (Join-Path $repo 'SECURITY.md'), (Join-Path $repo 'CHANGELOG.md'), (Join-Path $repo 'docs\architecture.md'), (Join-Path $repo 'docs\security.md'), (Join-Path $repo 'docs\agent-bootstrap-prompt.md')) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Public distribution artifact is missing: $requiredPath"
    }
}

foreach ($scriptPath in $installScriptPath, $doctorScriptPath, $uninstallScriptPath, $mcpMaintenancePath) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "Invalid PowerShell syntax in ${scriptPath}: $($parseErrors.Message -join '; ')"
    }
}
if ($skillText -notmatch "(?s)^---\s*\r?\nname:\s*workflows\r?\ndescription:\s*.+?\r?\n---\s*\r?\n") {
    throw 'Invalid workflows SKILL.md frontmatter.'
}

$evidenceSkillText = Get-Content -Raw -Encoding UTF8 $evidenceSkill
if ($evidenceSkillText -notmatch "(?s)^---\s*\r?\nname:\s*evidence-first\r?\ndescription:\s*.+?\r?\n---\s*\r?\n") {
    throw 'Invalid evidence-first SKILL.md frontmatter.'
}

if (!(Test-Path $evidenceSkillInterface)) {
    throw 'Missing evidence-first interface metadata.'
}

if (!(Test-Path $workflowSkillInterface)) {
    throw 'Missing workflows interface metadata.'
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

foreach ($file in 'backend-policy.md','commit.md','dictionary.md','mode-matrix.md','observability.md','quality-ratchet.md','research.md','runtime-adapters.md','subagents.md','validation.md') {
    $path = Join-Path $repo "skills\workflows\references\$file"
    if (!(Test-Path $path)) {
        throw "Missing reference: $file"
    }
}

foreach ($file in 'relay.toml','scout.toml','researcher.toml','reviewer.toml','worker.toml') {
    $path = Join-Path $repo "agents\$file"
    $text = Get-Content -Raw -Encoding UTF8 $path
    if ($text -notmatch 'name\s*=' -or $text -notmatch 'developer_instructions\s*=') {
        throw "Invalid agent profile: $file"
    }
}

$opencodeReaderAgentFiles = @('scout.md', 'researcher.md', 'reviewer.md')
$opencodeWriterAgentFiles = @('worker.md')
$opencodeAgentFiles = @($opencodeReaderAgentFiles + $opencodeWriterAgentFiles)
foreach ($file in $opencodeReaderAgentFiles) {
    $path = Join-Path $opencodeAgentsRoot $file
    if (!(Test-Path $path)) {
        throw "Missing OpenCode agent definition: $file"
    }

    $text = Get-Content -Raw -Encoding UTF8 $path
    foreach ($fragment in 'mode: subagent', 'edit: deny', 'bash: deny', 'task: allow', 'external_directory: allow', 'question: deny', 'skill: deny', 'todowrite: deny', 'lsp: deny') {
        if ($text -notmatch [regex]::Escape($fragment)) {
            throw "OpenCode agent $file is missing nested-read-only guardrail: $fragment"
        }
    }
}

foreach ($file in @('scout.md', 'reviewer.md')) {
    $path = Join-Path $opencodeAgentsRoot $file
    $text = Get-Content -Raw -Encoding UTF8 $path
    foreach ($fragment in 'webfetch: deny', 'websearch: deny') {
        if ($text -notmatch [regex]::Escape($fragment)) {
            throw "OpenCode reader $file is missing side-effect channel guardrail: $fragment"
        }
    }
}

foreach ($file in $opencodeWriterAgentFiles) {
    $path = Join-Path $opencodeAgentsRoot $file
    if (!(Test-Path $path)) {
        throw "Missing OpenCode writer definition: $file"
    }

    $text = Get-Content -Raw -Encoding UTF8 $path
    foreach ($fragment in 'mode: subagent', 'edit: allow', 'bash: deny', 'task: deny', 'external_directory: deny', 'webfetch: deny', 'websearch: deny', 'question: deny', 'skill: deny', 'todowrite: deny', 'lsp: deny', 'claim-map', 'isolated worktree') {
        if ($text -notmatch [regex]::Escape($fragment)) {
            throw "OpenCode writer $file is missing writer guardrail: $fragment"
        }
    }
}

$unexpectedOpenCodeAgents = @(Get-ChildItem -File $opencodeAgentsRoot -Filter '*.md' | Where-Object { $opencodeAgentFiles -notcontains $_.Name })
if ($unexpectedOpenCodeAgents.Count -gt 0) {
    throw "Unexpected OpenCode agent definitions: $($unexpectedOpenCodeAgents.Name -join ', ')"
}

Get-ChildItem -File (Join-Path $repo 'agents') -Filter '*.toml' | ForEach-Object {
    $text = Get-Content -Raw -Encoding UTF8 $_.FullName
    if ($text -notmatch '(?m)^model\s*=\s*"gpt-5\.4-mini"\s*$') {
        throw "Agent must use gpt-5.4-mini: $($_.Name)"
    }

    $expectedEffort = if ($_.Name -eq 'relay.toml') { 'high' } else { 'xhigh' }
    $effortPattern = '(?m)^model_reasoning_effort\s*=\s*"' + [regex]::Escape($expectedEffort) + '"\s*$'
    if ($text -notmatch $effortPattern) {
        throw "Base agent must use $expectedEffort reasoning: $($_.Name)"
    }
}

$modelCatalogPath = if ($env:CODEX_MODEL_CATALOG) { $env:CODEX_MODEL_CATALOG } else { Join-Path $codexHome 'super-app-manager\custom_model_catalog.json' }
if (Test-Path $modelCatalogPath) {
    $modelCatalog = Get-Content -Raw -Encoding UTF8 $modelCatalogPath | ConvertFrom-Json
    $modelSlugs = @($modelCatalog.models | ForEach-Object { [string]$_.slug })
    if ($modelSlugs -notcontains 'gpt-5.4-mini') {
        throw 'Configured agent model is absent from the Codex model catalog: gpt-5.4-mini'
    }

    $miniModel = @($modelCatalog.models | Where-Object { $_.slug -eq 'gpt-5.4-mini' })[0]
    $supportedEfforts = @($miniModel.supported_reasoning_levels | ForEach-Object { [string]$_.effort })
    foreach ($effort in 'high', 'xhigh') {
        if ($supportedEfforts -notcontains $effort) {
            throw "gpt-5.4-mini does not support required reasoning effort: $effort"
        }
    }
}

$installerText = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'scripts\install.ps1')
foreach ($fragment in '$agentEfforts = @(''low'', ''high'', ''xhigh'', ''max'')', 'function Install-AgentProfile', 'model_reasoning_effort = `"$effort`"', 'SupportsShouldProcess', 'function Install-ManagedContent', 'function Save-InstallState') {
    if ($installerText -notmatch [regex]::Escape($fragment)) {
        throw "Agent installer is missing effort-variant support: $fragment"
    }
}

foreach ($fragment in 'opencodeAgentsSource', 'opencodeAgentsDest', 'opencode-agents', 'Copy-ManagedTree -Source $opencodeAgentsSource', 'bin\opencode-worker.cmd', '$Profile', '$ConfigureMcp', '$InstallAhk') {
    if ($installerText -notmatch [regex]::Escape($fragment)) {
        throw "Agent installer is missing OpenCode agent synchronization: $fragment"
    }
}
if ($installerText -match '(?i)opencodeHybrid|opencode-hybrid|opencode_hybrid_worker|HYBRID_ROUTE') {
    throw 'Agent installer still contains removed hybrid synchronization or routing.'
}

$dictionary = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\workflows\references\dictionary.md')
$dictionaryNormalized = $dictionary -replace '\s+', ' '
$modeMatrix = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\workflows\references\mode-matrix.md')
$modeMatrixNormalized = $modeMatrix -replace '\s+', ' '
$qualityRatchet = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\workflows\references\quality-ratchet.md')
$qualityRatchetNormalized = $qualityRatchet -replace '\s+', ' '
$observability = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills/workflows/references/observability.md')
$observabilityNormalized = $observability -replace '\s+', ' '
$backendPolicy = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills/workflows/references/backend-policy.md')
$runtimeAdapters = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills/workflows/references/runtime-adapters.md')
$validationReference = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills/workflows/references/validation.md')
$subagents = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\workflows\references\subagents.md')
$commitReference = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\workflows\references\commit.md')
$research = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'skills\workflows\references\research.md')
$scout = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents\scout.toml')
$researcher = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents\researcher.toml')
$relay = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents\relay.toml')
$relayNormalized = $relay -replace '\s+', ' '
$worker = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents/worker.toml')
$reviewer = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'agents/reviewer.toml')
$opencodeWorker = Get-Content -Raw -Encoding UTF8 (Join-Path $opencodeAgentsRoot 'worker.md')
$workflowSkillInterfaceText = Get-Content -Raw -Encoding UTF8 $workflowSkillInterface
$ahkText = Get-Content -Raw -Encoding UTF8 $ahk
$readmeText = Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'README.md')
$readmeTextNormalized = $readmeText -replace '\s+', ' '
$publicDocsText = @(Get-ChildItem -LiteralPath (Join-Path $repo 'docs') -Filter '*.md' -File | ForEach-Object {
    Get-Content -Raw -Encoding UTF8 $_.FullName
})
$distributionText = @('CHANGELOG.md', 'SECURITY.md', 'CONTRIBUTING.md', 'LICENSE', 'bin\opencode-worker.cmd') | ForEach-Object {
    Get-Content -Raw -Encoding UTF8 (Join-Path $repo $_)
}
$portableSurfaces = @(
    @{ Name = 'README'; Text = $readmeText }
    @{ Name = 'public docs'; Text = $publicDocsText }
    @{ Name = 'distribution docs'; Text = $distributionText }
    @{ Name = 'AGENTS.md'; Text = $agentsMdText }
    @{ Name = 'relay'; Text = $relay }
    @{ Name = 'backend policy'; Text = $backendPolicy }
    @{ Name = 'validation reference'; Text = $validationReference }
    @{ Name = 'AHK'; Text = $ahkText }
)
foreach ($surface in $portableSurfaces) {
    if ($surface.Text -match '(?i)C:\\Users\\|[A-Z]:\\Repositories\\|[A-Z]:\\Pessoal\\|[A-Z]:\\Programs\\AHK|2026-07-01') {
        throw "$($surface.Name) contains a machine-specific path or dated destination."
    }
}
$skillTextNormalized = $skillText -replace '\s+', ' '
$runtimeAdaptersNormalized = $runtimeAdapters -replace '\s+', ' '
$opencodeNativeProfiles = @($relay, $scout, $researcher, $reviewer, $worker)
$planSyncSkill = (($skillText -split '\r?\n' | Where-Object { $_ -match 'plan-sync' }) -join ' ')
$planSyncSkillSurface = $skillText
$planSyncAgents = (($agentsMdText -split '\r?\n' | Where-Object { $_ -match 'checklist synchronized' }) -join ' ')
$planSyncAgentsSurface = $agentsMdText
$planSyncReadmeMatch = [regex]::Match($readmeText, '(?ms)^## Sincroniza.+?o do plano no Codex App\s.*?(?=^## |\z)')
if (!$planSyncReadmeMatch.Success) {
    throw 'README is missing the isolated plan-sync section.'
}
$planSyncReadmeNormalized = $planSyncReadmeMatch.Value -replace '\s+', ' '
$planSyncValidation = (($validationReference -split '\r?\n' | Where-Object { $_ -match 'Codex checklist' }) -join ' ')
$planSyncValidationSurface = $validationReference

foreach ($instruction in 'Treat `mode=<MODE>` as the complete default execution contract.','`references/quality-ratchet.md`: for every workflow mode','`references/observability.md`: for code-facing planning','never split for line count alone','`references/validation.md`: for every workflow mode','when mode is `PLAN.AUTO`') {
    if ($skillText -notmatch [regex]::Escape($instruction)) {
        throw "workflows skill is missing mode-only internal routing: $instruction"
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
        throw "workflows skill is missing proportional-cadence routing: $instruction"
    }
}

foreach ($instruction in 'Use proportional cadence:','start with the smallest route that can prove the request','expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open','parallelize approved independent work only when it saves wall-clock','checkpoint before repeating no-progress work','when a materially different cheapest action exists, take it once','before using the mode''s own done, blocked, or replan outcome','scale validation by impact') {
    if ($agentsMdText -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing proportional-cadence guidance: $instruction"
    }
}

foreach ($instruction in '## Cad.+?ncia proporcional','menor caminho capaz de responder . d.vida ou provar o comportamento pedido','amplia escopo ou profundidade quando uma evid.ncia existente ou um risco material revela incerteza, ou quando h. um gate obrigat.rio ainda aberto','paraleliza trabalho independente j. aprovado somente quando isso economiza tempo','quando houver uma,','tenta uma .nica a..o diferente e mais barata','se ela falhar ou n.o existir','reporta bloqueio ou replaneja','Cada modo tem seu pr.prio crit.rio de encerramento','N.o h. prazo fixo para interromper subagents ativos') {
    if ($readmeTextNormalized -notmatch $instruction) {
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
        $exemptsSimpleChecklist = $sentence -match '(?i)(?:do not|does not|don''t|doesn''t)\s+(?:need|require|use)|need\s+not\s+(?:use|have|keep)|not\s+(?:required|needed)|without\s+(?:a\s+)?checklist|n.o\s+(?:recebem|precisam|precisa)\b|sem\s+(?:uma\s+)?lista|skip it for (?:one[- ]step|simple)|skip (?:the )?plan-sync'
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
            $hasCadenceNegation = $candidate -match '(?i)\b(?:never|do not|does not|don''t|doesn''t|not|n.o)\b'
            if ($updatesEveryCommand -and !$hasCadenceNegation) {
                throw "$Name contains a contradictory per-command plan update: $candidate"
            }
        }
    }
}

$planSyncSurfaces = @(
    [pscustomobject]@{ Name = 'dictionary plan-sync'; Text = $planSyncDefinition }
    [pscustomobject]@{ Name = 'workflows plan-sync'; Text = $planSyncSkillSurface }
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
        throw "workflows skill is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in '`update_plan`','For nontrivial work with two or more phases','2-5 short observable steps','start the first as `in_progress` and the rest as `pending`','before the first command of the next phase','only after proof','current phase `completed`','next phase `in_progress`','future phases `pending`','after the last proof','every step `completed`','no `in_progress`','before continuing after scope changes','never after every command','One-step or simple tasks do not need a checklist','subagents report to the main agent') {
    if ($planSyncAgents -notmatch [regex]::Escape($instruction)) {
        throw "AGENTS.md is missing plan-sync guidance: $instruction"
    }
}

foreach ($surface in @(
    @{ Name = 'workflows skill'; Text = $skillText }
    @{ Name = 'dictionary'; Text = $dictionary }
    @{ Name = 'mode matrix'; Text = $modeMatrix }
    @{ Name = 'subagents reference'; Text = $subagents }
    @{ Name = 'validation reference'; Text = $validationReference }
    @{ Name = 'AGENTS.md'; Text = $agentsMdText }
    @{ Name = 'README'; Text = $readmeText }
)) {
    if ($surface.Text -notmatch [regex]::Escape('internal_subagent_backend=opencode')) {
        throw "$($surface.Name) is missing the internal OpenCode backend policy."
    }
}

foreach ($surface in @(
    @{ Name = 'workflows skill'; Text = $skillText }
    @{ Name = 'dictionary'; Text = $dictionary }
    @{ Name = 'mode matrix'; Text = $modeMatrix }
    @{ Name = 'subagents reference'; Text = $subagents }
    @{ Name = 'validation reference'; Text = $validationReference }
    @{ Name = 'backend policy'; Text = $backendPolicy }
    @{ Name = 'AGENTS.md'; Text = $agentsMdText }
    @{ Name = 'README'; Text = $readmeText }
    @{ Name = 'relay'; Text = $relay }
    @{ Name = 'OpenCode worker'; Text = $opencodeWorker }
    @{ Name = 'installer'; Text = $installScriptText }
)) {
    if ($surface.Text -match '(?i)opencode_hybrid_worker|opencode-hybrid|hybrid=canary|hybrid=off|HYBRID_ROUTE=writer|HYBRID_WORKTREE|HYBRID_MAIN_CHECKOUT|HYBRID_BASELINE|safe-edit') {
        throw "$($surface.Name) still contains removed hybrid/writer routing."
    }
}

foreach ($surface in @(
    @{ Name = 'workflows skill'; Text = $skillText }
    @{ Name = 'backend policy'; Text = $backendPolicy }
    @{ Name = 'subagents reference'; Text = $subagents }
    @{ Name = 'AGENTS.md'; Text = $agentsMdText }
)) {
    foreach ($instruction in 'multi_agent_v1__spawn_agent','agent_type=relay','{target_agent,cwd,task}') {
        if ($surface.Text -notmatch [regex]::Escape($instruction)) {
            throw "$($surface.Name) is missing the native relay spawn contract: $instruction"
        }
    }
}

foreach ($instruction in 'internal_subagent_backend=opencode','internal_subagent_backend=native','internal_subagent_transport=native_relay','opencode_worker','opencode-go/deepseek-v4-flash','AGENT_PERMISSION=yolo','task','external_directory','read-only','writer','claim-map','isolated worktree','WRITER_WORKTREE','WRITER_BASELINE','blocked','native','do not silently fall back') {
    if ($subagents -notmatch [regex]::Escape($instruction)) {
        throw "Subagents reference is missing internal-backend contract: $instruction"
    }
}

foreach ($instruction in 'internal_subagent_backend=opencode','internal_subagent_backend=native','internal_subagent_transport=native_relay','native `relay`','opencode_worker','opencode-go/deepseek-v4-flash','variant=max','OpenCode','worker','claim-map','cwd','external_directory','do not silently fall back') {
    if ($modeMatrixNormalized -notmatch [regex]::Escape($instruction)) {
        throw "Mode matrix is missing internal-backend contract: $instruction"
    }
}

foreach ($instruction in 'internal_subagent_backend=opencode','internal_subagent_backend=native','internal_subagent_transport=native_relay','agents/relay.toml','not part of the user-facing compact syntax','OpenCode `worker`','`worker` profile is only an explicit','AGENT_PERMISSION=yolo','task','external_directory','edit','bash','isolated worktree','WRITER_WORKTREE=<cwd>','WRITER_BASELINE=<full-commit>','preserve the required gate as blocked','sub-agent=opencode') {
    if ($backendPolicy -notmatch [regex]::Escape($instruction)) {
        throw "Backend policy is missing internal-route contract: $instruction"
    }
}

$tomlCodexHome = $codexHome.Replace('\', '\\')
$expectedWorkerCommand = 'command = "' + $tomlCodexHome + '\\bin\\opencode-worker.cmd"'
$expectedAgentsDir = 'AGENTS_DIR = "' + $tomlCodexHome + '\\opencode-agents"'
foreach ($instruction in 'opencode_worker','native','relay','AGENT_TYPE = "opencode"','AGENT_MODEL = "opencode-go/deepseek-v4-flash"','AGENT_EFFORT = "max"','AGENT_PERMISSION = "yolo"','SESSION_ENABLED = "false"','sub-agents-mcp@0.12.0','AGENTS_DIR = "%CODEX_HOME%\\opencode-agents"','PATH = "<gerado pelo instalador a partir do PATH do Windows>"','opencode run --model opencode-go/deepseek-v4-flash --variant max "Responda somente OK"') {
    if ($readmeText -notmatch [regex]::Escape($instruction)) {
        throw "README is missing OpenCode activation evidence: $instruction"
    }
}

$codexConfigPath = Join-Path $codexHome 'config.toml'
if (Test-Path -LiteralPath $codexConfigPath) {
    $codexConfigText = Get-Content -Raw -Encoding UTF8 $codexConfigPath
    if ($codexConfigText -notmatch '(?m)^\[mcp_servers\.opencode_worker\]') {
        Write-Warning 'Codex config exists without opencode_worker; MCP checks are skipped until -ConfigureMcp is used.'
    }
    else {
    $workerConfigMatch = [regex]::Match($codexConfigText, '(?ms)^\[mcp_servers\.opencode_worker\]\s*(?<body>.*?)(?=^\[|\z)')
    if (!$workerConfigMatch.Success) {
        throw 'Configured Codex runtime is missing the [mcp_servers.opencode_worker] table.'
    }

    $workerConfigText = $workerConfigMatch.Groups['body'].Value
    foreach ($instruction in $expectedWorkerCommand, 'args = ["-y", "sub-agents-mcp@0.12.0"]', 'startup_timeout_sec = 30', 'tool_timeout_sec = 600') {
        if ($workerConfigText -notmatch [regex]::Escape($instruction)) {
            throw "Configured opencode_worker is missing runtime wiring: $instruction"
        }
    }

    if ($codexConfigText -notmatch '(?m)^AGENT_PERMISSION\s*=\s*"yolo"\s*$') {
        throw 'Configured opencode_worker must use AGENT_PERMISSION=yolo so task/external_directory can be delegated; agent frontmatter owns reader no-edit and writer edit-only boundaries.'
    }

    $workerEnvMatch = [regex]::Match($codexConfigText, '(?ms)^\[mcp_servers\.opencode_worker\.env\]\s*(?<body>.*?)(?=^\[|\z)')
    if (!$workerEnvMatch.Success) {
        throw 'Configured opencode_worker requires the [mcp_servers.opencode_worker.env] table.'
    }

    $workerEnvText = $workerEnvMatch.Groups['body'].Value
    foreach ($instruction in 'SESSION_ENABLED = "false"') {
        if ($workerEnvText -notmatch [regex]::Escape($instruction)) {
            throw "Configured opencode_worker must disable session persistence: $instruction"
        }
    }
    if ($workerEnvText -match '(?m)^SESSION_(DIR|RETENTION_DAYS)\s*=') {
        throw 'Configured opencode_worker must not define a session directory or retention setting.'
    }

    if ($codexConfigText -cmatch '(?m)^\[mcp_servers\.opencode_hybrid_worker(?:\.|\])') {
        throw 'Removed opencode_hybrid_worker is still configured.'
    }
    if ($codexConfigText -match '(?i)opencode-hybrid|HYBRID_ROUTE|HYBRID_WORKTREE|HYBRID_MAIN_CHECKOUT|HYBRID_BASELINE|safe-edit') {
        throw 'Codex configuration still contains removed hybrid/writer routing.'
    }
}
}

$installedOpenCodeAgentsRoot = Join-Path $codexHome 'opencode-agents'
if (Test-Path -LiteralPath $installedOpenCodeAgentsRoot) {
    foreach ($file in $opencodeAgentFiles) {
        $sourcePath = Join-Path $opencodeAgentsRoot $file
        $installedPath = Join-Path $installedOpenCodeAgentsRoot $file
        if (!(Test-Path -LiteralPath $installedPath)) {
            throw "Installed OpenCode agent is missing: $file"
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash
        if ($sourceHash -ne $installedHash) {
            throw "Installed OpenCode agent is stale: $file"
        }
    }
}

foreach ($profile in $opencodeNativeProfiles) {
    if ($profile -notmatch [regex]::Escape('internal_subagent_backend=opencode')) {
        throw 'A native agent profile is missing the parent-owned OpenCode route guardrail.'
    }
}

if ($relay -notmatch '(?m)^name\s*=\s*"relay"\s*$' -or $relay -notmatch '(?m)^sandbox_mode\s*=\s*"read-only"\s*$') {
    throw 'Native relay profile must be named relay and use read-only sandbox.'
}

foreach ($instruction in 'mcp__opencode_worker__run_agent','RELAY_STATUS=success|blocked|error','RELAY_ROUTE=read-only|writer','RELAY_RESPONSE_BEGIN','target_agent','worker','`cwd` must be the absolute','WRITER_WORKTREE=<cwd>','WRITER_BASELINE=<full-commit>','route pairing is fixed','claim-map','isolated worktree','never fall back silently','built-in `tool_search` query','Delegate a complex multi-step task to an autonomous agent','This is deterministic activation, not route discovery','Do not list tools or agents') {
    if ($relayNormalized -notmatch [regex]::Escape($instruction)) {
        throw "Native relay profile is missing transport contract: $instruction"
    }
}
foreach ($instruction in 'the MCP function can be deferred','relay''s one exact','`tool_search`','a missing result remains blocked') {
    if (($backendPolicy -replace '\s+', ' ') -notmatch [regex]::Escape($instruction)) {
        throw "Backend policy is missing the deferred-MCP relay contract: $instruction"
    }
}
foreach ($instruction in '[mcp_servers.opencode_worker]','command = "__OPENCODE_WORKER_COMMAND__"','AGENTS_DIR = "__OPENCODE_AGENTS_DIR__"','AGENT_MODEL = "opencode-go/deepseek-v4-flash"','AGENT_EFFORT = "max"','enabled_tools = ["run_agent"]') {
    if ($relayNormalized -notmatch [regex]::Escape($instruction)) {
        throw "Native relay profile is missing explicit MCP tool exposure: $instruction"
    }
}
if ($relayNormalized -notmatch '(?i)never falls? back') {
    throw 'Native relay profile is missing the no-fallback transport contract.'
}

foreach ($instruction in '## Sincroniza.+?o do plano no Codex App','update_plan','tarefas n.+?triviais com duas ou mais fases','2 a 5 passos curtos','primeiro com.+?a em andamento','demais ficam pendentes','Depois de comprovar uma fase e antes do primeiro comando da pr.+?xima','completed','in_progress','futuras como pendentes','Se o escopo mudar, atualiza o plano antes de continuar','Ao provar a .+?ltima fase','todos os passos como conclu.+?dos','nenhum passo em andamento','N.+?o atualiza a lista depois de cada comando','Tarefas simples ou de uma fase n.+?o recebem uma lista artificial') {
    if ($planSyncReadmeNormalized -notmatch $instruction) {
        throw "README is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in 'with two or more phases','at the start, the first phase is `in_progress` and future phases are `pending`','before the first command of the next phase','previous phase is proven and `completed`','exactly one next phase is `in_progress`','future phases remain `pending`','after the last phase is proven','every phase is `completed` and none is `in_progress`','scope changes update the checklist before work continues','routine commands do not trigger updates','One-step or simple work does not need a checklist') {
    if ($planSyncValidation -notmatch [regex]::Escape($instruction)) {
        throw "Validation reference is missing plan-sync guidance: $instruction"
    }
}

foreach ($instruction in 'AHK launchers paste the canonical `$workflows` prefix with `mode=<MODE>`','compatibility aliases generated from the same source','canonical default execution contract') {
    if ($modeMatrixNormalized -notmatch [regex]::Escape($instruction)) {
        throw "Mode matrix is missing the mode-only launcher contract: $instruction"
    }
}

if ($workflowSkillInterfaceText -notmatch '(?m)^\s*default_prompt:\s*"\$workflows mode=PLAN\.AUTO"\s*$') {
    throw 'workflows interface must use the minimal PLAN.AUTO prompt.'
}

foreach ($instruction in 'references/runtime-adapters.md','`$workflows` as the canonical user-facing prefix','compatibility aliases','Select exactly one runtime adapter') {
    if ($skillText -notmatch [regex]::Escape($instruction)) {
        throw "workflows skill is missing canonical runtime routing: $instruction"
    }
}

foreach ($instruction in '## Common contract','## Codex','## Google Antigravity','## OpenCode','session persistence and continuation reuse are disabled') {
    if ($runtimeAdapters -notmatch [regex]::Escape($instruction)) {
        throw "Runtime adapters reference is missing host contract: $instruction"
    }
}

foreach ($instruction in 'Install-WorkflowSkill','workflows','codex-workflows','antigravity-workflows','opencode-workflows') {
    if ($installScriptText -notmatch [regex]::Escape($instruction)) {
        throw "Installer is missing workflows compatibility handling: $instruction"
    }
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

foreach ($instruction in '## Observability','por padr.+?o, n.+?o cria log.','pergunta diagn.+?stica','caminho j.+? existente no projeto','campos seguros','limite de volume','reten.+?o e acesso aplicados pelo destino','forma de desligar ou','remover e falha segura que n.+?o interrompe o fluxo principal','`contrato audit/compliance` explicitamente aprovado','coletor, hook, exportador ou servi.+?o externo sem escopo expl.+?cito') {
    if ($readmeTextNormalized -notmatch $instruction) {
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
    @{ Key = 'Numpad1'; Shortcut = 'NUM1'; Prompt = '$workflows mode=PLAN.AUTO'; Label = 'PLAN.AUTO' }
    @{ Key = 'Numpad2'; Shortcut = 'NUM2'; Prompt = '$workflows mode=DELIVER.AUTO'; Label = 'DELIVER.AUTO' }
    @{ Key = 'Numpad3'; Shortcut = 'NUM3'; Prompt = '$workflows mode=COMMIT'; Label = 'COMMIT' }
    @{ Key = 'Numpad4'; Shortcut = 'NUM4'; Prompt = '$workflows mode=BUG.INV'; Label = 'BUG.INV' }
    @{ Key = 'Numpad5'; Shortcut = 'NUM5'; Prompt = '$workflows mode=BUG.FIX'; Label = 'BUG.FIX' }
    @{ Key = 'Numpad6'; Shortcut = 'NUM6'; Prompt = '$workflows mode=DEBUG'; Label = 'DEBUG' }
    @{ Key = 'Numpad7'; Shortcut = 'NUM7'; Prompt = '$workflows mode=REWORK'; Label = 'REWORK' }
    @{ Key = 'Numpad8'; Shortcut = 'NUM8'; Prompt = '$workflows mode=R.A.F.V'; Label = 'R.A.F.V' }
    @{ Key = 'Numpad9'; Shortcut = 'NUM9'; Prompt = '$workflows mode=TN.SKILL'; Label = 'TN.SKILL' }
    @{ Key = 'NumpadMult'; Shortcut = 'NUM*'; Prompt = '$workflows mode=RESEARCH.DEEP'; Label = 'RESEARCH.DEEP' }
)
$modifierBindings = @()
$deepWorkflowBindings = @(
    @{ Key = 'Numpad0 & Numpad1'; Shortcut = 'NUM0+1'; Prompt = '$workflows mode=P.DEEP'; Label = 'P.DEEP' }
    @{ Key = 'Numpad0 & Numpad2'; Shortcut = 'NUM0+2'; Prompt = '$workflows mode=IMPL.PHASE'; Label = 'IMPL.PHASE' }
    @{ Key = 'Numpad0 & Numpad3'; Shortcut = 'NUM0+3'; Prompt = '$workflows mode=COMMIT'; Label = 'deep COMMIT' }
    @{ Key = 'Numpad0 & Numpad4'; Shortcut = 'NUM0+4'; Prompt = '$workflows mode=BUG.INV'; Label = 'deep BUG.INV' }
    @{ Key = 'Numpad0 & Numpad5'; Shortcut = 'NUM0+5'; Prompt = '$workflows mode=BUG.FIX'; Label = 'deep BUG.FIX' }
    @{ Key = 'Numpad0 & Numpad6'; Shortcut = 'NUM0+6'; Prompt = '$workflows mode=DEBUG'; Label = 'deep DEBUG' }
    @{ Key = 'Numpad0 & Numpad7'; Shortcut = 'NUM0+7'; Prompt = '$workflows mode=REWORK'; Label = 'deep REWORK' }
    @{ Key = 'Numpad0 & Numpad8'; Shortcut = 'NUM0+8'; Prompt = '$workflows mode=R.A.F.V'; Label = 'deep R.A.F.V' }
    @{ Key = 'Numpad0 & Numpad9'; Shortcut = 'NUM0+9'; Prompt = '$workflows mode=TN.SKILL'; Label = 'deep TN.SKILL' }
    @{ Key = 'Numpad0 & NumpadMult'; Shortcut = 'NUM0+*'; Prompt = '$workflows mode=RESEARCH.DEEP'; Label = 'deep RESEARCH.DEEP' }
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

foreach ($instruction in '`subA-role-lock`','`subA-custom-spawn`','`subA-effort`','`subA-retry`','`subA-slot-full`','`subA-retry-block`','never use `default` or omit the role','Never combine `fork_context=true` with `agent_type`','omit `fork_context`, `model`, and `reasoning_effort`','one fresh retry with the same exact role','any required read-only gate remains blocked','`review-embargo`','`subA-isolation`','`fix-embargo`','one fresh read-only reviewer checks the correction delta') {
    if ($subagents -notmatch [regex]::Escape($instruction)) {
        throw "Subagent guidance is missing role-lock or delivery anti-spam instruction: $instruction"
    }
}

foreach ($instruction in 'completed/idle subA whose final replies are already integrated','wait for an optional subA to finish','same exact role with the same custom-spawn shape','never close active/waiting/required subA','explicit capacity block') {
    if ($subagents -notmatch [regex]::Escape($instruction)) {
        throw "Subagent guidance is missing slot-recovery invariant: $instruction"
    }
}

foreach ($surface in @(
    @{ Name = 'workflows skill'; Text = $skillText; Phrase = 'rather than silently skipping' }
    @{ Name = 'subagents reference'; Text = $subagents; Phrase = 'rather than silently skipping' }
    @{ Name = 'dictionary'; Text = $dictionary; Phrase = 'rather than silently skipping' }
    @{ Name = 'backend policy'; Text = $backendPolicy; Phrase = 'not backend-unavailability fallback' }
    @{ Name = 'validation reference'; Text = $validationReference; Phrase = 'report explicit capacity evidence' }
    @{ Name = 'AGENTS.md'; Text = $agentsMdText; Phrase = 'report an explicit capacity block' }
    @{ Name = 'README'; Text = $readmeText; Phrase = 'bloqueio explícito' }
)) {
    if ($surface.Text -notmatch [regex]::Escape('`subA-slot-full`')) {
        throw "$($surface.Name) is missing the slot-full recovery contract."
    }
    if ($surface.Text -notmatch [regex]::Escape($surface.Phrase)) {
        throw "$($surface.Name) is missing the slot-full safety phrase: $($surface.Phrase)"
    }
}

foreach ($surface in @(
    @{ Name = 'subagents reference'; Text = $subagents }
    @{ Name = 'dictionary'; Text = $dictionary }
)) {
    if ($surface.Text -notmatch [regex]::Escape('Slot-full recovery permits one retry')) {
        throw "$($surface.Name) is missing the bounded slot-full retry contract."
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

$workflowPromptCount = [regex]::Matches($ahkText, '\$workflows mode=').Count
if ($workflowPromptCount -lt $workflowBindings.Count) {
    throw "AHK must contain at least $($workflowBindings.Count) minimal workflow prompts; found $workflowPromptCount."
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

foreach ($binding in $deepWorkflowBindings) {
    $bindingText = "$($binding.Key)::PastePrompt(`"$($binding.Prompt)`")"
    if ($ahkText -notmatch [regex]::Escape($bindingText)) {
        throw "Missing deep $($binding.Label) binding."
    }

    $readmePattern = "(?m)^$([regex]::Escape($binding.Shortcut))\s+$([regex]::Escape($binding.Prompt))\s*$"
    if ($readmeText -notmatch $readmePattern) {
        throw "README is missing the deep $($binding.Label) shortcut."
    }
}

if (Test-Path $ahkExe) {
    & $ahkExe /ErrorStdOut /Validate $ahk
} else {
    Write-Warning "AHK executable not found; skipping runtime syntax validation."
}

if (Get-Command codegraph -ErrorAction SilentlyContinue) {
    codegraph --version
} else {
    Write-Warning 'codegraph command not found.'
}

Write-Host 'Validation OK.'
