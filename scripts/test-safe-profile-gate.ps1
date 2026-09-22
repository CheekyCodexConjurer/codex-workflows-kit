[CmdletBinding()]
param(
    [int]$Scenario = 0
)

$targetScenario = $Scenario

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

function Normalize-CapturedOutput {
    param(
        [AllowEmptyString()][string]$Text = ''
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $unwrapped = $Text -replace '(?:\r\n|\r|\n)(?:\x1b\[[0-9;?]*[a-zA-Z])*?\x1b\[[0-9;]*[Hf]|\x1b\[[0-9;]*[Hf](?:\x1b\[[0-9;?]*[a-zA-Z])*?(?:\r\n|\r|\n)', ''
    $stripped = $unwrapped -replace '\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))', ''
    return $stripped
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $resolvedPath = $FilePath
    if (-not [IO.Path]::IsPathRooted($FilePath)) {
        $cmd = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrEmpty($cmd.Source)) {
            $resolvedPath = $cmd.Source
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolvedPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    if ($resolvedPath -like '*powershell.exe' -or $resolvedPath -like '*powershell') {
        $machinePsModule = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        $userPsModule = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
        $parts = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrEmpty($userPsModule)) { $parts.Add($userPsModule) }
        if (-not [string]::IsNullOrEmpty($machinePsModule)) { $parts.Add($machinePsModule) }
        if ($parts.Count -gt 0) {
            $joined = ($parts -join [IO.Path]::PathSeparator)
            if ($null -ne $psi.PSObject.Properties['Environment']) {
                $psi.Environment['PSModulePath'] = $joined
            }
            else {
                $psi.EnvironmentVariables['PSModulePath'] = $joined
            }
        }
    }

    if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
        foreach ($arg in $ArgumentList) {
            $psi.ArgumentList.Add([string]$arg)
        }
    }
    else {
        $escapedArgs = New-Object System.Collections.Generic.List[string]
        foreach ($arg in $ArgumentList) {
            if ($arg -match '[\s"]') {
                $escapedArgs.Add('"' + ($arg -replace '(\\*)(")', '$1$1\"' -replace '(\\+)$', '$1$1') + '"')
            }
            else {
                $escapedArgs.Add($arg)
            }
        }
        $psi.Arguments = ($escapedArgs -join ' ')
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $prev = $ErrorActionPreference
    $prevGlobal = $global:ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:ErrorActionPreference = 'Continue'

        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode

        $rawOutput = if ([string]::IsNullOrEmpty($stdout)) {
            $stderr
        }
        elseif ([string]::IsNullOrEmpty($stderr)) {
            $stdout
        }
        else {
            if ($stdout.EndsWith("`r`n") -or $stdout.EndsWith("`n")) {
                $stdout + $stderr
            }
            else {
                $stdout + [Environment]::NewLine + $stderr
            }
        }

        $normalizedOutput = Normalize-CapturedOutput -Text $rawOutput
        return [pscustomobject]@{
            ExitCode  = $exitCode
            Output    = $normalizedOutput
            RawOutput = $rawOutput
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
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

function Get-AgentsRuntimeBlock {
    param([Parameter(Mandatory)][string]$Text)

    $backendMatch = [regex]::Match($Text, '(?m)^\s*subagent_backend\s*=\s*([a-zA-Z0-9_-]+)\s*(?:#.*)?$')
    $continuationMatch = [regex]::Match($Text, '(?m)^\s*subagent_continuation\s*=\s*([a-zA-Z0-9_-]+)\s*(?:#.*)?$')
    return [pscustomobject]@{
        Backend = if ($backendMatch.Success) { $backendMatch.Groups[1].Value } else { $null }
        Continuation = if ($continuationMatch.Success) { $continuationMatch.Groups[1].Value } else { $null }
    }
}

function Invoke-ContinuationSwitch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('active_follow', 'park_and_wake')][string]$Continuation
    )

    $switchScript = Join-Path $repo 'scripts\switch-subagent-continuation.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Continuation', $Continuation, '-CodexHome', (Get-CodexHome $Root))
}

function Invoke-ContinuationStatus {
    param([Parameter(Mandatory)][string]$Root)

    $switchScript = Join-Path $repo 'scripts\switch-subagent-continuation.ps1'
    return Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Status', '-CodexHome', (Get-CodexHome $Root))
}

function Invoke-ContinuationSwitchWithHost {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('active_follow', 'park_and_wake')][string]$Continuation,
        [Parameter(Mandatory)][object]$HostInfo
    )

    $switchScript = Join-Path $repo 'scripts\switch-subagent-continuation.ps1'
    return Invoke-ProcessCapture -FilePath $HostInfo.Path -ArgumentList @('-NoProfile', '-File', $switchScript, '-Continuation', $Continuation, '-CodexHome', (Get-CodexHome $Root))
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
    if (-not [regex]::IsMatch($normalized, '(?i)(?:subagents_continue|deepseek_continue).{0,80}allow_respawn')) {
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

function Test-DeliveryReviewPolicySemantics {
    param(
        [Parameter(Mandatory)][string]$DeliveryReviewText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText
    )

    $deliveryNorm = [regex]::Replace($DeliveryReviewText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()

    # 1. Delivery review reference must define the risk-triggered operational/runtime proof gate
    $deliveryRequired = @(
        '(?i)prova operacional|operational proof|runtime proof',
        '(?i)processo/daemon/servi[cç]o ativo|live process|daemon|service',
        '(?i)persist[eê]ncia ou migra[cç][aã]o|persistence or migration',
        '(?i)concorr[eê]ncia/exactly-once|concurrency/exactly-once',
        '(?i)roteamento de provedor/modelo|provider/model routing',
        '(?i)integra[cç][aã]o externa|external integration',
        '(?i)volume/escala de dados|resource scale|data volume',
        '(?i)evid[eê]ncia observada|observed evidence',
        '(?i)lat[eê]ncia|readiness|health',
        '(?i)falsos?-verdes? est[aá]ticos?|static-only.*false green|test-only.*false green',
        '(?i)BLOCKED',
        '(?i)nunca inventar|never invent',
        '(?i)sem ampliar autoridade|never broaden authority'
    )
    foreach ($pattern in $deliveryRequired) {
        if (-not [regex]::IsMatch($deliveryNorm, $pattern)) {
            return $false
        }
    }

    # Sequence order in delivery review:
    # deterministic validation -> freeze target -> bounded operational proof -> revisor independente -> repair/closure -> commit gate
    if (-not [regex]::IsMatch($deliveryNorm, '(?i)(?:valida[cç][aã]o determin[ií]stica|deterministic validation).*(?:congelamento do alvo|frozen target|target_id).*(?:prova operacional|operational proof|runtime proof).*(?:revis[aã]o independente|independent review)')) {
        return $false
    }

    # Prohibit static-only bypass or assuming pass when proof is unavailable
    if ([regex]::IsMatch($deliveryNorm, '(?i)\b(?:may|can|should|pode|deve)\b\s+(?!not\b|never\b|n[aã]o\b|nunca\b)[^.;]*\b(?:aprovar sem prova operacional|approve without operational proof|presumir aprovado|assume pass|ignorar prova operacional|bypass operational proof|approve based on static tests alone|aprovar com base apenas em testes est[aá]ticos|aprovar apenas com testes est[aá]ticos)\b')) {
        return $false
    }
    if ([regex]::IsMatch($deliveryNorm, '(?i)\b(?:may|can|should|pode|deve)\b\s+(?!not\b|never\b|n[aã]o\b|nunca\b)[^.;]*\b(?:executar a[cç][oõ]es destrutivas implicitamente|broaden authority implicitly|ampliar autoridade|ampliar permiss[oõ]es sem autoriza[cç][aã]o)\b')) {
        return $false
    }

    # 2. SKILL.md checks
    $skillRequired = @(
        '(?i)operational proof|runtime proof|prova operacional',
        '(?i)live process|daemon|persistence|migration|concurrency|routing|integration|scale|volume',
        '(?i)static-only|false green|falso-verde',
        '(?i)BLOCKED'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNorm, $pattern)) {
            return $false
        }
    }

    # 3. AGENTS.md checks
    $agentsRequired = @(
        '(?i)prova operacional|operational proof|runtime proof',
        '(?i)processo/daemon/servi[cç]o|persist[eê]ncia|concorr[eê]ncia|roteamento|integra[cç][aã]o|escala|volume',
        '(?i)BLOCKED|falsos?-verdes?|false green'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            return $false
        }
    }

    # 4. GEMINI.md checks
    $geminiRequired = @(
        '(?i)prova operacional|operational proof|runtime proof|delivery review'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            return $false
        }
    }

    return $true
}

function Test-AlinhamentoPolicySemantics {
    param(
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$DelegationText,
        [Parameter(Mandatory)][string]$ReadmeText
    )

    $script:AlinhamentoPolicyFailure = ''
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
            $script:AlinhamentoPolicyFailure = "AGENTS.md required pattern missing: $pattern"
            return $false
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
            $script:AlinhamentoPolicyFailure = "GEMINI.md required pattern missing: $pattern"
            return $false
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
            $script:AlinhamentoPolicyFailure = "SKILL.md required pattern missing: $pattern"
            return $false
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
        '(?i)(?:GPT direto|direct GPT).{0,180}(?:sem ganho material de delega[c\u00e7][a\u00e3]o|no material delegation benefit)'
    )
    foreach ($pattern in $delegationRequired) {
        if (-not [regex]::IsMatch($delegationNorm, $pattern)) {
            $script:AlinhamentoPolicyFailure = "delegation.md required pattern missing: $pattern"
            return $false
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
            $script:AlinhamentoPolicyFailure = "README.md required pattern missing: $pattern"
            return $false
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
            $script:AlinhamentoPolicyFailure = "forbidden policy pattern detected: $pattern"
            return $false
        }
    }

    return $true
}

