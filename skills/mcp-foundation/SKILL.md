---
name: mcp-foundation
description: Use when routing, querying, or maintaining allowlisted MCP tools (Context7, CodeGraph, Serena, Codebase Memory), inspecting external library/framework documentation via context7-mcp, navigating structural code relationships, performing semantic symbol/LSP lookups, managing structural code graph indexing via codebase-memory-mcp, or executing read-only MCP doctor diagnostics and safe process checks.
---

# MCP Foundation

Canonical routing, usage constraints, and operational maintenance for allowlisted MCP tools (Context7, CodeGraph, Serena, and Codebase Memory).

## Routing Matrix

| Tool | Primary Purpose | Prerequisite / Trigger | Operation Contract |
|---|---|---|---|
| Context7 | External library/framework documentation and API references (credential-free) | Version/syntax uncertainty or unfamiliar external API | resolve -> query; atomic sanitized query; explicit version; share doc packet across swarm; trusted ID only (never inferred from version); credential-free policy (no verified-free-account claim); no secrets/proprietary code; on 429 stop with official docs notice (no model/provider switch); route to `context7-mcp` |
| CodeGraph | Structural architecture, symbol relationships, and call flow | .codegraph exists in repository root or explicit projectPath | Structural first via codegraph_explore; status -> sync -> recheck; fall back to Serena/rg; never auto-init |
| Serena | Symbol navigation, LSP features, references, diagnostics | Active codebase navigation | --project-from-cwd; one instance per project; read-only config check; safe concurrent reads; strictly no generic taskkill/auto-restart |
| Codebase Memory | Structural code graph, AST/call chains, and codebase architecture (free tier) | Active exploration in write modes where structural knowledge graph aids delivery | Global install separate from repo prep; auto-prep only in write modes under verified exclusions and single-owner lock; strictly no prep/cache/monitors in PLAN/RESEARCH/ALINHAMENTO/COMMIT; index is not authority (source validation + freshness); CodeGraph priority when .codegraph exists; Serena for LSP; route to `codebase-memory-mcp` |

mcp-foundation is mandatory for baseline routing, preflight, and maintenance; specialist skills (`context7-mcp` and `codebase-memory-mcp`) are loaded by the preflight when their MCP is relevant, before the first dependent read or edit.

## Automatic Use and Repository Maintenance Contract

Every workflow run, including work delegated to sub-agents, follows this loop before repository work:

1. Discover the allowlisted MCP capabilities and select the relevant tool by purpose: CodeGraph for an existing structural index, Serena for project-scoped LSP symbols and diagnostics, CBM for structural graph queries and architecture when its repository index is useful, and Context7 for current external documentation.
2. Check availability, repository scope, configuration, and freshness. Apply `Get-CodexMcpMaintenanceDecision` to the observed status; do not guess that an absent or unknown state is ready.
3. In authorized write modes, prepare only the repository state that the selected MCP supports: synchronize an existing CodeGraph index, activate Serena with `--project-from-cwd`, or initialize/refresh CBM after verifying exclusions and the single-owner canonical-root lock. Recheck the state before using it.
4. In no-write modes, inspect and report only. A missing or unknown route fails closed for that MCP and uses its documented safe alternative (Serena/rg for structural work or official docs for Context7), without creating local state.

This contract makes use automatic without making unsafe server lifecycle changes. Global installation, authentication, upgrade, restart, and CodeGraph full initialization remain explicit operator actions. Context7 has no repository index: availability is checked automatically, then its resolve -> query flow runs only when the task has a concrete current-documentation trigger.

## Context7

- Use Context7 (`skills/context7-mcp`) for current external library, framework, or API documentation when syntax, version changes, or API semantics matter.
- **Credential-Free Policy**: Operates strictly under a credential-free policy (`gratuito`). No paid plan, no excess/overage billing, no credit cards, no login, and no secrets. Do not make blanket claims of a "verified free account"; access is credential-free unauthenticated access.
- Always follow the atomic two-phase workflow:
  1. **Resolve**: Resolve the library ID (`resolve-library-id`) ONLY when a trusted library ID is absent (`resolver só sem ID confiável`). A trusted library ID must be an exact ID returned in the current task/session or explicitly provided by the user (format `/org/project` or `/org/project/version`); NEVER infer, synthesize, or construct an ID from a library name or version string.
  2. **Query**: Query (`query-docs`) with a focused, atomic sanitized question instead of a full conversational prompt (`consulta atômica sanitizada em vez de pergunta completa`).
