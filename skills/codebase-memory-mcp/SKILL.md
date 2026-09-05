---
name: codebase-memory-mcp
description: Use when querying structural knowledge graphs, tracing call chains (trace_path), analyzing codebase architecture (get_architecture), running Cypher queries (query_graph), checking index coverage, or mapping git diff impact with local zero-billing codebase-memory-mcp.
---

# Codebase Memory MCP

Canonical routing, operational constraints, and lifecycle safety for `codebase-memory-mcp` (upstream release `v0.10.8`).

## Overview and Upstream Baseline

- **Engine Baseline**: Upstream release [`v0.10.8`](https://github.com/DeusData/codebase-memory-mcp/releases/tag/v0.10.8).
- **Zero-Billing & Local Graph Operation**: Operates locally using an in-process SQLite graph with Tree-Sitter AST and Hybrid LSP type inference. Zero subscription tier and zero external API query costs. Local graph queries do not upload codebase data to the cloud, while any external integrations remain explicit and require separate review.
- **Managed Installation**: Install the global binary exclusively via repository helper script `scripts/install-free-mcps.ps1 -Mode Install` (default invocation runs inspect-only) with SHA256 digest verification.
- **Installation Safety**: Never run upstream `install.sh` or `install.ps1` directly from curl or repository checkouts without reviewed scope; avoid unreviewed upstream hooks, shell modifications, or agent configuration rewrites. External integrations and configuration modifications must remain explicit under repo-controlled helpers.
- **Rollback & Process Protection**: Rollback must execute exclusively via `scripts/install-free-mcps.ps1 -Mode Rollback` (the helper interface requires `-Mode Rollback`; `-Rollback` is an invalid flag). Never automate restart or taskkill of Antigravity desktop or MCP servers.

## Routing and Precedence Matrix

| Scenario / Condition | Primary Tool | Fallback / Alternative | Boundary Contract |
|---|---|---|---|
| `.codegraph` exists in repository root | CodeGraph (`codegraph_explore`) | Serena / CBM / `rg` | Prioritize CodeGraph when index exists; no auto-init if absent |
| Symbol definition, LSP references, diagnostics | Serena | CBM / `rg` | Serena handles LSP semantic symbols, definitions, implementations, and diagnostics; read-only in ALINHAMENTO |
| Multi-file call chains, architecture overview, Cypher graph query | codebase-memory-mcp | CodeGraph / `rg` with warning | Check existing index; verify graph against source |
| Index absent, stale, or unknown | `rg` (ripgrep) | Targeted file reads | Graph queries do not guarantee completeness; rg fallback |

## Verified Upstream Tools and Mutation Caveats

Tools verified against upstream v0.10.8 C runtime and MCP annotations:

### Pure Query / Read-Only Tools (`readOnlyHint=true`)
- `search_graph`: Regex name patterns, node labels, min/max degree, and path filters.
- `query_graph`: Cypher-like relationship queries (e.g. `MATCH (f:Function)-[:CALLS]->(g)`).
- `trace_path` (alias `trace_call_path`): Bidirectional call chain traversal (inbound/outbound).
- `get_code_snippet`: Retrieves code snippets for indexed graph entities.
- `get_graph_schema`: Inspects available node labels, edge types, and properties.
- `compare_graphs`: Compares graph topology across snapshots or projects.
- `get_architecture`: Summarizes packages, entry points, REST routes, clusters, and boundaries.
- `search_code`: Graph-augmented regex search over indexed files.
- `list_projects`: Lists indexed projects in the local store.
- `index_status`: Reports index freshness, file count, and sync state.
- `check_index_coverage`: Verifies file and language coverage in the graph store.
- `detect_changes`: Maps uncommitted git diffs to affected graph symbols with risk classification.

> **CRITICAL FENCING ON `readOnlyHint`**:
> Upstream `readOnlyHint=true` is advisory only and is **NOT** proof of zero disk or store writes. Starting the server process or invoking CLI tools on an unindexed or unprepared repository can trigger one-shot SQLite database creation, cache directory initialization, WAL file generation, or implicit store mutation.
> - In no-write modes (`ALINHAMENTO`, read-only, `COMMIT`), do **NOT** start the process or CLI just because `readOnlyHint` is true.
> - In no-write modes, require a proven, strictly side-effect-free route against an already prepared and verified store. If the store is missing, unindexed, stale, or a zero-mutation route is unproven, do not start the process or CLI; fall back immediately to `rg` (ripgrep).

### Mutating / Write Tools (`readOnlyHint=false`)
- `index_repository`: Parses codebase and writes SQLite graph database. MUTATING.
- `get_file_outline`: **CRITICAL CAVEAT** — Upstream annotations explicitly mark `read_only=false`, `destructive=true`. Do not assume that tools not named "index" are pure read-only. `get_file_outline` executes AST parsing and project store operations with mutation side effects.
- `delete_project`: Permanently removes an indexed project from the database. MUTATING.
- `manage_adr`: Creates or edits Architectural Decision Records on disk. MUTATING.
- `ingest_traces`: Ingests OpenTelemetry/trace JSON into the graph store. MUTATING.

### One-Shot CLI Mode
- Command pattern: `codebase-memory-mcp cli <tool_name> '<args_json>'`.
- CLI mode does not start daemon background watchers or the UI HTTP server. However, running CLI queries against an unprepared repository can still initialize local SQLite files or cache directories. In no-write modes, CLI invocation is permitted ONLY when an already prepared store exists and side-effect-free execution is guaranteed; otherwise, fall back to `rg`.

## Repository Preparation and Auto-Index Boundaries

1. **Mode Fencing**:
   - Preparing or indexing a repository is permitted ONLY in explicit, authorized write delivery modes AND when there is material benefit.
   - Strictly forbidden in read-only modes and `ALINHAMENTO`: no `auto-index`, no background watchers, no `index_repository`. Do not spawn the CBM server or CLI process based merely on `readOnlyHint=true` without a pre-existing prepared store.
   - Strictly forbidden in `COMMIT` mode: COMMIT is git-only; never mutate, index, or launch daemon/watchers.
2. **Canonical Root and Exclusions**:
   - Always verify the canonical repository root before indexing.
   - Enforce exclusions for secrets (`.env`, `*.key`, `*.pem`), vendor libraries (`vendor/`, `node_modules/`), build outputs (`dist/`, `target/`), and generated files.
   - **Single Root `.cbmignore` Rule**: `.cbmignore` is read ONLY from the repository root (`<repo>/.cbmignore`). Nested `.cbmignore` files in subdirectories are completely ignored by CBM discovery.
   - **Discovery Precedence**:
     1. Built-in skip list (safety core `.git`, `node_modules`, `.worktrees`, `.claude-worktrees` cannot be negated).
     2. Repo `.gitignore` + worktree `info/exclude`.
     3. Nested `.gitignore` files.
     4. `.cbmignore` (negation `!dir/` can un-skip layer 1 non-safety core dirs and rescue layer 5 paths).
     5. Git global excludes (`core.excludesFile`).
3. **Swarm Concurrency and Coordination**:
   - In multi-agent swarm environments, perform an atomic owner/lock check before initiating indexing to prevent duplicate indexing across workers.
   - Share project identifier and index freshness across peer workers to reuse existing graphs.

## Graph Query Verification Contract

- **No Completeness Guarantee**: Graph query results do not guarantee absolute completeness or up-to-the-minute freshness.
- **Load-Bearing Verification**: Material conclusions, call chain claims, and structural refactor decisions must be verified against original source code, file hash, version, or freshness.
- **Stale State Handling**: If an index is stale, execute a delimited write sync and recheck in write delivery mode; in read-only modes, state the limitation and fall back to `rg`.
- **Unknown State Handling**: An unknown index status blocks all graph-based claims. Fall back immediately to `rg` (ripgrep) with an explicit disclosure warning.

## Diagnostics and Operational Safety

- **Read-Only Diagnostics**: Inspect existing daemon events and conflicts without modifying state or activating tracing under `${CBM_CACHE_DIR}/logs`:
  - `cbm-daemon.log`: Lifecycle, indexing, and error events.
  - `daemon-conflicts.ndjson`: Coordination ABI and cache root conflicts.
  - `activation-events.ndjson`: Installer activation records.
- **Diagnostic Opt-In Prohibitions (`CBM_DIAGNOSTICS=1`)**: Setting `CBM_DIAGNOSTICS=1` is a mutation/logging opt-in that creates and writes diagnostic trajectory files (`trajectory.ndjson`) to disk. Routine activation is strictly prohibited, especially in read-only modes, ALINHAMENTO, and COMMIT. Read-only diagnostics must inspect existing logs only, without enabling active tracing or mutating environment variables.
- **Safe Rollback**: Use `scripts/install-free-mcps.ps1 -Mode Rollback` to cleanly restore configuration (never use bare `-Rollback`). Never kill or restart Antigravity processes or wipe authentication profiles.

## References

- [`references/scenarios.md`](references/scenarios.md): Deterministic scenario manual for independent forward-test verification by the parent orchestrator without simulated or fake actions.
