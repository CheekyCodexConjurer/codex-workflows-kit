[CmdletBinding()]
param(
    [int]$Scenario = 0
)

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

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $prev = $ErrorActionPreference
    $prevGlobal = $global:ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:ErrorActionPreference = 'Continue'
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        }
    }
    finally {
        $ErrorActionPreference = $prev
        $global:ErrorActionPreference = $prevGlobal
    }
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int[]]$ExpectedExitCodes = @(0)
    )

    $prev = $ErrorActionPreference
    $prevGlobal = $global:ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:ErrorActionPreference = 'Continue'
        $allArgs = @('-C', $RepoDir) + $ArgumentList
        $output = & git @allArgs 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        if ($ExpectedExitCodes -notcontains $exitCode) {
            throw "git $(($allArgs) -join ' ') failed with exit code $exitCode. Output:`n$outputText"
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $outputText
        }
    }
    finally {
        $ErrorActionPreference = $prev
        $global:ErrorActionPreference = $prevGlobal
    }
}

function Invoke-DeliveryTargetIdentityCapture {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$OwnedPaths,
        [string]$Baseline = ''
    )

    $prev = $ErrorActionPreference
    $prevGlobal = $global:ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:ErrorActionPreference = 'Continue'
        return Get-CodexDeliveryTargetIdentity -RepoPath $RepoPath -OwnedPaths $OwnedPaths -Baseline $Baseline
    }
    finally {
        $ErrorActionPreference = $prev
        $global:ErrorActionPreference = $prevGlobal
    }
}

function Invoke-CommitGateCapture {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ApprovedTargetId,
        [Parameter(Mandatory)][string[]]$ApprovedOwnedPaths,
        [string]$Baseline = ''
    )

    $prev = $ErrorActionPreference
    $prevGlobal = $global:ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:ErrorActionPreference = 'Continue'
        return Test-CodexCommitGate -RepoPath $RepoPath -ApprovedTargetId $ApprovedTargetId -ApprovedOwnedPaths $ApprovedOwnedPaths -Baseline $Baseline
    }
    finally {
        $ErrorActionPreference = $prev
        $global:ErrorActionPreference = $prevGlobal
    }
}

function Invoke-Doctor {
    param([Parameter(Mandatory)][string]$Root)

    $doctorScript = Join-Path $repo 'scripts\doctor.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $doctorScript, '-CodexHome', (Get-CodexHome $Root), '-AgentsHome', (Get-AgentsHome $Root), '-AntigravityHome', (Get-AntigravityHome $Root))
}

function Invoke-InstallCapture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Profile = 'safe',
        [switch]$Force
    )

    $installerScript = Join-Path $repo 'scripts\install.ps1'
    $argsList = @(
        '-NoProfile',
        '-File', $installerScript,
        '-Profile', $Profile,
        '-CodexHome', (Get-CodexHome $Root),
        '-AgentsHome', (Get-AgentsHome $Root),
        '-AntigravityHome', (Get-AntigravityHome $Root)
    )
    if ($Force) {
        $argsList += '-Force'
    }
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList $argsList
}

function Invoke-UninstallCapture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Force
    )

    $uninstallerScript = Join-Path $repo 'scripts\uninstall.ps1'
    $argsList = @(
        '-NoProfile',
        '-File', $uninstallerScript,
        '-CodexHome', (Get-CodexHome $Root),
        '-AgentsHome', (Get-AgentsHome $Root),
        '-AntigravityHome', (Get-AntigravityHome $Root)
    )
    if ($Force) {
        $argsList += '-Force'
    }
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList $argsList
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

    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList $argsList
}

function Invoke-BackendSwitch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend
    )

    $switchScript = Join-Path $repo 'scripts\switch-subagent-backend.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Backend', $Backend, '-CodexHome', (Get-CodexHome $Root))
}

function Invoke-BackendStatus {
    param([Parameter(Mandatory)][string]$Root)

    $switchScript = Join-Path $repo 'scripts\switch-subagent-backend.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Status', '-CodexHome', (Get-CodexHome $Root))
}

function Invoke-PolicySwitch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('balanced', 'aggressive')][string]$Policy
    )

    $switchScript = Join-Path $repo 'scripts\switch-subagent-policy.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Policy', $Policy, '-CodexHome', (Get-CodexHome $Root))
}

function Invoke-PolicyStatus {
    param([Parameter(Mandatory)][string]$Root)

    $switchScript = Join-Path $repo 'scripts\switch-subagent-policy.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Status', '-CodexHome', (Get-CodexHome $Root))
}

function Invoke-PolicySwitchWithHost {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('balanced', 'aggressive')][string]$Policy,
        [Parameter(Mandatory)][object]$HostInfo
    )

    $switchScript = Join-Path $repo 'scripts\switch-subagent-policy.ps1'
    return Invoke-ProcessCapture -FilePath $HostInfo.Path -ArgumentList @('-NoProfile', '-File', $switchScript, '-Policy', $Policy, '-CodexHome', (Get-CodexHome $Root))
}

function Get-AgentsRuntimeBlock {
    param([Parameter(Mandatory)][string]$Text)

    $backendMatch = [regex]::Match($Text, '(?m)^\s*subagent_backend\s*=\s*([a-zA-Z0-9_-]+)\s*(?:#.*)?$')
    $policyMatch = [regex]::Match($Text, '(?m)^\s*delegation_policy\s*=\s*([a-zA-Z0-9_-]+)\s*(?:#.*)?$')
    return [pscustomobject]@{
        Backend = if ($backendMatch.Success) { $backendMatch.Groups[1].Value } else { $null }
        Policy = if ($policyMatch.Success) { $policyMatch.Groups[1].Value } else { $null }
    }
}

function Get-SwitchHosts {
    $hosts = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            $hosts.Add([pscustomobject]@{
                    Name = if ($name -ceq 'powershell.exe') { 'Windows PowerShell 5.1' } else { 'PowerShell Core' }
                    Path = [string]$command.Source
                })
        }
    }
    if ($hosts.Count -lt 2) {
        throw 'Host regression requires both pwsh.exe and powershell.exe; no host may be silently skipped.'
    }
    return @($hosts.ToArray())
}

function Invoke-BackendSwitchWithHost {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('native', 'deepseek')][string]$Backend,
        [Parameter(Mandatory)][object]$HostInfo
    )

    $switchScript = Join-Path $repo 'scripts\switch-subagent-backend.ps1'
    return Invoke-ProcessCapture -FilePath $HostInfo.Path -ArgumentList @('-NoProfile', '-File', $switchScript, '-Backend', $Backend, '-CodexHome', (Get-CodexHome $Root))
}

function Get-TomlTableBody {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Table
    )

    $normalized = $Text -replace '\r\n', "`n"
    $escaped = [regex]::Escape($Table)
    $pattern = '(?ms)^[ \t]*\[' + $escaped + '\][ \t]*(?:#.*)?\n(?<body>.*?)(?=^[ \t]*\[[^\[\]]+\][ \t]*(?:#.*)?$|\z)'
    $match = [regex]::Match($normalized, $pattern)
    if (-not $match.Success) {
        return ''
    }
    return $match.Groups['body'].Value
}

function Get-TomlTableKeyCount {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Key
    )

    $body = Get-TomlTableBody -Text $Text -Table $Table
    return @([regex]::Matches($body, '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=')).Count
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
    if (-not [regex]::IsMatch($normalized, '(?i)antes de esperar,? mapeie frentes independentes,? depend[e\u00ea]ncias e recursos exclusivos ou compartilhados')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)lance em lote todas as frentes materiais independentes antes do primeiro follow')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)apenas trilhas com depend[e\u00ea]ncia real ou recurso compartilhado ficam seriais')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)enquanto aguarda,? fa[c\u00e7]a orquestra[c\u00e7][\u00e3a]o independente [u\u00fa]til')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)ledger est[a\u00e1]vel de request_id.{0,60}frente,? agente,? job,? estado,? consumido e fechado')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)consuma cada job e feche cada agente ap[o\u00f3]s a integra[c\u00e7][\u00e3a]o')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)deepseek_continue.{0,80}allow_respawn')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)sem pedir nova permiss[\u00e3a]o')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)cria sess[\u00e3a]o.{0,60}lineage')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)nunca recupere job running')) {
        return $false
    }
    if (-not [regex]::IsMatch($normalized, '(?i)sem fallback')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?=[^.;]*\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam|s[a\u00e3]o autorizad[ao]s? a|est[a\u00e3]o autorizad[ao]s? a|usam)\b)(?=[^.;]*\b(?:spawn_agent|wait_agent|multi_agent_v1__spawn_agent)\b)(?=[^.;]*\b(?:supervis[a\u00e3]o|guardian)\b)[^.;]+')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:l[e\u00ea]|ler|escreve|escrever|testa|testar|revisa|revisar|investiga|investigar|executa|executar|realiza|realizar|faz|fazer|verifica|verificar|confere|conferir)\b[^.;]*\b(?:localmente|diretamente|por conta pr[o\u00f3]pria)\b')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:job running|running|em execu[c\u00e7][a\u00e3]o|em andamento|em curso|ativos?|andamento)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:sem resposta final|resposta final persistida|sem resultado final|resultado final persistido|sem resultado terminal)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:abortad[oa]|abortados)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar)\b[^.;]*(?:escopo novo|outro escopo|escopo diferente|frente nova|fora do pedido|mudan[c\u00e7]a material|pedido divergiu|pedido divergente|outro pedido|mudan[c\u00e7]a de cwd|cwd diferente|mudando de cwd|outro cwd|cwd divergente)')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:recupera[r\u00e7]|reabrir|retomar|continuar|abrir|usar|allow_respawn)\b[^.;]*\b(?:fallback|outro provedor|outro modelo|troc\w*|substitu\w*)\b')) {
        return $false
    }
    if ([regex]::IsMatch($normalized, '(?i)\b(?:pode|podem|poderia|poderiam|poder[a\u00e1]|poder[a\u00e3]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:reabrir a sess[a\u00e3]o|mesma sess[a\u00e3]o|sess[a\u00e3]o antiga|continuar a sess[a\u00e3]o|abrir nova sess[a\u00e3]o|sess[a\u00e3]o nova)\b')) {
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
    Assert-Condition 'S1 installs a features table block' (($config1 -like '*# BEGIN CODEX-WORKFLOWS-KIT: *features*') -and (Get-FeatureHeaderCount $config1) -eq 1) $config1
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
    Assert-Condition 'S5 warns about the override' ($outputText -match '(?i)(?:multi_agent|Backend configuration was modified)') $outputText
    Assert-Condition 'S5 preserves install state for review' (Test-StateExists $root) ''

    $scenario = 6
    Write-Host 'Scenario 6: schema-3 install state migrates to schema 5' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
multi_agent = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json') -Content '{"schemaVersion":3,"product":"codex-workflows-kit","profile":"safe","installedAtUtc":"2026-01-01T00:00:00Z","files":[],"pendingFiles":[]}'
    Invoke-SafeInstall -Root $root
    $state = Get-InstallState $root
    Assert-Condition 'S6 state migrates to schema 5' ($null -ne $state -and [int]$state.schemaVersion -eq 5) ''
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
    Assert-Condition 'S7 records the observed feature state' ($null -ne $state -and [int]$state.schemaVersion -eq 5 -and $state.codexFeaturesPrior.multi_agent.present -eq $true -and [string]$state.codexFeaturesPrior.multi_agent.value -ceq 'true') ''
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

    $superTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' Os agentes de supervisao do sistema podem usar spawn_agent para gerenciar o ciclo de vida.' + $nl + '# END CODEX-WORKFLOWS-KIT')
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

    $recoveryNewFrontTampered = $installedAgents.Replace('# END CODEX-WORKFLOWS-KIT', ' O parent pode abrir nova sessao para frente nova.' + $nl + '# END CODEX-WORKFLOWS-KIT')
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

    $scenario = 15
    Write-Host 'Scenario 15: native switch creates the exact matrix from missing tables' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalNativeFixture = 'model = "top-level-model"
reasoning_effort = "top-level-reasoning"
service_tier = "default"

