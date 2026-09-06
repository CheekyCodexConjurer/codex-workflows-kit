# Structured Evidence Packet and Owned-Path Whitespace Validation

## 1. Overview and Purpose

The `DELIVER.AUTO` evidence quality slice establishes verifiable, tamper-evident delivery validation for automated workflows.

Previous workflow iterations were vulnerable to two key failure modes:
1. **Unverified counterfactual claims**: Claims of performance improvements (such as an advertised "12-minute savings") were asserted without empirical baseline measurements or verifiable execution telemetry. Furthermore, command-line flags (such as `--disable-mcp`) were referenced without verifying CLI availability via official tool documentation or `--help`.
2. **Silent defect omission via Git diff check**: Relying solely on `git diff HEAD --check` fails to detect whitespace defects in truly untracked source files in the working directory, as Git diff only examines tracked modifications relative to a commit or staged index entries.

The module `scripts/evidence-packet.psm1` resolves these limitations by providing:
- A reusable owned-path whitespace validator (`Test-OwnedPathWhitespace`) that directly inspects both tracked and untracked files on disk without mutating Git staging state.
- A structured evidence packet generator (`New-EvidencePacket`) that records actual artifacts, SHA256 hashes, commands, and exit codes, dynamically computing counts, distinguishing missing artifacts from pass, rejecting unsafe provenance/secrets, and binding directly to canonical target identities from `scripts/backend-routing.psm1`.

---

## 2. Owned-Path Whitespace Validator (`Test-OwnedPathWhitespace`)

### 2.1 Why `git diff HEAD --check` Is Insufficient

`git diff HEAD --check` evaluates whitespace errors only for changes between the working tree/index and `HEAD`. For newly created, untracked files:
- Git does not track the file in the commit tree.
- `git diff HEAD --check -- <untracked-path>` exits with code `0` and emits no diagnostics.
- Staging the file via `git add` to make Git inspect it mutates the Git index, violating read-only delivery inspection constraints.

### 2.2 Direct Disk Inspection and Reparse Traversal Resolution

`Test-OwnedPathWhitespace` and `Assert-ContainedRepoPath` read disk content directly for every repository-contained path specified in `OwnedPaths`:
- **Tracked and untracked parity**: Inspects disk state regardless of whether the file is tracked, untracked, modified, or staged.
- **Zero staging mutations**: Operates strictly read-only on the working tree without invoking `git add`, `git update-index`, or altering repository metadata.
- **Contained scope enforcement & reparse resolution**: Lexical containment via `[IO.Path]::GetFullPath` is insufficient because Windows directory junctions, symbolic links, or leaf links can create paths that lexically appear within the repository root while physically pointing outside. `Assert-ContainedRepoPath` implements dual-phase validation:
  1. *Lexical boundary check*: Rejects rooted paths, colons, `.` or `..` traversals, and lexical prefix escapes.
  2. *Reparse point resolution*:
     - **Legitimate repo root junctions**: The repository root itself may legitimately be a junction or symbolic link (e.g. Git worktree links or mapped paths). The validator resolves the canonical directory root (`Resolve-CanonicalDirectoryRoot`).
     - **Reparse traversal containment**: All existing path segments and leaf links are traversed using `Resolve-CanonicalReparsePath`. Any junction or symlink resolving outside the canonical repository root is safely rejected (`Path escapes the repository scope via reparse traversal`).
     - **Non-existent leaves under escaped junctions**: If a path specifies a non-existent child under an escaped junction, the parent junction escape is detected and rejected.
- **Inert fixture policy**: Verification tests use isolated, inert synthetic fixtures exclusively, strictly prohibiting any interaction with user authentication files, profiles, or private keys.

### 2.3 Detected Defect Classes

1. `trailing-whitespace`: Spaces or tabs immediately preceding line terminators (`[ \t]+$`).
2. `space-before-tab`: Spaces immediately preceding tab characters in line indentation (`^[ ]+\t`).
3. `blank-at-eof`: Trailing blank lines at the end of the file (`(?:\r?\n){2,}$`).

---

## 3. Structured Evidence Packet Specification

### 3.1 Canonical Identity Binding

Evidence packets are bound to the exact repository state using the canonical target identity generator from `scripts/backend-routing.psm1`:

```powershell
$targetIdentity = Get-CodexDeliveryTargetIdentity -RepoPath $RepoPath -OwnedPaths $OwnedPaths -Baseline $Baseline
```

The returned `TargetId` is a deterministic SHA256 digest of canonical ordered JSON containing:
- Baseline commit SHA (`baseline`).
- HEAD relative change status per file (`head_status`).
- Integrated patch SHA256 (`diff_sha256`).
- Per-file SHA256 hashes (`file_sha256`).

This ensures staging-invariance: staging changes with `git add` does not alter `TargetId`, but any modification to disk content immediately changes `TargetId` and breaks identity verification.

### 3.2 Artifact Verification, Target Drift, and Missing vs Pass Distinction

Every artifact supplied to `New-EvidencePacket` is validated against actual disk state:
- **Missing artifacts**: If an artifact does not exist on disk, its status is explicitly recorded as `Status = 'missing'`, `Exists = $false`, and `Pass = $false`. Missing artifacts never count toward passed artifacts and immediately cause the overall packet status to fail (`Status = 'missing_artifacts'`, `Pass = $false`).
- **Hash drift**: When an `ExpectedSha256` is provided, any mismatch between expected and computed disk SHA256 is flagged as `Status = 'drift'`, `Pass = $false`.
- **Target drift verification (`Test-EvidencePacket`)**: During verification, `Test-EvidencePacket` recomputes the target identity and evaluates both recorded SHA256 and caller `ExpectedSha256` digests:
  - Divergence between working tree state and the bound target identity flags `TargetDrift = $true` (`IdentityMatch = $false`).
  - Divergence from recorded or expected digests flags `HashMatch = $false` with detailed drift diagnostics.
  - Unexpected disk appearance of an artifact previously recorded as missing is flagged as state drift.
