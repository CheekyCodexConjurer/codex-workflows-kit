# Free MCPs Runtime Verification Harness Guide

## Overview

The runtime harness (`scripts/tests/free-mcps-runtime.mjs`) is a **pure Node.js built-ins** verification tool for **codebase-memory-mcp (CBM) v0.10.8** and MCP stdio JSON-RPC 2.0 protocol implementations:
- **Zero npm dependencies**: runs directly with native Node.js (`node:child_process`, `node:fs`, `node:crypto`, `node:path`, `node:os`).
- **Deterministic Mock Self-Test (`--self-test`)**: tests framing, parsing, error codes, bounded transport timeouts, concurrency demuxing, freshness, exclusions, and lifecycle without network or binary. Includes consolidated negative regression tests for path validation, fixture collision, binary hash pinning, and tool error handling.
- **Real Binary Integration (`--binary <path>`)**: performs end-to-end MCP validation against the verified CBM v0.10.8 binary in a strictly isolated environment validated before any `mkdir` or write.
- **Strict Process Ownership**: manages only the exact child process PID spawned for the test; never runs global kills (`taskkill`, `killall`, `Stop-Process`), never touches host profiles/auth/cookies/cache, and reports observed remaining processes truthfully without fake clean guarantees.
- **Compact Sanitized Telemetry**: reports only version strings, SHA-256 hashes, test status names, latencies, and PID metadata; zero proprietary source code or private secrets.

---

## Operating Modes

### 1. Deterministic Self-Test Mode (`--self-test`)

Runs a 21-point deterministic mock verification and negative regression suite without external network calls or binary dependencies:

```bash
# Human-readable output:
node scripts/tests/free-mcps-runtime.mjs --self-test

# Compact JSON output:
node scripts/tests/free-mcps-runtime.mjs --self-test --json
```

#### Self-Test Verification Gates:
1. `framing_content_length_roundtrip`: verifies encoding/decoding of MCP Content-Length framed packets (`Content-Length: <n>\r\n\r\n<json>`).
2. `framing_newline_roundtrip`: verifies encoding/decoding of newline-delimited JSON-RPC packets (`<json>\n`).
3. `handshake_and_notification`: validates `initialize` protocol negotiation (`protocolVersion: "2024-11-05"`) and `notifications/initialized`.
4. `tool_discovery`: verifies `tools/list` advertises `index_repository` and `search_graph`.
5. `protocol_error_handling`: confirms JSON-RPC `-32601` (`Method not found`) is returned for invalid methods.
6. `bounded_transport_timeout`: validates bounded transport timeout triggers (`TRANSPORT_TIMEOUT`) when an operation stalls, without hanging the process.
7. `concurrency_demuxing`: dispatches two concurrent queries in parallel and asserts responses are correctly matched to request IDs without cross-talk.
8. `fixture_mutation_and_freshness`: generates a JS fixture, computes initial SHA-256, mutates the fixture, proves SHA-256 changed, and asserts the new symbol is indexed with strict `isError` checks.
9. `exclusions_protection_gitignore`: verifies exact unindented `.gitignore` patterns exclude private files from graph indexing, enforcing positive coverage before negative absence.
10. `exclusions_protection_cbmignore`: verifies exact unindented `.cbmignore` root patterns exclude private files from graph indexing, enforcing positive coverage before negative absence.
11. `process_ownership_clean_exit`: tracks child PID, closes stdio, and verifies actual exit via process polling without global kill.
12. `negative_path_bounds_and_overlap_rejection`: proves directory validator rejects overlapping roots, system drive roots, user home roots, and non-empty existing directories before any `mkdir`.
13. `negative_existing_fixture_no_overwrite`: proves existing fixture directories are never overwritten.
14. `negative_binary_hash_pin_mismatch`: proves invalid or unverified binary hashes are rejected before execute.
15. `negative_tool_error_isError_detection`: proves tool calls returning `isError: true` throw errors and prevent false-green passes on failed searches.
16. `negative_version_empty_output_unknown`: proves version subprocess returns `unknown` rather than fabricating `v0.10.8` when output is empty.
17. `negative_client_stderr_capture_on_exit`: proves `McpStdioClient` captures bounded sanitized stderr on unexpected process exit and includes it in request rejection.
18. `negative_fail_fast_prerequisite_skipping`: proves prerequisite failures fail-fast by skipping dependent tests and preserving fixtures without mutation.
19. `negative_process_ownership_unobserved_daemon_truth`: proves `daemonPid: null` accurately reports unobserved rather than fabricating verified clean daemon lifecycle.
20. `regression_strict_ndjson_reader_framing`: proves that framing defaults to `newline` (NDJSON) as expected by upstream readers, verifying RED rejection of Content-Length framing against strict readers and GREEN pass under newline framing.
21. `regression_report_file_persistence_and_diagnostics`: proves that diagnostic directory snapshots and `--report-file` machine-readable output persist correctly.
22. `regression_retained_worker_log_bounded_retention`: proves that worker logs are detected and bounded to 8KB without retaining unbounded raw data.
23. `regression_project_naming_safe_canonical_root_hash_uniqueness`: proves that derived project names are deterministic, unique, <= 32 characters, and properly mapped to tool schemas.
24. `regression_delayed_daemon_shutdown_vs_wrong_immediate_clean_claim`: proves that delayed daemon shutdown (within bounded grace) is waited on and detected rather than falsely flagged as leaked, and proves that a process that never exits past bounded grace is never given a fake clean claim.

