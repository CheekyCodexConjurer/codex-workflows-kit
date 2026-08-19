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
| CodeGraph | Structural architecture, symbol relationships, and call flow | .codegraph exists in repository root | Structural first; fall back to rg; never auto-init |
| Serena | Symbol navigation, LSP features, references, diagnostics | Active codebase navigation | Safe concurrent reads; strictly no generic taskkill |

## Context7

- Use Context7 for current external library, framework, or API documentation when syntax, version changes, or API semantics matter.
- Always follow the atomic two-phase workflow:
  1. resolve the relevant library ID or package identifier.
  2. query with a focused, atomic question.
- Safety boundary: Never include secrets, API keys, passwords, environment variables, internal tokens, or proprietary source code in query payloads.

## CodeGraph

- Use CodeGraph for structural exploration in medium-to-large codebases to trace module dependencies, architecture, and multi-file call paths before broad file reads.
- Strict existence rule: Use CodeGraph ONLY if .codegraph exists in the repository root.
- If .codegraph is absent, skip CodeGraph immediately. Repository indexing is the user's manual choice; never auto-init, auto-index, or create .codegraph automatically.
- If CodeGraph is unavailable, stale, or returns no hits, fall back cleanly to targeted rg (ripgrep) and focused reads.

## Serena

- Use Serena for semantic symbol inspection, language server (LSP) queries, references, implementations, and diagnostics.
- Safe concurrent read operations are permitted.
- Process lifecycle: Serena runs as a managed MCP server. Never execute generic taskkill, wildcard process terminations, or external kill scripts against it.

## Maintenance & Operational Safety

1. Doctor is Read-Only: Health checks and diagnostics (scripts/doctor.ps1) inspect registrations, file presence, and SHA256 hashes without modifying configuration files or terminating processes.
2. Mirror Integrity: Managed skill and rule mirrors must match their canonical repository counterparts verified via SHA256 checksums.
3. Serena Shutdown Protocol: A running Serena process may ONLY be stopped upon an explicit human request and after verifying:
   - Process ownership (verifying PID and process owner).
   - Server idleness (no active requests or locks).
   - Zero pending or running jobs across the session.
4. No Unsafe Automation: NEVER automate kill, restart, upgrade, or initialization (auto-init) of MCP servers or background tooling.
5. DeepSeek Daemon Restart Exception: A tightly scoped, fail-closed restart exception applies ONLY to the local DeepSeek Sub-Agent daemon when expressly authorized by the current user and executed via canonical `dist/cli.js restart --config <known-config> --json`. All gates must pass: failing GET `/health` probe, verified PID/command/data-dir ownership, zero active/pending jobs in `bridge.sqlite`, and bounded readiness wait. Never trigger on `AntigravityProcessError`, `agy` failures, or HTTP errors alone; never restart Codex, Antigravity, Serena, CodeGraph, Context7, or use generic kill/process commands (`taskkill`, `Stop-Process`).

## References

Open only when safe shutdown verification, daemon recovery gates, or detailed process audits are required:
- references/lifecycle.md - Process ownership, idle verification, DeepSeek daemon restart gates, and mirror audit procedures.