- **Dynamic counts**: Totals, passed, missing, drifted, and failed counts are dynamically computed from verified records. Hardcoded success counts are strictly prohibited.

### 3.3 Command Tracking and Provenance Limitation

Commands executed during validation are captured with:
- The command invocation string (`Command`).
- Numeric exit code (`ExitCode`).
- Pass status (`Pass = ($ExitCode -eq 0)`).
- Provenance tag (`Provenance = 'asserted-receipt'`).
- Non-zero exits immediately mark the packet as failed (`Status = 'command_failed'`).

#### **Execution Limitation Contract**
Command records in an evidence packet represent **caller-asserted execution receipts**, NOT independent cryptographic proofs or kernel-level process guarantees.
- `Test-EvidencePacket` verifies the structure, exit code values, and provenance metadata of recorded receipts (`CommandsVerified = $commandPass`, `CommandProvenance = 'asserted-receipt'`).
- `Test-EvidencePacket` **does NOT** re-execute commands during verification, as re-running arbitrary commands could cause non-idempotent mutations, external side-effects, or unbounded delays.
- Callers and consumers must never treat command receipts in an evidence packet as fake execution proofs; runtime command verification must occur prior to packet generation.

### 3.4 Bounded Heuristic Safety and Provenance Rejection

To prevent accidental credential leaks and unsafe system state exposure:
- **Forbidden path patterns**: `.env*` (except `.env.example`), private keys (`*.pem`, `*.key`, `*.pfx`), SSH keys (`id_rsa*`), and credential stores (`credentials.json`, `secrets.json`).
- **Unsafe provenance**: Files originating from global tool directories (e.g. `~/.codex/config.toml`, `.gemini/`, `.serena/project.local.*`).
- **Secret content scanning**: Heuristic detection of private key blocks (`BEGIN PRIVATE KEY`), API keys (`sk-`, `ghp_`, `AKIA`, `Bearer `), and credential tokens in command strings, outputs, and text artifacts.
- **Raw global configs**: Rejection of raw configuration dumps containing `[mcp_servers]`, `[agents]`, or `[features]`.

> **Notice**: Secret detection is a bounded defensive heuristic intended to catch accidental leaks of common credentials. It does not promise exhaustive detection against arbitrary steganography, custom encodings, or deliberate obfuscation.

### 3.5 Lightweight Contract

The evidence packet schema relies on standard PowerShell PSCustomObjects and ordered dictionaries that serialize cleanly to JSON (`ConvertTo-Json`). No third-party schema validator or platform framework is required.

### 3.6 Test Runner Contract and Index Invariance

- **Deterministic Exit Code**: Any test failure in `scripts/tests/evidence-packet.Tests.ps1` forces a non-zero exit code (`exit 1`), guaranteeing CI/CD and automation gates fail closed.
- **Git Index Invariance**: Tests and whitespace validation operate strictly on working tree files, leaving the Git staging index completely unpolluted (`git diff --staged` remains empty).

---

## 4. Reproducible Fair Same-Task CLI Benchmark Plan

### 4.1 Context and Counterfactual Rejection

Claims of automated time savings (such as "saved 12 minutes") or unverified configuration switches (such as `--disable-mcp`) must be rejected unless accompanied by reproducible, empirical benchmark evidence.

*Scope boundary for this slice*: No benchmark run was executed during this slice, and no new benchmark launcher script was introduced. The plan below defines the mandatory protocol for future evaluation.

### 4.2 CLI Help Verification (Mandatory Precondition)

Before executing or scripting any candidate CLI benchmark:
1. The tester **must** inspect the authoritative CLI help of the installed tool:
   ```powershell
   codex --help
   codex exec --help
   ```
2. Any flag referenced in a benchmark plan (e.g. `--disable-mcp`, `--profile`, `--config`) must be confirmed in the CLI help output.
3. If a flag is absent or undocumented, it must not be used or asserted as a mechanism for savings.

### 4.3 Fair Same-Task Benchmark Protocol

To ensure valid comparison between a baseline configuration and a candidate configuration:

1. **Environment Isolation**:
   - Identical host hardware, CPU frequency scaling governor, and OS build.
   - Separate, clean temporary worktrees cloned from the identical commit SHA.
   - Clean user environment (temporary `CODEX_HOME` or isolated mock configuration).
   - Documented network connectivity state (offline/mocked vs live endpoints).

2. **Task Parity**:
   - Identical task prompt, seed, context files, and repository baseline.
   - Identical success criteria and validation gates.

3. **Repetitions and Statistical Rigor**:
   - Minimum $N = 5$ trials per configuration.
   - Alternating execution order (A/B/A/B/...) to mitigate cache and thermal bias.
   - Discard warm-up run if evaluating cold-start behavior; evaluate cold and warm states separately.

4. **Metric Limits and Collection**:
   - **Wall-clock time**: High-resolution timer (`System.Diagnostics.Stopwatch`), recording min, max, median, mean, and standard deviation.
   - **Resource utilization**: Peak process working set (MB), total CPU user/kernel time.
   - **Correctness**: Exit code verification and deterministic output validation (e.g. evidence packet verification). Incomplete or failing runs must be counted as failures, not discarded.
   - **Token and turn efficiency**: Total input tokens, output tokens, and subagent roundtrips reported by bridge logs.

5. **Reporting Standard**:
   - All published benchmarks must include raw run logs, environment specifications, CLI `--help` verification receipts, and confidence intervals.
   - Counterfactual extrapolation (asserting savings on tasks not directly measured) is invalid.