---

## Path Isolation & Validation Contract

Before executing any binary or creating any directories (`mkdir`), the harness validates all paths against the following contract:
1. **Validation Before Mkdir**: `validateIsolatedDirectories` resolves canonical paths and validates bounds before any directory is created.
2. **Reparse & Canonical Ancestor Checks**: Resolves native symlinks, junctions, and reparse points up through existing ancestor directories.
3. **Mutual Disjointness**: `--work-dir`, `--cache-dir`, and `--runtime-dir` must be mutually disjoint (neither identical nor subdirectories of one another).
4. **Root & Home Protection**: Paths must not be filesystem drive roots (e.g. `C:\`), Windows system directories (`SystemRoot`, `ProgramFiles`), the user home root (`~`), or sensitive user directories (`.gemini`, `.codex`, `.ssh`).
5. **Repository Protection**: Paths must not be inside or contain the repository/worktree root.
6. **New/Empty Root Requirement**: If an isolated root already exists, it must be empty (`readdir.length === 0`).
7. **Fixture Overwrite Protection**: Existing fixture directories (`runtime-fixture`) are never overwritten.

---

## Environment Isolation Contract

The harness configures the spawned process with strictly isolated paths and verifies environment variable support against pinned upstream v0.10.8:

| Variable | Upstream Status | Purpose / Behavior |
|---|---|---|
| `CBM_CACHE_DIR` | Supported upstream | Directs SQLite database, graph persistence, and logs (`cbm-daemon.log`) away from `%LOCALAPPDATA%` / `~/.cache`. |
| `CBM_RUNTIME_DIR` | Supported upstream | Relocates rendezvous IPC endpoint, sockets, named pipes, and coordinator locks. |
| `CBM_ALLOWED_ROOT` | Supported upstream | Enforces containment boundary; upstream refuses any indexing requests resolving outside this root. |
| `CBM_AUTO_INDEX` | **Not supported upstream** | Unsupported in v0.10.8; unsupported envs do nothing. Upstream indexing is client-triggered. |
| `CBM_AUTO_WATCH` | **Not supported upstream** | Unsupported in v0.10.8; unsupported envs do nothing. Upstream watcher operates via internal Git-poll/HEAD logic. |

---

## Binary Hash Pin & Version Verification

Before executing the binary:
1. **Hash Pin Verification**: Computes the SHA-256 digest of the target binary and verifies it matches the official pinned release v0.10.8 digest:
   - `amd64` / `x64`: `b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6`
   - `arm64`: `67b0341ee62f07f850d3954e4f387855f90ea8c6c4b7ed41b8a62d61344373a4`
2. **Isolated Version Subprocess**: Runs `--version` within an isolated environment and runtime directory. Empty or failing outputs return `unknown` (no fabricated `v0.10.8`).

---

## Tool Parameter Mapping (`tools/list`)

When invoking MCP tools:
- The harness dynamically inspects `tools/list` `inputSchema` properties and required fields.
- Maps `path` vs. `repo_path` and `project` based on the advertised schema rather than assuming hardcoded argument names.
- Enforces parsed successful results and positive coverage (confirming a known symbol exists) before asserting negative absence on excluded symbols.

---

## Process Ownership & Cleanup Protocol

1. **Exact PID Tracking**: Records `child.pid` upon spawning.
2. **Bounded Stderr Capture**: Captures sanitized bounded stderr lines (stripping ANSI escapes, truncating long lines) so that premature process closures retain exact error causes instead of losing diagnostics.
3. **Fail-Fast Prerequisites**: When a prerequisite fails (such as `initialize`), dependent tests are marked as `skipped` rather than cascading false errors against a closed client, and test fixtures are never mutated after failure.
4. **Daemon Observability & Bounded Grace Exit**: Distinguishes between observed daemon PIDs and unobserved states (`daemonPid: null`), truthfully reporting `unobserved` rather than fabricating clean daemon guarantees. When a daemon is observed, the harness executes an immediate check upon client closure and waits a bounded grace period (default 5000ms, `--daemon-grace-ms`) for the daemon to complete its graceful stop sequence (`msg=daemon.stop`).
5. **Graceful Stdio Shutdown**: Sends `child.stdin.end()` followed by bounded grace timeout (1200ms grace, SIGTERM, 400ms SIGKILL on the test child only).
6. **Zero Global Kills**: Never executes `taskkill /F /IM ...`, `killall`, or `Stop-Process`.
7. **Real Liveness Verification & Timestamped Later Check**: Probes `isProcessAlive(pid)` using signal 0. Reports initial liveness at client exit and a timestamped later check separately in `processOwnership.laterCheck`, verifying exact PID quiescence without fake clean claims.

---

## CLI Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--self-test` | Flag | `false` | Runs deterministic mock self-test suite (24 tests). |
| `--binary <path>` | String | `null` | Path to `codebase-memory-mcp` binary. |
| `--work-dir <path>` | String | Auto-temp | Root directory where test fixtures are generated. |
| `--cache-dir <path>` | String | Auto-temp | Explicit directory for `CBM_CACHE_DIR`. |
| `--runtime-dir <path>` | String | Auto-temp | Explicit directory for `CBM_RUNTIME_DIR`. |
| `--allowed-root <path>`| String | `work-dir` | Explicit boundary for `CBM_ALLOWED_ROOT`. |
| `--expected-sha256 <hex>` | String | `null` | Optional override for binary SHA-256 verification. |
| `--report-file <path>` | String | `null` | Path to persist complete sanitized JSON diagnostic report. |
| `--timeout-ms <n>` | Integer | `5000` | Bounded transport timeout in milliseconds. |
| `--daemon-grace-ms <n>`| Integer | `5000` | Bounded grace period in milliseconds to wait for background daemon exit. |
| `--json` | Flag | `false` | Outputs compact, machine-readable JSON report. |

---

## Known Upstream Limitations & Considerations

1. **Windows Long Paths**: SQLite and rendezvous socket paths must be within Windows `MAX_PATH` limits unless long path support is enabled. The harness normalizes paths and resolves canonical paths.
2. **Admission Barrier**: CBM prevents conflicting instances from running under different builds or incompatible cache directories simultaneously. The isolated `CBM_RUNTIME_DIR` and `CBM_CACHE_DIR` ensure integration tests never collide with pre-existing host sessions.
3. **Daemon Persistence**: On Windows, the coordinator daemon may persist after the MCP stdio frontend exits. The harness monitors observed PIDs, reports real process liveness, and avoids destructive global kills.
4. **Unsupported Environment Variables**: `CBM_AUTO_INDEX` and `CBM_AUTO_WATCH` are not present in CBM v0.10.8; setting them has no effect on upstream behavior.
5. **Windows NTFS Ancestor DACL Validation (`cache-private` / `executable-path`)**: Upstream CBM v0.10.8 enforces strict Windows named-pipe IPC rendezvous security by inspecting DACLs on all ancestor directories of `CBM_CACHE_DIR`, `CBM_RUNTIME_DIR`, and the executable path. If any ancestor directory (such as a secondary drive root or data folder like `E:\CodexData`) has inherited ACEs granting mutation rights (`0x00010112`) to untrusted identities such as `Authenticated Users` (`S-1-5-11`), `BUILTIN\Users`, or `Everyone`, CBM aborts immediately with code 1 (`codebase-memory-mcp: exact executable identity could not be verified (cache-private) ... DACL entry N grants mutation rights 0x00010112 to untrusted identity (Authenticated Users S-1-5-11)`). There is no upstream configuration or environment variable in v0.10.8 to bypass this security check. Without modifying parent folder host permissions (which would affect host security) or relocating the host root to a private user profile directory, this constitutes an upstream structural limitation on drives with default Windows NTFS permissions.
6. **Transport Framing (NDJSON)**: CBM v0.10.8 stdio communication follows newline-delimited JSON (NDJSON / `\n`). Sending or expecting HTTP/LSP-style `Content-Length: ...\r\n\r\n` headers triggers `TRANSPORT_TIMEOUT` (5000ms) on clients expecting Content-Length because CBM v0.10.8 does not emit Content-Length headers. Separately, byte-stream decoders should handle possible CRLF or repeated carriage returns (`\r\r\n`), though attributing specific sequences to Windows text-mode stdio translation remains speculative rather than an established protocol property. The harness defaults to `newline` framing and tolerates CR stripping to maintain reliable transport decoding.
7. **Index Mutation Lock Contention (`index operation blocked by another mutation for this project`)**: When calling `index_repository`, the observed generic error is `Tool "index_repository" returned isError=true: index operation blocked by another mutation for this project`. Upstream source inspection indicates this generic error string follows `mutation_begin` returning false (which can occur on lock acquisition errors or active mutation flags, rather than establishing proven competing ownership). Pinned v0.10.8 configuration defaults `auto_index = false` (proven via read-only `config list`). The harness fail-fast prerequisite gate detects this observed error and skips dependent downstream tests (`search_graph`, `exclusions_protection`, `freshness_mutation`, `concurrency`), preserving fixture integrity.
8. **Git Root Traversal & Windows AppData Redirection**: CBM invokes `git -C <repo_path> rev-parse --show-toplevel`. If a test fixture lacks an initialized Git repository, `git` traverses parent directories, which on Windows can collide with MSIX/App virtualization paths (e.g. `E:\WpSystem`). The harness initializes a standalone Git repository with an initial commit directly in the fixture root to bound Git resolution.

9. **Daemon PID Logfmt Format & Strict Process Ownership**: CBM daemon logs emit events using logfmt key-value pairs (`level=info msg=daemon.start version=0.10.8 pid=65680 ...`). The harness parses exact daemon PIDs via `parseDaemonPidFromLog`, avoiding regex mismatches on `=` and maintaining exact process ownership records (`daemonObserved: true`, exact PID tracking, distinguishing clean exit from active background daemons).
10. **Bounded Path-Safe Report Persistence**: The `--report-file` option enforces strict bounds via `validateReportFilePath`: it refuses to overwrite existing files, forbids writes to system drive roots, system directories, user profile roots, and sensitive directories (`.ssh`, `.aws`, `.git`, `.codex`, `.gemini`), and optionally validates containment within an allowed root.
11. **Supervisor Worker Log Lifecycle & Diagnostic Retention**:
    - **Source Lifecycle (`src/mcp/index_supervisor.c`)**: During supervised indexing (`index_run_supervised`), the supervisor creates a temporary worker log file via `worker_unique_file(handle->log_path, sizeof(handle->log_path), "log")` at `$CBM_CACHE_DIR/logs/.worker-log-XXXXXX` and spawns the child worker process (`--index-worker`) with stdout/stderr redirected to this file (`options.log_file = handle->log_path; options.delete_log_on_exit = false`).
    - **Clean Exit Log Deletion**: When the worker completes in `src/main.c`, it writes its JSON result to `invocation.response_out` (`handle->response_path`). Because the write succeeds, `worker_response_written` is true, so the worker terminates via `_Exit(0)` regardless of whether the result is an MCP tool error (`isError: true`). The supervisor polls the child, records `index.supervisor.reap outcome=clean exit_code=0 signal=0` in `cbm-daemon.log`, and in `worker_terminal_log` invokes `(void)cbm_unlink(handle->log_path)` whenever `outcome == CBM_PROC_CLEAN && !cbm_profile_active`. Consequently, on any clean worker exit under default configuration, the supervisor deletes the physical worker log file from disk.
    - **Supported Log Retention Seam**: When performance profiling is enabled via `CBM_PROFILE=1` (`cbm_profile_active = true`), the unlinking branch is bypassed, the supervisor emits `level=info msg=index.supervisor.profile_log log=<path>`, and the worker log is preserved on disk for inspection.
    - **Observation vs. Inference**:
      - *Default Unprofiled Baseline (`cycle1-lock`)*: In unprofiled probe runs (persisted report: `C:/Users/mathe/AppData/Local/FreeMcpProof-20260905/cycle1-lock-work/cycle1-lock-diagnostic-report.json`), `cycle1-lock-cache/logs` contained only `cbm-daemon.log` with `outcome=clean exit_code=0 signal=0`. No `.worker-log-*` files remained because `worker_terminal_log` unlinked them on clean exit when profiling was inactive (`!cbm_profile_active`).
      - *Isolated Profiling Probe (`profile1` with `CBM_PROFILE=1`)*: In the authorized isolated probe (persisted report: `C:/Users/mathe/AppData/Local/FreeMcpProof-20260905/profile1-work/profile1-diagnostic-report.json`), `CBM_PROFILE=1` was confirmed supported via `src/foundation/profile.c` (`cbm_profile_init` parsing `getenv("CBM_PROFILE")`). With profiling active, the supervisor bypassed unlinking, logged `level=info msg=index.supervisor.profile_log log=.../.worker-log-a64312` in `cbm-daemon.log`, and retained the physical log file `.worker-log-a64312` (1494 bytes) on disk under `profile1-cache/logs`.
      - *Concrete Worker Diagnostics & Branch Classification*:
        - *Observed Worker Event*: `.worker-log-a64312` captured `level=error msg=cli.project_lock_failed project=E-WpSystem-S-1-5-21-2562703562-1658950967-1640246537-1001-AppData-Local-Packages-OpenAI.Codex_2p2nqsd0c76g0-LocalCache-Local-FreeMcpProof-20260905-profile1-work-runtime-fixture action=refuse_mutation` followed by `index operation blocked by another mutation for this project` and `index.worker.fast_exit action=_Exit`.
        - *Source Branch Identification*: In `src/main.c`, `main_local_cli_mutation_begin_internal` executes `status = cbm_project_lock_acquire(mutation->manager, project, deadline, NULL, &lease)`. The log proves the branch `status != CBM_PRIVATE_FILE_LOCK_BUSY` was taken.
        - *Observed Fact vs. Inference*: The failure is definitively an acquisition/creation error (`status != BUSY`), NOT contention with an active lock holder (`BUSY`). There was no competing mutation process. In `profile1`, the project path key was derived from the fixture path with a measured length of 176 characters (previously estimated as 145 chars).
        - *Process Quiescence*: Both client PID (25572) and worker PID (35544) exited cleanly. Daemon PID (56132) logged `reason=runtime_exited`, `daemon.stop`, and terminated. Zero orphaned processes remain.
      - *Discriminating Short Project Key Probe (`shortkey1` with explicit `--name` / `"name"`)*:
        - *Discriminating Test Context*: Verified from inputSchema and CLI help (`codebase-memory-mcp cli index_repository --help`) that `index_repository` accepts explicit project name override via `--name` / `"name"`. The harness was updated with `deriveProjectName` providing collision-safe canonical root hash uniqueness (`runtime-fixture-154db219`, measured length: 24 characters).
        - *Execution & Environment*: Fresh isolated roots (`shortkey1-work`, `shortkey1-cache`, `shortkey1-runtime`) with exact same physical path class and runtime length under `C:/Users/mathe/AppData/Local/FreeMcpProof-20260905/`, verified binary hash `b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6`, profile active (`CBM_PROFILE=1`).
        - *Retained Diagnostics*: Supervisor retained `.worker-log-a49168` (1382 bytes) under `shortkey1-cache/logs/`. The worker confirmed input args `{"name":"runtime-fixture-154db219", ...}` and emitted `level=error msg=cli.project_lock_failed project=runtime-fixture-154db219 action=refuse_mutation` followed by `index operation blocked by another mutation for this project` and `index.worker.fast_exit action=_Exit`.
        - *Hypothesis Progress & Boundaries*: Shortening the project key (`name`) from 176 characters to 24 characters only weakened the project *key* length hypothesis; it did NOT vary total runtime path length (which remained ~170+ characters under virtualized AppData) or filesystem virtualization. The prior inference that path length was disproven or that an upstream binary fix was required was unsupported.
        - *Process Quiescence*: Worker PID (55200) exited cleanly (`_Exit`). Daemon PID (24720) logged `daemon.lifetime_end reason=runtime_exited`, `daemon.stop`, and terminated cleanly. Process table confirmed zero orphan processes. Report persisted to `shortkey1-diagnostic-report.json`.
      - *Discriminating Native User Profile Storage Probe (`CBMProof20260905` in `C:/Users/mathe/CBMProof20260905/{w,c,r}`)*:
        - *Discriminating Test Context*: Authorized bounded experiment varying environment location class as a single environment factor: fresh short user profile directory tree `C:/Users/mathe/CBMProof20260905/{w,c,r}`, verified non-MSIX user profile storage (realpaths confirmed disjoint child directories under user home, outside AppData package virtualization). Unmodified pinned binary (`b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6`), same short project name algorithm (`deriveProjectName`), same profiling seam (`CBM_PROFILE=1`).
        - *Execution & Outcomes*: Complete 7/7 tests passed:
          1. `real_binary_initialize` (PASS, 4240ms)
          2. `real_binary_tool_discovery` (PASS, 44ms, 15 advertised tools)
          3. `real_binary_index_repository` (PASS, 3312ms, indexed 5 nodes, 4 edges)
          4. `real_binary_search_graph` (PASS, 30ms, structural function lookup)
          5. `real_binary_exclusions_protection` (PASS, 61ms, positive coverage and exclusions for .gitignore & .cbmignore verified)
          6. `real_binary_freshness_mutation` (PASS, 3576ms, incremental re-index verified with fresh symbol)
          7. `real_binary_concurrency` (PASS, 19ms, concurrent search queries demuxed correctly)
        - *Retained Diagnostics & Worker Logs*: Supervisor retained `.worker-log-a42520` (7540 bytes, initial full indexing pipeline) and `.worker-log-a46616` (9710 bytes, incremental freshness pipeline) under `C:/Users/mathe/CBMProof20260905/c/logs/`. Diagnostic report persisted to `C:/Users/mathe/CBMProof20260905/w/native-storage-diagnostic-report.json`.
        - *Process Quiescence*: Both worker executions and client exited cleanly. Daemon PID 39736 logged clean termination (`daemon.lifetime_end reason=runtime_exited`, `daemon.stop`) and terminated cleanly. Zero orphan processes remain.
        - *Hypothesis Progress & Conclusions*:
          1. *Upstream Binary Fix Claim Falsified*: The hypothesis that codebase-memory-mcp v0.10.8 requires an upstream binary fix on Windows is falsified; it functions completely under native user profile storage.
          2. *Location Class Discrimination*: Native user profile storage successfully resolves the lock acquisition failure and validates all MCP gates.
          3. *Isolation Boundary*: Because this experiment varied environment location class (non-MSIX user profile storage) and total path length together as one factor, it does not claim isolation of total path length versus MSIX virtualization (subsequent isolation optional).
      - *Discriminating Independent Confirmation Probe (`confirm-{w,c,r}` in `C:/Users/mathe/CBMProof20260905/confirm-{w,c,r}` with Profiling OFF)*:
        - *Discriminating Test Context*: Independent confirmation in fresh, mutually disjoint directories `confirm-{w,c,r}` under native user profile storage (`C:/Users/mathe/CBMProof20260905/`), using the SAME pinned binary (`b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6`, v0.10.8) with profiling OFF (`CBM_PROFILE` inactive, default production setting).
        - *Profiling OFF Evidence*: With profiling disabled, the supervisor invokes `(void)cbm_unlink(handle->log_path)` upon clean worker exit (`outcome == CBM_PROC_CLEAN && !cbm_profile_active`). Consequently, zero `.worker-log-*` files were retained, proving retained log profiling is NOT required for successful operation.
        - *Execution & Outcomes*: All 7/7 real binary integration tests passed:
          1. `real_binary_initialize` (PASS, 4239ms)
          2. `real_binary_tool_discovery` (PASS, 37ms, 15 advertised tools)
          3. `real_binary_index_repository` (PASS, 3268ms, indexed 5 nodes, 4 edges)
          4. `real_binary_search_graph` (PASS, 15ms, structural function lookup)
          5. `real_binary_exclusions_protection` (PASS, 64ms, positive coverage and exclusions for .gitignore & .cbmignore verified)
          6. `real_binary_freshness_mutation` (PASS, 3279ms, incremental re-index verified with fresh symbol)
          7. `real_binary_concurrency` (PASS, 32ms, concurrent search queries demuxed correctly)
          Total test duration: 13070ms.
        - *Runtime Evidence Lifecycle & Exact PID Quiescence*:
          - Child PID 39480 cleanly exited upon client stdio close.
          - Daemon PID 62904 was observed via `cbm-daemon.log`.
          - *Initial Check* (`2026-09-05T21:48:44.265Z`): Daemon was still running during client disconnect / shutdown transition.
          - *Bounded Grace Verification*: Harness waited bounded grace for exact observed daemon exit (elapsed grace: 363ms; limit: 5000ms).
          - *Later Check* (`2026-09-05T21:48:44.629Z`): Probed PID 62904, confirming exit (`daemonAlive: false`, `quiescenceAchieved: true`).
          - Zero remaining processes (`remainingProcesses: []`, `cleanedCleanly: true`, `globalKillUsed: false`).
          - Report persisted at `C:/Users/mathe/CBMProof20260905/confirm-w/confirm-storage-diagnostic-report.json`.
        - *Runtime Readiness Criteria*:
          1. *Native Short Directory Paths*: Direct user profile directories (`C:/Users/mathe/...`) outside AppData package virtualization.
          2. *Mutual Disjointness*: Strict isolation where `workDir`, `cacheDir`, and `runtimeDir` are mutually disjoint.
          3. *Short Project Key Derivation*: Canonical hashing (`deriveProjectName`) producing identifiers <= 32 chars to prevent MAX_PATH overflow in rendezvous socket and lock file paths.
          4. *Honest Quiescence Lifecycle*: Bounded grace verification capturing both initial closure and timestamped post-grace exit, avoiding false leakage claims without fabricating clean status.
          5. *Production Profiling Independence*: Full functionality verified with profiling OFF.
          6. *Scope Boundary*: Proof established in controlled native environment; does not claim isolation of total path length versus virtualization or arbitrary consumer repository validation. No global install yet.

---

## JSON Output Schema

When invoked with `--json`, the harness prints a sanitized JSON payload:

```json
{
  "suite": "free-mcps-runtime",
  "mode": "self-test",
  "status": "passed",
  "summary": {
    "total": 21,
    "passed": 21,
    "failed": 0
  },
  "fixture": {
    "hashBefore": "6f250525b4b951ba942982528efbc8ce72132f682380255f95b58536358d92b0",
    "hashAfter": "d9481199d16424beeaa16394dfeb9b76c2f4c4685dab061b66e0ee5fcd45e37c"
  },
  "concurrency": {
    "supported": true,
    "parallelQueries": 2,
    "demuxedCorrectly": true
  },
  "processOwnership": {
    "childPid": 27752,
    "cleanedCleanly": true,
    "globalKillUsed": false
  },
  "tests": [
    { "name": "framing_content_length_roundtrip", "status": "passed", "durationMs": 66 },
    { "name": "framing_newline_roundtrip", "status": "passed", "durationMs": 63 },
    { "name": "handshake_and_notification", "status": "passed", "durationMs": 63 },
    { "name": "tool_discovery", "status": "passed", "durationMs": 59 },
    { "name": "protocol_error_handling", "status": "passed", "durationMs": 63 },
    { "name": "bounded_transport_timeout", "status": "passed", "durationMs": 367 },
    { "name": "concurrency_demuxing", "status": "passed", "durationMs": 64 },
    { "name": "fixture_mutation_and_freshness", "status": "passed", "durationMs": 67 },
    { "name": "exclusions_protection_gitignore", "status": "passed", "durationMs": 68 },
    { "name": "exclusions_protection_cbmignore", "status": "passed", "durationMs": 66 },
    { "name": "process_ownership_clean_exit", "status": "passed", "durationMs": 57 },
    { "name": "negative_path_bounds_and_overlap_rejection", "status": "passed", "durationMs": 55 },
    { "name": "negative_existing_fixture_no_overwrite", "status": "passed", "durationMs": 2 },
    { "name": "negative_binary_hash_pin_mismatch", "status": "passed", "durationMs": 1 },
    { "name": "negative_tool_error_isError_detection", "status": "passed", "durationMs": 74 },
    { "name": "negative_version_empty_output_unknown", "status": "passed", "durationMs": 2 },
    { "name": "negative_client_stderr_capture_on_exit", "status": "passed", "durationMs": 61 },
    { "name": "negative_fail_fast_prerequisite_skipping", "status": "passed", "durationMs": 71 },
    { "name": "regression_daemon_start_format_and_strict_pid_ownership", "status": "passed", "durationMs": 1 },
    { "name": "regression_strict_ndjson_reader_framing", "status": "passed", "durationMs": 328 },
    { "name": "regression_report_file_bounded_path_safety_and_no_overwrite", "status": "passed", "durationMs": 13 }
  ],
  "totalDurationMs": 1597
}
```

---

## References & Related Skills

- **Canonical Skill Guidance**: [codebase-memory-mcp SKILL.md](../skills/codebase-memory-mcp/SKILL.md)
- **Upstream Supervisor Source**: [index_supervisor.c](https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/46ae198fc11cda80e817acbc5f5908d7c2de7032/src/mcp/index_supervisor.c)
