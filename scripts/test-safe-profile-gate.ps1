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

function Invoke-SafeInstall {
    param([Parameter(Mandatory)][string]$Root, [string]$Profile = 'safe')

    & $installer -Profile $Profile -CodexHome (Get-CodexHome $Root) -AgentsHome (Get-AgentsHome $Root) -Force *>&1 | Out-Host
}

function Invoke-SafeUninstall {
    param([Parameter(Mandatory)][string]$Root)

    & $uninstaller -CodexHome (Get-CodexHome $Root) -AgentsHome (Get-AgentsHome $Root) *>&1 | Out-Host
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
