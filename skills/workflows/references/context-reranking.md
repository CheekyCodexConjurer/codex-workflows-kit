# Context Reranking Reference

Privacy-aware, budget-bounded context reranker powered by TypeSafe/Jev System One (`noul` primitive) to prioritize search retrieval candidates and reduce prompt context bloat.

---

## 1. Overview and Core Philosophy

During investigation, debugging, and task execution, code search tools (such as `rg`, `search_code`, or symbol lookups) often return dozens of matches containing thousands of lines of source code. Directly dumping hundreds of unfiltered search results into the prompt context wastes model tokens, pollutes working memory, distracts reasoning, and increases wall-clock latency.

The Context Reranker solves this by evaluating candidate relevance before full snippets are delivered to the parent orchestrator or delegated to subagents:

1. **Deterministic Lifecycle Position**: Executed on demand after search retrieval (e.g. via `select-context-from-rg.ps1` or direct candidate feeding) and before context assembly or subagent handoff. The canonical workflow lifecycle (`FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE`) remains completely unchanged.
2. **System One Semantic Judgment (Jev)**: TypeSafe/Jev acts as a non-autoregressive relevance evaluator using the `noul` (boolean probability) primitive to determine whether a candidate snippet contains actionable code, contract details, or contradictory evidence materially useful to the task.
3. **Strict Privacy Boundary**: The presence of `TYPESAFE_API_KEY` in the environment does **not** authorize code transmission. Explicit opt-in (`-AuthorizeContentTransmission` or `-PrivacyScope 'snippets_allowed'`) is mandatory; without it, the reranker safely falls back to local original-rank selection within the byte budget without making network calls.
4. **Byte-Bounded Budgeting**: Enforces an exact UTF-8 serialized byte ceiling (`MaxBudgetBytes`) and candidate count cap (`MaxSelectedCandidates`). High-priority items (`PINNED`) are admitted first, followed by `KEEP` and `MAYBE` candidates until the budget is exhausted.
5. **Orchestrator Sovereignty**: The parent GPT orchestrator retains ultimate decision authority. Jev evaluates relevance scores; the local code enforces security, paths, budgeting, and provenance. Excluded candidates are recorded in a lightweight manifest so the parent remains aware of deferred evidence.

```text
Search Tool (rg, search_code, symbols)
  ↓
Raw search matches & context lines
  ↓
Candidate extraction & normalization (New-ContextCandidate)
  ↓
Local security gate:
  ├── Reparse path containment (Resolve-CanonicalReparsePath)
  └── Secret & token scanner (Test-CandidateSafety)
  ↓
Exact deduplication & provenance merging (Optimize-CandidateSet)
  ↓
Privacy authorization check:
  ├── If unauthorized or policy == off:
  │     └── Local rank selection within byte budget
  └── If authorized & API key available:
        ├── Parallel batching (up to BatchSize per request)
        ├── System One (noul) relevance evaluation via Jev
        └── Score classification (KEEP, MAYBE, DROP)
  ↓
Package selection (Select-ContextPackage):
  ├── PINNED candidates (admitted first; overflow yields budget_exceeded)
  ├── KEEP candidates (admitted within budget)
  ├── MAYBE / UNROUTED candidates (admitted within remaining budget)
  └── Excluded items recorded in lightweight manifest (metadata only)
  ↓
Delivered compact package consumed by Parent / Subagent
```

---

## 2. Candidate Data Model & Serialization

All search results are transformed into a standardized, versioned candidate contract:

```json
{
  "schema_version": 1,
  "id": "cand:c02412c40e2767c9",
  "source": "rg",
  "source_ref": "skills/workflows/scripts/context-reranking.psm1",
  "repository_scope": "repo",
  "revision_or_hash": "HEAD",
  "line_start": 4,
  "line_end": 8,
  "original_rank": 1,
  "representation": "snippet",
  "content": "Set-StrictMode -Version Latest\n...",
  "provenances": [
    {
      "source": "rg",
      "source_ref": "skills/workflows/scripts/context-reranking.psm1",
      "original_rank": 1
    }
  ],
  "metadata": {}
}
```

### Stable Candidate ID Computation
When an explicit ID is omitted, `New-ContextCandidate` generates a deterministic 16-character SHA-256 hash prefixed with `cand:` computed from:
`$RepositoryScope|$cleanRef|$RevisionOrHash|$LineStart|$LineEnd|$Representation`

---

## 3. Privacy, Path Safety, and Containment

The context reranker enforces rigorous safety policies before any candidate is evaluated or packaged:

### A. Reparse Path Containment
Windows directory junctions, symlinks, and relative traversal sequences (`../`) can potentially break out of repository roots.
- `Assert-CandidatePathContainment` resolves all path segments using `Resolve-CanonicalReparsePath` against `Resolve-CanonicalDirectoryRoot`.
- Rooted paths, colon characters, drive leaps, or reparse targets that resolve outside the working repository boundary trigger a fail-fast rejection (`exclusion_reason = "unsafe_path"`).

### B. Secret and Credential Scanning
`Test-CandidateSafety` inspects both the file reference and content before processing:
1. **Forbidden Filenames**:
   - Environment files: `.env`, `.env.local`, `.env.production` (excluding `.env.example`).
   - Certificates and private keys: `*.pem`, `*.key`, `*.pfx`, `*.p12`, `id_rsa*`, `id_ed25519*`.
   - Credential databases: `credentials.json`, `secrets.json`, `token.json`.
2. **Profile and Internal Configs**:
   - Files referencing `.codex/`, `.gemini/`, `.serena/project.local`, or `config.toml`.
3. **Token Signatures in Content**:
   - Private key PEM headers (`-----BEGIN ... PRIVATE KEY-----`).
   - Token prefixes: `sk-`, `sk-ant-`, `ghp_`, `gho_`, `github_pat_`, `glpat-`, `AKIA...`.
   - Bearer tokens and generic key-value credential assignments.
