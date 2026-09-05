# Free MCPs Installation & Management Guide

## Overview

This guide details the controlled installation, inspection, and rollback helper for **codebase-memory-mcp (CBM)** and **Context7** on Windows under a **100% free tier** policy:
- **Zero billing credentials**: no API keys, tokens, auth headers, credit cards, paid plans, or overages.
- **No OAuth / no ctx7 setup**: purely unauthenticated remote endpoint for Context7.
- **Explicit pinning**: pinned strictly to CBM **v0.10.8** (no `@latest`, no unpinned updates).
- **Direct binary deployment**: unpacks binary without executing upstream hooks, instructions, or global agent modifications.
- **Safe zip extraction**: enforces path traversal protection (Zip Slip) and file allowlists.
- **Explicit native state root**: configures short native per-user state root (`-StateRoot`, default `~/.cbm-state` outside AppData) to guarantee reliable runtime without path length or virtualization issues.
- **Identical absolute env persistence**: persists absolute `CBM_CACHE_DIR` and `CBM_RUNTIME_DIR` identically in both Codex TOML (`[mcp_servers.codebase-memory-mcp.env]`) and Gemini JSON (`mcpServers.codebase-memory-mcp.env`).
- **Privacy & project scoping**: does NOT set `CBM_ALLOWED_ROOT` to proof fixture or entire drive; preserves upstream project selection and privacy policy.
- **Root safety checks**: rejects broad filesystem roots (`C:\`), system directories, user profile home root directly, reparse points (junctions/symlinks), and overlapping roots before any writes.
- **Preflight & transactional install**: preflights BOTH Codex and Gemini configurations before any download, extraction, or write; prepares in-memory merges and executes transactional rollback on write failure.
- **Strict binary verification**: `-SkipBinaryDownload` requires the binary to already exist at the destination and verifies its SHA-256 against the pinned digest (no bypass).
- **Idempotent reinstall & receipt verification**: verifies exact environment paths against manifest receipt; clean reruns report `AlreadyInstalled` without overwriting backups or binaries.
- **Fail-closed rollback on drift**: if target configurations or environment paths have been edited after installation, rollback aborts before making ANY modifications.
- **Zero state deletion on rollback**: preserves all state root directories, logs, caches, and pre-existing graph database indexes on rollback; restores only registration and removes installed binary, backups, and manifest receipt.
- **Inspect disclosures**: read-only inspect reports observed root configuration and notes that inspect mode does not guarantee runtime execution; reports Context7 billing as unproven anonymous intent.
- **Pure JSON output**: CLI `-Json` outputs pure parseable JSON without console text pollution.
- **Non-disruptive**: inspect mode is strictly read-only; no Antigravity process restarts.

---

## Pinned Metadata & Official Sources

Primary sources:
- Release v0.10.8: `https://github.com/DeusData/codebase-memory-mcp/releases/tag/v0.10.8`
- Upstream installer: `https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/v0.10.8/install.ps1`
- Context7 plans & public docs: `https://context7.com/plans`

### Official Hashes (SHA-256)

| Target Architecture | Asset Name | Archive SHA-256 | Extracted Binary SHA-256 |
|---|---|---|---|
| **Windows amd64** (`x86_64`) | `codebase-memory-mcp-windows-amd64.zip` | `b43ad982994c4d829670749e08d3b622a74bb20041fc0a7d02bef6113f81c34d` | `b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6` |
| **Windows arm64** (`aarch64`) | `codebase-memory-mcp-windows-arm64.zip` | `254b26e819f00bab7f430c5f809d37d22b07bb3eb6427e290e5a27ba5b8e983e` | `67b0341ee62f07f850d3954e4f387855f90ea8c6c4b7ed41b8a62d61344373a4` |

Archive entry allowlist:
- `codebase-memory-mcp.exe`
- `LICENSE`
- `install.ps1`
- `THIRD_PARTY_NOTICES.md`

### Context7 Remote Endpoint

- **Endpoint**: `https://mcp.context7.com/mcp`
- **Protocol**: Remote HTTP (SSE / Streamable JSON-RPC)
- **Billing**: Unproven anonymous intent (OAuth unknown; no cache checks).
- **Enforcement**: If rate limited (HTTP 429), stop requests and consult local or primary official documentation; zero billing keys or paid fallback.

---

## Configuration Merge Contracts

### 1. Codex CLI (`$CODEX_HOME\config.toml`)

Adds MCP server definitions and explicit short native state environment variables while preserving existing settings, comments, and other registered servers (`codegraph`, `serena`, `node_repl`, etc.):

```toml
[mcp_servers.codebase-memory-mcp]
command = 'C:\Users\<user>\AppData\Local\Programs\codebase-memory-mcp\codebase-memory-mcp.exe'
args = []

[mcp_servers.codebase-memory-mcp.env]
CBM_CACHE_DIR = 'C:\Users\<user>\.cbm-state\cache'
CBM_RUNTIME_DIR = 'C:\Users\<user>\.cbm-state\runtime'

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
```

### 2. Antigravity / Gemini CLI (`.gemini\config\mcp_config.json`)

Merges servers into `mcpServers` object with identical absolute environment paths while preserving `codegraph`, `serena`, and all other configured tools:

```json
{
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "C:\\Users\\<user>\\AppData\\Local\\Programs\\codebase-memory-mcp\\codebase-memory-mcp.exe",
      "args": [],
      "env": {
        "CBM_CACHE_DIR": "C:\\Users\\<user>\\.cbm-state\\cache",
        "CBM_RUNTIME_DIR": "C:\\Users\\<user>\\.cbm-state\\runtime"
      }
    },
    "context7": {
      "serverUrl": "https://mcp.context7.com/mcp"
    }
  }
}
```

---

## CLI Interface (`scripts/install-free-mcps.ps1`)

### Parameters

- `-Mode`: `Inspect` (default), `Install`, or `Rollback`.
- `-CodexHome`: Path to Codex configuration directory (default: `$env:CODEX_HOME` or `~/.codex`).
- `-AntigravityHome`: Path to Antigravity/Gemini configuration directory (default: `$env:ANTIGRAVITY_HOME` or `~/.gemini`).
- `-InstallRoot`: Target binary directory (default: `$env:LOCALAPPDATA\Programs\codebase-memory-mcp`).
- `-StateRoot`: Short native per-user state root directory (default: `~/.cbm-state` outside AppData; never user home root).
- `-OfflineArchive`: Path to pre-downloaded zip file for offline/fixture verification.
- `-ManifestPath`: Path to manifest file (default: `$InstallRoot\free-mcps-manifest.json`).
- `-SkipBinaryDownload`: Requires pre-existing binary at destination and validates expected SHA256.
- `-ExpectedBinarySha`: Overrides expected binary SHA256 (used in testing).
- `-Json`: Returns pure output formatted as JSON.

### Modes

#### 1. Inspect (Strictly Read-Only)
Performs non-mutating status checks on binary presence, hash verification, configuration registrations, observed state roots, and manifest existence:
```powershell
pwsh -File scripts/install-free-mcps.ps1 -Mode Inspect
# or with JSON output:
pwsh -File scripts/install-free-mcps.ps1 -Mode Inspect -Json
```

#### 2. Install (Controlled Execution)
Preflights both configurations, verifies root safety (rejecting broad roots, user home root, reparse points, and overlaps), verifies SHA256 digests, validates zip paths against traversal, creates unique backups, merges server entries and state environments transactionally, and writes `free-mcps-manifest.json`:
```powershell
pwsh -File scripts/install-free-mcps.ps1 -Mode Install -StateRoot "C:\Users\<user>\.cbm-state"
```

#### 3. Rollback (Fail-Closed & Safe)
Validates manifest bounds, verifies backup SHA256 integrity, checks for target configuration drift across both targets and env paths, and restores exact pre-install backups only when no drift occurred. Preserves state directories, database indexes, and state data completely (zero state deletion):
```powershell
pwsh -File scripts/install-free-mcps.ps1 -Mode Rollback
```

---

## Verification & Unit Testing

The test suite is located at `scripts/tests/free-mcps-installer.Tests.ps1` and contains 37 deterministic unit tests:
1. Module availability and exports.
2. Metadata pinning (v0.10.8, official digests, no `@latest`).
3. Negative: archive checksum mismatch handling.
4. Negative: zip path traversal (`..` Zip Slip) handling.
5. Negative: zip absolute path traversal (`/` or `:`) handling.
6. Negative: binary checksum mismatch inside archive.
7. Configuration preservation: Codex `config.toml`.
8. Configuration preservation: Gemini `mcp_config.json`.
9. Negative: Context7 auth detection in Gemini JSON (blocks without secret leak).
10. Negative: Context7 auth detection in Codex TOML (blocks without secret leak).
11. Negative: SkipBinaryDownload with absent binary throws.
12. Negative: SkipBinaryDownload with bad binary hash throws.
13. Negative: Config auth in second config (Gemini) blocks before first config (Codex) is modified.
14. Reinstall: Idempotent run preserves original manifest and backups.
15. Negative: Rollback drift in Codex config fails closed before modifying Gemini.
16. Negative: Rollback drift in Gemini config fails closed before modifying Codex.
17. Negative: Rollback with tampered backup fails closed without mutating targets.
18. Positive: Clean rollback restores exact original configs and cleans up binary and manifest.
19. Readonly: Inspect mode creates zero filesystem mutations and reports unproven billing.
20. CLI: -Json outputs pure parseable JSON without polluting objects.
21. Negative: Outside-bound backup matching filename pattern fails closed and preserves backups.
22. Negative: Reparse point in target/backup directory fails closed before mutation.
23. Negative: Manifest receipt write failure rolls back configs without leaving unreceipted state.
24. Negative: Drift with block headers rejects fake AlreadyInstalled and preserves backups.
25. Negative: Public CLI ExpectedBinarySha override is blocked without test authorization.
26. State Root: Absolute `CBM_CACHE_DIR` and `CBM_RUNTIME_DIR` persisted identically in TOML and JSON without allowed-root.
27. Quote Escaping: Paths with quotes properly escaped in TOML and roundtrip in JSON.
28. Negative: StateRoot rejected if pointing directly to UserProfile root.
29. Negative: StateRoot rejected if filesystem drive root.
30. Negative: StateRoot rejected if overlapping with CodexHome or InstallRoot.
31. Negative: Reparse point in StateRoot rejected before writes.
32. Idempotence and Drift: Second run succeeds; env path drift fails closed.
33. Rollback: Preserves state root, pre-existing indexes, and data (zero state deletion).
34. Inspect: Reports observed root configuration and runtime execution non-guarantee.

Run tests:
```powershell
pwsh -File scripts/tests/free-mcps-installer.Tests.ps1
```
