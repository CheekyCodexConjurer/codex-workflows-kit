[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$installer = Join-Path $repo 'scripts\install.ps1'
$uninstaller = Join-Path $repo 'scripts\uninstall.ps1'
$nl = [Environment]::NewLine

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Passed = 0

function Assert-Condition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [AllowEmptyString()][string]$Detail = ''
    )

    if ($Condition) {
        $script:Passed++
        Write-Host "[OK]   $Name" -ForegroundColor Green
    }
    else {
        $script:Failures.Add(($Name + ': ' + $Detail))
        Write-Host "[FAIL] $Name : $Detail" -ForegroundColor Red
    }
}

function New-FixtureHome {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('cwkgate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'codex') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'agents') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'gemini') -Force | Out-Null
    return $root
}

function Write-FixtureFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, ($Content -replace "`r?`n", "`r`n"), $encoding)
}

function Read-Config {
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path $Root 'codex\config.toml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

function Get-CodexHome {
    param([Parameter(Mandatory)][string]$Root)

    return (Join-Path $Root 'codex')
}

function Get-AgentsHome {
    param([Parameter(Mandatory)][string]$Root)

    return (Join-Path $Root 'agents')
}

function Get-AntigravityHome {
    param([Parameter(Mandatory)][string]$Root)

    return (Join-Path $Root 'gemini')
}

function Invoke-SafeInstall {
    param([Parameter(Mandatory)][string]$Root, [string]$Profile = 'safe')

    & $installer -Profile $Profile -CodexHome (Get-CodexHome $Root) -AgentsHome (Get-AgentsHome $Root) -AntigravityHome (Get-AntigravityHome $Root) -Force *>&1 | Out-Host
}

function Invoke-SafeUninstall {
    param([Parameter(Mandatory)][string]$Root)

    & $uninstaller -CodexHome (Get-CodexHome $Root) -AgentsHome (Get-AgentsHome $Root) -AntigravityHome (Get-AntigravityHome $Root) *>&1 | Out-Host
}

function Invoke-Doctor {
    param([Parameter(Mandatory)][string]$Root)

    $doctorScript = Join-Path $repo 'scripts\doctor.ps1'
    $output = & pwsh -NoProfile -File $doctorScript -CodexHome (Get-CodexHome $Root) -AgentsHome (Get-AgentsHome $Root) -AntigravityHome (Get-AntigravityHome $Root) 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    }
}

function Invoke-Validate {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$SkipInstalled
    )

    $validateScript = Join-Path $repo 'scripts\validate.ps1'
    $argsList = @(
        '-NoProfile',
        '-File', $validateScript,
        '-CodexHome', (Get-CodexHome $Root),
        '-AgentsHome', (Get-AgentsHome $Root),
        '-AntigravityHome', (Get-AntigravityHome $Root),
        '-SkipGateTests'
    )
    if ($SkipInstalled) {
        $argsList += '-SkipInstalled'
    }

    $output = & pwsh @argsList 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    }
}

function Get-FeatureHeaderCount {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text = $Text -replace '\r\n', "`n"
    return @([regex]::Matches($Text, '(?m)^[ \t]*\[features\][ \t]*(?:#.*)?$')).Count
}

function Get-MultiAgentKeyCount {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text = $Text -replace '\r\n', "`n"
    return @([regex]::Matches($Text, '(?m)^[ \t]*multi_agent[ \t]*=')).Count
}

function Get-MultiAgentValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text = $Text -replace '\r\n', "`n"
    $match = [regex]::Match($Text, '(?m)^[ \t]*multi_agent[ \t]*=[ \t]*([^\s#]+)')
    if (-not $match.Success) {
        return ''
    }
    return $match.Groups[1].Value
}

function Get-InstallState {
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path (Get-CodexHome $Root) 'codex-workflows-kit\install-state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-StateExists {
    param([Parameter(Mandatory)][string]$Root)

    return Test-Path -LiteralPath (Join-Path (Get-CodexHome $Root) 'codex-workflows-kit\install-state.json') -PathType Leaf
}

function Test-AgentsOrchestrationSemantics {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    if (-not [regex]::IsMatch($normalized, '(?i)falha fechado')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)antes de esperar,? mapeie frentes independentes,? depend[eê]ncias e recursos exclusivos ou compartilhados')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)lance em lote todas as frentes materiais independentes antes do primeiro follow')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)apenas trilhas com depend[eê]ncia real ou recurso compartilhado ficam seriais')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)enquanto aguarda,? fa[cç]a orquestra[cç][aã]o independente [uú]til')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)ledger est[aá]vel de request_id.{0,60}frente,? agente,? job,? estado,? consumido e fechado')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)consuma cada job e feche cada agente ap[oó]s a integra[cç][aã]o')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)deepseek_continue.{0,80}allow_respawn')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)sem pedir nova permiss[ãa]o')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)cria sess[ãa]o.{0,60}lineage')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)nunca recupere job running')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)sem fallback')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?=[^.;]*\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam|s[aã]o autorizad[ao]s? a|est[aã]o autorizad[ao]s? a|usam)\b)(?=[^.;]*\b(?:spawn_agent|wait_agent|multi_agent_v1__spawn_agent)\b)(?=[^.;]*\b(?:supervis[aã]o|guardian)\b)[^.;]+')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:l[eê]|ler|escreve|escrever|testa|testar|revisa|revisar|investiga|investigar|executa|executar|realiza|realizar|faz|fazer|verifica|verificar|confere|conferir)\b[^.;]*\b(?:localmente|diretamente|por conta pr[oó]pria)\b')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[rç]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:job running|running|em execu[cç][aã]o|em andamento|em curso|ativos?|andamento)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[rç]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:sem resposta final|resposta final persistida|sem resultado final|resultado final persistido|sem resultado terminal)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[rç]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:abortad[oa]|abortados)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[rç]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:escopo novo|outro escopo|escopo diferente|frente nova|fora do pedido|mudança material|pedido divergiu|pedido divergente|outro pedido|mudança de cwd|cwd diferente|mudando de cwd|outro cwd|cwd divergente)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[rç]|reabrir|retomar|continuar|abrir|usar|allow_respawn)\b[^.;]*\b(?:fallback|outro provedor|outro modelo|troc\w*|substitu\w*)\b')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:reabrir a sess[ãa]o|mesma sess[ãa]o|sess[ãa]o antiga|continuar a sess[ãa]o|abrir nova sess[ãa]o|sess[ãa]o nova)\b')) {
        return $false
    }
    return $true
}

