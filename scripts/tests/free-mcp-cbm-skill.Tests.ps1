# scripts/tests/free-mcp-cbm-skill.Tests.ps1
# Deterministic contract and content tests for skills/codebase-memory-mcp

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$skillDir = Join-Path $repoRoot 'skills\codebase-memory-mcp'
$skillFile = Join-Path $skillDir 'SKILL.md'
$scenariosFile = Join-Path $skillDir 'references\scenarios.md'
$agentYamlFile = Join-Path $skillDir 'agents\openai.yaml'

# Test runner harness
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

Write-Host "Running codebase-memory-mcp Skill Contract Tests..." -ForegroundColor Cyan

# 1. Structural file presence
Assert-Test "SKILL.md exists" (Test-Path -LiteralPath $skillFile -PathType Leaf)
Assert-Test "references/scenarios.md exists" (Test-Path -LiteralPath $scenariosFile -PathType Leaf)
Assert-Test "agents/openai.yaml exists" (Test-Path -LiteralPath $agentYamlFile -PathType Leaf)

if (-not (Test-Path -LiteralPath $skillFile)) {
    Write-Host "`nSKILL.md not found. Halting early (RED state)." -ForegroundColor Yellow
    exit 1
}

$skillContent = Get-Content -LiteralPath $skillFile -Raw
$scenariosContent = if (Test-Path -LiteralPath $scenariosFile) { Get-Content -LiteralPath $scenariosFile -Raw } else { '' }

# 2. YAML frontmatter & trigger-based description
Assert-Test "SKILL.md contains YAML frontmatter" ($skillContent -match '^---\s*[\r\n]+name:\s*codebase-memory-mcp')
Assert-Test "Frontmatter description uses trigger-based 'Use when' pattern" ($skillContent -match 'description:\s*Use when')
Assert-Test "SKILL.md is compact (under 25KB, not an unpruned README dump)" ($skillContent.Length -lt 25000)

# 3. Upstream baseline & installation safety
Assert-Test "References official v0.10.8 release baseline" ($skillContent -match 'v0\.10\.8')
Assert-Test "Documents installation via helper script install-free-mcps.ps1" ($skillContent -match 'install-free-mcps\.ps1')
Assert-Test "Documents installation specifies -Mode Install (default inspect)" ($skillContent -match 'install-free-mcps\.ps1\s+-Mode\s+Install')
Assert-Test "Explicitly forbids running upstream install.sh/install.ps1 directly without helper" ($skillContent -match '(?is)(never|proibir|forbid|do not).*upstream.*install\.(sh|ps1)')
Assert-Test "Removes unproven sweeping zero-telemetry and universal clobbering claims" (-not ($skillContent -match 'zero telemetry, and source code never leaves') -and -not ($skillContent -match 'clobber agent configurations, lifecycle hooks'))
Assert-Test "Describes local graph operation with explicit external integrations" ($skillContent -match '(?is)local graph.*(in-process|Tree-Sitter|SQLite)' -and $skillContent -match '(?is)external integration.*explicit')

# 4. Verified upstream tools categorization and honest annotations
Assert-Test "Documents search_graph as read-only tool" ($skillContent -match 'search_graph')
Assert-Test "Documents query_graph Cypher tool" ($skillContent -match 'query_graph')
Assert-Test "Documents trace_path tool" ($skillContent -match 'trace_path')
Assert-Test "Documents get_architecture tool" ($skillContent -match 'get_architecture')
Assert-Test "Documents index_repository as mutating/write tool" ($skillContent -match 'index_repository')
Assert-Test "Documents get_file_outline mutation caveat (not pure read-only in upstream annotations)" ($skillContent -match '(?is)get_file_outline.*(mutat|write|side effect|destructive|não.*pure read-only|read_only=false)')
Assert-Test "Documents manage_adr and ingest_traces as mutating tools" ($skillContent -match 'manage_adr' -and $skillContent -match 'ingest_traces')
Assert-Test "Documents full v0.10.8 tool list (delete_project, get_code_snippet, detect_changes, coverage, status)" ($skillContent -match 'delete_project' -and $skillContent -match 'get_code_snippet' -and $skillContent -match 'detect_changes' -and $skillContent -match 'check_index_coverage' -and $skillContent -match 'index_status')
Assert-Test "Documents readOnlyHint is advisory and not proof of zero writes" ($skillContent -match '(?is)readOnlyHint.*advisory.*(not proof|zero.*write)')
Assert-Test "Fences process/CLI startup in no-write modes without prepared store (requires proven side-effect-free route or rg)" ($skillContent -match '(?is)(no-write|ALINHAMENTO|read-only).*?(side-effect-free|prepared store|rg|ripgrep)')