function Test-CorrectionAdequacyGateSemantics {
    param(
        [Parameter(Mandatory)][string]$DeliveryReviewText,
        [Parameter(Mandatory)][string]$QualityRatchetText,
        [Parameter(Mandatory)][string]$ValidationText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$ReadmeText,
        [string]$CommitText = '',
        [string]$DelegationText = ''
    )

    $script:CorrectionAdequacyFailure = ''
    $deliveryNorm = [regex]::Replace($DeliveryReviewText, '\s+', ' ').Trim()
    $qualityNorm = [regex]::Replace($QualityRatchetText, '\s+', ' ').Trim()
    $validationNorm = [regex]::Replace($ValidationText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
    $readmeNorm = [regex]::Replace($ReadmeText, '\s+', ' ').Trim()
    $commitNorm = [regex]::Replace($CommitText, '\s+', ' ').Trim()
    $delegationNorm = [regex]::Replace($DelegationText, '\s+', ' ').Trim()

    # 1. Delivery review must define Correction Adequacy Gate and sustainable/sufficient fix
    $deliveryRequired = @(
        '(?i)Gate de Adequa[c\u00e7][a\u00e3]o(?: da Corre[c\u00e7][a\u00e3]o)?',
        '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel(?:/delimitada)?',
        '(?i)LOCAL_FIX',
        '(?i)ROBUST_FIX',
        '(?i)REWORK',
        '(?i)RESEARCH',
        '(?i)RESEARCH_THEN_REWORK',
        '(?i)BLOCKED',
        '(?i)pre-first-edit|antes da primeira edi[c\u00e7][a\u00e3]o',
        '(?i)\bfalha\b|\bfailure\b',
        '(?i)causa estrutural|structural cause',
        '(?i)expans[a\u00e3]o de escopo|scope expansion',
        '(?i)pr[e\u00e9]-revis[a\u00e3]o|pre-review',
        '(?i)(?:nunca|sem|n[a\u00e3]o).{0,30}(?:a cada turno|per-turn)',
        '(?i)(?:sem|nunca|proibid[oa]).{0,40}troca(?:r)? autom[a\u00e1]tica(?:mente)? de modo',
        '(?i)required_fix',
        '(?i)blast radius',
        '(?i)tn-paydown-gate',
        '(?i)replan-gate',
        '(?i)debug_ledger\.md|debug ledger',
        '(?i)pol[i\u00ed]tica de reparo orientada a evid[e\u00ea]ncia|evidence-based repair',
        '(?i)hip[o\u00f3]tese|hypothesis',
        '(?i)observa[c\u00e7][a\u00e3]o discriminante|expected discriminating observation',
        '(?i)delta observado|observed delta',
        '(?i)(?:admiss[a\u00e3]o|admission).{0,150}(?:hip[o\u00f3]tese|hypothesis).{0,150}(?:observa[c\u00e7][a\u00e3]o (?:esperada|discriminante)|expected (?:discriminating )?observation)',
        '(?i)(?:admiss[a\u00e3]o|admission).{0,180}(?:antes de delta|before (?:the )?delta).{0,100}(?:p[o\u00f3]s-resultado|post-result).{0,100}(?:delta observado|observed delta|falsifica[c\u00e7]|falsif)',
        '(?i)(?:p[o\u00f3]s-resultado|post-result).{0,120}(?:delta observado|observed delta|falsif)',
        '(?i)pr[o\u00f3]xima decis[a\u00e3]o|next decision',
        '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente|different diagnostic direction',
        '(?i)(?:sem|proibid[oa]|nunca).{0,50}(?:retentativa id[e\u00ea]ntica|duplicate retry|worker swarm)',
        '(?i)(?:terceir[ao]|subsequente).{0,50}(?:reparo|tentativa).{0,50}(?:permitid[ao]|avalan|avan[c\u00e7]a)|novas evid[e\u00ea]ncias [u\u00fa]teis e hip[o\u00f3]teses test[a\u00e1]veis',
        '(?i)bloqueio genu[i\u00ed]no de (?:autoridade|acesso|decis[a\u00e3]o do usu[a\u00e1]rio)',
        '(?i)sem caminho seguro acion[a\u00e1]vel|no safe actionable path',
        '(?i)(?:sem|proibid[oa]|nunca).{0,50}(?:limite num[e\u00e9]rico fixo|contador(?:es)? disfar[c\u00e7]ado|numerical stopping rule)',
        '(?i)transporte neutro|neutral transport'
    )
    foreach ($pattern in $deliveryRequired) {
        if (-not [regex]::IsMatch($deliveryNorm, $pattern)) {
            $script:CorrectionAdequacyFailure = "delivery-review.md required pattern missing: $pattern"
            return $false
        }
    }

    # 2. SKILL.md checks
    $skillRequired = @(
        '(?i)Gate de Adequa[c\u00e7][a\u00e3]o|corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel',
        '(?i)PLAN(?:\.AUTO)?',
        '(?i)DEBUG|BUG\.FIX',
        '(?i)DELIVER|IMPL',
        '(?i)REWORK',
        '(?i)RESEARCH\.DEEP',
        '(?i)ALINHAMENTO',
        '(?i)COMMIT',
        '(?i)references/delivery-review\.md.{0,100}(?:own|owns|gate details)|references/delivery-review\.md'
    )
    foreach ($pattern in $skillRequired) {
        if (-not [regex]::IsMatch($skillNorm, $pattern)) {
            $script:CorrectionAdequacyFailure = "SKILL.md required pattern missing: $pattern"
            return $false
        }
    }

    # 3. AGENTS.md checks
    $agentsRequired = @(
        '(?i)Gate de Adequa[c\u00e7][a\u00e3]o|corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel',
        '(?i)references/delivery-review\.md|delivery-review\.md',
        '(?i)transporte neutro|neutral transport',
        '(?i)bridge.{0,60}n[a\u00e3]o decide aprova[c\u00e7][a\u00e3]o|bridge.{0,60}does not decide approval'
    )
    foreach ($pattern in $agentsRequired) {
        if (-not [regex]::IsMatch($agentsNorm, $pattern)) {
            $script:CorrectionAdequacyFailure = "AGENTS.md required pattern missing: $pattern"
            return $false
        }
    }

    # 4. GEMINI.md checks
    $geminiRequired = @(
        '(?i)Gate de Adequa[c\u00e7][a\u00e3]o|corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel',
        '(?i)delivery review gate|references/delivery-review\.md',
        '(?i)transporte neutro'
    )
    foreach ($pattern in $geminiRequired) {
        if (-not [regex]::IsMatch($geminiNorm, $pattern)) {
            $script:CorrectionAdequacyFailure = "GEMINI.md required pattern missing: $pattern"
            return $false
        }
    }

    # 5. Quality ratchet & Validation checks
    if (-not [regex]::IsMatch($qualityNorm, '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel|sustent[a\u00e1]vel|tn-paydown-gate')) {
        $script:CorrectionAdequacyFailure = 'quality-ratchet.md missing sufficient/sustainable fix language'
        return $false
    }
    if (-not [regex]::IsMatch($validationNorm, '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel|Gate de Adequa[c\u00e7][a\u00e3]o')) {
        $script:CorrectionAdequacyFailure = 'validation.md missing sufficient/sustainable correction gate language'
        return $false
    }

    # 6. Forbiddens / Tampers across the policies
    $staleMax2Pattern = '(?i)(?:(?:at\s+most|max(?:imum)?(?:\s+of)?|up\s+to)\s+(?:\d+|two)\s+(?:(?:consolidated\s+)?repair\s+)?rounds?|max(?:imum)?\s+two\b|(?:(?:no\s+)?m(?:[a\u00e1]|\u00c3\u00a1)x(?:imo|\u00c3\u00admo)?\.?(?:\s+de)?|at(?:[e\u00e9]|\u00c3\u00a9)|limite\s+(?:fixo\s+)?de)\s+(?:\d+|duas?|dois)\s+(?:rodadas?(?:\s+de\s+reparo)?|tentativas?)|m(?:[a\u00e1]|\u00c3\u00a1)x\.?\s*2(?:\s+rodadas?)?|\blimite\s+num(?:[e\u00e9]|\u00c3\u00a9)rico\s+fixo\s+de\s+\d+)'
    $forbidden = @(
        '(?i)"required_fix":\s*"corre(?:[c\u00e7]|\u00c3\u00a7)(?:[a\u00e3]|\u00c3\u00a3)o m(?:[i\u00ed]|\u00c3\u00ad)nima exigida"',
        '(?i)\bmeta de corre(?:[c\u00e7]|\u00c3\u00a7)(?:[a\u00e3]|\u00c3\u00a3)o m(?:[i\u00ed]|\u00c3\u00ad)nima\b',
        '(?i)\b(?:pode|deve|autoriza|permite)\b\s+(?!n[a\u00e3]o\b|nunca\b|sem\b)[^.;]*\b(?:troca|trocar|transi[c\u00e7][a\u00e3]o)\s+autom[a\u00e1]tica(?:mente)?\s+de\s+modo\b',
        '(?i)\bbridge\b\s+(?:decide|aprova|rejeita)\b',
        '(?i)\b(?:regras de workflow|workflow rules)\s+residem\s+no\s+bridge\b',
        '(?i)\b(?:concede|permite|autoriza)\s+escrita\b[^.;]*(?:no ALINHAMENTO|em PLAN|em REWORK|em RESEARCH)',
        '(?i)\bacionado a cada turno\b|\bacionado em todo turno\b',
        $staleMax2Pattern
    )
    $allSurfaces = @($deliveryNorm, $skillNorm, $agentsNorm, $geminiNorm, $qualityNorm, $validationNorm, $readmeNorm)
    if (-not [string]::IsNullOrWhiteSpace($commitNorm)) { $allSurfaces += $commitNorm }
    if (-not [string]::IsNullOrWhiteSpace($delegationNorm)) { $allSurfaces += $delegationNorm }
    foreach ($pattern in $forbidden) {
        foreach ($surf in $allSurfaces) {
            if ([regex]::IsMatch($surf, $pattern)) {
                $script:CorrectionAdequacyFailure = "forbidden correction-gate pattern detected: $pattern"
                return $false
            }
        }
    }

    return $true
}

function Test-SubagentAutonomySemantics {
    param(
        [Parameter(Mandatory)][string]$DelegationText,
        [Parameter(Mandatory)][string]$DeliveryReviewText,
        [Parameter(Mandatory)][string]$SkillText,
        [Parameter(Mandatory)][string]$AgentsText,
        [Parameter(Mandatory)][string]$GeminiText,
        [Parameter(Mandatory)][string]$ReadmeText
    )

    $delegationNorm = [regex]::Replace($DelegationText, '\s+', ' ').Trim()
    $deliveryNorm = [regex]::Replace($DeliveryReviewText, '\s+', ' ').Trim()
    $skillNorm = [regex]::Replace($SkillText, '\s+', ' ').Trim()
    $agentsNorm = [regex]::Replace($AgentsText, '\s+', ' ').Trim()
    $geminiNorm = [regex]::Replace($GeminiText, '\s+', ' ').Trim()
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
            return $false
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
            return $false
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
            return $false
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
            return $false
        }
    }

    # 5. Delivery Review reference checks
    if (-not [regex]::IsMatch($deliveryNorm, '(?i)park_and_wake.*SUSPENDED.*ParkReceipt.*subagents_follow')) {
        return $false
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
            return $false
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
            return $false
        }
    }

    return $true
}

$currentScenario = 0
$fixtures = New-Object System.Collections.Generic.List[string]