[mcp_servers.sample]
command = "sample"
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalNativeFixture

    $nativeResult = Invoke-BackendSwitch -Root $root -Backend native
    $nativeConfig = Read-Config $root
    Assert-Condition 'S15 native switch succeeds' ($nativeResult.ExitCode -eq 0) $nativeResult.Output
    Assert-Condition 'S15 reports selected backend and running-task boundary' ($nativeResult.Output -match '(?i)native' -and $nativeResult.Output -match '(?i)already-running|already running|running tasks.*unchanged') $nativeResult.Output
    Assert-Condition 'S15 enables native multi-agent matrix' ((Get-MultiAgentValue $nativeConfig) -ceq 'true') $nativeConfig
    Assert-Condition 'S15 explicitly disables fast mode' ($nativeConfig -match '(?m)^\s*fast_mode\s*=\s*false\s*(?:#.*)?$') $nativeConfig
    Assert-Condition 'S15 pins native model and max reasoning' ($nativeConfig -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-5\.6-luna"\s*(?:#.*)?$' -and $nativeConfig -match '(?m)^\s*default_subagent_reasoning_effort\s*=\s*"max"\s*(?:#.*)?$') $nativeConfig
    Assert-Condition 'S15 disables the DeepSeek MCP without deleting its table' ($nativeConfig -match '(?ms)\[mcp_servers\.deepseek-subagent\].*?enabled\s*=\s*false' -and $nativeConfig -match '(?ms)\[mcp_servers\.sample\].*?command\s*=\s*"sample"') $nativeConfig
    Assert-Condition 'S15 preserves top-level model/reasoning/service tier and unrelated MCP' ($nativeConfig -match 'model = "top-level-model"' -and $nativeConfig -match 'reasoning_effort = "top-level-reasoning"' -and $nativeConfig -match 'service_tier = "default"' -and $nativeConfig -match 'command = "sample"') $nativeConfig

    $scenario = 16
    Write-Host 'Scenario 16: backend toggles are reversible, idempotent, and retain captured prior values' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalToggleFixture = '[features]
multi_agent = false
fast_mode = true
js_repl = false

[agents]
default_subagent_model = "user-model"
default_subagent_reasoning_effort = "high"
max_concurrent_threads_per_session = 3

[mcp_servers.deepseek-subagent]
command = "bridge-command"
args = ["--route", "user-route"]
enabled = true

[mcp_servers.sample]
command = "sample"
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalToggleFixture

    $deepseekFirst = Invoke-BackendSwitch -Root $root -Backend deepseek
    $deepseekConfig = Read-Config $root
    Assert-Condition 'S16 first DeepSeek selection succeeds' ($deepseekFirst.ExitCode -eq 0 -and $deepseekConfig -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $deepseekFirst.Output
    $nativeFirst = Invoke-BackendSwitch -Root $root -Backend native
    $nativeConfig16 = Read-Config $root
    Assert-Condition 'S16 native selection succeeds after DeepSeek' ($nativeFirst.ExitCode -eq 0 -and $nativeConfig16 -match '(?m)^\s*multi_agent\s*=\s*true\s*$') $nativeFirst.Output
    $nativeBytes16 = $nativeConfig16
    $nativeSecond = Invoke-BackendSwitch -Root $root -Backend native
    Assert-Condition 'S16 repeated native selection is byte-identical' ($nativeSecond.ExitCode -eq 0 -and (Read-Config $root) -ceq $nativeBytes16) $nativeSecond.Output

    $deepseekSecond = Invoke-BackendSwitch -Root $root -Backend deepseek
    $restoredConfig16 = Read-Config $root
    $expectedToggleConfig = $originalToggleFixture -replace "`r?`n", "`r`n"
    Assert-Condition 'S16 DeepSeek restores all captured prior values' ($deepseekSecond.ExitCode -eq 0 -and $restoredConfig16 -ceq $expectedToggleConfig) $restoredConfig16
    $deepseekBytes16 = $restoredConfig16
    $deepseekThird = Invoke-BackendSwitch -Root $root -Backend deepseek
    Assert-Condition 'S16 repeated DeepSeek selection is byte-identical' ($deepseekThird.ExitCode -eq 0 -and (Read-Config $root) -ceq $deepseekBytes16) $deepseekThird.Output
    $state16 = Get-InstallState $root
    Assert-Condition 'S16 state retains one captured prior record per managed key' ($null -ne $state16 -and $state16.PSObject.Properties.Name -contains 'codexBackend' -and @($state16.codexBackend.prior).Count -eq 5) ''

    $scenario = 17
    Write-Host 'Scenario 17: schema-5 safe install, native switch, safe reinstall preservation, and uninstall restoration' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalInstallFixture = '[features]
multi_agent = false
fast_mode = true

[agents]
default_subagent_model = "preinstall-model"
default_subagent_reasoning_effort = "high"

[mcp_servers.deepseek-subagent]
command = "preinstall-bridge"
enabled = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalInstallFixture
    Invoke-SafeInstall -Root $root
    $stateBeforeSwitch17 = Get-InstallState $root
    Assert-Condition 'S17 starts from a schema-5 safe install with default delegation' ($null -ne $stateBeforeSwitch17 -and [int]$stateBeforeSwitch17.schemaVersion -eq 5 -and [string]$stateBeforeSwitch17.codexDelegation.selected -ceq 'balanced') ''

    $native17 = Invoke-BackendSwitch -Root $root -Backend native
    $nativeConfig17 = Read-Config $root
    $stateAfterSwitch17 = Get-InstallState $root
    Assert-Condition 'S17 native switch updates the schema-5 state' ($native17.ExitCode -eq 0 -and $null -ne $stateAfterSwitch17.codexBackend -and [int]$stateAfterSwitch17.schemaVersion -eq 5 -and [string]$stateAfterSwitch17.codexBackend.selected -ceq 'native' -and [string]$stateAfterSwitch17.codexDelegation.selected -ceq 'balanced') $native17.Output
    Assert-Condition 'S17 native matrix is active before reinstall' ($nativeConfig17 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $nativeConfig17 -match '(?m)^\s*fast_mode\s*=\s*false\s*$') $nativeConfig17

    Invoke-SafeInstall -Root $root
    $nativeAfterReinstall17 = Read-Config $root
    $stateAfterReinstall17 = Get-InstallState $root
    Assert-Condition 'S17 safe reinstall preserves the selected native backend' ($nativeAfterReinstall17 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $nativeAfterReinstall17 -match '(?m)^\s*fast_mode\s*=\s*false\s*$' -and $nativeAfterReinstall17 -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-5\.6-luna"\s*$' -and [string]$stateAfterReinstall17.codexBackend.selected -ceq 'native') $nativeAfterReinstall17

    $deepseek17 = Invoke-BackendSwitch -Root $root -Backend deepseek
    Assert-Condition 'S17 deepseek switch succeeds after reinstall' ($deepseek17.ExitCode -eq 0 -and (Read-Config $root) -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $deepseek17.Output
    Invoke-SafeUninstall -Root $root
    $restoredAfterUninstall17 = Read-Config $root
    $expectedInstallConfig17 = $originalInstallFixture -replace "`r?`n", "`r`n"
    Assert-Condition 'S17 uninstall restores every captured prior value' ($restoredAfterUninstall17 -ceq $expectedInstallConfig17) $restoredAfterUninstall17

    $scenario = 18
    Write-Host 'Scenario 18: drift, tamper, doctor, and validator fail closed for both backends' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalSafetyFixture = '[features]
multi_agent = false
fast_mode = true

[agents]
default_subagent_model = "safe-model"
default_subagent_reasoning_effort = "high"

[mcp_servers.deepseek-subagent]
command = "safe-bridge"
enabled = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalSafetyFixture
    Invoke-SafeInstall -Root $root
    $nativeSafety = Invoke-BackendSwitch -Root $root -Backend native
    Assert-Condition 'S18 native switch succeeds before safety checks' ($nativeSafety.ExitCode -eq 0) $nativeSafety.Output

    $configPath18 = Join-Path (Get-CodexHome $root) 'config.toml'
    $nativeTampered = (Read-Config $root).Replace('default_subagent_model = "gpt-5.6-luna"', 'default_subagent_model = "user-tampered-model"')
    Write-FixtureFile -Path $configPath18 -Content $nativeTampered
    $driftResult18 = Invoke-BackendSwitch -Root $root -Backend deepseek
    Assert-Condition 'S18 user config drift blocks switching' ($driftResult18.ExitCode -ne 0 -and $driftResult18.Output -match '(?i)drift') $driftResult18.Output
    Assert-Condition 'S18 drift block leaves config untouched' ((Read-Config $root) -ceq $nativeTampered) ''

    Write-FixtureFile -Path $configPath18 -Content (Read-Config $root).Replace('user-tampered-model', 'gpt-5.6-luna')
    $statePath18 = Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json'
    $tamperedState18 = Get-InstallState $root
    $tamperedState18.codexBackend.selected = 'deepseek'
    Write-FixtureFile -Path $statePath18 -Content (($tamperedState18 | ConvertTo-Json -Depth 8) + $nl)
    $inconsistentResult18 = Invoke-BackendSwitch -Root $root -Backend native
    Assert-Condition 'S18 inconsistent selected matrix blocks switching' ($inconsistentResult18.ExitCode -ne 0 -and $inconsistentResult18.Output -match '(?i)inconsistent|matrix') $inconsistentResult18.Output

    Write-FixtureFile -Path $statePath18 -Content ((Get-InstallState $root | ForEach-Object { $_.codexBackend.selected = 'native'; $_ }) | ConvertTo-Json -Depth 8)
    $doctorNative18 = Invoke-Doctor -Root $root
    $validateNative18 = Invoke-Validate -Root $root
    Assert-Condition 'S18 doctor reports the native backend matrix' ($doctorNative18.ExitCode -eq 0 -and $doctorNative18.Output -match '(?i)Backend.*native' -and $doctorNative18.Output -match '(?i)matrix') $doctorNative18.Output
    Assert-Condition 'S18 validator reports the native backend matrix' ($validateNative18.ExitCode -eq 0 -and $validateNative18.Output -match '(?i)native' -and $validateNative18.Output -match 'Validation OK') $validateNative18.Output

    $deepseekSafety = Invoke-BackendSwitch -Root $root -Backend deepseek
    $doctorDeepseek18 = Invoke-Doctor -Root $root
    $validateDeepseek18 = Invoke-Validate -Root $root
    Assert-Condition 'S18 doctor reports the DeepSeek backend matrix' ($deepseekSafety.ExitCode -eq 0 -and $doctorDeepseek18.ExitCode -eq 0 -and $doctorDeepseek18.Output -match '(?i)Backend.*deepseek' -and $doctorDeepseek18.Output -match '(?i)matrix') $doctorDeepseek18.Output
    Assert-Condition 'S18 validator reports the DeepSeek backend matrix' ($validateDeepseek18.ExitCode -eq 0 -and $validateDeepseek18.Output -match '(?i)deepseek' -and $validateDeepseek18.Output -match 'Validation OK') $validateDeepseek18.Output

    $scenario = 19
    Write-Host 'Scenario 19: public switch regression across PowerShell hosts and multi-table ranges' -ForegroundColor Cyan
    foreach ($hostInfo in (Get-SwitchHosts)) {
        $root = New-FixtureHome
        $fixtures.Add($root)
        $hostLabel = $hostInfo.Name
        $originalHostFixture = 'model = "top-level-model"
reasoning_effort = "top-level-reasoning"
service_tier = "default"

[features]
multi_agent = false
fast_mode = true
js_repl = false

[agents]
default_subagent_model = "prior-model"
default_subagent_reasoning_effort = "high"
max_concurrent_threads_per_session = 3

[mcp_servers.deepseek-subagent]
command = "prior-bridge"
args = ["--route", "prior-route"]
enabled = true
'
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalHostFixture

        $nativeHostFirst = Invoke-BackendSwitchWithHost -Root $root -Backend native -HostInfo $hostInfo
        $nativeHostConfig = Read-Config $root
        $featuresHostBody = Get-TomlTableBody -Text $nativeHostConfig -Table 'features'
        $agentsHostBody = Get-TomlTableBody -Text $nativeHostConfig -Table 'agents'
        $deepseekHostBody = Get-TomlTableBody -Text $nativeHostConfig -Table 'mcp_servers.deepseek-subagent'
        $nativeExact = $nativeHostFirst.ExitCode -eq 0 -and
            (Get-TomlTableKeyCount -Text $nativeHostConfig -Table 'features' -Key 'multi_agent') -eq 1 -and $featuresHostBody -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and
            (Get-TomlTableKeyCount -Text $nativeHostConfig -Table 'features' -Key 'fast_mode') -eq 1 -and $featuresHostBody -match '(?m)^\s*fast_mode\s*=\s*false\s*$' -and
            (Get-TomlTableKeyCount -Text $nativeHostConfig -Table 'agents' -Key 'default_subagent_model') -eq 1 -and $agentsHostBody -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-5\.6-luna"\s*$' -and
            (Get-TomlTableKeyCount -Text $nativeHostConfig -Table 'agents' -Key 'default_subagent_reasoning_effort') -eq 1 -and $agentsHostBody -match '(?m)^\s*default_subagent_reasoning_effort\s*=\s*"max"\s*$' -and
            (Get-TomlTableKeyCount -Text $nativeHostConfig -Table 'mcp_servers.deepseek-subagent' -Key 'enabled') -eq 1 -and $deepseekHostBody -match '(?m)^\s*enabled\s*=\s*false\s*$'
        Assert-Condition "S19 $hostLabel first native switch has exact five-key matrix and one managed key each" $nativeExact $nativeHostFirst.Output
        Assert-Condition "S19 $hostLabel retains the DeepSeek MCP table and unrelated values" ($deepseekHostBody -match '(?m)^\s*command\s*=\s*"prior-bridge"\s*$' -and $nativeHostConfig -match 'model = "top-level-model"' -and $nativeHostConfig -match 'service_tier = "default"') $nativeHostConfig

        $nativeHostBytes = $nativeHostConfig
        $nativeHostSecond = Invoke-BackendSwitchWithHost -Root $root -Backend native -HostInfo $hostInfo
        Assert-Condition "S19 $hostLabel immediate native rerun succeeds and is byte-idempotent" ($nativeHostSecond.ExitCode -eq 0 -and (Read-Config $root) -ceq $nativeHostBytes) $nativeHostSecond.Output

        $deepseekHostFirst = Invoke-BackendSwitchWithHost -Root $root -Backend deepseek -HostInfo $hostInfo
        $restoredHostConfig = Read-Config $root
        $expectedHostConfig = $originalHostFixture -replace "`r?`n", "`r`n"
        $restoreDetail = if ($restoredHostConfig -ceq $expectedHostConfig) { $deepseekHostFirst.Output } else { "actualLength=$($restoredHostConfig.Length), expectedLength=$($expectedHostConfig.Length), actualTail=$($restoredHostConfig.Substring([Math]::Max(0, $restoredHostConfig.Length - 40))), expectedTail=$($expectedHostConfig.Substring([Math]::Max(0, $expectedHostConfig.Length - 40)))" }
        Assert-Condition "S19 $hostLabel DeepSeek restores exact prior values and presence" ($deepseekHostFirst.ExitCode -eq 0 -and $restoredHostConfig -ceq $expectedHostConfig) $restoreDetail

        $deepseekHostBytes = $restoredHostConfig
        $deepseekHostSecond = Invoke-BackendSwitchWithHost -Root $root -Backend deepseek -HostInfo $hostInfo
        Assert-Condition "S19 $hostLabel repeated DeepSeek rerun succeeds and is byte-idempotent" ($deepseekHostSecond.ExitCode -eq 0 -and (Read-Config $root) -ceq $deepseekHostBytes) $deepseekHostSecond.Output
    }

    $scenario = 20
    Write-Host 'Scenario 20: schema-4 migration to schema 5, default balanced delegation, runtime block in global AGENTS only, and clean static source template' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalS20 = '[features]
multi_agent = false
fast_mode = true

[agents]
default_subagent_model = "prior-model"
default_subagent_reasoning_effort = "high"

[mcp_servers.deepseek-subagent]
command = "bridge-cmd"
enabled = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS20
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json') -Content '{"schemaVersion":4,"product":"codex-workflows-kit","profile":"safe","installedAtUtc":"2026-01-01T00:00:00Z","files":[],"pendingFiles":[],"codexFeaturesPrior":{"multi_agent":{"present":true,"value":"false"}},"codexBackend":{"version":1,"selected":"deepseek","prior":[{"path":"features.multi_agent","tablePresent":true,"present":true,"value":"false"},{"path":"features.fast_mode","tablePresent":true,"present":true,"value":"true"},{"path":"agents.default_subagent_model","tablePresent":true,"present":true,"value":"\"prior-model\""},{"path":"agents.default_subagent_reasoning_effort","tablePresent":true,"present":true,"value":"\"high\""},{"path":"mcp_servers.deepseek-subagent.enabled","tablePresent":true,"present":true,"value":"true"}]}}'
    Invoke-SafeInstall -Root $root
    $state20 = Get-InstallState $root
    Assert-Condition 'S20 state migrates from schema 4 to schema 5' ($null -ne $state20 -and [int]$state20.schemaVersion -eq 5) ''
    Assert-Condition 'S20 delegation state defaults to balanced' ($null -ne $state20 -and ($state20.PSObject.Properties.Name -contains 'codexDelegation') -and [string]$state20.codexDelegation.selected -ceq 'balanced') ''
    Assert-Condition 'S20 backend state is preserved as deepseek' ($null -ne $state20 -and [string]$state20.codexBackend.selected -ceq 'deepseek') ''

    $installedAgents20 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
    $runtimeBlock20 = Get-AgentsRuntimeBlock -Text $installedAgents20
    Assert-Condition 'S20 global installed AGENTS.md contains runtime block with backend=deepseek' ($runtimeBlock20.Backend -ceq 'deepseek') $installedAgents20
    Assert-Condition 'S20 global installed AGENTS.md contains runtime block with policy=balanced' ($runtimeBlock20.Policy -ceq 'balanced') $installedAgents20

    $sourceAgentsText = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
    Assert-Condition 'S20 repository source codex/AGENTS.md is static template with no active runtime block' ($sourceAgentsText.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: runtime', [StringComparison]::Ordinal) -lt 0) $sourceAgentsText

    $scenario = 21
    Write-Host 'Scenario 21: four orthogonal backend/policy combinations, policy switch preserves backend/config, backend switch preserves policy' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalS21 = '[features]
multi_agent = false
fast_mode = true

[agents]
default_subagent_model = "prior-model"
default_subagent_reasoning_effort = "high"

[mcp_servers.deepseek-subagent]
command = "prior-bridge"
enabled = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS21
    Invoke-SafeInstall -Root $root

    # 1. Start: (deepseek, balanced)
    $state21_1 = Get-InstallState $root
    Assert-Condition 'S21 initial state is (deepseek, balanced)' ([string]$state21_1.codexBackend.selected -ceq 'deepseek' -and [string]$state21_1.codexDelegation.selected -ceq 'balanced') ''

    # 2. Switch policy to aggressive -> (deepseek, aggressive)
    $polAggResult = Invoke-PolicySwitch -Root $root -Policy aggressive
    $config21_2 = Read-Config $root
    $state21_2 = Get-InstallState $root
    $agents21_2 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
    $rt21_2 = Get-AgentsRuntimeBlock -Text $agents21_2
    Assert-Condition 'S21 switch policy to aggressive succeeds' ($polAggResult.ExitCode -eq 0) $polAggResult.Output
    Assert-Condition 'S21 policy switch leaves config.toml untouched' ($config21_2 -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $config21_2
    Assert-Condition 'S21 policy switch preserves backend deepseek in state and runtime block' ([string]$state21_2.codexBackend.selected -ceq 'deepseek' -and $rt21_2.Backend -ceq 'deepseek') ''
    Assert-Condition 'S21 policy switch updates policy to aggressive in state and runtime block' ([string]$state21_2.codexDelegation.selected -ceq 'aggressive' -and $rt21_2.Policy -ceq 'aggressive') ''

    # 3. Switch backend to native -> (native, aggressive)
    $backNatResult = Invoke-BackendSwitch -Root $root -Backend native
    $config21_3 = Read-Config $root
    $state21_3 = Get-InstallState $root
    $agents21_3 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
    $rt21_3 = Get-AgentsRuntimeBlock -Text $agents21_3
    Assert-Condition 'S21 switch backend to native succeeds' ($backNatResult.ExitCode -eq 0) $backNatResult.Output
    Assert-Condition 'S21 backend switch activates native matrix in config.toml' ($config21_3 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $config21_3 -match '(?m)^\s*fast_mode\s*=\s*false\s*$') $config21_3
    Assert-Condition 'S21 backend switch updates backend to native in state and runtime block' ([string]$state21_3.codexBackend.selected -ceq 'native' -and $rt21_3.Backend -ceq 'native') ''
    Assert-Condition 'S21 backend switch preserves policy aggressive in state and runtime block' ([string]$state21_3.codexDelegation.selected -ceq 'aggressive' -and $rt21_3.Policy -ceq 'aggressive') ''

    # 4. Switch policy to balanced -> (native, balanced)
    $polBalResult = Invoke-PolicySwitch -Root $root -Policy balanced
    $config21_4 = Read-Config $root
    $state21_4 = Get-InstallState $root
    $agents21_4 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
    $rt21_4 = Get-AgentsRuntimeBlock -Text $agents21_4
    Assert-Condition 'S21 switch policy to balanced succeeds' ($polBalResult.ExitCode -eq 0) $polBalResult.Output
    Assert-Condition 'S21 policy switch leaves native config.toml untouched' ($config21_4 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $config21_4 -match '(?m)^\s*fast_mode\s*=\s*false\s*$') $config21_4
    Assert-Condition 'S21 policy switch preserves backend native' ([string]$state21_4.codexBackend.selected -ceq 'native' -and $rt21_4.Backend -ceq 'native') ''
    Assert-Condition 'S21 policy switch updates policy to balanced' ([string]$state21_4.codexDelegation.selected -ceq 'balanced' -and $rt21_4.Policy -ceq 'balanced') ''

    # 5. Switch backend to deepseek -> (deepseek, balanced)
    $backDeepResult = Invoke-BackendSwitch -Root $root -Backend deepseek
    $config21_5 = Read-Config $root
    $state21_5 = Get-InstallState $root
    $agents21_5 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
    $rt21_5 = Get-AgentsRuntimeBlock -Text $agents21_5
    Assert-Condition 'S21 switch backend to deepseek succeeds' ($backDeepResult.ExitCode -eq 0) $backDeepResult.Output
    Assert-Condition 'S21 backend switch restores deepseek config.toml' ($config21_5 -ceq ($originalS21 -replace "`r?`n", "`r`n")) $config21_5
    Assert-Condition 'S21 backend is deepseek and policy is balanced' ([string]$state21_5.codexBackend.selected -ceq 'deepseek' -and $rt21_5.Backend -ceq 'deepseek' -and [string]$state21_5.codexDelegation.selected -ceq 'balanced' -and $rt21_5.Policy -ceq 'balanced') ''

    $scenario = 22
    Write-Host 'Scenario 22: idempotence, status reporting on both switchers, drift blocking, and rollback' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS21
    Invoke-SafeInstall -Root $root

    # Idempotence: re-running policy switch with balanced
    $polBalRe = Invoke-PolicySwitch -Root $root -Policy balanced
    Assert-Condition 'S22 re-selecting balanced policy is idempotent' ($polBalRe.ExitCode -eq 0 -and $polBalRe.Output -match '(?i)already active|no files changed') $polBalRe.Output

    # Status reporting on both switchers
    $polStatus = Invoke-PolicyStatus -Root $root
    $backStatus = Invoke-BackendStatus -Root $root
    Assert-Condition 'S22 switch-subagent-policy -Status reports active backend and policy' ($polStatus.ExitCode -eq 0 -and $polStatus.Output -match '(?i)backend:\s*deepseek' -and $polStatus.Output -match '(?i)policy:\s*balanced') $polStatus.Output
    Assert-Condition 'S22 switch-subagent-backend -Status reports active backend and policy' ($backStatus.ExitCode -eq 0 -and $backStatus.Output -match '(?i)backend:\s*deepseek' -and $backStatus.Output -match '(?i)policy:\s*balanced') $backStatus.Output

    # Drift blocking on AGENTS.md
    $agentsPath22 = Join-Path (Get-CodexHome $root) 'AGENTS.md'
    $agentsContent22 = Get-Content -LiteralPath $agentsPath22 -Raw -Encoding UTF8
    $driftAgentsContent22 = $agentsContent22 + $nl + '# user drift'
    Write-FixtureFile -Path $agentsPath22 -Content $driftAgentsContent22
    $driftPolResult = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S22 AGENTS.md drift blocks policy switching' ($driftPolResult.ExitCode -ne 0 -and $driftPolResult.Output -match '(?i)drift') $driftPolResult.Output
    Assert-Condition 'S22 AGENTS.md drift block leaves content untouched' ((Get-Content -LiteralPath $agentsPath22 -Raw -Encoding UTF8) -ceq $driftAgentsContent22) ''

    # Restore clean AGENTS.md
    Write-FixtureFile -Path $agentsPath22 -Content $agentsContent22
    $polAggClean = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S22 policy switch succeeds after restoring clean AGENTS.md' ($polAggClean.ExitCode -eq 0) $polAggClean.Output

    $scenario = 23
    Write-Host 'Scenario 23: fail-closed on missing/invalid/inconsistent delegation policy or runtime block; doctor and validator verification' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS21
    Invoke-SafeInstall -Root $root

    # Doctor and validator on clean state
    $doc23Clean = Invoke-Doctor -Root $root
    $val23Clean = Invoke-Validate -Root $root
    Assert-Condition 'S23 clean install passes doctor' ($doc23Clean.ExitCode -eq 0 -and $doc23Clean.Output -match '\[OK\]\s+Selected backend' -and $doc23Clean.Output -match '\[OK\]\s+Delegation policy') $doc23Clean.Output
    Assert-Condition 'S23 clean install passes validator' ($val23Clean.ExitCode -eq 0 -and $val23Clean.Output -match 'Validation OK') $val23Clean.Output

    # Tamper runtime block in AGENTS.md (inconsistency between state and AGENTS.md)
    $agentsPath23 = Join-Path (Get-CodexHome $root) 'AGENTS.md'
    $agentsContent23 = Get-Content -LiteralPath $agentsPath23 -Raw -Encoding UTF8
    $tamperedAgents23 = $agentsContent23 -replace 'delegation_policy = balanced', 'delegation_policy = aggressive'
    Write-FixtureFile -Path $agentsPath23 -Content $tamperedAgents23
    $doc23Tamper = Invoke-Doctor -Root $root
    Assert-Condition 'S23 doctor fails when AGENTS.md runtime block is inconsistent with state' ($doc23Tamper.ExitCode -ne 0) $doc23Tamper.Output

    # Restore clean AGENTS.md
    Write-FixtureFile -Path $agentsPath23 -Content $agentsContent23

    $scenario = 24
    Write-Host 'Scenario 24: public policy switch regression across PowerShell hosts' -ForegroundColor Cyan
    foreach ($hostInfo in (Get-SwitchHosts)) {
        $root = New-FixtureHome
        $fixtures.Add($root)
        $hostLabel = $hostInfo.Name
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS21
        Invoke-SafeInstall -Root $root

        $polHostAgg = Invoke-PolicySwitchWithHost -Root $root -Policy aggressive -HostInfo $hostInfo
        $stateHostAgg = Get-InstallState $root
        $agentsHostAgg = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
        $rtHostAgg = Get-AgentsRuntimeBlock -Text $agentsHostAgg
        Assert-Condition "S24 $hostLabel policy switch to aggressive succeeds" ($polHostAgg.ExitCode -eq 0 -and $null -ne $stateHostAgg.codexDelegation -and [string]$stateHostAgg.codexDelegation.selected -ceq 'aggressive' -and $rtHostAgg.Policy -ceq 'aggressive') $polHostAgg.Output

        $polHostBal = Invoke-PolicySwitchWithHost -Root $root -Policy balanced -HostInfo $hostInfo
        $stateHostBal = Get-InstallState $root
        $agentsHostBal = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root) 'AGENTS.md') -Raw -Encoding UTF8
        $rtHostBal = Get-AgentsRuntimeBlock -Text $agentsHostBal
        Assert-Condition "S24 $hostLabel policy switch back to balanced succeeds" ($polHostBal.ExitCode -eq 0 -and $null -ne $stateHostBal.codexDelegation -and [string]$stateHostBal.codexDelegation.selected -ceq 'balanced' -and $rtHostBal.Policy -ceq 'balanced') $polHostBal.Output
    }

    $scenario = 25
    Write-Host 'Scenario 25: strict schema 5 requires codexBackend and codexDelegation; schema 1-4 absent delegation migrates to balanced, but present invalid selector fails closed' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $originalS25 = '[features]
multi_agent = false
fast_mode = true

[agents]
default_subagent_model = "prior-model"
default_subagent_reasoning_effort = "high"

[mcp_servers.deepseek-subagent]
command = "bridge-cmd"
enabled = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS25
    Invoke-SafeInstall -Root $root
    $statePath25 = Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json'

    # S25.1: Schema 5 missing codexDelegation fails closed in doctor, validate, switchers, uninstall
    $stateMissingDelegation = Get-InstallState $root
    $stateMissingDelegation.PSObject.Properties.Remove('codexDelegation')
    Write-FixtureFile -Path $statePath25 -Content (($stateMissingDelegation | ConvertTo-Json -Depth 8) + $nl)
    $docS25_1 = Invoke-Doctor -Root $root
    $valS25_1 = Invoke-Validate -Root $root
    $backS25_1 = Invoke-BackendSwitch -Root $root -Backend native
    $polS25_1 = Invoke-PolicySwitch -Root $root -Policy aggressive
    $uninstS25_1 = Invoke-UninstallCapture -Root $root
    Assert-Condition 'S25 doctor fails closed when schema 5 is missing codexDelegation' ($docS25_1.ExitCode -ne 0) $docS25_1.Output
    Assert-Condition 'S25 validate fails closed when schema 5 is missing codexDelegation' ($valS25_1.ExitCode -ne 0) $valS25_1.Output
    Assert-Condition 'S25 backend switcher fails closed when schema 5 is missing codexDelegation' ($backS25_1.ExitCode -ne 0) $backS25_1.Output
    Assert-Condition 'S25 policy switcher fails closed when schema 5 is missing codexDelegation' ($polS25_1.ExitCode -ne 0) $polS25_1.Output
    Assert-Condition 'S25 uninstall fails closed when schema 5 is missing codexDelegation' ($uninstS25_1.ExitCode -ne 0) $uninstS25_1.Output

    # S25.2: Schema 5 missing codexBackend fails closed in doctor, validate, switchers, uninstall
    Remove-Item -LiteralPath $statePath25 -Force -ErrorAction SilentlyContinue
    Invoke-SafeInstall -Root $root
    $stateMissingBackend = Get-InstallState $root
    $stateMissingBackend.PSObject.Properties.Remove('codexBackend')
    Write-FixtureFile -Path $statePath25 -Content (($stateMissingBackend | ConvertTo-Json -Depth 8) + $nl)
    $docS25_2 = Invoke-Doctor -Root $root
    $valS25_2 = Invoke-Validate -Root $root
    $backS25_2 = Invoke-BackendSwitch -Root $root -Backend native
    $polS25_2 = Invoke-PolicySwitch -Root $root -Policy aggressive
    $uninstS25_2 = Invoke-UninstallCapture -Root $root
    Assert-Condition 'S25 doctor fails closed when schema 5 is missing codexBackend' ($docS25_2.ExitCode -ne 0) $docS25_2.Output
    Assert-Condition 'S25 validate fails closed when schema 5 is missing codexBackend' ($valS25_2.ExitCode -ne 0) $valS25_2.Output
    Assert-Condition 'S25 backend switcher fails closed when schema 5 is missing codexBackend' ($backS25_2.ExitCode -ne 0) $backS25_2.Output
    Assert-Condition 'S25 policy switcher fails closed when schema 5 is missing codexBackend' ($polS25_2.ExitCode -ne 0) $polS25_2.Output
    Assert-Condition 'S25 uninstall fails closed when schema 5 is missing codexBackend' ($uninstS25_2.ExitCode -ne 0) $uninstS25_2.Output

    # S25.3: Schema 5 with invalid codexDelegation.selected fails closed in doctor, validate, switchers, uninstall
    Remove-Item -LiteralPath $statePath25 -Force -ErrorAction SilentlyContinue
    Invoke-SafeInstall -Root $root
    $stateInvalidDelegation = Get-InstallState $root
    $stateInvalidDelegation.codexDelegation.selected = 'unsupported_policy'
    Write-FixtureFile -Path $statePath25 -Content (($stateInvalidDelegation | ConvertTo-Json -Depth 8) + $nl)
    $docS25_3 = Invoke-Doctor -Root $root
    $valS25_3 = Invoke-Validate -Root $root
    $backS25_3 = Invoke-BackendSwitch -Root $root -Backend native
    $polS25_3 = Invoke-PolicySwitch -Root $root -Policy aggressive
    $uninstS25_3 = Invoke-UninstallCapture -Root $root
    Assert-Condition 'S25 doctor fails closed when schema 5 codexDelegation is invalid' ($docS25_3.ExitCode -ne 0) $docS25_3.Output
    Assert-Condition 'S25 validate fails closed when schema 5 codexDelegation is invalid' ($valS25_3.ExitCode -ne 0) $valS25_3.Output
    Assert-Condition 'S25 backend switcher fails closed when schema 5 codexDelegation is invalid' ($backS25_3.ExitCode -ne 0) $backS25_3.Output
    Assert-Condition 'S25 policy switcher fails closed when schema 5 codexDelegation is invalid' ($polS25_3.ExitCode -ne 0) $polS25_3.Output
    Assert-Condition 'S25 uninstall fails closed when schema 5 codexDelegation is invalid' ($uninstS25_3.ExitCode -ne 0) $uninstS25_3.Output

    # S25.4: Schema 5 with invalid codexBackend.selected fails closed in doctor, validate, switchers, uninstall
    Remove-Item -LiteralPath $statePath25 -Force -ErrorAction SilentlyContinue
    Invoke-SafeInstall -Root $root
    $stateInvalidBackend = Get-InstallState $root
    $stateInvalidBackend.codexBackend.selected = 'unsupported_backend'
    Write-FixtureFile -Path $statePath25 -Content (($stateInvalidBackend | ConvertTo-Json -Depth 8) + $nl)
    $docS25_4 = Invoke-Doctor -Root $root
    $valS25_4 = Invoke-Validate -Root $root
    $backS25_4 = Invoke-BackendSwitch -Root $root -Backend native
    $polS25_4 = Invoke-PolicySwitch -Root $root -Policy aggressive
    $uninstS25_4 = Invoke-UninstallCapture -Root $root
    Assert-Condition 'S25 doctor fails closed when schema 5 codexBackend is invalid' ($docS25_4.ExitCode -ne 0) $docS25_4.Output
    Assert-Condition 'S25 validate fails closed when schema 5 codexBackend is invalid' ($valS25_4.ExitCode -ne 0) $valS25_4.Output
    Assert-Condition 'S25 backend switcher fails closed when schema 5 codexBackend is invalid' ($backS25_4.ExitCode -ne 0) $backS25_4.Output
    Assert-Condition 'S25 policy switcher fails closed when schema 5 codexBackend is invalid' ($polS25_4.ExitCode -ne 0) $polS25_4.Output
    Assert-Condition 'S25 uninstall fails closed when schema 5 codexBackend is invalid' ($uninstS25_4.ExitCode -ne 0) $uninstS25_4.Output

    # S25.5: Schema 3 with PRESENT invalid codexDelegation selector fails closed (never defaults silently to balanced)
    $stateS3Invalid = [ordered]@{
        schemaVersion = 3
        product = 'codex-workflows-kit'
        profile = 'safe'
        installedAtUtc = '2026-01-01T00:00:00Z'
        files = @()
        pendingFiles = @()
        codexDelegation = @{
            version = 1
            selected = 'invalid_policy_selector'
        }
    } | ConvertTo-Json -Depth 8
    Write-FixtureFile -Path $statePath25 -Content ($stateS3Invalid + $nl)
    $installS25_5 = Invoke-InstallCapture -Root $root
    $uninstS25_5 = Invoke-UninstallCapture -Root $root
    $backS25_5 = Invoke-BackendSwitch -Root $root -Backend native
    $polS25_5 = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S25 safe install fails closed when schema 3 has present invalid codexDelegation' ($installS25_5.ExitCode -ne 0) $installS25_5.Output
    Assert-Condition 'S25 safe uninstall fails closed when schema 3 has present invalid codexDelegation' ($uninstS25_5.ExitCode -ne 0) $uninstS25_5.Output
    Assert-Condition 'S25 backend switcher fails closed when schema 3 has present invalid codexDelegation' ($backS25_5.ExitCode -ne 0) $backS25_5.Output
    Assert-Condition 'S25 policy switcher fails closed when schema 3 has present invalid codexDelegation' ($polS25_5.ExitCode -ne 0) $polS25_5.Output

    # S25.6: Schema 4 with PRESENT invalid codexDelegation selector fails closed (never defaults silently to balanced)
    $stateS4Invalid = [ordered]@{
        schemaVersion = 4
        product = 'codex-workflows-kit'
        profile = 'safe'
        installedAtUtc = '2026-01-01T00:00:00Z'
        files = @()
        pendingFiles = @()
        codexFeaturesPrior = @{ multi_agent = @{ present = $true; value = 'false' } }
        codexBackend = @{
            version = 1
            selected = 'deepseek'
            prior = @(
                @{ path = 'features.multi_agent'; tablePresent = $true; present = $true; value = 'false' },
                @{ path = 'features.fast_mode'; tablePresent = $true; present = $true; value = 'true' },
                @{ path = 'agents.default_subagent_model'; tablePresent = $true; present = $true; value = '"prior-model"' },
                @{ path = 'agents.default_subagent_reasoning_effort'; tablePresent = $true; present = $true; value = '"high"' },
                @{ path = 'mcp_servers.deepseek-subagent.enabled'; tablePresent = $true; present = $true; value = 'true' }
            )
        }
        codexDelegation = @{
            version = 1
            selected = 'invalid_policy_selector'
        }
    } | ConvertTo-Json -Depth 8
    Write-FixtureFile -Path $statePath25 -Content ($stateS4Invalid + $nl)
    $installS25_6 = Invoke-InstallCapture -Root $root
    $uninstS25_6 = Invoke-UninstallCapture -Root $root
    $backS25_6 = Invoke-BackendSwitch -Root $root -Backend native
    $polS25_6 = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S25 safe install fails closed when schema 4 has present invalid codexDelegation' ($installS25_6.ExitCode -ne 0) $installS25_6.Output
    Assert-Condition 'S25 safe uninstall fails closed when schema 4 has present invalid codexDelegation' ($uninstS25_6.ExitCode -ne 0) $uninstS25_6.Output
    Assert-Condition 'S25 backend switcher fails closed when schema 4 has present invalid codexDelegation' ($backS25_6.ExitCode -ne 0) $backS25_6.Output
    Assert-Condition 'S25 policy switcher fails closed when schema 4 has present invalid codexDelegation' ($polS25_6.ExitCode -ne 0) $polS25_6.Output

    $scenario = 26
    Write-Host 'Scenario 26: switchers never silently replace invalid current policy with balanced or invalid current backend with deepseek' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS25
    Invoke-SafeInstall -Root $root

    # S26.1: switch-subagent-backend with invalid delegation_policy in AGENTS.md runtime block must fail closed
    $agentsPath26 = Join-Path (Get-CodexHome $root) 'AGENTS.md'
    $agentsClean26 = Get-Content -LiteralPath $agentsPath26 -Raw -Encoding UTF8
    $agentsTamperPol26 = $agentsClean26 -replace 'delegation_policy = balanced', 'delegation_policy = invalid_policy_value'
    Write-FixtureFile -Path $agentsPath26 -Content $agentsTamperPol26
    $backS26_1 = Invoke-BackendSwitch -Root $root -Backend native
    Assert-Condition 'S26 switch-subagent-backend fails closed on invalid current policy and does not default to balanced' ($backS26_1.ExitCode -ne 0) $backS26_1.Output

    # S26.2: switch-subagent-policy with invalid subagent_backend in AGENTS.md runtime block must fail closed
    $agentsTamperBack26 = $agentsClean26 -replace 'subagent_backend = deepseek', 'subagent_backend = invalid_backend_value'
    Write-FixtureFile -Path $agentsPath26 -Content $agentsTamperBack26
    $polS26_2 = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S26 switch-subagent-policy fails closed on invalid current backend and does not default to deepseek' ($polS26_2.ExitCode -ne 0) $polS26_2.Output

    $scenario = 27
    Write-Host 'Scenario 27: -Status on both switchers cross-checks state, runtime block, and config matrix fail-closed' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS25
    Invoke-SafeInstall -Root $root

    # Clean status succeeds
    $statBackClean = Invoke-BackendStatus -Root $root
    $statPolClean = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 clean install backend status succeeds' ($statBackClean.ExitCode -eq 0 -and $statBackClean.Output -match 'Active subagent backend:\s*deepseek' -and $statBackClean.Output -match 'Active delegation policy:\s*balanced') $statBackClean.Output
    Assert-Condition 'S27 clean install policy status succeeds' ($statPolClean.ExitCode -eq 0 -and $statPolClean.Output -match 'Active subagent backend:\s*deepseek' -and $statPolClean.Output -match 'Active delegation policy:\s*balanced') $statPolClean.Output

    # S27.1: Backend mismatch between state (deepseek) and AGENTS.md runtime block (native)
    $agentsPath27 = Join-Path (Get-CodexHome $root) 'AGENTS.md'
    $agentsClean27 = Get-Content -LiteralPath $agentsPath27 -Raw -Encoding UTF8
    $agentsTamperBack27 = $agentsClean27 -replace 'subagent_backend = deepseek', 'subagent_backend = native'
    Write-FixtureFile -Path $agentsPath27 -Content $agentsTamperBack27
    $statBackMismatch = Invoke-BackendStatus -Root $root
    $statPolMismatch = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on state vs runtime block backend mismatch' ($statBackMismatch.ExitCode -ne 0) $statBackMismatch.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on state vs runtime block backend mismatch' ($statPolMismatch.ExitCode -ne 0) $statPolMismatch.Output

    # S27.2: Policy mismatch between state (balanced) and AGENTS.md runtime block (aggressive)
    $agentsTamperPol27 = $agentsClean27 -replace 'delegation_policy = balanced', 'delegation_policy = aggressive'
    Write-FixtureFile -Path $agentsPath27 -Content $agentsTamperPol27
    $statBackPolMismatch = Invoke-BackendStatus -Root $root
    $statPolPolMismatch = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on state vs runtime block policy mismatch' ($statBackPolMismatch.ExitCode -ne 0) $statBackPolMismatch.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on state vs runtime block policy mismatch' ($statPolPolMismatch.ExitCode -ne 0) $statPolPolMismatch.Output

    # S27.3: Config matrix mismatch against deepseek state (state is deepseek, config.toml has multi_agent = true)
    Write-FixtureFile -Path $agentsPath27 -Content $agentsClean27
    $configPath27 = Join-Path (Get-CodexHome $root) 'config.toml'
    $configClean27 = Read-Config $root
    $configTampered27 = $configClean27 -replace 'multi_agent = false', 'multi_agent = true'
    Write-FixtureFile -Path $configPath27 -Content $configTampered27
    $statBackCfgMismatch = Invoke-BackendStatus -Root $root
    $statPolCfgMismatch = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on deepseek config matrix mismatch' ($statBackCfgMismatch.ExitCode -ne 0) $statBackCfgMismatch.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on deepseek config matrix mismatch' ($statPolCfgMismatch.ExitCode -ne 0) $statPolCfgMismatch.Output

    # S27.4: Config matrix mismatch against native state (state is native, config.toml has multi_agent = false)
    Write-FixtureFile -Path $configPath27 -Content $configClean27
    $switchNat27 = Invoke-BackendSwitch -Root $root -Backend native
    $configNatClean27 = Read-Config $root
    $configNatTampered27 = $configNatClean27 -replace 'multi_agent = true', 'multi_agent = false'
    Write-FixtureFile -Path $configPath27 -Content $configNatTampered27
    $statBackNatCfgMismatch = Invoke-BackendStatus -Root $root
    $statPolNatCfgMismatch = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on native config matrix mismatch' ($statBackNatCfgMismatch.ExitCode -ne 0) $statBackNatCfgMismatch.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on native config matrix mismatch' ($statPolNatCfgMismatch.ExitCode -ne 0) $statPolNatCfgMismatch.Output

    # Restore native config
    Write-FixtureFile -Path $configPath27 -Content $configNatClean27
    # Restore deepseek backend
    $switchDeep27 = Invoke-BackendSwitch -Root $root -Backend deepseek
    $agentsClean27 = Get-Content -LiteralPath $agentsPath27 -Raw -Encoding UTF8

    # S27.5: Duplicate runtime block in AGENTS.md
    $duplicateRtAgents27 = $agentsClean27 -replace '(?s)(# BEGIN CODEX-WORKFLOWS-KIT: runtime.*?# END CODEX-WORKFLOWS-KIT: runtime)', "`$1`n`n`$1"
    Write-FixtureFile -Path $agentsPath27 -Content $duplicateRtAgents27
    $statBackDupRt = Invoke-BackendStatus -Root $root
    $statPolDupRt = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on duplicate runtime block' ($statBackDupRt.ExitCode -ne 0) $statBackDupRt.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on duplicate runtime block' ($statPolDupRt.ExitCode -ne 0) $statPolDupRt.Output

    # S27.6: Duplicate subagent_backend keys inside runtime block
    $dupBackKeyAgents27 = $agentsClean27 -replace 'subagent_backend = deepseek', "subagent_backend = deepseek`nsubagent_backend = deepseek"
    Write-FixtureFile -Path $agentsPath27 -Content $dupBackKeyAgents27
    $statBackDupKey = Invoke-BackendStatus -Root $root
    $statPolDupKey = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on duplicate backend keys in runtime block' ($statBackDupKey.ExitCode -ne 0) $statBackDupKey.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on duplicate backend keys in runtime block' ($statPolDupKey.ExitCode -ne 0) $statPolDupKey.Output

    # S27.7: Duplicate delegation_policy keys inside runtime block
    $dupPolKeyAgents27 = $agentsClean27 -replace 'delegation_policy = balanced', "delegation_policy = balanced`ndelegation_policy = balanced"
    Write-FixtureFile -Path $agentsPath27 -Content $dupPolKeyAgents27
    $statBackDupPolKey = Invoke-BackendStatus -Root $root
    $statPolDupPolKey = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on duplicate policy keys in runtime block' ($statBackDupPolKey.ExitCode -ne 0) $statBackDupPolKey.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on duplicate policy keys in runtime block' ($statPolDupPolKey.ExitCode -ne 0) $statPolDupPolKey.Output

    # S27.8: Missing runtime block in AGENTS.md
    $noRtAgents27 = $agentsClean27 -replace '(?s)# BEGIN CODEX-WORKFLOWS-KIT: runtime.*?# END CODEX-WORKFLOWS-KIT: runtime\r?\n?', ''
    Write-FixtureFile -Path $agentsPath27 -Content $noRtAgents27
    $statBackNoRt = Invoke-BackendStatus -Root $root
    $statPolNoRt = Invoke-PolicyStatus -Root $root
    Assert-Condition 'S27 backend switcher -Status fails closed on missing runtime block' ($statBackNoRt.ExitCode -ne 0) $statBackNoRt.Output
    Assert-Condition 'S27 policy switcher -Status fails closed on missing runtime block' ($statPolNoRt.ExitCode -ne 0) $statPolNoRt.Output

    $scenario = 28
    Write-Host 'Scenario 28: policy switch asserts config matrix matches codexBackend before switch and leaves config.toml byte-for-byte unchanged' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $originalS25
    Invoke-SafeInstall -Root $root

    # S28.1: Drifted / mismatched config.toml before policy switch blocks policy switch on deepseek state
    $configPath28 = Join-Path (Get-CodexHome $root) 'config.toml'
    $configClean28 = Read-Config $root
    $configDrift28 = $configClean28 -replace 'fast_mode = true', 'fast_mode = false'
    Write-FixtureFile -Path $configPath28 -Content $configDrift28
    $polDriftResult28 = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S28 policy switch fails closed when deepseek config.toml matrix is inconsistent with state' ($polDriftResult28.ExitCode -ne 0) $polDriftResult28.Output
    Assert-Condition 'S28 policy switch leaves drifted config.toml byte-identical on deepseek rejection' ((Read-Config $root) -ceq $configDrift28) ''

    # S28.2: Drifted / mismatched config.toml before policy switch blocks policy switch on native state
    Write-FixtureFile -Path $configPath28 -Content $configClean28
    $switchNat28 = Invoke-BackendSwitch -Root $root -Backend native
    $configNatClean28 = Read-Config $root
    $configNatDrift28 = $configNatClean28 -replace 'fast_mode = false', 'fast_mode = true'
    Write-FixtureFile -Path $configPath28 -Content $configNatDrift28
    $polNatDriftResult28 = Invoke-PolicySwitch -Root $root -Policy aggressive
    Assert-Condition 'S28 policy switch fails closed when native config.toml matrix is inconsistent with state' ($polNatDriftResult28.ExitCode -ne 0) $polNatDriftResult28.Output
    Assert-Condition 'S28 policy switch leaves drifted config.toml byte-identical on native rejection' ((Read-Config $root) -ceq $configNatDrift28) ''

    # S28.3: Clean policy switch leaves config.toml byte-for-byte unchanged
    Write-FixtureFile -Path $configPath28 -Content $configNatClean28
    $hashBefore28 = (Get-FileHash -LiteralPath $configPath28 -Algorithm SHA256).Hash
    $polClean28 = Invoke-PolicySwitch -Root $root -Policy aggressive
    $hashAfter28 = (Get-FileHash -LiteralPath $configPath28 -Algorithm SHA256).Hash
    Assert-Condition 'S28 policy switch succeeds on consistent native matrix' ($polClean28.ExitCode -eq 0) $polClean28.Output
    Assert-Condition 'S28 policy switch leaves native config.toml byte-for-byte unchanged' ($hashBefore28 -ceq $hashAfter28) ''

    $polCleanBal28 = Invoke-PolicySwitch -Root $root -Policy balanced
    $hashAfterBal28 = (Get-FileHash -LiteralPath $configPath28 -Algorithm SHA256).Hash
    Assert-Condition 'S28 policy switch back to balanced succeeds on consistent native matrix' ($polCleanBal28.ExitCode -eq 0) $polCleanBal28.Output
    Assert-Condition 'S28 policy switch back to balanced leaves config.toml byte-for-byte unchanged' ($hashBefore28 -ceq $hashAfterBal28) ''

    $scenario = 29
    Write-Host 'Scenario 29: runtime block parser and assertion reject duplicate blocks, duplicate keys, and invalid selector values' -ForegroundColor Cyan
    Import-Module (Join-Path $repo 'scripts\backend-routing.psm1') -Force
    $validBlock = '# BEGIN CODEX-WORKFLOWS-KIT: runtime' + $nl + 'subagent_backend = deepseek' + $nl + 'delegation_policy = balanced' + $nl + '# END CODEX-WORKFLOWS-KIT: runtime'

    # S29.1: Valid block parses cleanly
    $rtInfo29_1 = Get-CodexRuntimeBlockInfo -Text $validBlock
    Assert-Condition 'S29 valid runtime block parses correctly' ($rtInfo29_1.Present -and $rtInfo29_1.Backend -ceq 'deepseek' -and $rtInfo29_1.Policy -ceq 'balanced') ''

    # S29.2: Duplicate runtime block throws or rejects
    $duplicateBlocks29 = $validBlock + $nl + $validBlock
    $dupThrows29 = $false
    try {
        $rtInfoDup = Get-CodexRuntimeBlockInfo -Text $duplicateBlocks29
        if ($rtInfoDup.Present) { $dupThrows29 = $false }
    }
    catch {
        $dupThrows29 = $true
    }
    Assert-Condition 'S29 Get-CodexRuntimeBlockInfo rejects duplicate runtime blocks' $dupThrows29 ''

    # S29.3: Duplicate keys in runtime block throws or rejects
    $dupKeysBlock29 = '# BEGIN CODEX-WORKFLOWS-KIT: runtime' + $nl + 'subagent_backend = deepseek' + $nl + 'subagent_backend = native' + $nl + 'delegation_policy = balanced' + $nl + '# END CODEX-WORKFLOWS-KIT: runtime'
    $dupKeyThrows29 = $false
    try {
        $rtInfoDupKey = Get-CodexRuntimeBlockInfo -Text $dupKeysBlock29
        if ($rtInfoDupKey.Present -and $null -ne $rtInfoDupKey.Backend) { $dupKeyThrows29 = $false }
    }
    catch {
        $dupKeyThrows29 = $true
    }
    Assert-Condition 'S29 Get-CodexRuntimeBlockInfo rejects duplicate subagent_backend keys' $dupKeyThrows29 ''

    # S29.4: Invalid selector values in runtime block are rejected
    $invalidBackendBlock29 = '# BEGIN CODEX-WORKFLOWS-KIT: runtime' + $nl + 'subagent_backend = invalid_val' + $nl + 'delegation_policy = balanced' + $nl + '# END CODEX-WORKFLOWS-KIT: runtime'
    $invalidBackendThrows29 = $false
    try {
        $rtInvalidBack = Get-CodexRuntimeBlockInfo -Text $invalidBackendBlock29
        if ($null -eq $rtInvalidBack.Backend -or -not $rtInvalidBack.Present) { $invalidBackendThrows29 = $true }
    }
    catch {
        $invalidBackendThrows29 = $true
    }
    Assert-Condition 'S29 Get-CodexRuntimeBlockInfo rejects invalid subagent_backend values' $invalidBackendThrows29 ''

    $invalidPolicyBlock29 = '# BEGIN CODEX-WORKFLOWS-KIT: runtime' + $nl + 'subagent_backend = deepseek' + $nl + 'delegation_policy = invalid_pol' + $nl + '# END CODEX-WORKFLOWS-KIT: runtime'
    $invalidPolicyThrows29 = $false
    try {
        $rtInvalidPol = Get-CodexRuntimeBlockInfo -Text $invalidPolicyBlock29
        if ($null -eq $rtInvalidPol.Policy -or -not $rtInvalidPol.Present) { $invalidPolicyThrows29 = $true }
    }
    catch {
        $invalidPolicyThrows29 = $true
    }
    Assert-Condition 'S29 Get-CodexRuntimeBlockInfo rejects invalid delegation_policy values' $invalidPolicyThrows29 ''

    # S29.5: Assert-CodexAgentsRuntimeBlock throws on duplicate or invalid blocks
    $assertDupThrows29 = $false
    try {
        Assert-CodexAgentsRuntimeBlock -Text $duplicateBlocks29 -Backend 'deepseek' -Policy 'balanced'
    }
    catch {
        $assertDupThrows29 = $true
    }
    Assert-Condition 'S29 Assert-CodexAgentsRuntimeBlock throws on duplicate runtime blocks' $assertDupThrows29 ''

    $scenario = 30
    Write-Host 'Scenario 30: transaction rollback in both switchers removes newly-created exact targets and restores pre-existing targets on failure' -ForegroundColor Cyan

    # S30.1: Backend switcher transaction failure when AGENTS.md and install-state.json did NOT pre-exist
    $root30_1 = New-FixtureHome
    $fixtures.Add($root30_1)
    $originalConfig30_1 = $originalS25
    $configPath30_1 = Join-Path (Get-CodexHome $root30_1) 'config.toml'
    $agentsPath30_1 = Join-Path (Get-CodexHome $root30_1) 'AGENTS.md'
    $statePath30_1 = Join-Path (Get-CodexHome $root30_1) 'codex-workflows-kit\install-state.json'
    Write-FixtureFile -Path $configPath30_1 -Content $originalConfig30_1

    # Inject failure: create a directory at install-state.json path to cause state write to throw after writing config and agents
    $stateDirBlocker = Join-Path (Get-CodexHome $root30_1) 'codex-workflows-kit\install-state.json'
    New-Item -ItemType Directory -Path $stateDirBlocker -Force | Out-Null

    $failedBackSwitch30_1 = Invoke-BackendSwitch -Root $root30_1 -Backend native
    Assert-Condition 'S30 backend switch fails when state write is blocked' ($failedBackSwitch30_1.ExitCode -ne 0) $failedBackSwitch30_1.Output
    Assert-Condition 'S30 backend switch output reports rollback' ($failedBackSwitch30_1.Output -match '(?i)rolled back') $failedBackSwitch30_1.Output
    Assert-Condition 'S30 backend switch restores pre-existing config.toml byte-identically on rollback' ((Read-Config $root30_1) -ceq ($originalConfig30_1 -replace "`r?`n", "`r`n")) (Read-Config $root30_1)
    Assert-Condition 'S30 backend switch removes newly-created AGENTS.md target on rollback' (-not (Test-Path -LiteralPath $agentsPath30_1 -PathType Leaf)) ''

    # S30.2: Backend switcher transaction failure when AGENTS.md DID pre-exist
    $root30_2 = New-FixtureHome
    $fixtures.Add($root30_2)
    $originalConfig30_2 = $originalS25
    $originalAgents30_2 = '# Pre-existing user AGENTS.md content' + $nl + '- user rule 1' + $nl
    $configPath30_2 = Join-Path (Get-CodexHome $root30_2) 'config.toml'
    $agentsPath30_2 = Join-Path (Get-CodexHome $root30_2) 'AGENTS.md'
    Write-FixtureFile -Path $configPath30_2 -Content $originalConfig30_2
    Write-FixtureFile -Path $agentsPath30_2 -Content $originalAgents30_2

    # Inject failure: create a directory at install-state.json path
    $stateDirBlocker2 = Join-Path (Get-CodexHome $root30_2) 'codex-workflows-kit\install-state.json'
    New-Item -ItemType Directory -Path $stateDirBlocker2 -Force | Out-Null

    $failedBackSwitch30_2 = Invoke-BackendSwitch -Root $root30_2 -Backend native
    Assert-Condition 'S30 backend switch with pre-existing AGENTS.md fails when state write is blocked' ($failedBackSwitch30_2.ExitCode -ne 0) $failedBackSwitch30_2.Output
    Assert-Condition 'S30 backend switch restores pre-existing config.toml byte-identically' ((Read-Config $root30_2) -ceq ($originalConfig30_2 -replace "`r?`n", "`r`n")) (Read-Config $root30_2)
    Assert-Condition 'S30 backend switch restores pre-existing AGENTS.md byte-identically' ((Get-Content -LiteralPath $agentsPath30_2 -Raw -Encoding UTF8) -ceq ($originalAgents30_2 -replace "`r?`n", "`r`n")) (Get-Content -LiteralPath $agentsPath30_2 -Raw -Encoding UTF8)

    # S30.3: Policy switcher transaction failure when AGENTS.md DID pre-exist
    $root30_3 = New-FixtureHome
    $fixtures.Add($root30_3)
    $originalConfig30_3 = $originalS25
    $originalAgents30_3 = '# Pre-existing AGENTS for policy switch' + $nl
    $configPath30_3 = Join-Path (Get-CodexHome $root30_3) 'config.toml'
    $agentsPath30_3 = Join-Path (Get-CodexHome $root30_3) 'AGENTS.md'
    Write-FixtureFile -Path $configPath30_3 -Content $originalConfig30_3
    Write-FixtureFile -Path $agentsPath30_3 -Content $originalAgents30_3

    # Inject failure: create a directory at install-state.json path
    $stateDirBlocker3 = Join-Path (Get-CodexHome $root30_3) 'codex-workflows-kit\install-state.json'
    New-Item -ItemType Directory -Path $stateDirBlocker3 -Force | Out-Null

    $failedPolSwitch30_3 = Invoke-PolicySwitch -Root $root30_3 -Policy aggressive
    Assert-Condition 'S30 policy switch fails when state write is blocked' ($failedPolSwitch30_3.ExitCode -ne 0) $failedPolSwitch30_3.Output
    Assert-Condition 'S30 policy switch output reports rollback' ($failedPolSwitch30_3.Output -match '(?i)rolled back') $failedPolSwitch30_3.Output
    Assert-Condition 'S30 policy switch restores pre-existing AGENTS.md byte-identically' ((Get-Content -LiteralPath $agentsPath30_3 -Raw -Encoding UTF8) -ceq ($originalAgents30_3 -replace "`r?`n", "`r`n")) (Get-Content -LiteralPath $agentsPath30_3 -Raw -Encoding UTF8)
    Assert-Condition 'S30 policy switch leaves config.toml untouched' ((Read-Config $root30_3) -ceq ($originalConfig30_3 -replace "`r?`n", "`r`n")) (Read-Config $root30_3)

    # S30.4: Policy switcher transaction failure when AGENTS.md did NOT pre-exist
    $root30_4 = New-FixtureHome
    $fixtures.Add($root30_4)
    $originalConfig30_4 = $originalS25
    $configPath30_4 = Join-Path (Get-CodexHome $root30_4) 'config.toml'
    $agentsPath30_4 = Join-Path (Get-CodexHome $root30_4) 'AGENTS.md'
    Write-FixtureFile -Path $configPath30_4 -Content $originalConfig30_4

    # Inject failure: create a directory at install-state.json path
    $stateDirBlocker4 = Join-Path (Get-CodexHome $root30_4) 'codex-workflows-kit\install-state.json'
    New-Item -ItemType Directory -Path $stateDirBlocker4 -Force | Out-Null

    $failedPolSwitch30_4 = Invoke-PolicySwitch -Root $root30_4 -Policy aggressive
    Assert-Condition 'S30 policy switch without AGENTS.md fails when state write is blocked' ($failedPolSwitch30_4.ExitCode -ne 0) $failedPolSwitch30_4.Output
    Assert-Condition 'S30 policy switch removes newly-created AGENTS.md target on rollback' (-not (Test-Path -LiteralPath $agentsPath30_4 -PathType Leaf)) ''

    $scenario = 31
    Write-Host 'Scenario 31: unmanaged top-level config fields are preserved across migration, reinstall, and backend switching with ledger hash reconciliation, while managed projection drift fails closed' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $configPath31 = Join-Path (Get-CodexHome $root) 'config.toml'
    $statePath31 = Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json'
    $agentsPath31 = Join-Path (Get-CodexHome $root) 'AGENTS.md'

    # Step 31.1: Schema 4 -> Schema 5 migration with unmanaged top-level model key and stale whole-file config hash
    $initialCfg31 = 'model = "custom-unmanaged-model-v1"' + $nl +
        'reasoning_effort = "custom-effort"' + $nl +
        '[features]' + $nl +
        'multi_agent = false' + $nl
    Write-FixtureFile -Path $configPath31 -Content $initialCfg31
    $initialHash31 = (Get-FileHash -LiteralPath $configPath31 -Algorithm SHA256).Hash

    $schema4State = [ordered]@{
        schemaVersion = 4
        product = 'codex-workflows-kit'
        profile = 'safe'
        installedAtUtc = [datetime]::UtcNow.ToString('o')
        files = @(
            [ordered]@{ path = $configPath31; sha256 = $initialHash31 }
        )
        pendingFiles = @()
        codexFeaturesPrior = [ordered]@{
            multi_agent = [ordered]@{
                present = $true
                value = 'false'
            }
        }
    }
    Write-FixtureFile -Path $statePath31 -Content (($schema4State | ConvertTo-Json -Depth 8) + $nl)

    $tamperedUnmanagedCfg31 = 'model = "custom-unmanaged-model-v2"' + $nl +
        'reasoning_effort = "custom-effort"' + $nl +
        '[features]' + $nl +
        'multi_agent = false' + $nl
    Write-FixtureFile -Path $configPath31 -Content $tamperedUnmanagedCfg31

    $migResult31 = Invoke-InstallCapture -Root $root -Profile safe
    Assert-Condition 'S31 schema 4 to 5 migration succeeds with unmanaged model change' ($migResult31.ExitCode -eq 0) $migResult31.Output

    $migratedCfg31 = Read-Config $root
    Assert-Condition 'S31 migration preserves unmanaged model byte/value' ($migratedCfg31 -match '(?m)^\s*model\s*=\s*"custom-unmanaged-model-v2"\s*$') $migratedCfg31
    Assert-Condition 'S31 migration preserves unmanaged reasoning_effort byte/value' ($migratedCfg31 -match '(?m)^\s*reasoning_effort\s*=\s*"custom-effort"\s*$') $migratedCfg31
    Assert-Condition 'S31 migration keeps deepseek backend matrix' ($migratedCfg31 -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $migratedCfg31

    $stateAfterMig31 = Get-InstallState $root
    $actualHashAfterMig31 = (Get-FileHash -LiteralPath $configPath31 -Algorithm SHA256).Hash
    $cfgEntryInState31 = @($stateAfterMig31.files) | Where-Object { [string]$_.path -eq $configPath31 } | Select-Object -First 1
    Assert-Condition 'S31 migration sets schemaVersion 5' ([int]$stateAfterMig31.schemaVersion -eq 5) $stateAfterMig31.schemaVersion
    Assert-Condition 'S31 migration defaults delegation policy to balanced' ([string]$stateAfterMig31.codexDelegation.selected -ceq 'balanced') ''
    Assert-Condition 'S31 migration keeps backend selected as deepseek' ([string]$stateAfterMig31.codexBackend.selected -ceq 'deepseek') ''
    Assert-Condition 'S31 migration refreshes ledger full-file hash' ($null -ne $cfgEntryInState31 -and [string]$cfgEntryInState31.sha256 -ceq $actualHashAfterMig31) ''

    # Step 31.2: Safe reinstall on Schema 5 after another unmanaged model change
    $tamperedUnmanagedCfg31_2 = $migratedCfg31 -replace '"custom-unmanaged-model-v2"', '"custom-unmanaged-model-v3"'
    Write-FixtureFile -Path $configPath31 -Content $tamperedUnmanagedCfg31_2
    $reinstallResult31 = Invoke-InstallCapture -Root $root -Profile safe
    Assert-Condition 'S31 safe reinstall succeeds after unmanaged model change' ($reinstallResult31.ExitCode -eq 0) $reinstallResult31.Output

    $reinstalledCfg31 = Read-Config $root
    Assert-Condition 'S31 safe reinstall preserves unmanaged model byte/value' ($reinstalledCfg31 -match '(?m)^\s*model\s*=\s*"custom-unmanaged-model-v3"\s*$') $reinstalledCfg31
    $actualHashAfterReinstall31 = (Get-FileHash -LiteralPath $configPath31 -Algorithm SHA256).Hash
    $stateAfterReinstall31 = Get-InstallState $root
    $cfgEntryAfterReinstall31 = @($stateAfterReinstall31.files) | Where-Object { [string]$_.path -eq $configPath31 } | Select-Object -First 1
    Assert-Condition 'S31 safe reinstall refreshes ledger full-file hash' ($null -ne $cfgEntryAfterReinstall31 -and [string]$cfgEntryAfterReinstall31.sha256 -ceq $actualHashAfterReinstall31) ''

    # Step 31.3: switch-subagent-backend after another unrelated model change: native then deepseek
    $tamperedUnmanagedCfg31_3 = $reinstalledCfg31 -replace '"custom-unmanaged-model-v3"', '"custom-unmanaged-model-v4"'
    Write-FixtureFile -Path $configPath31 -Content $tamperedUnmanagedCfg31_3

    $switchNatResult31 = Invoke-BackendSwitch -Root $root -Backend native
    Assert-Condition 'S31 switch-subagent-backend to native succeeds after unmanaged model change' ($switchNatResult31.ExitCode -eq 0) $switchNatResult31.Output
    $configAfterNat31 = Read-Config $root
    Assert-Condition 'S31 native switch preserves unmanaged model byte/value' ($configAfterNat31 -match '(?m)^\s*model\s*=\s*"custom-unmanaged-model-v4"\s*$') $configAfterNat31
    Assert-Condition 'S31 native switch updates native backend matrix' ($configAfterNat31 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $configAfterNat31 -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-5\.6-luna"\s*$') $configAfterNat31
    $actualHashAfterNat31 = (Get-FileHash -LiteralPath $configPath31 -Algorithm SHA256).Hash
    $stateAfterNat31 = Get-InstallState $root
    $cfgEntryAfterNat31 = @($stateAfterNat31.files) | Where-Object { [string]$_.path -eq $configPath31 } | Select-Object -First 1
    Assert-Condition 'S31 native switch refreshes ledger full-file hash' ($null -ne $cfgEntryAfterNat31 -and [string]$cfgEntryAfterNat31.sha256 -ceq $actualHashAfterNat31) ''

    $tamperedUnmanagedCfg31_4 = $configAfterNat31 -replace '"custom-unmanaged-model-v4"', '"custom-unmanaged-model-v5"'
    Write-FixtureFile -Path $configPath31 -Content $tamperedUnmanagedCfg31_4

    $switchDeepResult31 = Invoke-BackendSwitch -Root $root -Backend deepseek
    Assert-Condition 'S31 switch-subagent-backend back to deepseek succeeds after unmanaged model change' ($switchDeepResult31.ExitCode -eq 0) $switchDeepResult31.Output
    $configAfterDeep31 = Read-Config $root
    Assert-Condition 'S31 deepseek switch preserves unmanaged model byte/value' ($configAfterDeep31 -match '(?m)^\s*model\s*=\s*"custom-unmanaged-model-v5"\s*$') $configAfterDeep31
    Assert-Condition 'S31 deepseek switch updates deepseek backend matrix' ($configAfterDeep31 -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $configAfterDeep31
    $actualHashAfterDeep31 = (Get-FileHash -LiteralPath $configPath31 -Algorithm SHA256).Hash
    $stateAfterDeep31 = Get-InstallState $root
    $cfgEntryAfterDeep31 = @($stateAfterDeep31.files) | Where-Object { [string]$_.path -eq $configPath31 } | Select-Object -First 1
    Assert-Condition 'S31 deepseek switch refreshes ledger full-file hash' ($null -ne $cfgEntryAfterDeep31 -and [string]$cfgEntryAfterDeep31.sha256 -ceq $actualHashAfterDeep31) ''

    # Step 31.4: Managed-key mismatch MUST continue to fail closed in install and switch
    $tamperedManagedCfg31 = $configAfterDeep31 -replace '(?m)^\s*multi_agent\s*=\s*false\s*$', 'multi_agent = true'
    Write-FixtureFile -Path $configPath31 -Content $tamperedManagedCfg31
    $failInstall31 = Invoke-InstallCapture -Root $root -Profile safe
    Assert-Condition 'S31 safe reinstall fails closed on managed matrix mismatch' ($failInstall31.ExitCode -ne 0) $failInstall31.Output

    $failSwitch31 = Invoke-BackendSwitch -Root $root -Backend native
    Assert-Condition 'S31 backend switch fails closed on managed matrix mismatch' ($failSwitch31.ExitCode -ne 0) $failSwitch31.Output

    $scenario = 32
    Write-Host 'Scenario 32: delivery target identity contract is staging-invariant and content-sensitive, with precise commit gate validation' -ForegroundColor Cyan
    Import-Module (Join-Path $repo 'scripts\backend-routing.psm1') -Force
    $root32 = New-FixtureHome
    $fixtures.Add($root32)
    $gitRepoDir = Join-Path $root32 'git-delivery-test'
    New-Item -ItemType Directory -Path $gitRepoDir -Force | Out-Null

    # Initialize test git repo with initial baseline commit
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('init', '-b', 'main')
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('config', 'user.name', 'Test User')
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('config', 'user.email', 'test@example.com')
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('config', 'commit.gpgsign', 'false')
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('config', 'core.autocrlf', 'true')
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('config', 'core.safecrlf', 'warn')

    $initFilePath = Join-Path $gitRepoDir 'baseline.txt'
    Write-FixtureFile -Path $initFilePath -Content 'initial baseline content'
    $existingTracked = Join-Path $gitRepoDir 'src\app.txt'
    Write-FixtureFile -Path $existingTracked -Content 'initial app content'
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('add', 'baseline.txt', 'src/app.txt')
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('commit', '-m', 'initial commit')
    $baselineCommit = (Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('rev-parse', 'HEAD')).Output.Trim()

    # Step 32.1: Make changes in worktree (modify tracked file, add new file, untracked unowned file)
    $lfNoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    # Keep a non-ASCII code point in the tracked diff so target identity tests
    # exercise native Git stdout decoding across Windows console code pages.
    $approvedAppContent = ("modified app content v1 " + [char]0x00E7 + "ao`nsecond line")
    [IO.File]::WriteAllText($existingTracked, $approvedAppContent, $lfNoBom)
    $newOwnedFile = Join-Path $gitRepoDir 'src\feature.txt'
    [IO.File]::WriteAllText($newOwnedFile, "new feature file content`nsecond line", $lfNoBom)
    $unownedUntracked = Join-Path $gitRepoDir 'scratch\notes.txt'
    Write-FixtureFile -Path $unownedUntracked -Content 'unrelated scratch note'

    $ownedPaths = @('src/app.txt', 'src/feature.txt')

    $gitDiffWithDiagnostic = (Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('diff', $baselineCommit, '--', 'src/app.txt')).Output
    Assert-Condition 'S32 fixture emits a Git EOL diagnostic on stderr before staging' ($gitDiffWithDiagnostic -match '(?im)^warning:.*(?:LF|CRLF)') $gitDiffWithDiagnostic

    # S32.1: Compute delivery target identity before staging
    $targetBeforeStaging = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths
    Assert-Condition 'S32 returns non-empty TargetId before staging' ($null -ne $targetBeforeStaging -and -not [string]::IsNullOrWhiteSpace($targetBeforeStaging.TargetId)) ''
    Assert-Condition 'S32 records baseline commit in target identity' ($targetBeforeStaging.Baseline -ceq $baselineCommit) ''
    Assert-Condition 'S32 records HEAD-relative status for owned paths' ($targetBeforeStaging.HeadStatus['src/app.txt'] -ceq 'M' -and $targetBeforeStaging.HeadStatus['src/feature.txt'] -ceq 'A') ''
    Assert-Condition 'S32 computes diff_sha256 and file_sha256 for owned paths' (-not [string]::IsNullOrWhiteSpace($targetBeforeStaging.DiffSha256) -and $targetBeforeStaging.FileSha256.Contains('src/app.txt') -and $targetBeforeStaging.FileSha256.Contains('src/feature.txt')) ''

    $originalConsoleOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(850)
        $targetCp850 = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $targetUtf8 = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths
    }
    finally {
        [Console]::OutputEncoding = $originalConsoleOutputEncoding
    }
    Assert-Condition 'S32 TargetId is invariant across CP850 and UTF-8 native stdout decoding' ($targetCp850.TargetId -ceq $targetUtf8.TargetId) ("CP850: " + $targetCp850.TargetId + " UTF8: " + $targetUtf8.TargetId)
    Assert-Condition 'S32 DiffSha256 is invariant across CP850 and UTF-8 native stdout decoding' ($targetCp850.DiffSha256 -ceq $targetUtf8.DiffSha256) ("CP850: " + $targetCp850.DiffSha256 + " UTF8: " + $targetUtf8.DiffSha256)

    $invalidBaselineRejected = $false
    $invalidBaselineDetail = ''
    try {
        $null = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths -Baseline 'definitely-not-a-valid-commit'
    }
    catch {
        $invalidBaselineRejected = $true
        $invalidBaselineDetail = $_.Exception.Message
    }
    Assert-Condition 'S32 rejects an invalid baseline instead of classifying every file as added' $invalidBaselineRejected $invalidBaselineDetail

    $escapingPathRejected = $false
    $escapingPathDetail = ''
    try {
        $null = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths @('../outside.txt')
    }
    catch {
        $escapingPathRejected = $true
        $escapingPathDetail = $_.Exception.Message
    }
    Assert-Condition 'S32 rejects owned paths that escape the repository' $escapingPathRejected $escapingPathDetail

    # S32.2: Stage the owned files (git add) -> changes porcelain state from ' M'/'??' to 'M '/'A '
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('add', 'src/app.txt', 'src/feature.txt')
    $porcelainAfterAdd = (Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('status', '--porcelain')).Output
    Assert-Condition 'S32 porcelain reflects staged state' ($porcelainAfterAdd -match 'M\s+src/app\.txt' -and $porcelainAfterAdd -match 'A\s+src/feature\.txt') $porcelainAfterAdd

    # Compute delivery target identity after staging
    $targetAfterStaging = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths

    # S32.3: STAGING-INVARIANCE ASSERTION
    Assert-Condition 'S32 TargetId is strictly staging-invariant (before staging == after staging)' ($targetBeforeStaging.TargetId -ceq $targetAfterStaging.TargetId) ("Before: " + $targetBeforeStaging.TargetId + " After: " + $targetAfterStaging.TargetId)
    Assert-Condition 'S32 DiffSha256 is strictly staging-invariant' ($targetBeforeStaging.DiffSha256 -ceq $targetAfterStaging.DiffSha256) ''
    Assert-Condition 'S32 FileSha256 map is strictly staging-invariant' ($targetBeforeStaging.FileSha256['src/app.txt'] -ceq $targetAfterStaging.FileSha256['src/app.txt'] -and $targetBeforeStaging.FileSha256['src/feature.txt'] -ceq $targetAfterStaging.FileSha256['src/feature.txt']) ''
    Assert-Condition 'S32 HeadStatus is strictly staging-invariant' ($targetBeforeStaging.HeadStatus['src/app.txt'] -ceq $targetAfterStaging.HeadStatus['src/app.txt'] -and $targetBeforeStaging.HeadStatus['src/feature.txt'] -ceq $targetAfterStaging.HeadStatus['src/feature.txt']) ''

    # S32.4: Commit gate passes with approved TargetId and matching staged paths
    $gatePassResult = Invoke-CommitGateCapture -RepoPath $gitRepoDir -ApprovedTargetId $targetBeforeStaging.TargetId -ApprovedOwnedPaths $ownedPaths
    Assert-Condition 'S32 commit gate succeeds on exact approved target and exact staged paths' ($gatePassResult.Pass -eq $true) $gatePassResult.Detail

    # S32.5: Commit gate fails if unapproved path is staged
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('add', 'scratch/notes.txt')
    $gateUnapprovedResult = Invoke-CommitGateCapture -RepoPath $gitRepoDir -ApprovedTargetId $targetBeforeStaging.TargetId -ApprovedOwnedPaths $ownedPaths
    Assert-Condition 'S32 commit gate rejects when unapproved path is staged' ($gateUnapprovedResult.Pass -eq $false -and $gateUnapprovedResult.Detail -match '(?i)unapproved|mismatch|staged') $gateUnapprovedResult.Detail
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('reset', 'HEAD', '--', 'scratch/notes.txt')

    # S32.6: The index content itself must match the approved working-tree content.
    # Stage a tampered blob, then restore the approved working tree to reproduce a
    # path-set/target-id bypass that would otherwise commit unreviewed content.
    [IO.File]::WriteAllText($existingTracked, "tampered staged blob`nsecond line", $lfNoBom)
    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('add', 'src/app.txt')
    [IO.File]::WriteAllText($existingTracked, $approvedAppContent, $lfNoBom)
    $targetWithRestoredWorktree = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths
    Assert-Condition 'S32 restored working tree still matches approved TargetId while index is tampered' ($targetWithRestoredWorktree.TargetId -ceq $targetBeforeStaging.TargetId) ''

    $gateIndexMismatchResult = Invoke-CommitGateCapture -RepoPath $gitRepoDir -ApprovedTargetId $targetBeforeStaging.TargetId -ApprovedOwnedPaths $ownedPaths
    Assert-Condition 'S32 commit gate rejects staged blob content that differs from approved working tree' ($gateIndexMismatchResult.Pass -eq $false -and $gateIndexMismatchResult.Detail -match '(?i)index|blob|content|staged') $gateIndexMismatchResult.Detail

    $null = Invoke-GitCapture -RepoDir $gitRepoDir -ArgumentList @('add', 'src/app.txt')
    $gateIndexRestoredResult = Invoke-CommitGateCapture -RepoPath $gitRepoDir -ApprovedTargetId $targetBeforeStaging.TargetId -ApprovedOwnedPaths $ownedPaths
    Assert-Condition 'S32 commit gate passes after staged blob is restored to approved content' ($gateIndexRestoredResult.Pass -eq $true) $gateIndexRestoredResult.Detail

    # S32.7: CONTENT-SENSITIVITY ASSERTION (content change after staging alters TargetId and causes commit gate to fail)
    Write-FixtureFile -Path $existingTracked -Content 'tampered content modified after review'
    $targetTampered = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir -OwnedPaths $ownedPaths
    Assert-Condition 'S32 TargetId is strictly content-sensitive (content change alters TargetId)' ($targetTampered.TargetId -cne $targetBeforeStaging.TargetId) ("Original: " + $targetBeforeStaging.TargetId + " Tampered: " + $targetTampered.TargetId)

    $gateTamperedResult = Invoke-CommitGateCapture -RepoPath $gitRepoDir -ApprovedTargetId $targetBeforeStaging.TargetId -ApprovedOwnedPaths $ownedPaths
    Assert-Condition 'S32 commit gate rejects when post-staging recomputed identity differs from approved target' ($gateTamperedResult.Pass -eq $false -and $gateTamperedResult.Detail -match '(?i)target_id|mismatch|identity') $gateTamperedResult.Detail

    $scenario = 33
    Write-Host 'Scenario 33: global installer preserves selected aggressive delegation and backend across updates, updates global kit artifacts, leaves consumer repo AGENTS.md untouched, and keeps toggles functional' -ForegroundColor Cyan
    $root33 = New-FixtureHome
    $fixtures.Add($root33)
    $configPath33 = Join-Path (Get-CodexHome $root33) 'config.toml'
    $agentsPath33 = Join-Path (Get-CodexHome $root33) 'AGENTS.md'
    $statePath33 = Join-Path (Get-CodexHome $root33) 'codex-workflows-kit\install-state.json'

    # Set up mock consumer repository with its own AGENTS.md outside CodexHome
    $consumerRepoDir = Join-Path $root33 'consumer-repo'
    New-Item -ItemType Directory -Path $consumerRepoDir -Force | Out-Null
    $consumerAgentsPath = Join-Path $consumerRepoDir 'AGENTS.md'
    $consumerAgentsContent = '# Consumer Repository Rules' + $nl +
        '- Always write clean and modular code.' + $nl +
        '- Never commit secrets or api keys.' + $nl
    Write-FixtureFile -Path $consumerAgentsPath -Content $consumerAgentsContent

    # Initial config fixture
    $initialConfig33 = '[features]' + $nl +
        'multi_agent = false' + $nl +
        'fast_mode = true' + $nl +
        $nl +
        '[agents]' + $nl +
        'default_subagent_model = "test-model"' + $nl +
        'default_subagent_reasoning_effort = "high"' + $nl +
        $nl +
        '[mcp_servers.deepseek-subagent]' + $nl +
        'command = "bridge-cmd"' + $nl +
        'enabled = true' + $nl
    Write-FixtureFile -Path $configPath33 -Content $initialConfig33

    # Step 33.1: Initial safe install
    $install1_33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 initial safe install succeeds' ($install1_33.ExitCode -eq 0) $install1_33.Output

    # Step 33.2: Switch delegation policy to aggressive and backend to native
    $polAggResult33 = Invoke-PolicySwitch -Root $root33 -Policy aggressive
    $backNatResult33 = Invoke-BackendSwitch -Root $root33 -Backend native
    Assert-Condition 'S33 switch policy to aggressive succeeds' ($polAggResult33.ExitCode -eq 0) $polAggResult33.Output
    Assert-Condition 'S33 switch backend to native succeeds' ($backNatResult33.ExitCode -eq 0) $backNatResult33.Output

    $stateBeforeUpdate33 = Get-InstallState $root33
    $agentsBeforeUpdate33 = Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8
    $rtBeforeUpdate33 = Get-AgentsRuntimeBlock -Text $agentsBeforeUpdate33
    Assert-Condition 'S33 state records aggressive delegation before update' ($stateBeforeUpdate33.codexDelegation.selected -ceq 'aggressive') ''
    Assert-Condition 'S33 state records native backend before update' ($stateBeforeUpdate33.codexBackend.selected -ceq 'native') ''
    Assert-Condition 'S33 global AGENTS.md has aggressive policy before update' ($rtBeforeUpdate33.Policy -ceq 'aggressive') $agentsBeforeUpdate33
    Assert-Condition 'S33 global AGENTS.md has native backend before update' ($rtBeforeUpdate33.Backend -ceq 'native') $agentsBeforeUpdate33

    # Step 33.3: Re-install / update kit over the aggressive + native installation
    $updateResult33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 kit update/reinstall succeeds' ($updateResult33.ExitCode -eq 0) $updateResult33.Output

    $stateAfterUpdate33 = Get-InstallState $root33
    $agentsAfterUpdate33 = Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8
    $configAfterUpdate33 = Read-Config $root33
    $rtAfterUpdate33 = Get-AgentsRuntimeBlock -Text $agentsAfterUpdate33

    # Requirement 1: delegation_policy=aggressive continues aggressive after install/update
    Assert-Condition 'S33 update preserves selected aggressive delegation in state' ($stateAfterUpdate33.codexDelegation.selected -ceq 'aggressive') ''
    Assert-Condition 'S33 update preserves delegation_policy = aggressive in global AGENTS.md' ($rtAfterUpdate33.Policy -ceq 'aggressive') $agentsAfterUpdate33

    # Requirement 2: subagent_backend selected (native) is also preserved
    Assert-Condition 'S33 update preserves selected native backend in state' ($stateAfterUpdate33.codexBackend.selected -ceq 'native') ''
    Assert-Condition 'S33 update preserves subagent_backend = native in global AGENTS.md' ($rtAfterUpdate33.Backend -ceq 'native') $agentsAfterUpdate33
    Assert-Condition 'S33 update preserves native backend matrix in config.toml' ($configAfterUpdate33 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $configAfterUpdate33 -match '(?m)^\s*fast_mode\s*=\s*false\s*$' -and $configAfterUpdate33 -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-5\.6-luna"\s*$') $configAfterUpdate33

    # Requirement 3: Global kit artifacts are updated/present, and consumer repo AGENTS.md has NO runtime flags
    $wfSkillAgents33 = Join-Path (Get-AgentsHome $root33) 'skills\workflows\SKILL.md'
    $mcpSkillAgents33 = Join-Path (Get-AgentsHome $root33) 'skills\mcp-foundation\SKILL.md'
    $efSkillAgents33 = Join-Path (Get-AgentsHome $root33) 'skills\evidence-first\SKILL.md'
    $wfSkillAg1_33 = Join-Path (Get-AntigravityHome $root33) 'antigravity\skills\workflows\SKILL.md'
    $mcpSkillAg1_33 = Join-Path (Get-AntigravityHome $root33) 'antigravity\skills\mcp-foundation\SKILL.md'
    $wfSkillAg2_33 = Join-Path (Get-AntigravityHome $root33) 'config\skills\workflows\SKILL.md'
    $mcpSkillAg2_33 = Join-Path (Get-AntigravityHome $root33) 'config\skills\mcp-foundation\SKILL.md'
    $geminiAg33 = Join-Path (Get-AntigravityHome $root33) 'config\GEMINI.md'

    Assert-Condition 'S33 workflows skill installed in agents' (Test-Path -LiteralPath $wfSkillAgents33 -PathType Leaf) $wfSkillAgents33
    Assert-Condition 'S33 mcp-foundation skill installed in agents' (Test-Path -LiteralPath $mcpSkillAgents33 -PathType Leaf) $mcpSkillAgents33
    Assert-Condition 'S33 evidence-first skill installed in agents' (Test-Path -LiteralPath $efSkillAgents33 -PathType Leaf) $efSkillAgents33
    Assert-Condition 'S33 workflows skill installed in antigravity 1' (Test-Path -LiteralPath $wfSkillAg1_33 -PathType Leaf) $wfSkillAg1_33
    Assert-Condition 'S33 mcp-foundation skill installed in antigravity 1' (Test-Path -LiteralPath $mcpSkillAg1_33 -PathType Leaf) $mcpSkillAg1_33
    Assert-Condition 'S33 workflows skill installed in antigravity 2' (Test-Path -LiteralPath $wfSkillAg2_33 -PathType Leaf) $wfSkillAg2_33
    Assert-Condition 'S33 mcp-foundation skill installed in antigravity 2' (Test-Path -LiteralPath $mcpSkillAg2_33 -PathType Leaf) $mcpSkillAg2_33
    Assert-Condition 'S33 GEMINI.md installed in antigravity config' (Test-Path -LiteralPath $geminiAg33 -PathType Leaf) $geminiAg33

    $consumerAgentsAfterInstall = Get-Content -LiteralPath $consumerAgentsPath -Raw -Encoding UTF8
    Assert-Condition 'S33 consumer repo AGENTS.md is strictly untouched' ($consumerAgentsAfterInstall -ceq ($consumerAgentsContent -replace "`r?`n", "`r`n")) $consumerAgentsAfterInstall
    Assert-Condition 'S33 consumer repo AGENTS.md contains no kit runtime block' ($consumerAgentsAfterInstall.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: runtime', [StringComparison]::Ordinal) -lt 0) $consumerAgentsAfterInstall
    Assert-Condition 'S33 consumer repo AGENTS.md contains no subagent_backend flag' ($consumerAgentsAfterInstall.IndexOf('subagent_backend', [StringComparison]::Ordinal) -lt 0) $consumerAgentsAfterInstall
    Assert-Condition 'S33 consumer repo AGENTS.md contains no delegation_policy flag' ($consumerAgentsAfterInstall.IndexOf('delegation_policy', [StringComparison]::Ordinal) -lt 0) $consumerAgentsAfterInstall

    # Step 33.4: Switch policy to balanced, re-install, verify balanced is preserved; switch to aggressive, re-install, verify aggressive is preserved
    $polBalResult33 = Invoke-PolicySwitch -Root $root33 -Policy balanced
    Assert-Condition 'S33 switch policy to balanced succeeds' ($polBalResult33.ExitCode -eq 0) $polBalResult33.Output
    $stateBal33 = Get-InstallState $root33
    $rtBal33 = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8)
    Assert-Condition 'S33 policy is balanced in state and AGENTS.md before reinstall' ($stateBal33.codexDelegation.selected -ceq 'balanced' -and $rtBal33.Policy -ceq 'balanced') ''

    $reinstallBal33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 reinstall with balanced policy succeeds' ($reinstallBal33.ExitCode -eq 0) $reinstallBal33.Output
    $stateAfterReinstallBal33 = Get-InstallState $root33
    $rtAfterReinstallBal33 = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8)
    Assert-Condition 'S33 reinstall preserves active balanced policy' ($stateAfterReinstallBal33.codexDelegation.selected -ceq 'balanced' -and $rtAfterReinstallBal33.Policy -ceq 'balanced') ''

    # Switch back to deepseek backend, then to aggressive policy, reinstall, verify preservation
    $backDeepResult33 = Invoke-BackendSwitch -Root $root33 -Backend deepseek
    $polAggResult33_2 = Invoke-PolicySwitch -Root $root33 -Policy aggressive
    Assert-Condition 'S33 switch backend to deepseek succeeds' ($backDeepResult33.ExitCode -eq 0) $backDeepResult33.Output
    Assert-Condition 'S33 switch policy to aggressive succeeds again' ($polAggResult33_2.ExitCode -eq 0) $polAggResult33_2.Output

    $reinstallAgg33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 reinstall with deepseek + aggressive succeeds' ($reinstallAgg33.ExitCode -eq 0) $reinstallAgg33.Output
    $stateAfterReinstallAgg33 = Get-InstallState $root33
    $rtAfterReinstallAgg33 = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8)
    $configAfterReinstallAgg33 = Read-Config $root33
    Assert-Condition 'S33 reinstall preserves active aggressive policy with deepseek' ($stateAfterReinstallAgg33.codexDelegation.selected -ceq 'aggressive' -and $rtAfterReinstallAgg33.Policy -ceq 'aggressive') ''
    Assert-Condition 'S33 reinstall preserves active deepseek backend with aggressive policy' ($stateAfterReinstallAgg33.codexBackend.selected -ceq 'deepseek' -and $rtAfterReinstallAgg33.Backend -ceq 'deepseek') ''
    Assert-Condition 'S33 config.toml reflects deepseek matrix' ($configAfterReinstallAgg33 -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $configAfterReinstallAgg33

    # Status checks report consistent state
    $statusPol33 = Invoke-PolicyStatus -Root $root33
    $statusBack33 = Invoke-BackendStatus -Root $root33
    Assert-Condition 'S33 policy status reports deepseek and aggressive' ($statusPol33.ExitCode -eq 0 -and $statusPol33.Output -match '(?i)backend:\s*deepseek' -and $statusPol33.Output -match '(?i)policy:\s*aggressive') $statusPol33.Output
    Assert-Condition 'S33 backend status reports deepseek and aggressive' ($statusBack33.ExitCode -eq 0 -and $statusBack33.Output -match '(?i)backend:\s*deepseek' -and $statusBack33.Output -match '(?i)policy:\s*aggressive') $statusBack33.Output

    # Requirement 5: Verify real environment was untouched (root paths were confined to $root33 in temp)
    Assert-Condition 'S33 fixture root is inside temp directory' ($root33.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) $root33
    Assert-Condition 'S33 consumer repo AGENTS.md remains pristine after all toggles and updates' ((Get-Content -LiteralPath $consumerAgentsPath -Raw -Encoding UTF8) -ceq ($consumerAgentsContent -replace "`r?`n", "`r`n")) ''
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
