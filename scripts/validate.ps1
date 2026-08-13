[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$AgentsHome,
    [switch]$SkipInstalled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$defaultAgentsHome = if ($env:AGENTS_HOME) { $env:AGENTS_HOME } else { Join-Path $env:USERPROFILE '.agents' }
$codexHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($CodexHome)) { $defaultCodexHome } else { $CodexHome }))
$agentsHome = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($AgentsHome)) { $defaultAgentsHome } else { $AgentsHome }))

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
        '(?i)`?interrupted`?,? `?errored`?,? `?timed out`?,? or `?missing final response`? means unavailable: keep `?the gate`? `?open/BLOCKED`?; do not use a `?silent fallback`?'
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
        '(?i)(?:synthesis|advancement|synthesize|advance|proceed|continue)[^.;]*(?:before|prior to|without|in the absence of)[^.;]*(?:final response|response|reply|answer|return)'
    )
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            throw "$Label contains a forbidden completion-policy exception: $pattern"
        }
    }
}

function Test-OrchestrationPolicy {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()

    $requiredPatterns = @(
        '(?i)sem `?\$?workflows`?,? a delega[cç][aã]o continua usando o deepseek',
        '(?i)mas n[aã]o [eé] condi[cç][aã]o para selecionar o mcp',
        '(?i)mesmo quando o usu[aá]rio n[aã]o (?:menciona|pede|invoca)',
        '(?i)trabalho material (?:de|em) leitura, investiga[cç][aã]o, teste, escrita e revis[aã]o [eé] delegado',
        '(?i)delegado ao deepseek mcp por padr[aã]o',
        '(?i)trabalho local do parent [eé] at[oóô]mico',
        '(?i)nunca refazer localmente uma frente material delegada',
        '(?i)consuma todo job aceito antes de um gate dependente ou da resposta final',
        '(?i)feche explicitamente todo agente terminado',
        '(?i)sem obriga[cç][oõ]es pendentes ou em aberto',
        '(?i)o writer fica aberto.{0,80}at[ée] a revis[aã]o independente',
        '(?i)defeitos provados voltam [aáà] mesma frente',
        '(?i)feche s[oó] depois',
        '(?i)n[aã]o est[aá] terminado antes de revis[aã]o e corre[cç][oõ]es conclu[ií]das',
        '(?i)exceto quando o usu[aá]rio pedir explicitamente sub-agentes nativos do codex',
        '(?i)agentes de supervis[aã]o do sistema.{0,60}isentos',
        '(?i)a isen[cç][aã]o nunca autoriza o parent a invocar ferramentas nativas',
        '(?i)falha fechado',
        '(?i)visual_context',
        '(?i)antes de esperar,? mapeie frentes independentes,? depend[eê]ncias e recursos exclusivos ou compartilhados',
        '(?i)lance em lote todas as frentes materiais independentes antes do primeiro follow',
        '(?i)apenas trilhas com depend[eê]ncia real ou recurso compartilhado ficam seriais',
        '(?i)enquanto aguarda,? fa[cç]a orquestra[cç][aã]o independente [uú]til',
        '(?i)ledger est[aá]vel de request_id.{0,60}frente,? agente,? job,? estado,? consumido e fechado',
        '(?i)consuma cada job e feche cada agente ap[oó]s a integra[cç][aã]o'
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not [regex]::IsMatch($normalized, $pattern)) {
            return "missing required orchestration policy pattern: $pattern"
        }
    }

    $forbiddenPatterns = @(
        '(?i)\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam)\b[^.;]*\b(?:l[eê]|ler|escreve|escrever|testa|testar|revisa|revisar|investiga|investigar|executa|executar|realiza|realizar|faz|fazer|verifica|verificar|confere|conferir)\b[^.;]*\b(?:localmente|diretamente|por conta pr[oó]pria)\b',
        '(?i)\b(?:pode|poderia|poder[aá]|deve|deveria)\b[^.;]*\b(?:refazer|repetir|duplicar)\b',
        '(?i)(?:n[aã]o precisa|sem precisar|sem a necessidade)\b[^.;]*\bdelegar\b',
        '(?i)\b(?:exceto|salvo)\b[^.;]*\b(?:leitura|investiga[cç][aã]o|escrita|teste|revis[aã]o)\b',
        '(?i)\b(?:pode|poderia|poder[aá]|deve|deveria)\b[^.;]*\b(?:fechar|encerrar)\b[^.;]*(?:writer|agente|frente)',
        '(?i)\b(?=[^.;]*\b(?:pode|podem|poderia|poderiam|poder[aá]|poder[aã]o|poderao|deve|devem|deveria|deveriam|s[aã]o autorizad[ao]s? a|est[aã]o autorizad[ao]s? a|usam)\b)(?=[^.;]*\b(?:spawn_agent|wait_agent|multi_agent_v1__spawn_agent)\b)(?=[^.;]*\b(?:supervis[aã]o|guardian)\b)[^.;]+',
        '(?i)\b(?:parent|parent gpt)\b[^.;]*\b(?:l[eê]|ler|escreve|escrever|testa|testar|revisa|revisar|investiga|investigar|executa|executar|realiza|realizar|faz|fazer|verifica|verificar|confere|conferir)\b[^.;]*\b(?:localmente|diretamente|por conta pr[oó]pria)\b'
    )

    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($normalized, $pattern)) {
            return "forbidden direct-local-work carve-out: $pattern"
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
            Name = 'direct-local-work carve-out added'
            Text = ($normalized + ' O parent pode ler arquivos localmente sem delegar.')
        }
        [pscustomobject]@{
            Name = 'native tools authorized for supervisory agents'
            Text = ($normalized + ' O parent pode usar spawn_agent para agentes de supervisao do sistema.')
        }
        [pscustomobject]@{
            Name = 'parent verifies results locally'
            Text = ($normalized + ' O parent verifica o resultado localmente.')
        }
        [pscustomobject]@{
            Name = 'parent double-checks directly'
            Text = ($normalized + ' O parent confere o resultado diretamente.')
        }
        [pscustomobject]@{
            Name = 'fail-closed behavior removed'
            Text = (New-TamperedText -Text $normalized -Old 'e o parent falha fechado — inclusive quando os tools DeepSeek estão indisponíveis — em vez de outra rota silenciosa.')
        }
        [pscustomobject]@{
            Name = 'user-mention default-delegation clause removed'
            Text = (New-TamperedText -Text $normalized -Old 'e vale mesmo quando o usuário não menciona `$workflows`, sub-agentes ou delegação')
        }
        [pscustomobject]@{
            Name = '$workflows made a condition for MCP selection'
            Text = (New-TamperedText -Text $normalized -Old 'mas não é condição para selecionar o MCP' -New 'mas é condição para selecionar o MCP')
        }
        [pscustomobject]@{
            Name = 'writer close-before-review exemption added'
            Text = ($normalized + ' O parent pode fechar o writer antes da revisão independente.')
        }
        [pscustomobject]@{
            Name = 'supervisory agents may use native tools to manage lifecycle'
            Text = ($normalized + ' Os agentes de supervisão do sistema podem usar spawn_agent para gerenciar o ciclo de vida.')
        }
        [pscustomobject]@{
            Name = 'supervisory agents authorized to use native tools'
            Text = ($normalized + ' Os agentes de supervisão do sistema estão autorizados a usar wait_agent.')
        }
        [pscustomobject]@{
            Name = 'supervisory agents use native tools freely'
            Text = ($normalized + ' Os agentes de supervisão do sistema usam spawn_agent livremente.')
        }
        [pscustomobject]@{
            Name = 'native-tool ban negated'
            Text = (New-TamperedText -Text $normalized -Old 'nunca autoriza' -New 'autoriza')
        }
        [pscustomobject]@{
            Name = 'map-before-wait removed'
            Text = (New-TamperedText -Text $normalized -Old 'Antes de esperar, mapeie frentes independentes' -New 'Antes de esperar, apenas aguarde')
        }
        [pscustomobject]@{
            Name = 'batch launch before first follow removed'
            Text = (New-TamperedText -Text $normalized -Old 'lance em lote todas as frentes materiais independentes' -New 'lance as frentes uma a uma')
        }
        [pscustomobject]@{
            Name = 'serial-only-real-dependencies removed'
            Text = (New-TamperedText -Text $normalized -Old 'apenas trilhas com dependência real ou recurso compartilhado ficam seriais' -New 'todas as trilhas podem ser seriais')
        }
        [pscustomobject]@{
            Name = 'useful orchestration while waiting removed'
            Text = (New-TamperedText -Text $normalized -Old 'enquanto aguarda, faça orquestração independente útil' -New 'enquanto aguarda, espere ocioso')
        }
        [pscustomobject]@{
            Name = 'request_id ledger removed'
            Text = (New-TamperedText -Text $normalized -Old 'ledger estável de request_id' -New 'controle interno de jobs')
        }
        [pscustomobject]@{
            Name = 'consume-and-close-after-integration removed'
            Text = (New-TamperedText -Text $normalized -Old 'consuma cada job e feche cada agente após a integração' -New 'consuma os resultados')
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
    if ($schemaText -notin @('1', '2', '3', '4')) {
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

    if ($schema -eq 4) {
        if (-not ($State.PSObject.Properties.Name -contains 'codexFeaturesPrior') -or $null -eq $State.codexFeaturesPrior) {
            throw 'Schema 4 installed state is missing codexFeaturesPrior.'
        }
        if (-not ($State.codexFeaturesPrior.PSObject.Properties.Name -contains 'multi_agent')) {
            throw 'Schema 4 installed state is missing the multi_agent feature record.'
        }
        $featureRecord = $State.codexFeaturesPrior.multi_agent
        if ($null -eq $featureRecord -or -not ($featureRecord.PSObject.Properties.Name -contains 'present') -or -not ($featureRecord.PSObject.Properties.Name -contains 'value')) {
            throw 'Schema 4 installed state contains an invalid multi_agent feature record.'
        }
        if ($featureRecord.present -notin @($true, $false)) {
            throw 'Schema 4 installed state has an invalid multi_agent presence flag.'
        }
        if ([bool]$featureRecord.present -and $null -eq $featureRecord.value) {
            throw 'Schema 4 installed state has a present multi_agent record without a value.'
        }
        if (-not [bool]$featureRecord.present -and $null -ne $featureRecord.value) {
            throw 'Schema 4 installed state has an absent multi_agent record with a value.'
        }
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
$agentsMd = Join-Path $repo 'codex\AGENTS.md'
$skill = Read-RequiredText (Join-Path $workflowSource 'SKILL.md')
$agentsText = Read-RequiredText $agentsMd
$installer = Read-RequiredText (Join-Path $repo 'scripts\install.ps1')
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
    'capabilities | change permission | done gate',
    'visual_context',
    'Final audit',
    'Delivery commit gate',
    'local commit series',
    'never push',
    'Git index',
    'No-edit',
    'not the repository workforce'
)
Assert-ModeMatrix -Label 'workflow skill' -Text $skill
$implAutoRow = [regex]::Match($skill, '(?m)^\| `IMPL\.AUTO` \|[^\r\n]+')
if (-not $implAutoRow.Success -or $implAutoRow.Value -notmatch '\| write \|') {
    throw "Workflow skill does not grant IMPL.AUTO write permission"
}

Assert-Forbidden -Label 'workflow skill' -Text $skill -Tokens @(
    'AGENTS.md',
    'subagents=',
    'backend',
    'native',
    'sidecar',
    'read-only',
    'scout',
    'researcher',
    'writer',
    'reviewer',
    'worker'
)
Assert-Forbidden -Label 'codex AGENTS.md' -Text $agentsText -Tokens @(
    'subagents=',
    'backend',
    'sidecar',
    'read-only',
    'FRAME',
    'mode matrix',
    'lifecycle',
    'scout',
    'researcher'
)

Assert-Contains -Label 'codex AGENTS.md' -Text $agentsText -Needles @(
    '$workflows',
    'SKILL.md',
    'Preserve',
    'parent GPT',
    'DeepSeek',
    'MCP',
    'delega',
    'job',
    'visual_context',
    (-join [char[]]@(110, 227, 111, 32, 97, 32, 102, 111, 114, 231, 97, 32, 100, 101, 32, 116, 114, 97, 98, 97, 108, 104, 111, 32, 100, 111, 32, 114, 101, 112, 111, 115, 105, 116, 243, 114, 105, 111)),
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
    'explicitamente',
    'falha fechado',
    'resultado terminal'
)
$agentsLines = @(($agentsText -split '\r?\n') | Where-Object { $_.Trim() -ne '' })
if ($agentsLines.Count -gt 40) {
    throw "codex AGENTS.md exceeds the compact budget: $($agentsLines.Count) non-empty lines"
}

Assert-CompletionPolicy -Label 'workflow skill' -Text $skill

Assert-OrchestrationPolicy -Label 'codex AGENTS.md' -Text $agentsText

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
    '\bnative\b',
    '\bbackend\b',
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
            if ($relativePath -eq 'codex/AGENTS.md' -and $token -in @('writer', 'reviewer', 'worker')) {
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

$promptBindings = @([regex]::Matches($promptPad, '(?m)^[^;\r\n]+::PastePrompt\("([^\"]+)"\)'))
if ($promptBindings.Count -eq 0) {
    throw 'Prompt pad has no workflow bindings.'
}
foreach ($binding in $promptBindings) {
    if (-not $binding.Groups[1].Value.StartsWith('$workflows mode=', [StringComparison]::Ordinal)) {
        throw 'Prompt pad contains a binding outside the workflow contract.'
    }
}
if ($promptPad -match '(?m)^![A-Za-z0-9]+::') {
    throw 'Prompt pad contains a non-workflow hotkey binding.'
}
Assert-Forbidden -Label 'prompt pad' -Text $promptPad -Tokens @(
    'deepseek',
    'mcp',
    'native',
    'backend',
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
    (-join [char[]]@(119, 97, 116, 99, 104, 101, 114)),
    (-join [char[]]@(97, 110, 116, 105, 103, 114, 97, 118, 105, 116, 121))
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

    $workflowsDest = Join-Path $agentsHome 'skills\workflows'
    $evidenceDest = Join-Path $agentsHome 'skills\evidence-first'
    Assert-MirrorTree -Source $workflowSource -Installed $workflowsDest -Label 'workflows skill'
    Assert-MirrorTree -Source $evidenceSource -Installed $evidenceDest -Label 'evidence skill'

    if ([string]$state.profile -eq 'safe') {
        Assert-NoManagedAgentsBlock -Path (Join-Path $codexHome 'config.toml')
        Assert-FeaturesMultiAgentDisabled -Path (Join-Path $codexHome 'config.toml')

        $installedAgents = Read-RequiredText (Join-Path $codexHome 'AGENTS.md')
        Assert-OrchestrationPolicy -Label 'installed AGENTS.md' -Text $installedAgents
    }
}

& (Join-Path $repo 'scripts\test-safe-profile-gate.ps1')

Write-Host 'Validation OK.'