try {
    if ($targetScenario -eq 0 -or $targetScenario -lt 37) {
    $currentScenario = 1
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
    Write-Host 'Scenario 6: schema-3 install state migrates to schema 6' -ForegroundColor Cyan
    $root = New-FixtureHome
    $fixtures.Add($root)
    $original = '[features]
multi_agent = true
'
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'config.toml') -Content $original
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root) 'codex-workflows-kit\install-state.json') -Content '{"schemaVersion":3,"product":"codex-workflows-kit","profile":"safe","installedAtUtc":"2026-01-01T00:00:00Z","files":[],"pendingFiles":[]}'
    Invoke-SafeInstall -Root $root
    $state = Get-InstallState $root
    Assert-Condition 'S6 state migrates to schema 6' ($null -ne $state -and [int]$state.schemaVersion -eq 6) ''
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
    Assert-Condition 'S7 records the observed feature state' ($null -ne $state -and [int]$state.schemaVersion -eq 6 -and $state.codexFeaturesPrior.multi_agent.present -eq $true -and [string]$state.codexFeaturesPrior.multi_agent.value -ceq 'true') ''
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
    $tamperedManagedGemini = $installedGemini.Replace('# END CODEX-WORKFLOWS-KIT', '- forbidden read-only reader inside managed block' + $nl + '# END CODEX-WORKFLOWS-KIT')
    Write-FixtureFile -Path $installedGeminiPath -Content $tamperedManagedGemini

    $docResult2 = Invoke-Doctor -Root $root
    Assert-Condition 'S12 doctor fails when read-only reader is inside the managed GEMINI block' ($docResult2.ExitCode -ne 0 -and $docResult2.Output -match '\[FAIL\]\s+Installed contract') $docResult2.Output

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
    Assert-Condition 'S15 pins native model and max reasoning' ($nativeConfig -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-6-luna"\s*(?:#.*)?$' -and $nativeConfig -match '(?m)^\s*default_subagent_reasoning_effort\s*=\s*"max"\s*(?:#.*)?$') $nativeConfig
    $hasCanonicalMcp = ($nativeConfig -match '(?ms)\[mcp_servers\.subagents\].*?enabled\s*=\s*false' -and $nativeConfig -notmatch '\[mcp_servers\.deepseek-subagent\]')
    $hasLegacyMcp = ($nativeConfig -match '(?ms)\[mcp_servers\.deepseek-subagent\].*?enabled\s*=\s*false' -and $nativeConfig -notmatch '\[mcp_servers\.subagents\]')
    Assert-Condition 'S15 disables the DeepSeek MCP without deleting its table' (($hasCanonicalMcp -or $hasLegacyMcp) -and $nativeConfig -match '(?ms)\[mcp_servers\.sample\].*?command\s*=\s*"sample"') $nativeConfig
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
    Write-Host 'Scenario 17: schema-6 safe install, native switch, safe reinstall preservation, and uninstall restoration' -ForegroundColor Cyan
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
    Assert-Condition 'S17 starts from a schema-6 safe install with backend and continuation state' ($null -ne $stateBeforeSwitch17 -and [int]$stateBeforeSwitch17.schemaVersion -eq 6 -and $stateBeforeSwitch17.PSObject.Properties.Name -contains 'codexBackend' -and $stateBeforeSwitch17.PSObject.Properties.Name -contains 'codexContinuation' -and -not ($stateBeforeSwitch17.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($stateBeforeSwitch17.PSObject.Properties.Name -contains 'codexStrategy')) ''

    $native17 = Invoke-BackendSwitch -Root $root -Backend native
    $nativeConfig17 = Read-Config $root
    $stateAfterSwitch17 = Get-InstallState $root
    Assert-Condition 'S17 native switch updates schema-6 backend and continuation state' ($native17.ExitCode -eq 0 -and $null -ne $stateAfterSwitch17.codexBackend -and [int]$stateAfterSwitch17.schemaVersion -eq 6 -and [string]$stateAfterSwitch17.codexBackend.selected -ceq 'native' -and [string]$stateAfterSwitch17.codexContinuation.selected -ceq 'active_follow' -and -not ($stateAfterSwitch17.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($stateAfterSwitch17.PSObject.Properties.Name -contains 'codexStrategy')) $native17.Output
    Assert-Condition 'S17 native matrix is active before reinstall' ($nativeConfig17 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $nativeConfig17 -match '(?m)^\s*fast_mode\s*=\s*false\s*$') $nativeConfig17

    Invoke-SafeInstall -Root $root
    $nativeAfterReinstall17 = Read-Config $root
    $stateAfterReinstall17 = Get-InstallState $root
    Assert-Condition 'S17 safe reinstall preserves the selected native backend' ($nativeAfterReinstall17 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $nativeAfterReinstall17 -match '(?m)^\s*fast_mode\s*=\s*false\s*$' -and $nativeAfterReinstall17 -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-6-luna"\s*$' -and [string]$stateAfterReinstall17.codexBackend.selected -ceq 'native') $nativeAfterReinstall17

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
    $nativeTampered = (Read-Config $root).Replace('default_subagent_model = "gpt-6-luna"', 'default_subagent_model = "user-tampered-model"')
    Write-FixtureFile -Path $configPath18 -Content $nativeTampered
    $driftResult18 = Invoke-BackendSwitch -Root $root -Backend deepseek
    Assert-Condition 'S18 user config drift blocks switching' ($driftResult18.ExitCode -ne 0 -and $driftResult18.Output -match '(?i)drift') $driftResult18.Output
    Assert-Condition 'S18 drift block leaves config untouched' ((Read-Config $root) -ceq $nativeTampered) ''

    Write-FixtureFile -Path $configPath18 -Content (Read-Config $root).Replace('user-tampered-model', 'gpt-6-luna')
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
            (Get-TomlTableKeyCount -Text $nativeHostConfig -Table 'agents' -Key 'default_subagent_model') -eq 1 -and $agentsHostBody -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-6-luna"\s*$' -and
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
    Write-Host 'Scenario 20: schemas 1-5 migrate to schema 6, preserving backend and continuation while retiring legacy selectors' -ForegroundColor Cyan
    $originalS25 = '[features]' + $nl +
        'multi_agent = false' + $nl +
        'fast_mode = true' + $nl + $nl +
        '[agents]' + $nl +
        'default_subagent_model = "prior-model"' + $nl +
        'default_subagent_reasoning_effort = "high"' + $nl + $nl +
        '[mcp_servers.deepseek-subagent]' + $nl +
        'command = "bridge-cmd"' + $nl +
        'enabled = true' + $nl

    foreach ($legacySchema in @(1, 2, 3, 4, 5)) {
        $legacyRoot = New-FixtureHome
        $fixtures.Add($legacyRoot)
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $legacyRoot) 'config.toml') -Content $originalS25
        Invoke-SafeInstall -Root $legacyRoot

        if ($legacySchema -eq 5) {
            Invoke-ContinuationSwitch -Root $legacyRoot -Continuation park_and_wake | Out-Null
        }

        $legacyState = Get-InstallState $legacyRoot
        $legacyState.schemaVersion = $legacySchema
        if ($legacySchema -lt 3) {
            $legacyState.PSObject.Properties.Remove('pendingFiles')
        }
        if ($legacySchema -lt 4) {
            $legacyState.PSObject.Properties.Remove('codexFeaturesPrior')
        }
        if ($legacySchema -lt 5) {
            $legacyState.PSObject.Properties.Remove('codexBackend')
            $legacyState.PSObject.Properties.Remove('codexContinuation')
            $legacyState.PSObject.Properties.Remove('codexDelegation')
            $legacyState.PSObject.Properties.Remove('codexStrategy')
        }
        else {
            $legacyState | Add-Member -MemberType NoteProperty -Name codexDelegation -Value ([pscustomobject]@{ version = 1; selected = 'aggressive' }) -Force
            $legacyState | Add-Member -MemberType NoteProperty -Name codexStrategy -Value ([pscustomobject]@{ version = 1; selected = 'critical' }) -Force
            $legacyAgentsPath = Join-Path (Get-CodexHome $legacyRoot) 'AGENTS.md'
            $legacyAgents = Get-Content -LiteralPath $legacyAgentsPath -Raw -Encoding UTF8
            $legacyAgents = $legacyAgents.Replace('subagent_backend = deepseek', ('subagent_backend = deepseek' + $nl + 'delegation_policy = aggressive' + $nl + 'subagent_strategy = critical'))
            Write-FixtureFile -Path $legacyAgentsPath -Content $legacyAgents
        }

        $legacyStatePath = Join-Path (Get-CodexHome $legacyRoot) 'codex-workflows-kit\install-state.json'
        Write-FixtureFile -Path $legacyStatePath -Content (($legacyState | ConvertTo-Json -Depth 8) + $nl)
        $migrateResult = Invoke-InstallCapture -Root $legacyRoot -Profile safe
        $migratedState = Get-InstallState $legacyRoot
        $migratedAgents = Get-Content -LiteralPath (Join-Path (Get-CodexHome $legacyRoot) 'AGENTS.md') -Raw -Encoding UTF8
        $migratedRuntime = Get-AgentsRuntimeBlock -Text $migratedAgents
        $expectedContinuation = if ($legacySchema -eq 5) { 'park_and_wake' } else { 'active_follow' }
        $runtimeStart = $migratedAgents.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: runtime', [StringComparison]::Ordinal)
        $runtimeEnd = $migratedAgents.IndexOf('# END CODEX-WORKFLOWS-KIT: runtime', $runtimeStart, [StringComparison]::Ordinal)
        $runtimeText = if ($runtimeStart -ge 0 -and $runtimeEnd -gt $runtimeStart) { $migratedAgents.Substring($runtimeStart, $runtimeEnd - $runtimeStart) } else { '' }

        Assert-Condition "S20 schema $legacySchema migrates to schema 6" ($migrateResult.ExitCode -eq 0 -and [int]$migratedState.schemaVersion -eq 6) $migrateResult.Output
        Assert-Condition "S20 schema $legacySchema keeps backend and resolves continuation" ([string]$migratedState.codexBackend.selected -ceq 'deepseek' -and [string]$migratedState.codexContinuation.selected -ceq $expectedContinuation -and $migratedRuntime.Backend -ceq 'deepseek' -and $migratedRuntime.Continuation -ceq $expectedContinuation) $runtimeText
        Assert-Condition "S20 schema $legacySchema removes retired selector state and runtime keys" (-not ($migratedState.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($migratedState.PSObject.Properties.Name -contains 'codexStrategy') -and $runtimeText -notmatch '(?m)^\s*(delegation_policy|subagent_strategy)\s*=') $runtimeText
    }

    $sourceAgents20 = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
    Assert-Condition 'S20 repository source codex/AGENTS.md remains a static template' ($sourceAgents20.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: runtime', [StringComparison]::Ordinal) -lt 0) $sourceAgents20

    $scenario = 21
    Write-Host 'Scenario 21: schema 6 requires backend and continuation; retired selectors fail closed across lifecycle commands' -ForegroundColor Cyan
    $root21 = New-FixtureHome
    $fixtures.Add($root21)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root21) 'config.toml') -Content $originalS25
    Invoke-SafeInstall -Root $root21
    $statePath21 = Join-Path (Get-CodexHome $root21) 'codex-workflows-kit\install-state.json'
    $validState21 = Get-InstallState $root21

    $commands21 = @('install', 'doctor', 'validate', 'backend switch', 'continuation switch', 'uninstall')
    $baselineConfig21 = Read-Config $root21
    $baselineAgents21 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root21) 'AGENTS.md') -Raw -Encoding UTF8
    foreach ($requiredProperty in @('codexBackend', 'codexContinuation')) {
        $invalidState21 = $validState21 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $invalidState21.PSObject.Properties.Remove($requiredProperty)
        $invalidJson21 = ($invalidState21 | ConvertTo-Json -Depth 8) + $nl

        foreach ($command21 in $commands21) {
            Write-FixtureFile -Path $statePath21 -Content $invalidJson21
            $stateBeforeCommand21 = Get-Content -LiteralPath $statePath21 -Raw -Encoding UTF8
            switch ($command21) {
                'install' { $result21 = Invoke-InstallCapture -Root $root21 -Profile safe }
                'doctor' { $result21 = Invoke-Doctor -Root $root21 }
                'validate' { $result21 = Invoke-Validate -Root $root21 }
                'backend switch' { $result21 = Invoke-BackendSwitch -Root $root21 -Backend native }
                'continuation switch' { $result21 = Invoke-ContinuationSwitch -Root $root21 -Continuation park_and_wake }
                'uninstall' { $result21 = Invoke-UninstallCapture -Root $root21 }
            }
            $unchanged21 = ((Get-Content -LiteralPath $statePath21 -Raw -Encoding UTF8) -ceq $stateBeforeCommand21) -and
                ((Read-Config $root21) -ceq $baselineConfig21) -and
                ((Get-Content -LiteralPath (Join-Path (Get-CodexHome $root21) 'AGENTS.md') -Raw -Encoding UTF8) -ceq $baselineAgents21)
            Assert-Condition "S21 schema 6 missing $requiredProperty rejects $command21" ($result21.ExitCode -ne 0) $result21.Output
            Assert-Condition "S21 schema 6 missing $requiredProperty leaves managed files unchanged after $command21" $unchanged21 $result21.Output
        }
    }

    $retiredState21 = $validState21 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $retiredState21 | Add-Member -MemberType NoteProperty -Name codexDelegation -Value ([pscustomobject]@{ version = 1; selected = 'aggressive' }) -Force
    $retiredState21 | Add-Member -MemberType NoteProperty -Name codexStrategy -Value ([pscustomobject]@{ version = 1; selected = 'critical' }) -Force
    $retiredJson21 = ($retiredState21 | ConvertTo-Json -Depth 8) + $nl
    foreach ($command21 in $commands21) {
        Write-FixtureFile -Path $statePath21 -Content $retiredJson21
        $stateBeforeCommand21 = Get-Content -LiteralPath $statePath21 -Raw -Encoding UTF8
        switch ($command21) {
            'install' { $result21 = Invoke-InstallCapture -Root $root21 -Profile safe }
            'doctor' { $result21 = Invoke-Doctor -Root $root21 }
            'validate' { $result21 = Invoke-Validate -Root $root21 }
            'backend switch' { $result21 = Invoke-BackendSwitch -Root $root21 -Backend native }
            'continuation switch' { $result21 = Invoke-ContinuationSwitch -Root $root21 -Continuation park_and_wake }
            'uninstall' { $result21 = Invoke-UninstallCapture -Root $root21 }
        }
        $unchanged21 = ((Get-Content -LiteralPath $statePath21 -Raw -Encoding UTF8) -ceq $stateBeforeCommand21) -and
            ((Read-Config $root21) -ceq $baselineConfig21) -and
            ((Get-Content -LiteralPath (Join-Path (Get-CodexHome $root21) 'AGENTS.md') -Raw -Encoding UTF8) -ceq $baselineAgents21)
        Assert-Condition "S21 schema 6 with retired selectors rejects $command21" ($result21.ExitCode -ne 0) $result21.Output
        Assert-Condition "S21 schema 6 with retired selectors leaves managed files unchanged after $command21" $unchanged21 $result21.Output
    }

    $scenario = 22
    Write-Host 'Scenario 22: duplicate TOML matrix keys and duplicate managed runtime keys fail closed without modifying user files' -ForegroundColor Cyan
    $root22 = New-FixtureHome
    $fixtures.Add($root22)
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root22) 'config.toml') -Content $originalS25
    Invoke-SafeInstall -Root $root22

    $configPath22 = Join-Path (Get-CodexHome $root22) 'config.toml'
    $validConfig22 = Read-Config $root22
    $duplicateConfig22 = $validConfig22.Replace('multi_agent = false', ('multi_agent = false' + $nl + 'multi_agent = false'))
    Write-FixtureFile -Path $configPath22 -Content $duplicateConfig22
    $duplicateConfigSwitch22 = Invoke-BackendSwitch -Root $root22 -Backend native
    Assert-Condition 'S22 duplicate TOML backend key blocks switching and preserves config.toml' ($duplicateConfigSwitch22.ExitCode -ne 0 -and (Read-Config $root22) -ceq $duplicateConfig22) $duplicateConfigSwitch22.Output
    Write-FixtureFile -Path $configPath22 -Content $validConfig22

    $agentsPath22 = Join-Path (Get-CodexHome $root22) 'AGENTS.md'
    $validAgents22 = Get-Content -LiteralPath $agentsPath22 -Raw -Encoding UTF8
    $duplicateBackendAgents22 = $validAgents22.Replace('subagent_backend = deepseek', ('subagent_backend = deepseek' + $nl + 'subagent_backend = deepseek'))
    Write-FixtureFile -Path $agentsPath22 -Content $duplicateBackendAgents22
    $duplicateBackendSwitch22 = Invoke-BackendSwitch -Root $root22 -Backend native
    Assert-Condition 'S22 duplicate backend runtime key blocks switching and preserves AGENTS.md' ($duplicateBackendSwitch22.ExitCode -ne 0 -and (Get-Content -LiteralPath $agentsPath22 -Raw -Encoding UTF8) -ceq $duplicateBackendAgents22) $duplicateBackendSwitch22.Output
    Write-FixtureFile -Path $agentsPath22 -Content $validAgents22

    $duplicateContinuationAgents22 = $validAgents22.Replace('subagent_continuation = active_follow', ('subagent_continuation = active_follow' + $nl + 'subagent_continuation = active_follow'))
    Write-FixtureFile -Path $agentsPath22 -Content $duplicateContinuationAgents22
    $duplicateContinuationSwitch22 = Invoke-ContinuationSwitch -Root $root22 -Continuation park_and_wake
    Assert-Condition 'S22 duplicate continuation runtime key blocks switching and preserves AGENTS.md' ($duplicateContinuationSwitch22.ExitCode -ne 0 -and (Get-Content -LiteralPath $agentsPath22 -Raw -Encoding UTF8) -ceq $duplicateContinuationAgents22) $duplicateContinuationSwitch22.Output

    $scenario = 30
    Write-Host 'Scenario 30: transaction rollback in backend and continuation switchers restores targets on failure' -ForegroundColor Cyan

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

    # S30.3: Continuation switcher transaction failure when AGENTS.md DID pre-exist
    $root30_3 = New-FixtureHome
    $fixtures.Add($root30_3)
    $originalConfig30_3 = $originalS25
    $originalAgents30_3 = '# Pre-existing AGENTS for continuation switch' + $nl
    $configPath30_3 = Join-Path (Get-CodexHome $root30_3) 'config.toml'
    $agentsPath30_3 = Join-Path (Get-CodexHome $root30_3) 'AGENTS.md'
    Write-FixtureFile -Path $configPath30_3 -Content $originalConfig30_3
    Write-FixtureFile -Path $agentsPath30_3 -Content $originalAgents30_3

    # Inject failure: create a directory at install-state.json path
    $stateDirBlocker3 = Join-Path (Get-CodexHome $root30_3) 'codex-workflows-kit\install-state.json'
    New-Item -ItemType Directory -Path $stateDirBlocker3 -Force | Out-Null

    $failedContinuationSwitch30_3 = Invoke-ContinuationSwitch -Root $root30_3 -Continuation park_and_wake
    Assert-Condition 'S30 continuation switch fails when state write is blocked' ($failedContinuationSwitch30_3.ExitCode -ne 0) $failedContinuationSwitch30_3.Output
    Assert-Condition 'S30 continuation switch restores pre-existing AGENTS.md byte-identically' ((Get-Content -LiteralPath $agentsPath30_3 -Raw -Encoding UTF8) -ceq $originalAgents30_3) (Get-Content -LiteralPath $agentsPath30_3 -Raw -Encoding UTF8)
    Assert-Condition 'S30 continuation switch leaves config.toml untouched' ((Read-Config $root30_3) -ceq $originalConfig30_3) (Read-Config $root30_3)

    # S30.4: Continuation switcher transaction failure when AGENTS.md did NOT pre-exist
    $root30_4 = New-FixtureHome
    $fixtures.Add($root30_4)
    $originalConfig30_4 = $originalS25
    $configPath30_4 = Join-Path (Get-CodexHome $root30_4) 'config.toml'
    $agentsPath30_4 = Join-Path (Get-CodexHome $root30_4) 'AGENTS.md'
    Write-FixtureFile -Path $configPath30_4 -Content $originalConfig30_4

    # Inject failure: create a directory at install-state.json path
    $stateDirBlocker4 = Join-Path (Get-CodexHome $root30_4) 'codex-workflows-kit\install-state.json'
    New-Item -ItemType Directory -Path $stateDirBlocker4 -Force | Out-Null

    $failedContinuationSwitch30_4 = Invoke-ContinuationSwitch -Root $root30_4 -Continuation park_and_wake
    Assert-Condition 'S30 continuation switch without AGENTS.md fails when state write is blocked' ($failedContinuationSwitch30_4.ExitCode -ne 0) $failedContinuationSwitch30_4.Output
    Assert-Condition 'S30 continuation switch removes newly-created AGENTS.md target on rollback' (-not (Test-Path -LiteralPath $agentsPath30_4 -PathType Leaf)) ''
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
    Assert-Condition 'S31 migration sets schemaVersion 6' ([int]$stateAfterMig31.schemaVersion -eq 6) $stateAfterMig31.schemaVersion
    Assert-Condition 'S31 migration defaults continuation to active_follow' ([string]$stateAfterMig31.codexContinuation.selected -ceq 'active_follow' -and -not ($stateAfterMig31.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($stateAfterMig31.PSObject.Properties.Name -contains 'codexStrategy')) ''
    Assert-Condition 'S31 migration keeps backend selected as deepseek' ([string]$stateAfterMig31.codexBackend.selected -ceq 'deepseek') ''
    Assert-Condition 'S31 migration refreshes ledger full-file hash' ($null -ne $cfgEntryInState31 -and [string]$cfgEntryInState31.sha256 -ceq $actualHashAfterMig31) ''

    # Step 31.2: Safe reinstall on Schema 6 after another unmanaged model change
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
    Assert-Condition 'S31 native switch updates native backend matrix' ($configAfterNat31 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $configAfterNat31 -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-6-luna"\s*$') $configAfterNat31
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
    Write-Host 'Scenario 33: installer updates preserve backend and continuation, refresh global artifacts, and leave consumer AGENTS.md untouched' -ForegroundColor Cyan
    $root33 = New-FixtureHome
    $fixtures.Add($root33)
    $configPath33 = Join-Path (Get-CodexHome $root33) 'config.toml'
    $agentsPath33 = Join-Path (Get-CodexHome $root33) 'AGENTS.md'

    $consumerRepoDir = Join-Path $root33 'consumer-repo'
    New-Item -ItemType Directory -Path $consumerRepoDir -Force | Out-Null
    $consumerAgentsPath = Join-Path $consumerRepoDir 'AGENTS.md'
    $consumerAgentsContent = '# Consumer Repository Rules' + $nl +
        '- Always write clean and modular code.' + $nl +
        '- Never commit secrets or api keys.' + $nl
    Write-FixtureFile -Path $consumerAgentsPath -Content $consumerAgentsContent

    $initialConfig33 = '[features]' + $nl +
        'multi_agent = false' + $nl +
        'fast_mode = true' + $nl + $nl +
        '[agents]' + $nl +
        'default_subagent_model = "test-model"' + $nl +
        'default_subagent_reasoning_effort = "high"' + $nl + $nl +
        '[mcp_servers.deepseek-subagent]' + $nl +
        'command = "bridge-cmd"' + $nl +
        'enabled = true' + $nl
    Write-FixtureFile -Path $configPath33 -Content $initialConfig33

    $install1_33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 initial safe install succeeds' ($install1_33.ExitCode -eq 0) $install1_33.Output

    $parkResult33 = Invoke-ContinuationSwitch -Root $root33 -Continuation park_and_wake
    $nativeResult33 = Invoke-BackendSwitch -Root $root33 -Backend native
    Assert-Condition 'S33 continuation switch to park_and_wake succeeds' ($parkResult33.ExitCode -eq 0) $parkResult33.Output
    Assert-Condition 'S33 backend switch to native succeeds' ($nativeResult33.ExitCode -eq 0) $nativeResult33.Output

    $stateBeforeUpdate33 = Get-InstallState $root33
    $agentsBeforeUpdate33 = Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8
    $runtimeBeforeUpdate33 = Get-AgentsRuntimeBlock -Text $agentsBeforeUpdate33
    Assert-Condition 'S33 state records schema-6 native backend and park_and_wake' ([int]$stateBeforeUpdate33.schemaVersion -eq 6 -and $stateBeforeUpdate33.codexBackend.selected -ceq 'native' -and $stateBeforeUpdate33.codexContinuation.selected -ceq 'park_and_wake') ''
    Assert-Condition 'S33 runtime block records native backend and park_and_wake' ($runtimeBeforeUpdate33.Backend -ceq 'native' -and $runtimeBeforeUpdate33.Continuation -ceq 'park_and_wake') $agentsBeforeUpdate33

    $updateResult33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 kit update/reinstall succeeds' ($updateResult33.ExitCode -eq 0) $updateResult33.Output

    $stateAfterUpdate33 = Get-InstallState $root33
    $agentsAfterUpdate33 = Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8
    $configAfterUpdate33 = Read-Config $root33
    $runtimeAfterUpdate33 = Get-AgentsRuntimeBlock -Text $agentsAfterUpdate33
    Assert-Condition 'S33 update preserves selected backend and continuation in schema 6' ([int]$stateAfterUpdate33.schemaVersion -eq 6 -and $stateAfterUpdate33.codexBackend.selected -ceq 'native' -and $stateAfterUpdate33.codexContinuation.selected -ceq 'park_and_wake' -and -not ($stateAfterUpdate33.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($stateAfterUpdate33.PSObject.Properties.Name -contains 'codexStrategy')) ''
    Assert-Condition 'S33 update preserves both runtime settings' ($runtimeAfterUpdate33.Backend -ceq 'native' -and $runtimeAfterUpdate33.Continuation -ceq 'park_and_wake') $agentsAfterUpdate33
    Assert-Condition 'S33 update preserves native backend matrix in config.toml' ($configAfterUpdate33 -match '(?m)^\s*multi_agent\s*=\s*true\s*$' -and $configAfterUpdate33 -match '(?m)^\s*fast_mode\s*=\s*false\s*$' -and $configAfterUpdate33 -match '(?m)^\s*default_subagent_model\s*=\s*"gpt-6-luna"\s*$') $configAfterUpdate33

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
    Assert-Condition 'S33 consumer repo AGENTS.md is strictly untouched' ($consumerAgentsAfterInstall -ceq $consumerAgentsContent) $consumerAgentsAfterInstall
    Assert-Condition 'S33 consumer repo AGENTS.md has no kit runtime block' ($consumerAgentsAfterInstall.IndexOf('# BEGIN CODEX-WORKFLOWS-KIT: runtime', [StringComparison]::Ordinal) -lt 0) $consumerAgentsAfterInstall
    Assert-Condition 'S33 consumer repo AGENTS.md has no installed selector values' ($consumerAgentsAfterInstall -notmatch '(?i)subagent_backend|subagent_continuation|delegation_policy|subagent_strategy') $consumerAgentsAfterInstall

    $deepseekResult33 = Invoke-BackendSwitch -Root $root33 -Backend deepseek
    $followResult33 = Invoke-ContinuationSwitch -Root $root33 -Continuation active_follow
    Assert-Condition 'S33 backend switch back to deepseek succeeds' ($deepseekResult33.ExitCode -eq 0) $deepseekResult33.Output
    Assert-Condition 'S33 continuation switch back to active_follow succeeds' ($followResult33.ExitCode -eq 0) $followResult33.Output

    $reinstallResult33 = Invoke-InstallCapture -Root $root33 -Profile safe
    Assert-Condition 'S33 reinstall after backend and continuation changes succeeds' ($reinstallResult33.ExitCode -eq 0) $reinstallResult33.Output
    $stateAfterReinstall33 = Get-InstallState $root33
    $runtimeAfterReinstall33 = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath $agentsPath33 -Raw -Encoding UTF8)
    $configAfterReinstall33 = Read-Config $root33
    Assert-Condition 'S33 reinstall preserves deepseek and active_follow in schema 6' ([int]$stateAfterReinstall33.schemaVersion -eq 6 -and $stateAfterReinstall33.codexBackend.selected -ceq 'deepseek' -and $stateAfterReinstall33.codexContinuation.selected -ceq 'active_follow' -and $runtimeAfterReinstall33.Backend -ceq 'deepseek' -and $runtimeAfterReinstall33.Continuation -ceq 'active_follow') ''
    Assert-Condition 'S33 reinstall preserves deepseek config matrix' ($configAfterReinstall33 -match '(?m)^\s*multi_agent\s*=\s*false\s*$') $configAfterReinstall33

    $statusBack33 = Invoke-BackendStatus -Root $root33
    $statusContinuation33 = Invoke-ContinuationStatus -Root $root33
    Assert-Condition 'S33 backend status reports consistent backend and continuation' ($statusBack33.ExitCode -eq 0 -and $statusBack33.Output -match '(?i)backend:\s*deepseek' -and $statusBack33.Output -match '(?i)continuation:\s*active_follow') $statusBack33.Output
    Assert-Condition 'S33 continuation status reports the active continuation' ($statusContinuation33.ExitCode -eq 0 -and $statusContinuation33.Output -match '(?i)active subagent continuation:\s*active_follow') $statusContinuation33.Output
    Assert-Condition 'S33 fixture root is inside temp directory' ($root33.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) $root33
    Assert-Condition 'S33 consumer repo AGENTS.md remains pristine after all updates' ((Get-Content -LiteralPath $consumerAgentsPath -Raw -Encoding UTF8) -ceq $consumerAgentsContent) ''

    $scenario = 34
    Write-Host 'Scenario 34: Invoke-ProcessCapture normalizes PTY/ConPTY cursor-position wraps and ANSI codes while preserving raw output and semantic newlines' -ForegroundColor Cyan
    $escChar = [char]27
    $syntheticCommand = "[Console]::Out.Write(`"${escChar}[31minstalled mcp-foundation lifecy`r`n${escChar}[23;80Hcle.md (agents) is missing required DeepSeek daemon restart policy pattern${escChar}[0m`r`n[OK] Semantic second line`n[OK] Semantic third line`"); [Console]::Error.Write(`"`n[STDERR] Stderr message line`"); exit 42"
    $captureResult34 = Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', $syntheticCommand)

    Assert-Condition 'S34 preserves exit code' ($captureResult34.ExitCode -eq 42) ("ExitCode: " + $captureResult34.ExitCode)
    Assert-Condition 'S34 RawOutput contains raw CSI sequences' ($null -ne $captureResult34.PSObject.Properties['RawOutput'] -and $captureResult34.RawOutput.Contains("${escChar}[23;80H")) ($captureResult34.RawOutput)
    Assert-Condition 'S34 normalizes artificial hard-wrap and strips ANSI color from Output' ($captureResult34.Output -match 'installed mcp-foundation lifecycle\.md \(agents\) is missing required DeepSeek daemon restart policy pattern') ("Normalized Output:`n" + $captureResult34.Output + "`nRaw Output:`n" + $captureResult34.RawOutput)
    Assert-Condition 'S34 preserves distinct semantic newlines in Output' ($captureResult34.Output -match '\[OK\] Semantic second line' -and $captureResult34.Output -match '\[OK\] Semantic third line' -and ($captureResult34.Output -split '\r?\n').Count -ge 3) $captureResult34.Output
    Assert-Condition 'S34 preserves both stdout and stderr streams in output' ($captureResult34.Output -match '\[STDERR\] Stderr message line' -and $captureResult34.RawOutput -match '\[STDERR\] Stderr message line') ("Output:`n" + $captureResult34.Output)

    $scenario = 35
    Write-Host 'Scenario 35: delivery review requires risk-triggered operational/runtime proof gate, rejects static-only false greens and unauthorized live actions, and validates installed mirrors' -ForegroundColor Cyan
    $root35 = New-FixtureHome
    $fixtures.Add($root35)
    $canonicalDelivery = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\delivery-review.md') -Raw -Encoding UTF8
    $canonicalSkill = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\SKILL.md') -Raw -Encoding UTF8
    $canonicalAgents = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
    $canonicalGemini = Get-Content -LiteralPath (Join-Path $repo 'antigravity\GEMINI.md') -Raw -Encoding UTF8

    Assert-Condition 'S35 canonical policies satisfy delivery review operational proof semantics' (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini) ''

    # Tamper 1: Revisor permitido aprovar com base apenas em testes estáticos quando daemon/persistência é afetado
    $tamperStaticOnly = $canonicalDelivery + $nl + 'Quando um daemon ativo for afetado, o revisor pode aprovar com base apenas em testes estáticos se a prova operacional for difícil.'
    Assert-Condition 'S35 detects static-only bypass tamper' (-not (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $tamperStaticOnly -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 2: Assume pass when runtime proof is unavailable instead of BLOCKED
    $tamperAssumePass = $canonicalDelivery + $nl + 'Se a prova operacional estiver indisponível, o revisor pode presumir aprovado e emitir APPROVED.'
    Assert-Condition 'S35 detects assume-pass on unavailable proof tamper' (-not (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $tamperAssumePass -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 3: Broaden authority implicitly to obtain proof
    $tamperBroadenAuth = $canonicalDelivery + $nl + 'The agent may broaden authority implicitly to execute live destructive actions for runtime proof.'
    Assert-Condition 'S35 detects implicit authority broadening tamper' (-not (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $tamperBroadenAuth -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 4: Remove operational proof requirement from SKILL.md
    $tamperSkill = $canonicalSkill -replace '(?i)operational proof|runtime proof|prova operacional', 'unconditional static review'
    Assert-Condition 'S35 detects missing operational proof in SKILL.md' (-not (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $canonicalDelivery -SkillText $tamperSkill -AgentsText $canonicalAgents -GeminiText $canonicalGemini)) ''

    # Tamper 5: Remove operational proof invariant from AGENTS.md
    $tamperAgents = $canonicalAgents -replace '(?i)prova operacional|operational proof|runtime proof', 'revisão exclusivamente estática'
    Assert-Condition 'S35 detects missing operational proof in AGENTS.md' (-not (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $tamperAgents -GeminiText $canonicalGemini)) ''

    # Tamper 6: Remove operational proof invariant from GEMINI.md
    $tamperGemini = $canonicalGemini -replace '(?i)prova operacional|operational proof|runtime proof|delivery review', 'regras antigas'
    Assert-Condition 'S35 detects missing operational proof in GEMINI.md' (-not (Test-DeliveryReviewPolicySemantics -DeliveryReviewText $canonicalDelivery -SkillText $canonicalSkill -AgentsText $canonicalAgents -GeminiText $tamperGemini)) ''

    # Installed mirror verification and tamper detection
    $originalConfig35 = '[features]' + $nl + 'multi_agent = false' + $nl + $nl + '[mcp_servers.deepseek-subagent]' + $nl + 'command = "pwsh"' + $nl
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root35) 'config.toml') -Content $originalConfig35
    Invoke-SafeInstall -Root $root35

    $installedDeliveryAgents = Join-Path (Get-AgentsHome $root35) 'skills\workflows\references\delivery-review.md'
    $installedDeliveryAg1 = Join-Path (Get-AntigravityHome $root35) 'antigravity\skills\workflows\references\delivery-review.md'
    $installedDeliveryAg2 = Join-Path (Get-AntigravityHome $root35) 'config\skills\workflows\references\delivery-review.md'
    $installedAgentsPath35 = Join-Path (Get-CodexHome $root35) 'AGENTS.md'
    $installedGeminiPath35 = Join-Path (Get-AntigravityHome $root35) 'config\GEMINI.md'

    Assert-Condition 'S35 delivery-review.md installed in agents home' (Test-Path -LiteralPath $installedDeliveryAgents -PathType Leaf) $installedDeliveryAgents
    Assert-Condition 'S35 delivery-review.md installed in antigravity 1' (Test-Path -LiteralPath $installedDeliveryAg1 -PathType Leaf) $installedDeliveryAg1
    Assert-Condition 'S35 delivery-review.md installed in antigravity 2' (Test-Path -LiteralPath $installedDeliveryAg2 -PathType Leaf) $installedDeliveryAg2

    # Tamper installed delivery-review.md in agents
    $tamperInstalledDelivery = (Get-Content -LiteralPath $installedDeliveryAgents -Raw -Encoding UTF8) -replace '(?i)prova operacional|operational proof|runtime proof', 'static tests only'
    Write-FixtureFile -Path $installedDeliveryAgents -Content $tamperInstalledDelivery
    $valTamperInstalled = Invoke-Validate -Root $root35
    Assert-Condition 'S35 validate rejects tampered installed delivery-review mirror' ($valTamperInstalled.ExitCode -ne 0) $valTamperInstalled.Output
    $docTamperInstalled = Invoke-Doctor -Root $root35
    Assert-Condition 'S35 doctor rejects tampered installed delivery-review mirror hash' ($docTamperInstalled.ExitCode -ne 0) $docTamperInstalled.Output

    # Reinstall heals all mirrors
    Invoke-SafeInstall -Root $root35
    $valHealed35 = Invoke-Validate -Root $root35
    Assert-Condition 'S35 reinstall heals delivery-review mirrors and passes validation' ($valHealed35.ExitCode -eq 0 -and $valHealed35.Output -match 'Validation OK') $valHealed35.Output

    $scenario = 36
    Write-Host 'Scenario 36: ALINHAMENTO implicit state enforces read-only discussion, no mutation, imperative verb boundaries, conditional read-only delegation, mode persistence, pt-BR/audio defaults, and mirror healing' -ForegroundColor Cyan
    $root36 = New-FixtureHome
    $fixtures.Add($root36)
    $canonicalAgents36 = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
    $canonicalGemini36 = Get-Content -LiteralPath (Join-Path $repo 'antigravity\GEMINI.md') -Raw -Encoding UTF8
    $canonicalSkill36 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\SKILL.md') -Raw -Encoding UTF8
    $canonicalDelegation36 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\delegation.md') -Raw -Encoding UTF8
    $canonicalReadme36 = Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw -Encoding UTF8

    Assert-Condition 'S36 canonical policies satisfy ALINHAMENTO state semantics' (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36) $script:AlinhamentoPolicyFailure

    # Tamper 1: No-write boundary tamper (allowing file edits in ALINHAMENTO)
    $tamperNoWrite = $canonicalAgents36 + $nl + 'No ALINHAMENTO, o parent pode editar arquivos pequenos diretamente se o usuário pedir.'
    Assert-Condition 'S36 detects no-write boundary tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperNoWrite -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 2: Imperative verbs boundary tamper (inferring mode from imperative verbs)
    $tamperImperative = $canonicalAgents36 + $nl + 'Verbos imperativos inferem modo automaticamente.'
    Assert-Condition 'S36 detects imperative verbs inference tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperImperative -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 3: Conditional read-only delegation tamper (allowing write subagents or fallback)
    $tamperDelegation = $canonicalDelegation36 -replace '(?i)read-only|somente leitura', 'write-enabled execution'
    Assert-Condition 'S36 detects delegation boundary tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $tamperDelegation -ReadmeText $canonicalReadme36)) ''

    # Tamper 4: Cancellation process kill tamper
    $tamperCancellation = $canonicalAgents36 + $nl + 'Ao cancelar, o parent pode matar processos com taskkill.'
    Assert-Condition 'S36 detects cancellation process kill tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperCancellation -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 5: Active-mode persistence contract tamper (removing or breaking persistence across unprefixed follow-ups)
    $tamperPersistence = $canonicalAgents36 -replace '(?i)permanece ativo na mesma execu[c\u00e7][a\u00e3]o', 'expira imediatamente a cada turno'
    Assert-Condition 'S36 detects active-mode persistence contract tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperPersistence -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 6: pt-BR output language default tamper
    $tamperPtBr = $canonicalAgents36 -replace '(?i)portugu[e\u00ea]s do brasil|pt-BR|portugu[e\u00ea]s', 'English only'
    Assert-Condition 'S36 detects pt-BR output language default tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperPtBr -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 7: Audio transcript handling tamper (removing audio/noise/assumptions handling while keeping pt-BR intact)
    $tamperAudio = $canonicalAgents36 -replace '(?i)em (?:transcri[c\u00e7][o\u00f5]es? de )?[a\u00e1]udio,[^;]*;', ''
    Assert-Condition 'S36 detects audio transcript handling tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperAudio -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 8: Missing ALINHAMENTO in AGENTS.md
    $tamperMissingAgents = $canonicalAgents36 -replace '(?i)ALINHAMENTO', 'DISCUSS_STATE'
    Assert-Condition 'S36 detects missing ALINHAMENTO in AGENTS.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperMissingAgents -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 9: Missing ALINHAMENTO in GEMINI.md
    $tamperMissingGemini = $canonicalGemini36 -replace '(?i)ALINHAMENTO', 'DISCUSS_STATE'
    Assert-Condition 'S36 detects missing ALINHAMENTO in GEMINI.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $tamperMissingGemini -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 10: Missing ALINHAMENTO in SKILL.md
    $tamperMissingSkill = $canonicalSkill36 -replace '(?i)ALINHAMENTO', 'DISCUSS_STATE'
    Assert-Condition 'S36 detects missing ALINHAMENTO in SKILL.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $tamperMissingSkill -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 11: Missing ALINHAMENTO in delegation.md
    $tamperMissingDelegation = $canonicalDelegation36 -replace '(?i)ALINHAMENTO', 'DISCUSS_STATE'
    Assert-Condition 'S36 detects missing ALINHAMENTO in delegation.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $tamperMissingDelegation -ReadmeText $canonicalReadme36)) ''

    # Tamper 12: Missing ALINHAMENTO in README.md
    $tamperMissingReadme = $canonicalReadme36 -replace '(?i)ALINHAMENTO', 'DISCUSS_STATE'
    Assert-Condition 'S36 detects missing ALINHAMENTO in README.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $tamperMissingReadme)) ''

    # Tamper 13: Ceremony and formal plan tamper (introducing formal plans or todo lists in ALINHAMENTO)
    $tamperCeremony = $canonicalAgents36 + $nl + 'No ALINHAMENTO, o parent pode criar planos formais e todo lists para organizar ideias.'
    Assert-Condition 'S36 detects ceremony and formal plan tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperCeremony -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 14: Unnecessary repo inspection tamper (allowing repo reads without material dependency)
    $tamperInspection = $canonicalAgents36 + $nl + 'No ALINHAMENTO, o parent pode ler arquivos sem dependencia material para se antecipar.'
    Assert-Condition 'S36 detects unnecessary repo inspection tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperInspection -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 15: Stateful read tool and workspace metadata tamper (allowing metadata or local state creation on read tools)
    $tamperStatefulRead = $canonicalAgents36 + $nl + 'Em ALINHAMENTO, o parent pode criar metadados no workspace ao ler arquivos.'
    Assert-Condition 'S36 detects stateful read tool and metadata tamper' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperStatefulRead -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 16: Imperative verbs boundary tamper in README.md
    $tamperReadmeImperative = $canonicalReadme36 -replace '(?i)verbos imperativos nunca inferem modo', 'verbos imperativos podem inferir modo'
    Assert-Condition 'S36 detects imperative verbs tamper in README.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $tamperReadmeImperative)) ''

    # Tamper 17: ALINHAMENTO subagent ledger lifecycle tamper in delegation.md
    $tamperLedgerDelegation = $canonicalDelegation36 -replace '(?i)com consumo\s+e\s+fechamento no ledger', 'sem consumo ou fechamento no ledger'
    Assert-Condition 'S36 ledger lifecycle tamper changes the current delegation wording' ($tamperLedgerDelegation -cne $canonicalDelegation36) ''
    Assert-Condition 'S36 detects ALINHAMENTO subagent ledger lifecycle tamper in delegation.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $canonicalAgents36 -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $tamperLedgerDelegation -ReadmeText $canonicalReadme36)) ''

    # Tamper 18: ALINHAMENTO subagent ledger lifecycle tamper in AGENTS.md
    $tamperLedgerAgents = $canonicalAgents36 -replace '(?i)com consumo e encerramento (?:normais )?no ledger', 'sem consumo ou encerramento no ledger'
    Assert-Condition 'S36 detects ALINHAMENTO subagent ledger lifecycle tamper in AGENTS.md' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperLedgerAgents -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Tamper 19: ALINHAMENTO subagent ledger bypass anti-pattern tamper
    $tamperLedgerBypass = $canonicalAgents36 + $nl + 'No ALINHAMENTO, o parent pode ignorar o ledger e deixar subagentes abertos.'
    Assert-Condition 'S36 detects ALINHAMENTO subagent ledger bypass anti-pattern' (-not (Test-AlinhamentoPolicySemantics -AgentsText $tamperLedgerBypass -GeminiText $canonicalGemini36 -SkillText $canonicalSkill36 -DelegationText $canonicalDelegation36 -ReadmeText $canonicalReadme36)) ''

    # Installed mirror verification and tamper healing in fixture
    $originalConfig36 = '[features]' + $nl + 'multi_agent = false' + $nl + $nl + '[mcp_servers.deepseek-subagent]' + $nl + 'command = "pwsh"' + $nl
    Write-FixtureFile -Path (Join-Path (Get-CodexHome $root36) 'config.toml') -Content $originalConfig36
    Invoke-SafeInstall -Root $root36

    $installedAgents36 = Join-Path (Get-CodexHome $root36) 'AGENTS.md'
    $installedGemini36 = Join-Path (Get-AntigravityHome $root36) 'config\GEMINI.md'
    $installedSkill36 = Join-Path (Get-AgentsHome $root36) 'skills\workflows\SKILL.md'
    $installedDelegation36 = Join-Path (Get-AgentsHome $root36) 'skills\workflows\references\delegation.md'

    Assert-Condition 'S36 AGENTS.md installed in codex home' (Test-Path -LiteralPath $installedAgents36 -PathType Leaf) $installedAgents36
    Assert-Condition 'S36 GEMINI.md installed in antigravity config' (Test-Path -LiteralPath $installedGemini36 -PathType Leaf) $installedGemini36
    Assert-Condition 'S36 SKILL.md installed in agents home' (Test-Path -LiteralPath $installedSkill36 -PathType Leaf) $installedSkill36
    Assert-Condition 'S36 delegation.md installed in agents home' (Test-Path -LiteralPath $installedDelegation36 -PathType Leaf) $installedDelegation36

    # Tamper installed delegation.md in agents
    $tamperInstalledDelegation = (Get-Content -LiteralPath $installedDelegation36 -Raw -Encoding UTF8) -replace '(?i)ALINHAMENTO', 'DISCUSS_STATE'
    Write-FixtureFile -Path $installedDelegation36 -Content $tamperInstalledDelegation
    $valTamperInstalled36 = Invoke-Validate -Root $root36
    Assert-Condition 'S36 validate rejects tampered installed delegation mirror' ($valTamperInstalled36.ExitCode -ne 0) $valTamperInstalled36.Output
    $docTamperInstalled36 = Invoke-Doctor -Root $root36
    Assert-Condition 'S36 doctor rejects tampered installed delegation mirror hash' ($docTamperInstalled36.ExitCode -ne 0) $docTamperInstalled36.Output

    # Reinstall heals all mirrors
    Invoke-SafeInstall -Root $root36
    $valHealed36 = Invoke-Validate -Root $root36
    Assert-Condition 'S36 reinstall heals delegation mirror and passes validation' ($valHealed36.ExitCode -eq 0 -and $valHealed36.Output -match 'Validation OK') $valHealed36.Output
    }

    $currentScenario = 38
    if ($targetScenario -eq 0 -or $targetScenario -eq 38) {
        Write-Host 'Scenario 38: SubAgents MCP canonical key ([mcp_servers.subagents]), tool names (subagents_*), and legacy alias migration' -ForegroundColor Cyan
        $root38 = New-FixtureHome
        $fixtures.Add($root38)

        # 1. Config with canonical key [mcp_servers.subagents]
        $canonicalMcpConfig = '[features]' + $nl +
            'multi_agent = false' + $nl +
            'fast_mode = true' + $nl + $nl +
            '[agents]' + $nl +
            'default_subagent_model = "test-model"' + $nl +
            'default_subagent_reasoning_effort = "high"' + $nl + $nl +
            '[mcp_servers.subagents]' + $nl +
            'command = "subagents-bridge"' + $nl +
            'args = ["--port", "4000"]' + $nl +
            'enabled = true' + $nl

        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root38) 'config.toml') -Content $canonicalMcpConfig
        Invoke-SafeInstall -Root $root38

        # Verify state captures canonical key
        $state38 = Get-InstallState $root38
        $prior38 = @($state38.codexBackend.prior)
        $mcpPrior = $prior38 | Where-Object { $_.path -eq 'mcp_servers.subagents.enabled' }
        Assert-Condition 'S38 state captures canonical mcp_servers.subagents.enabled path' ($null -ne $mcpPrior -and $mcpPrior.present -eq $true -and $mcpPrior.value -ceq 'true') ''

        # Native switch disables canonical subagents MCP table
        $nativeSwitch38 = Invoke-BackendSwitch -Root $root38 -Backend native
        Assert-Condition 'S38 native switch succeeds with canonical key' ($nativeSwitch38.ExitCode -eq 0) $nativeSwitch38.Output
        $configNative38 = Read-Config $root38
        Assert-Condition 'S38 native switch sets enabled = false under [mcp_servers.subagents]' ($configNative38 -match '(?ms)\[mcp_servers\.subagents\].*?enabled\s*=\s*false') $configNative38
        Assert-Condition 'S38 native switch does not create legacy alias table' ($configNative38 -notmatch '\[mcp_servers\.deepseek-subagent\]') $configNative38

        # Deepseek switch restores canonical subagents MCP table
        $deepseekSwitch38 = Invoke-BackendSwitch -Root $root38 -Backend deepseek
        Assert-Condition 'S38 deepseek switch succeeds with canonical key' ($deepseekSwitch38.ExitCode -eq 0) $deepseekSwitch38.Output
        $configDeepseek38 = Read-Config $root38
        Assert-Condition 'S38 deepseek switch restores enabled = true under [mcp_servers.subagents]' ($configDeepseek38 -match '(?ms)\[mcp_servers\.subagents\].*?enabled\s*=\s*true') $configDeepseek38

        # Doctor check detects canonical SubAgents MCP
        $docResult38 = Invoke-Doctor -Root $root38
        Assert-Condition 'S38 doctor reports SubAgents MCP configured' ($docResult38.ExitCode -eq 0 -and $docResult38.Output -match '(?i)SubAgents MCP:\s*Configured') $docResult38.Output

        # 2. Backward compatibility: existing config with legacy alias [mcp_servers.deepseek-subagent]
        $root38Legacy = New-FixtureHome
        $fixtures.Add($root38Legacy)
        $legacyMcpConfig = '[features]' + $nl +
            'multi_agent = false' + $nl + $nl +
            '[mcp_servers.deepseek-subagent]' + $nl +
            'command = "legacy-bridge"' + $nl +
            'enabled = true' + $nl
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root38Legacy) 'config.toml') -Content $legacyMcpConfig
        Invoke-SafeInstall -Root $root38Legacy

        # Native switch modifies existing legacy table in-place without breaking it
        $nativeLegacy = Invoke-BackendSwitch -Root $root38Legacy -Backend native
        Assert-Condition 'S38 native switch succeeds with legacy alias config' ($nativeLegacy.ExitCode -eq 0) $nativeLegacy.Output
        $configNativeLegacy = Read-Config $root38Legacy
        Assert-Condition 'S38 native switch sets enabled = false under legacy [mcp_servers.deepseek-subagent]' ($configNativeLegacy -match '(?ms)\[mcp_servers\.deepseek-subagent\].*?enabled\s*=\s*false') $configNativeLegacy
        Assert-Condition 'S38 native switch does not create duplicate canonical table' ($configNativeLegacy -notmatch '\[mcp_servers\.subagents\]') $configNativeLegacy

        # Deepseek switch restores legacy table
        $deepseekLegacy = Invoke-BackendSwitch -Root $root38Legacy -Backend deepseek
        Assert-Condition 'S38 deepseek switch restores legacy table' ($deepseekLegacy.ExitCode -eq 0 -and (Read-Config $root38Legacy) -match '(?ms)\[mcp_servers\.deepseek-subagent\].*?enabled\s*=\s*true') ''

        # Doctor check detects SubAgents MCP via legacy alias
        $docLegacy = Invoke-Doctor -Root $root38Legacy
        Assert-Condition 'S38 doctor reports SubAgents MCP configured via legacy alias' ($docLegacy.ExitCode -eq 0 -and $docLegacy.Output -match '(?i)SubAgents MCP:\s*Configured') $docLegacy.Output
    }

    $currentScenario = 39
    if ($targetScenario -eq 0 -or $targetScenario -eq 39) {
        Write-Host 'Scenario 39: Serena & CodeGraph operational contract, COMMIT candidate classifier, and mirror tree' -ForegroundColor Cyan
        Import-Module (Join-Path $repo 'scripts\backend-routing.psm1') -Force

        # 1. Test candidate classifier
        $clean1 = Get-CodexCommitCandidateClassification -Path 'src/main.py'
        Assert-Condition 'S39 clean python path is clean' ($clean1.Category -ceq 'clean' -and -not $clean1.IsBlocked) ''

        $dbFile = Get-CodexCommitCandidateClassification -Path 'data/app.db'
        Assert-Condition 'S39 *.db is not globally blocked' ($dbFile.Category -ceq 'clean' -and -not $dbFile.IsBlocked) ''

        $sqliteFile = Get-CodexCommitCandidateClassification -Path 'bridge.sqlite'
        Assert-Condition 'S39 bridge.sqlite is not blocked' ($sqliteFile.Category -ceq 'clean' -and -not $sqliteFile.IsBlocked) ''

        $cacheFile = Get-CodexCommitCandidateClassification -Path '.serena/cache/ast.bin'
        Assert-Condition 'S39 .serena/cache is classified as cache' ($cacheFile.Category -ceq 'cache' -and $cacheFile.IsBlocked) ''

        $pycacheFile = Get-CodexCommitCandidateClassification -Path '__pycache__/module.pyc'
        Assert-Condition 'S39 __pycache__ is classified as cache' ($pycacheFile.Category -ceq 'cache' -and $pycacheFile.IsBlocked) ''

        $localFile = Get-CodexCommitCandidateClassification -Path '.serena/project.local.yml'
        Assert-Condition 'S39 project.local.yml is classified as local' ($localFile.Category -ceq 'local' -and $localFile.IsBlocked) ''

        $localGenFile = Get-CodexCommitCandidateClassification -Path 'settings.local.json'
        Assert-Condition 'S39 *.local.* is classified as local' ($localGenFile.Category -ceq 'local' -and $localGenFile.IsBlocked) ''

        $genBak = Get-CodexCommitCandidateClassification -Path 'backup.bak'
        Assert-Condition 'S39 *.bak is classified as generated' ($genBak.Category -ceq 'generated' -and $genBak.IsBlocked) ''

        $genTmp = Get-CodexCommitCandidateClassification -Path 'scratch.tmp'
        Assert-Condition 'S39 *.tmp is classified as generated' ($genTmp.Category -ceq 'generated' -and $genTmp.IsBlocked) ''

        $genCg = Get-CodexCommitCandidateClassification -Path '.codegraph/index.db'
        Assert-Condition 'S39 .codegraph is classified as generated' ($genCg.Category -ceq 'generated' -and $genCg.IsBlocked) ''

        $genMem = Get-CodexCommitCandidateClassification -Path '.serena/memories/idea.md'
        Assert-Condition 'S39 .serena/memories is classified as generated' ($genMem.Category -ceq 'generated' -and $genMem.IsBlocked) ''

        $thumbs = Get-CodexCommitCandidateClassification -Path 'Thumbs.db'
        Assert-Condition 'S39 Thumbs.db is classified as generated' ($thumbs.Category -ceq 'generated' -and $thumbs.IsBlocked) ''

        $secretEnv = Get-CodexCommitCandidateClassification -Path '.env'
        Assert-Condition 'S39 .env is classified as secret' ($secretEnv.Category -ceq 'secret' -and $secretEnv.IsBlocked) ''

        $secretPem = Get-CodexCommitCandidateClassification -Path 'certs/server.key'
        Assert-Condition 'S39 *.key is classified as secret' ($secretPem.Category -ceq 'secret' -and $secretPem.IsBlocked) ''

        $secretEnvProduction = Get-CodexCommitCandidateClassification -Path '.env.production'
        Assert-Condition 'S39 .env.<suffix> is classified as secret' ($secretEnvProduction.Category -ceq 'secret' -and $secretEnvProduction.IsBlocked) ''

        $exampleEnv = Get-CodexCommitCandidateClassification -Path '.env.example'
        Assert-Condition 'S39 .env.example remains clean' ($exampleEnv.Category -ceq 'clean' -and -not $exampleEnv.IsBlocked) ''

        $localCode = Get-CodexCommitCandidateClassification -Path 'src/storage.local.js'
        Assert-Condition 'S39 arbitrary *.local.* source code remains clean' ($localCode.Category -ceq 'clean' -and -not $localCode.IsBlocked) ''

        $hasCandidateEnumerator = $null -ne (Get-Command -Name Get-CodexCommitCandidates -ErrorAction SilentlyContinue)
        Assert-Condition 'S39 exports a real staged/unstaged/untracked candidate enumerator' $hasCandidateEnumerator ''

        $hasCodeGraphDecision = $null -ne (Get-Command -Name Get-CodexCodeGraphMaintenanceDecision -ErrorAction SilentlyContinue)
        Assert-Condition 'S39 exports deterministic CodeGraph maintenance decisions' $hasCodeGraphDecision ''

        if ($hasCodeGraphDecision) {
            $decisionFresh = Get-CodexCodeGraphMaintenanceDecision -Status ([pscustomobject]@{ state = 'fresh' }) -WriteMode
            $decisionStale = Get-CodexCodeGraphMaintenanceDecision -Status ([pscustomobject]@{ state = 'stale' }) -WriteMode
            $decisionPending = Get-CodexCodeGraphMaintenanceDecision -Status ([pscustomobject]@{ state = 'pending' }) -WriteMode
            $decisionFailure = Get-CodexCodeGraphMaintenanceDecision -Status ([pscustomobject]@{ state = 'failure' }) -WriteMode
            $decisionUnknown = Get-CodexCodeGraphMaintenanceDecision -Status ([pscustomobject]@{}) -WriteMode
            $decisionReadOnly = Get-CodexCodeGraphMaintenanceDecision -Status ([pscustomobject]@{ state = 'stale' })
            Assert-Condition 'S39 CodeGraph fresh status skips sync' ($decisionFresh.Action -ceq 'none') ($decisionFresh | Out-String)
            Assert-Condition 'S39 CodeGraph stale status requests sync' ($decisionStale.Action -ceq 'sync') ($decisionStale | Out-String)
            Assert-Condition 'S39 CodeGraph pending status requests sync' ($decisionPending.Action -ceq 'sync') ($decisionPending | Out-String)
            Assert-Condition 'S39 CodeGraph failure falls back safely' ($decisionFailure.Action -ceq 'fallback') ($decisionFailure | Out-String)
            Assert-Condition 'S39 CodeGraph unknown falls back safely' ($decisionUnknown.Action -ceq 'fallback') ($decisionUnknown | Out-String)
            Assert-Condition 'S39 CodeGraph read-only stale status only inspects' ($decisionReadOnly.Action -ceq 'inspect') ($decisionReadOnly | Out-String)
        }

        # 2. Test Commit Gate rejection of blocked candidate in approved owned paths
        $root39 = New-FixtureHome
        $fixtures.Add($root39)
        $gitRepoDir39 = Join-Path $root39 'git-repo'
        New-Item -ItemType Directory -Path $gitRepoDir39 -Force | Out-Null
        $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('init', '-b', 'main')
        $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('config', 'user.name', 'Test')
        $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('config', 'user.email', 'test@example.com')
        $baseFile = Join-Path $gitRepoDir39 'base.txt'
        Write-FixtureFile -Path $baseFile -Content 'base'
        $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('add', 'base.txt')
        $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('commit', '-m', 'base')

        $tmpFile = Join-Path $gitRepoDir39 'notes.tmp'
        Write-FixtureFile -Path $tmpFile -Content 'temp data'
        $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('add', 'notes.tmp')
        $targetTmp = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir39 -OwnedPaths @('notes.tmp')
        $gateTmpResult = Invoke-CommitGateCapture -RepoPath $gitRepoDir39 -ApprovedTargetId $targetTmp.TargetId -ApprovedOwnedPaths @('notes.tmp')
        Assert-Condition 'S39 commit gate rejects blocked candidate in approved owned paths' ($gateTmpResult.Pass -eq $false -and $gateTmpResult.Detail -match '(?i)blocked|generated') $gateTmpResult.Detail

        if ($hasCandidateEnumerator) {
            $approvedFile39 = Join-Path $gitRepoDir39 'approved.txt'
            $stagedFile39 = Join-Path $gitRepoDir39 'staged.txt'
            $untrackedFile39 = Join-Path $gitRepoDir39 'untracked.txt'
            $secretFile39 = Join-Path $gitRepoDir39 '.env.production'
            Write-FixtureFile -Path $approvedFile39 -Content 'approved'
            Write-FixtureFile -Path $stagedFile39 -Content 'staged'
            Write-FixtureFile -Path $untrackedFile39 -Content 'untracked'
            Write-FixtureFile -Path $secretFile39 -Content 'secret'
            $null = Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('add', 'approved.txt', 'staged.txt')
            $porcelainBeforeCandidates39 = (Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('status', '--porcelain=v1', '-uall')).Output
            $candidates39 = @(Get-CodexCommitCandidates -RepoPath $gitRepoDir39)
            $porcelainAfterCandidates39 = (Invoke-GitCapture -RepoDir $gitRepoDir39 -ArgumentList @('status', '--porcelain=v1', '-uall')).Output
            Assert-Condition 'S39 candidate enumeration preserves the Git index and status' ($porcelainBeforeCandidates39 -ceq $porcelainAfterCandidates39) ($porcelainBeforeCandidates39 + "`n" + $porcelainAfterCandidates39)
            Assert-Condition 'S39 candidate enumeration includes staged and untracked paths' (($candidates39.Path -contains 'staged.txt') -and ($candidates39.Path -contains 'untracked.txt')) ($candidates39 | Out-String)
            Assert-Condition 'S39 candidate enumeration blocks an untracked environment secret' (@($candidates39 | Where-Object { $_.Path -eq '.env.production' -and $_.IsBlocked -and $_.Category -ceq 'secret' }).Count -eq 1) ($candidates39 | Out-String)
            $approvedTarget39 = Invoke-DeliveryTargetIdentityCapture -RepoPath $gitRepoDir39 -OwnedPaths @('approved.txt')
            $gateSecretResult39 = Invoke-CommitGateCapture -RepoPath $gitRepoDir39 -ApprovedTargetId $approvedTarget39.TargetId -ApprovedOwnedPaths @('approved.txt')
            Assert-Condition 'S39 commit gate rejects blocked untracked candidates before touching the index' ($gateSecretResult39.Pass -eq $false -and $gateSecretResult39.Detail -match '(?i)\.env\.production|secret|blocked') $gateSecretResult39.Detail
        }

        # 3. Test Safe Install and Mirror Tree for serena-codegraph.md
        $installResult39 = Invoke-InstallCapture -Root $root39 -Profile safe
        Assert-Condition 'S39 safe install succeeds' ($installResult39.ExitCode -eq 0) $installResult39.Output

        $installedRefAgents = Join-Path (Get-AgentsHome $root39) 'skills\mcp-foundation\references\serena-codegraph.md'
        $installedRefAg1 = Join-Path (Get-AntigravityHome $root39) 'antigravity\skills\mcp-foundation\references\serena-codegraph.md'
        $installedRefAg2 = Join-Path (Get-AntigravityHome $root39) 'config\skills\mcp-foundation\references\serena-codegraph.md'
        Assert-Condition 'S39 serena-codegraph.md mirrored to agents home' (Test-Path -LiteralPath $installedRefAgents -PathType Leaf) ''
        Assert-Condition 'S39 serena-codegraph.md mirrored to antigravity home 1' (Test-Path -LiteralPath $installedRefAg1 -PathType Leaf) ''
        Assert-Condition 'S39 serena-codegraph.md mirrored to antigravity home 2' (Test-Path -LiteralPath $installedRefAg2 -PathType Leaf) ''

        # 4. Mirror tree validation in fixture home
        $valResult39 = Invoke-Validate -Root $root39
        Assert-Condition 'S39 validate succeeds on installed fixture' ($valResult39.ExitCode -eq 0) $valResult39.Output
    }

    $currentScenario = 40
    if ($targetScenario -eq 0 -or $targetScenario -eq 40) {
        Write-Host 'Scenario 40: Correction Adequacy Gate (Gate de Adequação da Correção), sufficient/sustainable fix, event triggers, 6 decisions, bridge transport neutrality, and required_fix backcompat' -ForegroundColor Cyan

        # 1. Semantic tests on canonical files
        $canonicalDelivery40 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\delivery-review.md') -Raw -Encoding UTF8
        $canonicalQuality40 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\quality-ratchet.md') -Raw -Encoding UTF8
        $canonicalValidation40 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\validation.md') -Raw -Encoding UTF8
        $canonicalCommit40 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\commit.md') -Raw -Encoding UTF8
        $canonicalDelegation40 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\delegation.md') -Raw -Encoding UTF8
        $canonicalSkill40 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\SKILL.md') -Raw -Encoding UTF8
        $canonicalAgents40 = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
        $canonicalGemini40 = Get-Content -LiteralPath (Join-Path $repo 'antigravity\GEMINI.md') -Raw -Encoding UTF8
        $canonicalReadme40 = Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw -Encoding UTF8

        Assert-Condition 'S40 canonical policies satisfy correction adequacy gate semantics' (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40) $script:CorrectionAdequacyFailure

        # 2. Tampers
        $minFixStr = 'corre' + [char]0x00e7 + [char]0x00e3 + 'o m' + [char]0x00ed + 'nima'
        $tamperMinFix = $canonicalDelivery40 -replace '(?i)corre[c\u00e7][a\u00e3]o suficiente e sustent[a\u00e1]vel(?:/delimitada)?', $minFixStr
        Assert-Condition 'S40 detects minimum-fix tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMinFix -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperAutoMode = $canonicalDelivery40 + $nl + 'O gate pode trocar automaticamente de modo quando julgar necessário.'
        Assert-Condition 'S40 detects automatic mode switch tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperAutoMode -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperBridgeDecides = $canonicalSkill40 + $nl + 'O bridge decide regras de workflow e aprovação.'
        Assert-Condition 'S40 detects bridge decider tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $tamperBridgeDecides -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperWriteNoWrite = $canonicalAgents40 + $nl + 'A correção concede escrita no ALINHAMENTO para acelerar fixes.'
        Assert-Condition 'S40 detects write in ALINHAMENTO tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $tamperWriteNoWrite -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperPerTurn = $canonicalDelivery40 + $nl + 'O gate de adequação é acionado a cada turno conversacional.'
        Assert-Condition 'S40 detects per-turn trigger tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperPerTurn -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $oldReqFix = '"required_fix": "corre' + [char]0x00e7 + [char]0x00e3 + 'o m' + [char]0x00ed + 'nima exigida"'
        $tamperOldRequiredFix = $canonicalDelivery40 -replace '(?i)"required_fix":\s*"[^"]+"', $oldReqFix
        Assert-Condition 'S40 detects obsolete required_fix minimum semantics tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperOldRequiredFix -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        # Stale max2 policy rejected across all canonical surfaces and synonyms
        $tamperStaleMax2 = $canonicalDelivery40 + $nl + "$([char]0x00c9) permitido um m$([char]0x00e1)ximo de 2 rodadas de reparo."
        Assert-Condition 'S40 detects stale max2 policy tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperStaleMax2 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperSkillStaleMax2 = $canonicalSkill40 + $nl + 'blocked verdicts apply consolidated repair rounds at most 2 rounds'
        Assert-Condition 'S40 detects at most 2 rounds tamper in SKILL.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $tamperSkillStaleMax2 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperSkillMaxTwo = $canonicalSkill40 + $nl + 'repair rounds have a maximum two limit'
        Assert-Condition 'S40 detects maximum two tamper in SKILL.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $tamperSkillMaxTwo -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperSkillPtMax2 = $canonicalSkill40 + $nl + "no m$([char]0x00e1)ximo duas rodadas de reparo"
        Assert-Condition 'S40 detects Portuguese max2 tamper in SKILL.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $tamperSkillPtMax2 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperSkillMax2Short = $canonicalSkill40 + $nl + "com m$([char]0x00e1)x 2 rodadas"
        Assert-Condition 'S40 detects Portuguese máx 2 tamper in SKILL.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $tamperSkillMax2Short -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperValidStaleMax2 = $canonicalValidation40 + $nl + 'at most 2 rounds allowed'
        Assert-Condition 'S40 detects stale max2 tamper in validation.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $tamperValidStaleMax2 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperCommitStaleMax2 = $canonicalCommit40 + $nl + 'at most 2 rounds'
        Assert-Condition 'S40 detects stale max2 tamper in commit.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $tamperCommitStaleMax2 -DelegationText $canonicalDelegation40)) ''

        $tamperQualityStaleMax2 = $canonicalQuality40 + $nl + 'maximum two rounds of repair'
        Assert-Condition 'S40 detects stale max2 tamper in quality-ratchet.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $tamperQualityStaleMax2 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperDelegaStaleMax2 = $canonicalDelegation40 + $nl + 'up to 2 rounds'
        Assert-Condition 'S40 detects stale max2 tamper in delegation.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $tamperDelegaStaleMax2)) ''

        $tamperAgentsStaleMax2 = $canonicalAgents40 + $nl + 'at most 2 rounds'
        Assert-Condition 'S40 detects stale max2 tamper in AGENTS.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $tamperAgentsStaleMax2 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperGeminiStaleMax2 = $canonicalGemini40 + $nl + 'at most 2 rounds'
        Assert-Condition 'S40 detects stale max2 tamper in GEMINI.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $tamperGeminiStaleMax2 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperReadmeStaleMax2 = $canonicalReadme40 + $nl + 'at most 2 rounds'
        Assert-Condition 'S40 detects stale max2 tamper in README.md' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $canonicalDelivery40 -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $tamperReadmeStaleMax2 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        # Missing anti-loop invariants rejected
        $tamperMissingHypothesis = $canonicalDelivery40 -replace '(?i)hip[o\u00f3]tes', 'suposic' -replace '(?i)hypothesis', 'guess'
        Assert-Condition 'S40 detects missing anti-loop hypothesis invariant tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMissingHypothesis -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperMissingExpectedObs = $canonicalDelivery40 -replace '(?i)observa[c\u00e7][a\u00e3]o discriminante', 'resultado' -replace '(?i)discriminating observation', 'result'
        Assert-Condition 'S40 detects missing anti-loop expected observation invariant tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMissingExpectedObs -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperMissingObservedDelta = $canonicalDelivery40 -replace '(?i)delta observado', 'mudanca' -replace '(?i)observed delta', 'change'
        Assert-Condition 'S40 detects missing anti-loop observed delta invariant tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMissingObservedDelta -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperMissingNextDecision = $canonicalDelivery40 -replace '(?i)pr[o\u00f3]xima decis[a\u00e3]o', 'passo' -replace '(?i)next decision', 'step'
        Assert-Condition 'S40 detects missing anti-loop next decision invariant tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMissingNextDecision -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperMissingDiffDirection = $canonicalDelivery40 -replace '(?i)dire[c\u00e7][a\u00e3]o diagn[o\u00f3]stica diferente', 'mesma' -replace '(?i)different diagnostic direction', 'same'
        Assert-Condition 'S40 detects missing different diagnostic direction on no-delta tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMissingDiffDirection -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperMissingAuthBoundary = $canonicalDelivery40 -replace '(?i)bloqueio genu[i\u00ed]no de', 'bloqueio arbitrario de'
        Assert-Condition 'S40 detects missing genuine authority safety boundary tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperMissingAuthBoundary -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''

        $tamperDisguisedCounter = $canonicalDelivery40 + $nl + "O reparo possui um limite num$([char]0x00e9)rico fixo de 3 tentativas."
        Assert-Condition 'S40 detects disguised numerical stopping rule tamper' (-not (Test-CorrectionAdequacyGateSemantics -DeliveryReviewText $tamperDisguisedCounter -QualityRatchetText $canonicalQuality40 -ValidationText $canonicalValidation40 -SkillText $canonicalSkill40 -AgentsText $canonicalAgents40 -GeminiText $canonicalGemini40 -ReadmeText $canonicalReadme40 -CommitText $canonicalCommit40 -DelegationText $canonicalDelegation40)) ''
    }

    $currentScenario = 41
    if ($targetScenario -eq 0 -or $targetScenario -eq 41) {
        Write-Host 'Scenario 41: continuation switch, schema-6 persistence, fail-closed behavior, multi-host coverage, and no consumer injection' -ForegroundColor Cyan

        # 1. Semantic tests on canonical policies (active_follow in-run wait, park_and_wake external arm and SUSPENDED run termination, predicates, suspension message, no polling, no auto-archive, trusted metadata, separate goal ownership)
        $canonicalDelegation41 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\delegation.md') -Raw -Encoding UTF8
        $canonicalDelivery41 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\references\delivery-review.md') -Raw -Encoding UTF8
        $canonicalSkill41 = Get-Content -LiteralPath (Join-Path $repo 'skills\workflows\SKILL.md') -Raw -Encoding UTF8
        $canonicalAgents41 = Get-Content -LiteralPath (Join-Path $repo 'codex\AGENTS.md') -Raw -Encoding UTF8
        $canonicalGemini41 = Get-Content -LiteralPath (Join-Path $repo 'antigravity\GEMINI.md') -Raw -Encoding UTF8
        $canonicalReadme41 = Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw -Encoding UTF8

        Assert-Condition 'S41 canonical policies satisfy subagent autonomy hybrid lifecycle semantics' (Test-SubagentAutonomySemantics -DelegationText $canonicalDelegation41 -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41) ''

        # 2. Tampers against autonomy invariants (7 required: in-turn wait, missing SUSPENDED, premature wake, invalid quorum/required, duplicate wake, worker text, auto-resume goal)
        $tamperInTurnWait = $canonicalDelegation41 + $nl + 'Sob park_and_wake, em task carregada o subagents_park aguarda no mesmo turno com wait in-turn até o evento retornar.'
        Assert-Condition 'S41 detects in-turn wait tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperInTurnWait -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperMissingSuspended = $canonicalDelegation41 + $nl + 'O parent pode encerrar a run sem emitir mensagem visível de suspensão ao usuário.'
        Assert-Condition 'S41 detects missing suspension message tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperMissingSuspended -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperPrematureWake = $canonicalDelegation41 + $nl + 'O bridge pode acionar retomada parcial prematura antes que o predicado da barreira seja satisfeito.'
        Assert-Condition 'S41 detects premature partial wake tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperPrematureWake -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperInvalidPredicate = $canonicalDelegation41 + $nl + 'O bridge aceita quorum inválido com k maior que o total de jobs e required com conjunto vazio.'
        Assert-Condition 'S41 detects invalid quorum/required sets tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperInvalidPredicate -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperDuplicateWake = $canonicalDelegation41 + $nl + 'O bridge pode emitir múltiplos wakes e duplicate wake para a mesma geração de barreira.'
        Assert-Condition 'S41 detects duplicate wake tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperDuplicateWake -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperWorkerPayload = $canonicalAgents41 + $nl + 'O bridge injeta o texto de resposta do worker na mensagem de retomada.'
        Assert-Condition 'S41 detects worker text in bridge payload tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $canonicalDelegation41 -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $tamperWorkerPayload -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperResumeGoal = $canonicalGemini41 + $nl + 'A retomada retoma automaticamente o goal pausado pelo usuário.'
        Assert-Condition 'S41 detects auto-resume paused goal tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $canonicalDelegation41 -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $tamperResumeGoal -ReadmeText $canonicalReadme41)) ''

        $tamperModelPoll = $canonicalDelegation41 + $nl + 'O parent pode realizar polling periódico com subagents_follow enquanto aguarda o término da tarefa.'
        Assert-Condition 'S41 detects model-polling tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperModelPoll -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperAutoArchive = $canonicalSkill41 + $nl + 'Active writer autoriza arquivar ou descarregar a task para liberar o lock.'
        Assert-Condition 'S41 detects active-writer auto-archive tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $canonicalDelegation41 -DeliveryReviewText $canonicalDelivery41 -SkillText $tamperAutoArchive -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperUnarmedTurnEnd = $canonicalDelegation41 + $nl + 'O parent pode encerrar o turno mesmo se o recibo retornar deliveryMode=none.'
        Assert-Condition 'S41 detects turn ending without armed receipt tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperUnarmedTurnEnd -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $tamperSilentFallback = $canonicalDelegation41 + $nl + 'Se a barreira falhar, ocorre fallback silencioso para active_follow.'
        Assert-Condition 'S41 detects silent fallback to active_follow tamper' (-not (Test-SubagentAutonomySemantics -DelegationText $tamperSilentFallback -DeliveryReviewText $canonicalDelivery41 -SkillText $canonicalSkill41 -AgentsText $canonicalAgents41 -GeminiText $canonicalGemini41 -ReadmeText $canonicalReadme41)) ''

        $root41 = New-FixtureHome
        $fixtures.Add($root41)

        # 1. Installation establishes active_follow by default in state and AGENTS.md
        $originalConfig41 = '[features]' + $nl + 'multi_agent = false' + $nl + $nl + '[mcp_servers.subagents]' + $nl + 'command = "pwsh"' + $nl
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root41) 'config.toml') -Content $originalConfig41
        Invoke-SafeInstall -Root $root41

        $state41 = Get-InstallState $root41
        Assert-Condition 'S41 safe install records schema-6 backend and default continuation without retired selectors' ($null -ne $state41 -and [int]$state41.schemaVersion -eq 6 -and $state41.PSObject.Properties.Name -contains 'codexBackend' -and $state41.PSObject.Properties.Name -contains 'codexContinuation' -and [string]$state41.codexContinuation.selected -ceq 'active_follow' -and -not ($state41.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($state41.PSObject.Properties.Name -contains 'codexStrategy')) ''

        $agents41 = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8
        $rt41 = Get-AgentsRuntimeBlock -Text $agents41
        Assert-Condition 'S41 safe install establishes subagent_continuation = active_follow in AGENTS.md' ($rt41.Continuation -ceq 'active_follow') $rt41.Continuation

        # 2. Continuation switch to park_and_wake
        $parkResult = Invoke-ContinuationSwitch -Root $root41 -Continuation park_and_wake
        Assert-Condition 'S41 switch to park_and_wake succeeds' ($parkResult.ExitCode -eq 0) $parkResult.Output
        $state41AfterPark = Get-InstallState $root41
        Assert-Condition 'S41 state updated to park_and_wake continuation' ($null -ne $state41AfterPark.codexContinuation -and [string]$state41AfterPark.codexContinuation.selected -ceq 'park_and_wake') ''
        $agents41AfterPark = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8
        $rt41AfterPark = Get-AgentsRuntimeBlock -Text $agents41AfterPark
        Assert-Condition 'S41 AGENTS.md runtime block updated to subagent_continuation = park_and_wake' ($rt41AfterPark.Continuation -ceq 'park_and_wake') $rt41AfterPark.Continuation
        $config41AfterPark = Read-Config $root41
        Assert-Condition 'S41 continuation switch leaves config.toml untouched' ($config41AfterPark -ceq ($originalConfig41 -replace "`r?`n", "`r`n")) ''

        # 3. Status reporting across all switchers
        $statusResult = Invoke-ContinuationStatus -Root $root41
        Assert-Condition 'S41 continuation status reports active park_and_wake' ($statusResult.ExitCode -eq 0 -and $statusResult.Output -match '(?i)Active subagent continuation:\s*park_and_wake') $statusResult.Output
        $backendStatus = Invoke-BackendStatus -Root $root41
        Assert-Condition 'S41 backend status reports active continuation' ($backendStatus.ExitCode -eq 0 -and $backendStatus.Output -match '(?i)Active subagent continuation:\s*park_and_wake') $backendStatus.Output

        # 4. Idempotence
        $parkRerun = Invoke-ContinuationSwitch -Root $root41 -Continuation park_and_wake
        $agents41Rerun = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8
        Assert-Condition 'S41 repeated switch to park_and_wake is byte-identical' ($parkRerun.ExitCode -eq 0 -and $agents41Rerun -ceq $agents41AfterPark) $parkRerun.Output

        # 5. Switch back to active_follow
        $followResult = Invoke-ContinuationSwitch -Root $root41 -Continuation active_follow
        Assert-Condition 'S41 switch back to active_follow succeeds' ($followResult.ExitCode -eq 0) $followResult.Output
        $state41Follow = Get-InstallState $root41
        Assert-Condition 'S41 state updated to active_follow continuation' ([string]$state41Follow.codexContinuation.selected -ceq 'active_follow') ''
        $agents41Follow = Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8
        $rt41Follow = Get-AgentsRuntimeBlock -Text $agents41Follow
        Assert-Condition 'S41 AGENTS.md runtime block updated to subagent_continuation = active_follow' ($rt41Follow.Continuation -ceq 'active_follow') $rt41Follow.Continuation

        # 6. Multi-host continuation switch
        foreach ($hostInfo in (Get-SwitchHosts)) {
            $hPark = Invoke-ContinuationSwitchWithHost -Root $root41 -Continuation park_and_wake -HostInfo $hostInfo
            Assert-Condition "S41 $($hostInfo.Name) switch to park_and_wake succeeds" ($hPark.ExitCode -eq 0) $hPark.Output
            $hFollow = Invoke-ContinuationSwitchWithHost -Root $root41 -Continuation active_follow -HostInfo $hostInfo
            Assert-Condition "S41 $($hostInfo.Name) switch to active_follow succeeds" ($hFollow.ExitCode -eq 0) $hFollow.Output
        }

        # 7. Fail closed on invalid selector
        $switchScript = Join-Path $repo 'scripts\switch-subagent-continuation.ps1'
        $invalidParamResult = Invoke-ProcessCapture -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $switchScript, '-Continuation', 'invalid_mode', '-CodexHome', (Get-CodexHome $root41))
        Assert-Condition 'S41 switcher fails closed on invalid selector parameter' ($invalidParamResult.ExitCode -ne 0) $invalidParamResult.Output

        # Tampered AGENTS.md with invalid continuation fails switcher
        $tamperedAgents = (Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8) -replace 'subagent_continuation = active_follow', 'subagent_continuation = invalid_continuation'
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Content $tamperedAgents
        $tamperSwitchResult = Invoke-ContinuationSwitch -Root $root41 -Continuation park_and_wake
        Assert-Condition 'S41 switcher fails closed when AGENTS.md contains invalid continuation' ($tamperSwitchResult.ExitCode -ne 0) $tamperSwitchResult.Output
        # Restore valid AGENTS.md
        Write-FixtureFile -Path (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Content $agents41Follow

        # 8. Backend and continuation preserve each other
        $restoreParkResult = Invoke-ContinuationSwitch -Root $root41 -Continuation park_and_wake
        Assert-Condition 'S41 restores park_and_wake before backend preservation check' ($restoreParkResult.ExitCode -eq 0) $restoreParkResult.Output
        Invoke-BackendSwitch -Root $root41 -Backend native | Out-Null
        $rtAfterBackend = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8)
        $stateAfterBackend = Get-InstallState $root41
        Assert-Condition 'S41 backend switch preserves active park_and_wake continuation' ($rtAfterBackend.Continuation -ceq 'park_and_wake' -and $rtAfterBackend.Backend -ceq 'native') ''
        Assert-Condition 'S41 backend switch keeps schema-6 continuation state' ([int]$stateAfterBackend.schemaVersion -eq 6 -and [string]$stateAfterBackend.codexContinuation.selected -ceq 'park_and_wake') ''

        Invoke-ContinuationSwitch -Root $root41 -Continuation active_follow | Out-Null
        $rtAfterContinuation = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8)
        $stateAfterContinuation = Get-InstallState $root41
        Assert-Condition 'S41 continuation switch preserves native backend' ($rtAfterContinuation.Continuation -ceq 'active_follow' -and $rtAfterContinuation.Backend -ceq 'native') ''
        Assert-Condition 'S41 continuation switch keeps schema-6 backend state' ([int]$stateAfterContinuation.schemaVersion -eq 6 -and [string]$stateAfterContinuation.codexBackend.selected -ceq 'native') ''

        # 10. Safe reinstall preserves continuation
        Invoke-ContinuationSwitch -Root $root41 -Continuation park_and_wake | Out-Null
        Invoke-SafeInstall -Root $root41
        $rtAfterReinstall = Get-AgentsRuntimeBlock -Text (Get-Content -LiteralPath (Join-Path (Get-CodexHome $root41) 'AGENTS.md') -Raw -Encoding UTF8)
        Assert-Condition 'S41 safe reinstall preserves active park_and_wake in AGENTS.md' ($rtAfterReinstall.Continuation -ceq 'park_and_wake') ''
        $stateAfterReinstall = Get-InstallState $root41
        Assert-Condition 'S41 safe reinstall preserves schema-6 continuation and omits retired selectors' ([int]$stateAfterReinstall.schemaVersion -eq 6 -and [string]$stateAfterReinstall.codexContinuation.selected -ceq 'park_and_wake' -and -not ($stateAfterReinstall.PSObject.Properties.Name -contains 'codexDelegation') -and -not ($stateAfterReinstall.PSObject.Properties.Name -contains 'codexStrategy')) ''

        # 11. No consumer repository injection
        $consumerRepo = Join-Path $root41 'consumer-app'
        New-Item -ItemType Directory -Path $consumerRepo -Force | Out-Null
        $consumerAgents = Join-Path $consumerRepo 'AGENTS.md'
        Set-Content -LiteralPath $consumerAgents -Value '# Project AGENTS file' -Encoding UTF8
        $consumerBefore = Get-Content -LiteralPath $consumerAgents -Raw -Encoding UTF8
        Invoke-ContinuationSwitch -Root $root41 -Continuation active_follow | Out-Null
        $consumerAfter = Get-Content -LiteralPath $consumerAgents -Raw -Encoding UTF8
        Assert-Condition 'S41 consumer repo AGENTS.md remains untouched by continuation operations' ($consumerBefore -ceq $consumerAfter) ''
    }

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