function Test-DaemonRestartPolicySemantics {
    param(
        [Parameter(Mandatory)][string]$LifecycleText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText
    )

    $lifecycleNorm = [regex]::Replace($LifecycleText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()

    # Must contain required gates
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)express (?:human|user) authorization|explicit user authorization')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)dist/cli\.js restart --config <known-config> --json')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)GET\s+[`]?/health')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)PID,? command(?: line)?,? and data (?:dir|directory) ownership')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)bridge\.sqlite')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)bounded readiness')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)fail-closed')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)AntigravityProcessError')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)taskkill')) {
        return $false
    }
    if (-not [regex]::IsMatch($lifecycleNorm, '(?i)Stop-Process')) {
        return $false
    }

    # Prohibit /v1/health
    if ([regex]::IsMatch($LifecycleText, '(?i)/v1/health') -or [regex]::IsMatch($SkillText, '(?i)/v1/health') -or [regex]::IsMatch($AgentsText, '(?i)/v1/health') -or [regex]::IsMatch($GeminiText, '(?i)/v1/health')) {
        return $false
    }

    # Prohibit un-gated generic restart / kill
    if ([regex]::IsMatch($lifecycleNorm, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:restart automatically|auto-restart without consent|restart on any error)\b')) {
        return $false
    }
    if ([regex]::IsMatch($lifecycleNorm, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:use taskkill|use Stop-Process|kill-all)\b')) {
        return $false
    }
    if ([regex]::IsMatch($lifecycleNorm, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:restart Serena|restart CodeGraph|restart Context7|restart Codex|restart Antigravity)\b')) {
        return $false
    }
    if ([regex]::IsMatch($lifecycleNorm, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:restart with active jobs|restart when jobs are running|ignore active jobs)\b')) {
        return $false
    }
    if ([regex]::IsMatch($lifecycleNorm, '(?i)\b(?:may|can|should|must|authorized to)\b\s+(?!not\b|never\b)[^.;]*\b(?:trigger on AntigravityProcessError|triggered by agy failure|trigger on HTTP error alone)\b')) {
        return $false
    }

    # SKILL.md checks
    if (-not [regex]::IsMatch($skillNorm, '(?i)DeepSeek (?:Sub-Agent )?Daemon Restart Exception')) {
        return $false
    }
    if (-not [regex]::IsMatch($skillNorm, '(?i)dist/cli\.js restart --config <known-config> --json')) {
        return $false
    }
    if (-not [regex]::IsMatch($skillNorm, '(?i)/health')) {
        return $false
    }
    if (-not [regex]::IsMatch($skillNorm, '(?i)bridge\.sqlite')) {
        return $false
    }

    # AGENTS.md checks
    if (-not [regex]::IsMatch($agentsNorm, '(?i)daemon DeepSeek')) {
        return $false
    }
    if (-not [regex]::IsMatch($agentsNorm, '(?i)dist/cli\.js restart --config <known-config> --json')) {
        return $false
    }
    if (-not [regex]::IsMatch($agentsNorm, '(?i)/health')) {
        return $false
    }
    if (-not [regex]::IsMatch($agentsNorm, '(?i)bridge\.sqlite')) {
        return $false
    }

    # GEMINI.md checks
    if (-not [regex]::IsMatch($geminiNorm, '(?i)daemon DeepSeek')) {
        return $false
    }
    if (-not [regex]::IsMatch($geminiNorm, '(?i)dist/cli\.js restart --config <known-config> --json')) {
        return $false
    }
    if (-not [regex]::IsMatch($geminiNorm, '(?i)/health')) {
        return $false
    }
    if (-not [regex]::IsMatch($geminiNorm, '(?i)bridge\.sqlite')) {
        return $false
    }

    return $true
}

$scenario = 0
$fixtures = New-Object System.Collections.Generic.List[string]

try {
    $scenario = 1
    Write-Host 'Scenario 1: absent [features] table, rerun idempotence, uninstall restore' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = 'model = "gpt-test"

[mcp_servers.sample]
command = "sample"
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $config1 = Read-Config $root
    Assert-Condition 'S1 installs a features table block' (($config1 -like '*# BEGIN CODEX-WORKFLOWS-KIT: features*') -and (Get-FeatureHeaderCount $config1) -eq 1) $config1
    Assert-Condition 'S1 sets multi_agent = false' ((Get-MultiAgentKeyCount $config1) -eq 1 -and (Get-MultiAgentValue $config1) -ceq 'false') $config1
    Assert-Condition 'S1 preserves unrelated content' (($config1 -like '*model = "gpt-test"*') -and ($config1 -like '*[mcp_servers.sample]*')) $config1
    Invoke-SafeInstall -Root $root
    $config2 = Read-Config $root
    Assert-Condition 'S1 rerun is byte-identical' ($config1 -ceq $config2) ''
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    Assert-Condition 'S1 uninstall restores the original config' ($config3 -ceq ($original -replace "`r?`n", "`r`n")) $config3
    Assert-Condition 'S1 no [features] header remains' ((Get-FeatureHeaderCount $config3) -eq 0) $config3
    Assert-Condition 'S1 state is removed' (-not (Test-StateExists $root)) ''

    $scenario = 2
    Write-Host 'Scenario 2: existing [features] with unrelated keys' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
js_repl = false
memories = true

[other]
keep = "me"
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $config1 = Read-Config $root
    Assert-Condition 'S2 keeps a single [features] header' ((Get-FeatureHeaderCount $config1) -eq 1) $config1
    Assert-Condition 'S2 inserts a single multi_agent key' ((Get-MultiAgentKeyCount $config1) -eq 1 -and (Get-MultiAgentValue $config1) -ceq 'false') $config1
    Assert-Condition 'S2 preserves unrelated feature keys' (($config1 -like '*js_repl = false*') -and ($config1 -like '*memories = true*') -and ($config1 -like '*[other]*keep = "me"*')) $config1
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    Assert-Condition 'S2 uninstall restores the original config' ($config3 -ceq ($original -replace "`r?`n", "`r`n")) $config3

    $scenario = 3
    Write-Host 'Scenario 3: existing multi_agent = true is forced false and restored' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
multi_agent = true
js_repl = false
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $config1 = Read-Config $root
    Assert-Condition 'S3 forces multi_agent to false' ((Get-MultiAgentValue $config1) -ceq 'false') $config1
    Assert-Condition 'S3 keeps a single [features] header and key' ((Get-FeatureHeaderCount $config1) -eq 1 -and (Get-MultiAgentKeyCount $config1) -eq 1) $config1
    Assert-Condition 'S3 preserves unrelated feature keys' ($config1 -like '*js_repl = false*') $config1
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    Assert-Condition 'S3 uninstall restores the prior value' ($config3 -ceq ($original -replace "`r?`n", "`r`n")) $config3

    $scenario = 4
    Write-Host 'Scenario 4: existing multi_agent = false is left untouched' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
multi_agent = false
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $config1 = Read-Config $root
    Assert-Condition 'S4 keeps multi_agent = false untouched' ((Get-MultiAgentKeyCount $config1) -eq 1 -and (Get-MultiAgentValue $config1) -ceq 'false') $config1
    $featureLine1 = ($config1 -split '\r?\n' | Where-Object { $_ -match '^\s*multi_agent\s*=' }) -join '|'
    Invoke-SafeInstall -Root $root
    $config2 = Read-Config $root
    $featureLine2 = ($config2 -split '\r?\n' | Where-Object { $_ -match '^\s*multi_agent\s*=' }) -join '|'
    Assert-Condition 'S4 rerun does not rewrite the feature line' ($featureLine1 -ceq $featureLine2) ''
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    Assert-Condition 'S4 uninstall leaves the config identical' ($config3 -ceq ($original -replace "`r?`n", "`r`n")) $config3

    $scenario = 5
    Write-Host 'Scenario 5: user override is warned and preserved on uninstall' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
js_repl = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $config1 = Read-Config $root
    Assert-Condition 'S5 installs the managed false' ((Get-MultiAgentValue $config1) -ceq 'false') $config1
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content ($config1 -replace 'multi_agent = false', 'multi_agent = true')
    $uninstallOutput = & $uninstaller -CodexHome (Get-CodexHome $root) -AgentsHome (Get-AgentsHome $root) 3>&1
    $uninstallOutput | Out-Host
    $outputText = ($uninstallOutput | ForEach-Object { $_.ToString() }) -join $nl
    $configAfter = Read-Config $root
    Assert-Condition 'S5 leaves the user value alone' ((Get-MultiAgentValue $configAfter) -ceq 'true') $configAfter
    Assert-Condition 'S5 warns about the override' ($outputText -like '*multi_agent*') $outputText
    Assert-Condition 'S5 preserves install state for review' (Test-StateExists $root) ''

    $scenario = 6
    Write-Host 'Scenario 6: schema-3 install state migrates to schema 4' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
multi_agent = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json') -Content '{"schemaVersion":3,"product":"codex-workflows-kit","profile":"safe","installedAtUtc":"2026-01-01T00:00:00Z","files":[],"pendingFiles":[]}'
    Invoke-SafeInstall -Root $root
    $state = Get-InstallState $root
    Assert-Condition 'S6 state migrates to schema 4' ($null -ne $state -and [int]$state.schemaVersion -eq 4) ''
    Assert-Condition 'S6 records the prior feature value' ($null -ne $state -and $state.codexFeaturesPrior.multi_agent.present -eq $true -and [string]$state.codexFeaturesPrior.multi_agent.value -ceq 'true') ''
    $config1 = Read-Config $root
    Assert-Condition 'S6 installs the managed false' ((Get-MultiAgentValue $config1) -ceq 'false') $config1
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    Assert-Condition 'S6 uninstall restores the prior value' ($config3 -ceq ($original -replace "`r?`n", "`r`n")) $config3

    $scenario = 7
    Write-Host 'Scenario 7: minimal profile keeps its limited scope' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
multi_agent = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root -Profile 'minimal'
    $config1 = Read-Config $root
    Assert-Condition 'S7 minimal leaves the config untouched' ($config1 -ceq ($original -replace "`r?`n", "`r`n")) $config1
    $state = Get-InstallState $root
    Assert-Condition 'S7 records the observed feature state' ($null -ne $state -and [int]$state.schemaVersion -eq 4 -and $state.codexFeaturesPrior.multi_agent.present -eq $true -and [string]$state.codexFeaturesPrior.multi_agent.value -ceq 'true') ''
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    Assert-Condition 'S7 uninstall leaves the config untouched' ($config3 -ceq ($original -replace "`r?`n", "`r`n")) $config3

    $scenario = 8
    Write-Host 'Scenario 8: schema-4 pending file modified by the user is preserved on uninstall' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $pendingPath = Join-Path (Get-CodexHome $root) 'pending-sample.txt'
    Write-FixtureFile -Path $pendingPath -Content 'kit-managed original'
    $pendingHash = (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash
    Write-FixtureFile -Path $pendingPath -Content 'user-modified content'
    $stateJson = [ordered]@{
        schemaVersion = 4
        product = 'codex-workflows-kit'
        profile = 'safe'
        installedAtUtc = '2026-01-01T00:00:00Z'
        files = @()
        pendingFiles = @(@{ path = $pendingPath; sha256 = $pendingHash; reason = 'modified' })
        codexFeaturesPrior = @{ multi_agent = @{ present = $true; value = 'true' } }
    } | ConvertTo-Json -Depth 5
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json') -Content $stateJson
    $uninstallOutput = & $uninstaller -CodexHome (Get-CodexHome $root) -AgentsHome (Get-AgentsHome $root) 3>&1
    $uninstallOutput | Out-Host
    $outputText = ($uninstallOutput | ForEach-Object { $_.ToString() }) -join $nl
    Assert-Condition 'S8 preserves the user-modified pending file' ((Test-Path -LiteralPath $pendingPath -PathType Leaf) -and (Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8) -ceq 'user-modified content') $pendingPath
    Assert-Condition 'S8 warns about the modified pending file' ($outputText -like '*Skipping modified managed file*') $outputText
    $state = Get-InstallState $root
    Assert-Condition 'S8 preserves install state for review' ($null -ne $state -and [int]$state.schemaVersion -eq 4) ''
    Assert-Condition 'S8 retains the pending entry and reason' ($null -ne $state -and @($state.pendingFiles).Count -eq 1 -and [string]$state.pendingFiles[0].path -ceq $pendingPath -and [string]$state.pendingFiles[0].reason -ceq 'modified' -and [string]$state.pendingFiles[0].sha256 -ceq $pendingHash) ''
    $scenario = 9
    Write-Host 'Scenario 9: reinstall removes the legacy managed agents block and preserves an unmanaged [agents]' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $legacyAgentsBlock = '# BEGIN CODEX-WORKFLOWS-KIT: agents' + $nl +
        '[agents]' + $nl +
        'max_concurrent_threads_per_session = 5' + $nl +
        'default_subagent_model = "gpt-5.6-luna"' + $nl +
        'default_subagent_reasoning_effort = "high"' + $nl +
        '# END CODEX-WORKFLOWS-KIT: agents' + $nl
    $unmanagedAgents = '[agents]' + $nl + 'max_concurrent_threads_per_session = 3' + $nl
    $original = $legacyAgentsBlock + $unmanagedAgents + $nl + '[features]' + $nl + 'multi_agent = true' + $nl
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $config1 = Read-Config $root
    Assert-Condition 'S9 removes the legacy managed agents block' ($config1.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: agents', [StringComparison]::Ordinal) -lt 0) $config1
    Assert-Condition 'S9 preserves the unmanaged [agents] section' (($config1 -like '*[agents]*') -and ($config1 -like '*max_concurrent_threads_per_session = 3*')) $config1
    Assert-Condition 'S9 keeps multi_agent = false' ((Get-MultiAgentKeyCount $config1) -eq 1 -and (Get-MultiAgentValue $config1) -ceq 'false') $config1
    Assert-Condition 'S9 keeps a single [features] header' ((Get-FeatureHeaderCount $config1) -eq 1) $config1
    Invoke-SafeInstall -Root $root
    $config2 = Read-Config $root
    Assert-Condition 'S9 rerun is byte-identical and block stays removed' ($config1 -ceq $config2 -and $config2.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: agents', [StringComparison]::Ordinal) -lt 0) ''
    Invoke-SafeUninstall -Root $root
    $config3 = Read-Config $root
    $expectedAfterUninstall = (($unmanagedAgents + $nl + '[features]' + $nl + 'multi_agent = true' + $nl) -replace "`r?`n", "`r`n")
    Assert-Condition 'S9 uninstall preserves the unmanaged agents section and restores multi_agent' ($config3 -ceq $expectedAfterUninstall) $config3
    Assert-Condition 'S9 uninstall leaves no kit markers' ($config3.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT', [StringComparison]::Ordinal) -lt 0) $config3
    Assert-Condition 'S9 state is removed' (-not (Test-StateExists $root)) ''

    $scenario = 10
    Write-Host 'Scenario 10: safe profile propagates the AGENTS orchestration policy and heals tampering' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]' + $nl + 'multi_agent = true' + $nl
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Invoke-SafeInstall -Root $root
    $agentsMdPath = Join-Path (Get-CodexHome $root) 'AGENTS.md'
    $installedAgents = Get-Content -LiteralPath $agentsMdPath -Raw -Encoding UTF8
    $canonicalAgents = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
    $normalizedInstalled = ([regex]::Replace($installedAgents, '\s+', ' ')).Trim()
    $normalizedCanonical = ([regex]::Replace($canonicalAgents, '\s+', ' ')).Trim()
    Assert-Condition 'S10 wraps the policy in managed markers' (($installedAgents -like '*# BEGIN CODEX-WORKFLOWS-KIT*') -and ($installedAgents -like '*# END CODEX-WORKFLOWS-KIT*')) ''
    Assert-Condition 'S10 propagates the full canonical AGENTS policy' ($normalizedInstalled.IndexOf($normalizedCanonical, [StringComparison]::Ordinal) -ge 0) ''
    Assert-Condition 'S10 installed policy satisfies the orchestration semantics' (Test-AgentsOrchestrationSemantics -Text $installedAgents) ''

    $tampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', '- O parent pode ler arquivos localmente sem delegar.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Write-FixtureFile -Path $agentsMdPath -Content $tampered
    Assert-Condition 'S10 tamper injects a direct-local-work carve-out' (($tampered -ne $installedAgents) -and ($tampered -like '*pode ler arquivos localmente*')) ''
    Assert-Condition 'S10 detects the tampered policy' (-not (Test-AgentsOrchestrationSemantics -Text $tampered)) ''

    $superTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' Os agentes de supervisão do sistema podem usar spawn_agent para gerenciar o ciclo de vida.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the supervision tool tamper' (-not (Test-AgentsOrchestrationSemantics -Text $superTampered)) ''

    $recoveryTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode recuperar job running com allow_respawn.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery-for-running tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryTampered)) ''

    $recoveryScopeTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode recuperar com allow_respawn em escopo novo.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery scope-expansion tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryScopeTampered)) ''

    $recoveryFallbackTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode recuperar com allow_respawn usando fallback de provedor.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery fallback tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryFallbackTampered)) ''

    $recoveryContinueTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode continuar com allow_respawn para job em andamento.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery continue-running tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryContinueTampered)) ''

    $recoveryMissingResultTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode recuperar job sem resposta final persistida.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery missing-result tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryMissingResultTampered)) ''

    $recoveryDivergedTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode usar allow_respawn quando o pedido divergiu.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery diverged-request tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryDivergedTampered)) ''

    $recoveryCwdTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode recuperar com allow_respawn mudando de cwd.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery cwd-change tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryCwdTampered)) ''

    $recoveryNewFrontTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode abrir nova sessão para frente nova.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery new-front tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoveryNewFrontTampered)) ''

    $recoverySwitchTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode retomar com allow_respawn trocando de modelo/provedor.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery switch-model tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoverySwitchTampered)) ''

    $recoverySubstituteTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode retomar com allow_respawn substituindo o provedor.' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Assert-Condition 'S10 detects the recovery substitute-provider tamper' (-not (Test-AgentsOrchestrationSemantics -Text $recoverySubstituteTampered)) ''

    Invoke-SafeInstall -Root $root
    $healedAgents = Get-Content -LiteralPath $agentsMdPath -Raw -Encoding UTF8
    $normalizedHealed = ([regex]::Replace($healedAgents, '\s+', ' ')).Trim()
    Assert-Condition 'S10 reinstall heals the tamper back to the canonical policy' (($normalizedHealed.IndexOf($normalizedCanonical, [StringComparison]::Ordinal) -ge 0) -and ($healedAgents.IndexOf('pode ler arquivos localmente', [StringComparison]::Ordinal) -lt 0) -and ($healedAgents.IndexOf('pode recuperar job running', [StringComparison]::Ordinal) -lt 0) -and ($healedAgents.IndexOf('pode continuar com allow_respawn', [StringComparison]::Ordinal) -lt 0) -and (Test-AgentsOrchestrationSemantics -Text $healedAgents)) ''

    Invoke-SafeUninstall -Root $root
    Assert-Condition 'S10 uninstall removes the managed AGENTS block' (-not (Test-Path -LiteralPath $agentsMdPath -PathType Leaf)) ''

    $scenario = 11
    Write-Host 'Scenario 11: safe profile installs mcp-foundation skill across all targets and GEMINI.md in config, preserves unmanaged content without Force' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $canonicalGemini = Get-Content -LiteralPath (Join-Path $repo 'antigravity\GEMINI.md') -Raw -Encoding UTF8
    $unmanagedGemini = '# My Custom Rules' + $nl + 'custom_setting = true' + $nl
    $installedGeminiPath = Join-Path (Get-AntigravityHome $root) 'config\GEMINI.md'
    Write-FixtureFile -Path $installedGeminiPath -Content $unmanagedGemini

    # Install without -Force over unmanaged content
    & $installer -Profile 'safe' -CodexHome (Get-CodexHome $root) -AgentsHome (Get-AgentsHome $root) -AntigravityHome (Get-AntigravityHome $root) *>&1 | Out-Host

    $installedGemini = Get-Content -LiteralPath $installedGeminiPath -Raw -Encoding UTF8
    $mcpSkillPathAgents = Join-Path (Get-AgentsHome $root) 'skills\mcp-foundation\SKILL.md'
    $mcpSkillPathAg1 = Join-Path (Get-AntigravityHome $root) 'antigravity\skills\mcp-foundation\SKILL.md'
    $mcpSkillPathAg2 = Join-Path (Get-AntigravityHome $root) 'config\skills\mcp-foundation\SKILL.md'
    $wfSkillPathAg1 = Join-Path (Get-AntigravityHome $root) 'antigravity\skills\workflows\SKILL.md'
    $efSkillPathAg1 = Join-Path (Get-AntigravityHome $root) 'antigravity\skills\evidence-first\SKILL.md'
    $wfSkillPathAg2 = Join-Path (Get-AntigravityHome $root) 'config\skills\workflows\SKILL.md'
    $efSkillPathAg2 = Join-Path (Get-AntigravityHome $root) 'config\skills\evidence-first\SKILL.md'

    Assert-Condition 'S11 installs mcp-foundation in agents skills' (Test-Path -LiteralPath $mcpSkillPathAgents -PathType Leaf) $mcpSkillPathAgents
    Assert-Condition 'S11 installs mcp-foundation in antigravity skills 1' (Test-Path -LiteralPath $mcpSkillPathAg1 -PathType Leaf) $mcpSkillPathAg1
    Assert-Condition 'S11 installs mcp-foundation in antigravity skills 2' (Test-Path -LiteralPath $mcpSkillPathAg2 -PathType Leaf) $mcpSkillPathAg2
    Assert-Condition 'S11 installs workflows in antigravity skills 1' (Test-Path -LiteralPath $wfSkillPathAg1 -PathType Leaf) $wfSkillPathAg1
    Assert-Condition 'S11 installs evidence in antigravity skills 1' (Test-Path -LiteralPath $efSkillPathAg1 -PathType Leaf) $efSkillPathAg1
    Assert-Condition 'S11 installs workflows in antigravity skills 2' (Test-Path -LiteralPath $wfSkillPathAg2 -PathType Leaf) $wfSkillPathAg2
    Assert-Condition 'S11 installs evidence in antigravity skills 2' (Test-Path -LiteralPath $efSkillPathAg2 -PathType Leaf) $efSkillPathAg2

    Assert-Condition 'S11 wraps GEMINI in managed markers' (($installedGemini -like '*# BEGIN CODEX-WORKFLOWS-KIT*') -and ($installedGemini -like '*# END CODEX-WORKFLOWS-KIT*')) ''
    Assert-Condition 'S11 preserves unmanaged GEMINI rules without Force' ($installedGemini -like '*custom_setting = true*') $installedGemini
    Assert-Condition 'S11 includes canonical GEMINI content' ($installedGemini.IndexOf('mcp-foundation', [StringComparison]::Ordinal) -ge 0) $installedGemini

    # Idempotent re-run
    Invoke-SafeInstall -Root $root
    $installedGemini2 = Get-Content -LiteralPath $installedGeminiPath -Raw -Encoding UTF8
    Assert-Condition 'S11 rerun is identical' ($installedGemini -ceq $installedGemini2) ''

    Invoke-SafeUninstall -Root $root
    $geminiAfterUninstall = Get-Content -LiteralPath $installedGeminiPath -Raw -Encoding UTF8
    Assert-Condition 'S11 uninstall preserves unmanaged GEMINI content' ($geminiAfterUninstall -ceq ($unmanagedGemini -replace "`r?`n", "`r`n")) $geminiAfterUninstall
    Assert-Condition 'S11 uninstall removes mcp-foundation skill from agents' (-not (Test-Path -LiteralPath $mcpSkillPathAgents -PathType Leaf)) ''
    Assert-Condition 'S11 uninstall removes mcp-foundation skill from antigravity 1' (-not (Test-Path -LiteralPath $mcpSkillPathAg1 -PathType Leaf)) ''
    Assert-Condition 'S11 uninstall removes mcp-foundation skill from antigravity 2' (-not (Test-Path -LiteralPath $mcpSkillPathAg2 -PathType Leaf)) ''

    $scenario = 12
    Write-Host 'Scenario 12: doctor scopes GEMINI contract scan to managed block and tolerates unmanaged read-only' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalConfig = '[features]' + $nl + 'multi_agent = false' + $nl + $nl + '[mcp_servers.deepseek-subagent]' + $nl + 'command = "pwsh"' + $nl
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalConfig
    $unmanagedGeminiWithReadOnly = '# My Custom Rules' + $nl + '- All read-only subagents must use sol medium.' + $nl
    $installedGeminiPath = Join-Path (Get-AntigravityHome $root) 'config\GEMINI.md'
    Write-FixtureFile -Path $installedGeminiPath -Content $unmanagedGeminiWithReadOnly

    Invoke-SafeInstall -Root $root

    $docResult1 = Invoke-Doctor -Root $root
    Assert-Condition 'S12 doctor succeeds when read-only is in unmanaged GEMINI content' ($docResult1.ExitCode -eq 0 -and $docResult1.Output -match '\[OK\]\s+Installed contract') $docResult1.Output

    $installedGemini = Get-Content -LiteralPath $installedGeminiPath -Raw -Encoding UTF8
    $tamperedManagedGemini = $installedGemini.Replace('# END CODEX-WORKFLOWS-KIT', '- forbidden read-only inside managed block' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Write-FixtureFile -Path $installedGeminiPath -Content $tamperedManagedGemini

    $docResult2 = Invoke-Doctor -Root $root
    Assert-Condition 'S12 doctor fails when read-only is inside the managed GEMINI block' ($docResult2.ExitCode -ne 0 -and $docResult2.Output -match '\[FAIL\]\s+Installed contract') $docResult2.Output

    Write-FixtureFile -Path $installedGeminiPath -Content $installedGemini
    $docResult3 = Invoke-Doctor -Root $root
    Assert-Condition 'S12 doctor passes again after restoring clean managed block' ($docResult3.ExitCode -eq 0 -and $docResult3.Output -match '\[OK\]\s+Installed contract') $docResult3.Output

    Invoke-SafeUninstall -Root $root

    $scenario = 13
    Write-Host 'Scenario 13: safe profile validates DeepSeek daemon restart fail-closed policy and detects tampered carve-outs' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $canonicalLifecycle = Get-Content -LiteralPath (Join-Path $repo 'skills\mcp-foundation\references\lifecycle.md') -Raw -Encoding UTF8
    $canonicalSkill = Get-Content -LiteralPath (Join-Path $repo 'skills\mcp-foundation\SKILL.md') -Raw -Encoding UTF8
    $canonicalAgents = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
    $canonicalGemini = Get-Content -LiteralPath (Join-Path $repo 'antigravity\GEMINI.md') -Raw -Encoding UTF8

    Assert-Condition 'S13 canonical policies satisfy daemon restart semantics' (Test-DaemonRestartPolicySemantics -LifecycleText $canonicalLifecycle -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini) ''

    # Tamper 1: Unconditional auto-restart without user authorization
    $tamperNoAuth = $canonicalLifecycle + $nl + 'The daemon may restart automatically on error without user consent.'
    Assert-Condition 'S13 detects un-authorized restart tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperNoAuth -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 2: Permitting taskkill / Stop-Process
    $tamperKill = $canonicalLifecycle + $nl + 'Operators may use taskkill or Stop-Process to restart the daemon.'
    Assert-Condition 'S13 detects taskkill/Stop-Process tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperKill -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 3: Wrong endpoint /v1/health introduced
    $tamperV1 = $canonicalLifecycle.Replace('/health', '/v1/health')
    Assert-Condition 'S13 detects /v1/health endpoint tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperV1 -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 4: Trigger on AntigravityProcessError alone
    $tamperAgy = $canonicalLifecycle + $nl + 'May trigger on AntigravityProcessError when the job fails.'
    Assert-Condition 'S13 detects AntigravityProcessError trigger tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperAgy -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 5: Restart other MCPs
    $tamperOtherMcp = $canonicalLifecycle + $nl + 'May restart Serena and CodeGraph when unresponsive.'
    Assert-Condition 'S13 detects other MCP restart tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperOtherMcp -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 6: Restart with active jobs
    $tamperActiveJobs = $canonicalLifecycle + $nl + 'May restart with active jobs in flight if urgent.'
    Assert-Condition 'S13 detects active jobs restart tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperActiveJobs -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 7: Missing required canonical command
    $tamperNoCmd = $canonicalLifecycle.Replace('dist/cli.js restart --config <known-config> --json', 'custom restart script')
    Assert-Condition 'S13 detects missing canonical command tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperNoCmd -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 8: Missing express authorization in lifecycle
    $tamperNoExpress = $canonicalLifecycle.Replace('authorization', 'detection').Replace('Authorization', 'Detection')
    Assert-Condition 'S13 detects missing authorization gate tamper' (-not (Test-DaemonRestartPolicySemantics -LifecycleText $tamperNoExpress -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    $scenario = 14
    Write-Host 'Scenario 14: installed DeepSeek restart policy lifecycle verifies installed mirrors, rejects tampered/missing mirrors via validation and doctor, and heals on reinstall' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalConfig = '[features]' + $nl + 'multi_agent = false' + $nl + $nl + '[mcp_servers.deepseek-subagent]' + $nl + 'command = "pwsh"' + $nl
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalConfig

    Invoke-SafeInstall -Root $root

    # Initial clean post-install validation and doctor
    $val1 = Invoke-Validate -Root $root
    Assert-Condition 'S14 fresh safe install passes post-install validation' ($val1.ExitCode -eq 0 -and $val1.Output -match 'Validation OK') $val1.Output
    $doc1 = Invoke-Doctor -Root $root
    Assert-Condition 'S14 fresh safe install passes doctor' ($doc1.ExitCode -eq 0 -and $doc1.Output -match '\[OK\]\s+Installed contract') $doc1.Output

    $sourceLifecycle = Join-Path $repo 'skills\mcp-foundation\references\lifecycle.md'
    $sourceSkill = Join-Path $repo 'skills\mcp-foundation\SKILL.md'
    $installedLifecycleAgents = Join-Path (Get-AgentsHome $root) 'skills\mcp-foundation\references\lifecycle.md'
    $canonicalLifecycleContent = Get-Content -LiteralPath $sourceLifecycle -Raw -Encoding UTF8

    # Tamper 1: Remove express user authorization from installed agents lifecycle mirror
    $tamperNoAuth = $canonicalLifecycleContent -replace '(?i)express (?:human|user) authorization|explicit user authorization', 'autonomous self-healing without user authorization'
    Write-FixtureFile -Path $installedLifecycleAgents -Content $tamperNoAuth
    $valTamper1 = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation rejects installed lifecycle mirror missing user authorization' ($valTamper1.ExitCode -ne 0 -and $valTamper1.Output -match 'installed mcp-foundation lifecycle\.md \(agents\) is missing required DeepSeek daemon restart policy pattern') $valTamper1.Output
    $docTamper1 = Invoke-Doctor -Root $root
    Assert-Condition 'S14 doctor rejects tampered lifecycle mirror hash' ($docTamper1.ExitCode -ne 0 -and $docTamper1.Output -match '\[FAIL\]\s+Managed artifact') $docTamper1.Output

    # Tamper 2: Add non-trigger carve-out to installed antigravity 1 lifecycle mirror
    Copy-Item -LiteralPath $sourceLifecycle -Destination $installedLifecycleAgents -Force
    $installedLifecycleAg1 = Join-Path (Get-AntigravityHome $root) 'antigravity\skills\mcp-foundation\references\lifecycle.md'
    $tamperNonTrigger = $canonicalLifecycleContent + $nl + 'May trigger on AntigravityProcessError when the subagent fails.'
    Write-FixtureFile -Path $installedLifecycleAg1 -Content $tamperNonTrigger
    $valTamper2 = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation rejects installed antigravity 1 lifecycle mirror with non-trigger carve-out' ($valTamper2.ExitCode -ne 0 -and $valTamper2.Output -match 'permits restarting on non-trigger conditions') $valTamper2.Output
    $docTamper2 = Invoke-Doctor -Root $root
    Assert-Condition 'S14 doctor rejects tampered antigravity 1 lifecycle mirror' ($docTamper2.ExitCode -ne 0 -and $docTamper2.Output -match '\[FAIL\]\s+Managed artifact') $docTamper2.Output

    # Tamper 3: Change endpoint to /v1/health in installed antigravity 2 lifecycle mirror
    Copy-Item -LiteralPath $sourceLifecycle -Destination $installedLifecycleAg1 -Force
    $installedLifecycleAg2 = Join-Path (Get-AntigravityHome $root) 'config\skills\mcp-foundation\references\lifecycle.md'
    $tamperV1 = $canonicalLifecycleContent.Replace('/health', '/v1/health')
    Write-FixtureFile -Path $installedLifecycleAg2 -Content $tamperV1
    $valTamper3 = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation rejects installed antigravity 2 lifecycle mirror with /v1/health' ($valTamper3.ExitCode -ne 0 -and $valTamper3.Output -match 'contains forbidden endpoint /v1/health') $valTamper3.Output

    # Tamper 4: Remove DeepSeek daemon restart exception from installed mcp-foundation SKILL.md
    Copy-Item -LiteralPath $sourceLifecycle -Destination $installedLifecycleAg2 -Force
    $installedSkillAgents = Join-Path (Get-AgentsHome $root) 'skills\mcp-foundation\SKILL.md'
    $canonicalSkillContent = Get-Content -LiteralPath $sourceSkill -Raw -Encoding UTF8
    $tamperSkill = $canonicalSkillContent.Replace('DeepSeek Daemon Restart Exception', 'Generic Restart Exception')
    Write-FixtureFile -Path $installedSkillAgents -Content $tamperSkill
    $valTamper4 = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation rejects installed skill mirror missing DeepSeek restart exception' ($valTamper4.ExitCode -ne 0 -and $valTamper4.Output -match 'installed mcp-foundation SKILL\.md \(agents\) is missing required DeepSeek daemon restart policy pattern') $valTamper4.Output

    # Tamper 5: Remove DeepSeek daemon restart policy from installed AGENTS.md
    Copy-Item -LiteralPath $sourceSkill -Destination $installedSkillAgents -Force
    $installedAgentsPath = Join-Path (Get-CodexHome $root) 'AGENTS.md'
    $canonicalAgentsContent = Get-Content -LiteralPath $installedAgentsPath -Raw -Encoding UTF8
    $tamperAgents = $canonicalAgentsContent.Replace('daemon DeepSeek', 'daemon Generic').Replace('dist/cli.js restart', 'custom restart')
    Write-FixtureFile -Path $installedAgentsPath -Content $tamperAgents
    $valTamper5 = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation rejects installed AGENTS.md missing DeepSeek restart policy' ($valTamper5.ExitCode -ne 0 -and $valTamper5.Output -match 'installed AGENTS\.md is missing required DeepSeek daemon restart policy pattern') $valTamper5.Output

    # Tamper 6: Add /v1/health to installed GEMINI.md
    Write-FixtureFile -Path $installedAgentsPath -Content $canonicalAgentsContent
    $installedGeminiPath = Join-Path (Get-AntigravityHome $root) 'config\GEMINI.md'
    $canonicalGeminiContent = Get-Content -LiteralPath $installedGeminiPath -Raw -Encoding UTF8
    $tamperGemini = $canonicalGeminiContent.Replace('/health', '/v1/health')
    Write-FixtureFile -Path $installedGeminiPath -Content $tamperGemini
    $valTamper6 = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation rejects installed GEMINI.md with /v1/health' ($valTamper6.ExitCode -ne 0 -and $valTamper6.Output -match 'installed GEMINI\.md contains forbidden endpoint /v1/health') $valTamper6.Output

    # Missing mirror test: delete installed lifecycle.md in agents home
    Write-FixtureFile -Path $installedGeminiPath -Content $canonicalGeminiContent
    Remove-Item -LiteralPath $installedLifecycleAgents -Force
    $valMissing = Invoke-Validate -Root $root
    Assert-Condition 'S14 validation fails-closed when an installed policy mirror is missing' ($valMissing.ExitCode -ne 0 -and ($valMissing.Output -match '(?:Required file is missing|Installed.*missing)')) $valMissing.Output
    $docMissing = Invoke-Doctor -Root $root
    Assert-Condition 'S14 doctor detects missing installed mirror' ($docMissing.ExitCode -ne 0 -and $docMissing.Output -match '\[FAIL\]\s+Managed artifact:\s+Missing') $docMissing.Output

    # Healing test: reinstall restores all mirrors and passes validation & doctor
    Invoke-SafeInstall -Root $root
    $valHealed = Invoke-Validate -Root $root
    Assert-Condition 'S14 reinstall heals all mirrors and passes post-install validation' ($valHealed.ExitCode -eq 0 -and $valHealed.Output -match 'Validation OK') $valHealed.Output
    $docHealed = Invoke-Doctor -Root $root
    Assert-Condition 'S14 reinstall heals all mirrors and passes doctor' ($docHealed.ExitCode -eq 0 -and $docHealed.Output -match '\[OK\]\s+Installed contract') $docHealed.Output

    # Uninstall test
    Invoke-SafeUninstall -Root $root
    Assert-Condition 'S14 state is removed after uninstall' (-not (Test-StateExists $root)) ''
}
finally {
    foreach ($fixture in $fixtures) {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures.Count -gt 0) {
    throw ("Safe profile gate fixture failures ({0}): {1}" -f $script:Failures.Count, ($script:Failures -join '; '))
}

Write-Host "Safe profile gate fixtures OK ($($script:Passed) assertions)."