Any detected secret candidate is excluded and placed in the manifest with `exclusion_reason = "secret_detected"` or specific violation reason.

### C. Explicit Transmission Authorization
The reranker enforces three privacy scopes:
- `none` (default): Third-party transmission is strictly prohibited. If invoked, the reranker performs local original-rank selection without making external HTTP requests (`status = "skipped_privacy_unauthorized"`).
- `metadata_only`: Only file paths, line ranges, and symbols may be evaluated. Content snippets are stripped.
- `snippets_allowed` (or `-AuthorizeContentTransmission`): Content snippets are permitted to be transmitted to the TypeSafe/Jev evaluation endpoint.

---

## 4. Exact Deduplication vs Contradictory Evidence

When multiple search queries or search tools identify the same code, redundant tokens should not be delivered twice:
- **Exact Duplication**: Candidates sharing the exact same `source_ref`, `line_start`, `line_end`, `content`, and `revision_or_hash` are coalesced into a single candidate object. All unique discovery origins are preserved under the `provenances` array (`source`, `source_ref`, `original_rank`).
- **Conflicting Candidates**: If two candidates share the exact same ID or location but contain differing content (e.g. from different git revisions, unstaged edits, or conflicting runtime outputs), they are strictly preserved as separate candidates. Contradictory evidence is never silently suppressed.

---

## 5. TypeSafe / Jev System One Contract

### API Endpoint & Latency
- **Endpoint**: `POST https://api.typesafe.ai/v1/systemone`
- **Model**: `jev-latest`
- **Latency Profile**: 80ms – 400ms per parallel batch.

### Parallel Question Formulation
Candidates are evaluated using the `noul` primitive (non-autoregressive boolean probability). Up to `BatchSize` (default 20) candidate questions are packed into a single request body against the shared task state:

```json
{
  "model": "jev-latest",
  "state": "{\"task\":{\"mode\":\"IMPL.AUTO\",\"objective\":\"Fix authentication regression\"}}",
  "questions": {
    "q_0": {
      "type": "noul",
      "instructions": "Candidate ID: 'cand:c02412c40e2767c9' from 'auth/service.go' (lines 40-55) (snippet):\n\"...\"\nDoes this candidate contain materially useful information to investigate or execute the task, including evidence that contradicts hypotheses?",
      "criteria": {
        "true": "The candidate contains directly relevant code, contract, configuration, test, or contradictory evidence materially useful for the task.",
        "false": "The candidate is merely superficially related, tangential, or lacks actionable utility."
      }
    }
  }
}
```

### Threshold Classification
- `score >= KeepThreshold` (default 0.70): Classified as `KEEP`.
- `MaybeThreshold <= score < KeepThreshold` (default 0.40): Classified as `MAYBE`.
- `score < MaybeThreshold`: Classified as `DROP`.
- Pinned items bypass scoring and are always classified as `PINNED`.
- Under `policy = "off"` or fallback: Classified as `UNROUTED`.

---

## 6. Budget Allocation and Manifest Output

The local budget engine enforces deterministic token/byte containment:

1. **Pre-Check (Pinned Overflow)**:
   If the cumulative content size of `PINNED` items alone exceeds `MaxBudgetBytes`, the reranker terminates immediately with `status = "budget_exceeded"`, returning an empty `selected` array and the complete candidate list in `manifest`. This alerts the parent orchestrator that task sharding is required.
2. **Selection Ordering**:
   - `PINNED` candidates admitted first (ordered by `original_rank` ascending).
   - `KEEP` candidates admitted second (ordered by `score` descending, then `original_rank` ascending).
   - `MAYBE` candidates admitted third (ordered by `score` descending, then `original_rank` ascending).
   - Candidates are appended until adding the next item would exceed `MaxBudgetBytes` or `MaxSelectedCandidates`.
3. **Manifest of Deferred / Dropped Evidence**:
   Candidates not admitted into `selected` are recorded in `manifest` without their heavy `content` property:
   ```json
   {
     "id": "cand:e8910b",
     "source_ref": "docs/architecture.md",
     "line_start": 100,
     "line_end": 120,
     "score": 0.35,
     "decision": "DROP",
     "exclusion_reason": "low_relevance"
   }
   ```
   Possible exclusion reasons:
   - `low_relevance`: Score fell below `MaybeThreshold`.
   - `budget_deferred`: Candidate scored well (`KEEP` or `MAYBE`) but could not fit within `MaxBudgetBytes`.
   - `count_limit_exceeded`: Exceeded `MaxSelectedCandidates`.
   - `unsafe_path`: Candidate escaped repository root.
   - `secret_detected`: Candidate matched secret file or credential patterns.

---

## 7. Tooling & CLI Reference

### `rerank-context.ps1`
Core reranking tool. Accepts candidates from pipeline, JSON string, or array.

```powershell
# Advisory reranking with explicit authorization
$package = Get-Content candidates.json | .\skills\workflows\scripts\rerank-context.ps1 `
    -TaskObjective "Trace database connection leaks" `
    -AuthorizeContentTransmission `
    -MaxBudgetBytes 32768 `
    -AsJson
```

### `select-context-from-rg.ps1`
End-to-end ripgrep search adapter. Executes `rg --json`, groups contiguous matches into candidate snippets, and feeds them to `rerank-context.ps1`.

```powershell
# Search and rerank with ripgrep
$package = .\skills\workflows\scripts\select-context-from-rg.ps1 `
    -Query "ConnectionPool" `
    -Path "src/" `
    -TaskObjective "Find pool sizing configurations" `
    -AuthorizeContentTransmission `
    -AsJson
```