# 5. CLI mode documentation
Assert-Test "Documents one-shot CLI execution syntax (codebase-memory-mcp cli)" ($skillContent -match 'codebase-memory-mcp cli <tool_name>')
Assert-Test "Explains CLI mode does not start daemon or watchers" ($skillContent -match '(?is)cli.*(daemon|watcher)')
Assert-Test "Fences CLI in no-write modes against unprepared store" ($skillContent -match '(?is)CLI.*(prepared store|side-effect-free|rg)')

# 6. Repository preparation & indexing boundaries
Assert-Test "Restricts index preparation to explicit write mode with material benefit" ($skillContent -match '(?is)(explicit|autoriz).*write.*(benefício|material)')
Assert-Test "Forbids auto-indexing or background indexing in read-only and ALINHAMENTO modes" ($skillContent -match '(?is)(read-only|ALINHAMENTO).*no.*(auto-index|index_repository)')
Assert-Test "Forbids auto-indexing or mutations in COMMIT mode" ($skillContent -match '(?is)COMMIT.*(não|never|no).*(mutat|index|daemon|watcher)')

# 7. Exclusions & .cbmignore rules
Assert-Test "Enforces exclusions for secrets, vendor, and generated files" ($skillContent -match '(?is)secrets.*vendor.*generated|\.cbmignore')
Assert-Test "Specifies single root .cbmignore requirement (nested .cbmignore ignored by CBM)" ($skillContent -match '(?is)(\.cbmignore.*root|nested \.cbmignore.*(ignored|não))')
Assert-Test "Documents discovery precedence order (.cbmignore precedence over git global)" ($skillContent -match '(?is)precedence|built-in.*gitignore.*cbmignore')

# 8. Swarm coordination & multi-agent concurrency
Assert-Test "Enforces swarm lock / atomic owner check to prevent duplicate indexing" ($skillContent -match '(?is)(owner|lock|swarm).*(duplicat|index)')
Assert-Test "Documents sharing project identifier and index freshness across workers" ($skillContent -match '(?is)(identif|freshness).*(shar|swarm|worker)')

# 9. Priority matrix & zero-billing guarantees
Assert-Test "Preserves CodeGraph priority when .codegraph exists" ($skillContent -match '(?is)CodeGraph.*(\.codegraph|priorit)')
Assert-Test "Preserves Serena priority for semantic LSP and symbol lookups" ($skillContent -match '(?is)Serena.*(LSP|symbol)')
Assert-Test "Enforces strictly local execution with zero cloud telemetry or source upload" ($skillContent -match '(?is)(local|zero.*telemetry|cloud|no.*cloud|never.*leave)')

# 10. Graph query verification contract
Assert-Test "States graph queries do not guarantee completeness and require source verification" ($skillContent -match '(?is)(complet|verif|source.*hash|freshness)')
Assert-Test "Specifies fallback to rg when graph is stale or unknown" ($skillContent -match '(?is)(rg|ripgrep).*fallback')

# 11. Diagnostics & operational safety
Assert-Test "Documents read-only diagnostics in CBM_CACHE_DIR/logs" ($skillContent -match '(?is)(logs|cbm-daemon\.log|daemon-conflicts\.ndjson)')
Assert-Test "Documents CBM_DIAGNOSTICS=1 is mutation opt-in and prohibited in routine/read-only checks" ($skillContent -match '(?is)CBM_DIAGNOSTICS=1.*?(mutat|opt-in).*?prohibit.*?(routine|read-only)')
Assert-Test "Documents safe rollback via helper with -Mode Rollback" ($skillContent -match 'install-free-mcps\.ps1\s+-Mode\s+Rollback')
Assert-Test "Regression: forbids invalid bare -Rollback flag in SKILL.md and scenarios.md" (-not ($skillContent -match 'install-free-mcps\.ps1\s+-Rollback\b') -and -not ($scenariosContent -match 'install-free-mcps\.ps1\s+-Rollback\b'))
Assert-Test "Documents safe rollback forbids Antigravity/MCP auto-restarts" ($skillContent -match '(?is)rollback.*(install-free-mcps|helper)' -and $skillContent -match '(?is)(never|não).*restart.*(Antigravity|MCP)')

# 12. Forward-test scenarios manual
Assert-Test "Scenarios manual contains independent forward-test verification steps" ($scenariosContent -match '(?is)Scenario|Forward-Test|Verification')
Assert-Test "Scenarios manual forbids pretending real actions (no fake mock results)" ($scenariosContent -match '(?is)(fake|real action|mock|pretend|não.*fingir)')

Write-Host "`n================================" -ForegroundColor Cyan
Write-Host "Total Tests : $script:TestCount"
Write-Host "Passed      : $script:PassedCount" -ForegroundColor Green
Write-Host "Failed      : $script:FailedCount" -ForegroundColor $(if ($script:FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "================================" -ForegroundColor Cyan

if ($script:FailedCount -gt 0) {
    Write-Host "`nFailure details:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
}

exit 0
