$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$skill = Join-Path $repo 'skills\codex-workflows\SKILL.md'
$ahk = Join-Path $repo 'ahk\codex_prompt_pad.ahk'
$ahkExe = 'E:\Programs\AHK\v2\AutoHotkey64.exe'

$skillText = Get-Content -Raw $skill
if ($skillText -notmatch "(?s)^---\s*\r?\nname:\s*codex-workflows\r?\ndescription:\s*.+?\r?\n---\s*\r?\n") {
    throw 'Invalid codex-workflows SKILL.md frontmatter.'
}

foreach ($file in 'dictionary.md','mode-matrix.md','subagents.md','validation.md') {
    $path = Join-Path $repo "skills\codex-workflows\references\$file"
    if (!(Test-Path $path)) {
        throw "Missing reference: $file"
    }
}

foreach ($file in 'scout.toml','reviewer.toml','worker.toml') {
    $path = Join-Path $repo "agents\$file"
    $text = Get-Content -Raw $path
    if ($text -notmatch 'name\s*=' -or $text -notmatch 'developer_instructions\s*=') {
        throw "Invalid agent profile: $file"
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