- **Safety Boundary**: Never include secrets, API keys, passwords, environment variables, internal tokens, or proprietary source code in query payloads (`sem enviar código proprietário ou secrets`).
- **Version Verification**: Request and verify explicit versions (`versão explícita`). Disclose any mismatch when returned documentation sources point to unversioned main branches.
- **Swarm Cache & Sharing**: Share retrieved documentation packets across swarm agents (`compartilhar pacote docs entre agents`) to prevent redundant external API round-trips.
- **Rate Limit & 429 Handling**: If a 429 rate limit or quota exhaustion error occurs, stop immediately (`429 stop`) and report official documentation references with a user notice. Strictly NO provider fallback or model switching (`sem trocar modelo/provedor`).

## CodeGraph

- Use CodeGraph for structural exploration in medium-to-large codebases to trace module dependencies, architecture, and multi-file call paths before broad file reads. Structural queries must invoke `codegraph_explore` directly.
- Strict existence rule: Use CodeGraph ONLY if `.codegraph` exists in the repository root OR an explicit `projectPath` pointing to an existing index is provided.
- If `.codegraph` is absent and no explicit `projectPath` exists, skip CodeGraph immediately. Repository indexing is the user's manual choice; never auto-init, auto-index, or create `.codegraph` automatically.
- Maintenance & sync: Implementation/write modes may run `codegraph sync` when `status --json` indicates stale/pending delay, followed by a mandatory recheck; failure/unknown terminates the attempt and falls back to Serena and `rg` with a warning. No-write modes (including `COMMIT` for MCP purposes) verify status only without syncing. Full index/init are explicit operator requests only. The deterministic decision contract is exposed by `Get-CodexCodeGraphMaintenanceDecision`.

## Serena

- Use Serena for semantic symbol inspection, language server (LSP) queries, references, implementations, and diagnostics.
- Project scope & instance: Invoked with `--project-from-cwd`; run one instance per project/client by default; no global singleton across all repositories.
- Configuration: Read-only confirmation of project and configuration state before operational use.
- Mode constraints: In read-only modes and ALINHAMENTO, enforce `no-onboarding` and `no-memories` (memory writes/edits/deletions prohibited; memory reads allowed). Symbol and file editing tools are restricted strictly to explicit write delivery modes.
- Safe concurrent read operations are permitted.
- Process lifecycle: Serena runs as a managed MCP server. Never execute generic taskkill, wildcard process terminations, or automatic restarts against it.

## Codebase Memory (CBM)

