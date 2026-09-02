---
name: mcp-foundation
description: Use when routing, querying, or maintaining allowlisted MCP tools (Context7, CodeGraph, Serena), inspecting external library/framework documentation, navigating structural code relationships, performing semantic symbol/LSP lookups, or executing read-only MCP doctor diagnostics and safe process checks.
---

# MCP Foundation

Canonical routing, usage constraints, and operational maintenance for allowlisted MCP tools (Context7, CodeGraph, and Serena).

## Routing Matrix

| Tool | Primary Purpose | Prerequisite / Trigger | Operation Contract |
|---|---|---|---|
| Context7 | External library/framework documentation and API references | Version/syntax uncertainty or unfamiliar external API | resolve -> query; atomic query; no secrets |
| CodeGraph | Structural architecture, symbol relationships, and call flow | .codegraph exists in repository root or explicit projectPath | Structural first via codegraph_explore; status -> sync -> recheck; fall back to Serena/rg; never auto-init |
| Serena | Symbol navigation, LSP features, references, diagnostics | Active codebase navigation | --project-from-cwd; one instance per project; read-only config check; safe concurrent reads; strictly no generic taskkill/auto-restart |

## Context7

- Use Context7 for current external library, framework, or API documentation when syntax, version changes, or API semantics matter.
- Always follow the atomic two-phase workflow:
  1. resolve the relevant library ID or package identifier.
  2. query with a focused, atomic question.
- Safety boundary: Never include secrets, API keys, passwords, environment variables, internal tokens, or proprietary source code in query payloads.

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

## Maintenance & Operational Safety

1. Preflight by Mode: All workflow modes execute an MCP maintenance preflight. Read-only modes only verify status. Implementation modes may synchronize CodeGraph when status indicates delay/stale/pending via status -> sync -> recheck, falling back to Serena/rg with a warning on failure/unknown.
2. Doctor is Read-Only: Health checks and diagnostics (scripts/doctor.ps1) inspect registrations, file presence, and SHA256 hashes without modifying configuration files or terminating processes.
3. Mirror Integrity: Managed skill and rule mirrors must match their canonical repository counterparts verified via SHA256 checksums.
4. Serena Shutdown Protocol: A running Serena process may ONLY be stopped upon an explicit human request and after verifying:
   - Process ownership (verifying PID and process owner).
   - Server idleness (no active requests or locks).
   - Zero pending or running jobs across the session.
5. No Unsafe Automation & Antigravity Protection: NEVER automate kill, restart, upgrade, or initialization (auto-init) of MCP servers or background tooling. Never restart, close, login, or logout Antigravity desktop; never touch auth, profile, cookies, or cache.
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