- Use Codebase Memory (`skills/codebase-memory-mcp`) for structural code graph analysis, AST/call-graph relationships, and architecture queries on the free tier (structural code graph, not generic persistent project memories).
- **Global Install vs. Repository Preparation**: Global MCP server installation is completely decoupled from per-repository preparation (`instalação global separada de preparação por repo`).
- **Authorized Auto-Preparation**: Automatic repository preparation (`index_repository`) is permitted ONLY when useful in authorized write delivery modes (`IMPL`, `IMPL.AUTO`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`, `DEBUG`, `R.A.F.V`) (`auto preparação apenas quando útil em modos write autorizados`).
- **Exclusion Verification**: Verify exclusions (`exclusions verificadas`) before preparation or indexing, ensuring `.gitignore`, local state, build outputs, and secrets are strictly excluded.
- **Single-Owner Concurrency Lock**: Enforce a single owner per canonical repository root with a cooperative lock across swarm agents (`owner único por raiz canônica/lock entre swarm`) to eliminate concurrent indexing collisions.
- **No .codegraph Init**: Never execute `codegraph init` or trigger `.codegraph` generation from CBM (`sem .codegraph init`).
- **Negative No-Write Invariant**: Strictly FORBIDDEN to induce installations, index generation, cache creation, or background file monitors in read-only and no-write modes (`PLAN`, `PLAN.AUTO`, `P.DEEP`, `RESEARCH.DEEP`, `REVIEW`, `COMMIT`, `BUG.INV`, `REWORK`, `TN.SKILL`, and implicit `ALINHAMENTO`) (`sem instalações/indices/cache/monitores induzidos em PLAN/RESEARCH/ALINHAMENTO/COMMIT`).
- **Index Is Not Authority**: The CBM index is an auxiliary search index, not an authoritative code source. Always validate findings against the original source code files and verify freshness (`Index não é autoridade: validar fonte original e freshness`).
- **Tool Discipline & Hierarchy**: Preserve CodeGraph priority for structural queries when `.codegraph` exists; preserve Serena for LSP symbols, diagnostics, and implementations. Select each tool strictly by necessity without cascading or multiplying calls across all tools (`Preserve CodeGraph prioridade existente quando .codegraph existe e Serena LSP, escolha ferramenta por necessidade sem multiplicar todas`).
- **Scoped Exception Safety**: The CBM operational exception is strictly scoped to semantic search and repo indexing; it never removes universal maintenance protections.

## Maintenance & Operational Safety

1. Preflight by Mode: All workflow modes execute an MCP maintenance preflight. Read-only modes only verify status. Implementation modes may synchronize CodeGraph when status indicates delay/stale/pending via status -> sync -> recheck, falling back to Serena/rg with a warning on failure/unknown.
2. Doctor is Read-Only: Health checks and diagnostics (scripts/doctor.ps1) inspect registrations, file presence, and SHA256 hashes without modifying configuration files or terminating processes.
3. Mirror Integrity: Managed skill and rule mirrors must match their canonical repository counterparts verified via SHA256 checksums.
4. Serena Shutdown Protocol: A running Serena process may ONLY be stopped upon an explicit human request and after verifying:
   - Process ownership (verifying PID and process owner).
   - Server idleness (no active requests or locks).
   - Zero pending or running jobs across the session.
5. No Unsafe Automation & Antigravity Protection: NEVER automate kill, restart, upgrade, or server initialization (auto-init) of MCP servers or background tooling (CodeGraph strictly requires manual init; the sole scoped exception is authorized CBM repository preparation in write delivery modes). Never restart, close, login, or logout Antigravity desktop; never touch auth, profile, cookies, or cache.
6. DeepSeek Daemon Restart Exception: A tightly scoped, fail-closed operational recovery exception applies ONLY to the local owned DeepSeek Sub-Agent daemon under standing user authorization on this host. Recovery routes by observed state:
   - Transport closed + health ready: reconnect MCP transport; never restart daemon or Antigravity.
   - recovering: await bounded readiness without duplicate restart.
   - absent: canonical start (`dist/cli.js start --config <known-config> --json`) with verified PID/command/data-dir ownership and GET `/health` readiness.
   - owned-unhealthy: canonical restart (`dist/cli.js restart --config <known-config> --json`) only if ownership is verified and GET `/health` fails.
   - Fail-closed gates: bounded single attempt per incident; active jobs only allow recovery when all have proven durable spool/recovery (check `bridge.sqlite`); stale-running with absent daemon reconciles only with installed durable capacity; never trigger on `AntigravityProcessError`, provider/model timeout, or quota; no provider/model fallback; resume existing lineage after ready. Never restart, close, login, or logout Antigravity; never touch auth, profile, cookies, or cache; never use generic kill commands (`taskkill`, `Stop-Process`).

## References

Open only when safe shutdown verification, daemon recovery gates, or detailed process audits are required:
- references/serena-codegraph.md - Centralized Serena and CodeGraph operational management, preflight by mode, status->sync->recheck lifecycle, and project scoping.
- references/lifecycle.md - Process ownership, idle verification, DeepSeek daemon restart gates, and mirror audit procedures.
- `../context7-mcp/SKILL.md` (`context7-mcp`) - Context7 documentation lookup workflow, atomic sanitized queries, and rate-limit handling.
- `../codebase-memory-mcp/SKILL.md` (`codebase-memory-mcp`) - Codebase Memory structural code graph, lifecycle, preparation, and graph query usage.
