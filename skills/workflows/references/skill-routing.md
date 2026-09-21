# Skill Routing Reference

Semantic skill routing gate executed during the `FRAME` stage of the canonical workflow lifecycle, before `FANOUT`.

---

## 1. Overview and Core Philosophy

In large repositories or multi-skill environments, exposing dozens of full `SKILL.md` documents to the orchestrator creates context bloat, increases prompt token overhead, and introduces distraction.

The skill routing gate solves this by evaluating candidate skills before their full instructions or references are loaded:
1. **Deterministic Lifecycle**: During FRAME, `if routing policy != off: execute skill-routing before FANOUT; if routing policy == off: preserve normal skill resolution`.
2. **Lightweight Catalog**: Only lightweight frontmatter metadata (`name`, `description`, `scope`, `path`) is inspected initially. Full instruction bodies are never parsed during routing.
3. **System One Semantic Judgment (Jev)**: TypeSafe/Jev acts as a fast, non-autoregressive evaluator using the `noul` (boolean probability) primitive to determine whether loading a candidate skill materially improves task completion.
4. **Parallel Batching**: Candidate questions are grouped and evaluated in parallel batches against the minimized task state in a single HTTP request, reducing latency to a minimum.
5. **Orchestrator Sovereignty**: The parent GPT orchestrator retains ultimate routing authority. Jev never executes code, designs plans, or overrides workflow rules.
6. **Sub-Agent Execution**: DeepSeek Sub-Agent MCP remains the workforce for material tasks.

```text
USER
  ↓
workflow execution mode=<MODE>
  ↓
FRAME
  ├── resolve routing policy (off, advisory, enforce)
  ├── if policy == off:
  │     └── preserve normal skill resolution (all unforced candidates unrouted)
  └── if policy != off:
        ├── identify explicitly requested skills (marked forced, bypassing Jev)
        ├── discover candidate skills (kit + repo ancestor chain)
        ├── build lightweight catalog (frontmatter only)
        ├── run route-skills with minimized -RoutingObjective
        ├── batch evaluate relevance via TypeSafe/Jev (noul primitive)
        └── resolve decisions (forced, select, review, skip) under thresholds & policy
  ↓
load/use selected skills
  ↓
FANOUT
  ↓
DeepSeek Sub-Agent MCP
  ↓
COLLECT → ACT → VERIFY → REVIEW → DONE
```

---

## 2. Skill Discovery & Stable Identity

The router discovers candidate skills from two distinct sources:

### A. Codex Workflows Kit Skills (Strict Ownership)
- Discovered dynamically via `~/.codex/codex-workflows-kit/install-state.json` (or the repository `skills/` directory when running in development mode).
- Does not scan generic global skill directories (e.g. `~/.agents/skills`) without proven kit ownership. Unmanaged global skills are never classified as kit skills.
- Stable ID prefix: `kit:<name>` (e.g. `kit:workflows`, `kit:evidence-first`, `kit:mcp-foundation`, `kit:context7-mcp`, `kit:codebase-memory-mcp`).

### B. Repository Skills (Hierarchical Ancestor Chain)
- Discovered by traversing upwards from WorkingDir along the direct ancestor chain to the repository root (`git rev-parse --show-toplevel` or directory `.git` ancestor search):
  `WorkingDir → Parent → ... → Repository Root`
- At each level in the chain, checks `.agents/skills/*` for `SKILL.md`.
- **Excludes Sibling Subdirectories**: Subpackages outside the direct working directory chain (e.g. `repo/packages/worker-only/.agents/skills` when working in `repo/packages/api`) are never scanned.
- **Stable Identity**: Prefixed with relative repository path to isolate identically named skills across different scopes:
  - `repo:.agents/skills/database`
  - `repo:packages/api/.agents/skills/database`

---

## 3. Mandatory Policies & Forced Skills

The following skills bypass Jev evaluation entirely and are marked with `decision = "forced"` (`score = null`, `enforced = true`):
- **Workflows Skill**: The canonical workflow router (`workflows`) is always forced.
- **Explicit User Invocations**: Any skill explicitly requested or invoked by the user (e.g. via mode options or explicit prompts) is always forced.
- **Workflow Mode Policies**: When workflow policies mandate specific skills (such as `evidence-first` for material external or high-impact claims under `RESEARCH.DEEP` or `P.DEEP`), the policy overrides semantic evaluation.

Jev evaluates **only** implicit, candidate, or complementary skills.

---

## 4. TypeSafe / Jev Integration Contract

### API Specification
- **Endpoint**: `POST https://api.typesafe.ai/v1/systemone`
- **Model**: `jev-latest`
- **Authentication**: `Authorization: Bearer $env:TYPESAFE_API_KEY`
- **Latency profile**: 70ms – 500ms typical per batch.

### Semantic Question & Parallel Batching
The relevance question is evaluated per candidate in parallel against the shared task state:
> *"Given skill '<name>' (scope: <scope>). Description: '<description>'. Would loading this skill materially improve the agent's ability to complete this task correctly, rather than merely being superficially related?"*

All unforced candidates are grouped into batches (up to 25 candidates per request), evaluating independent `noul` questions in parallel in a single HTTP call. The router records `jev_calls` and `candidates_evaluated` metrics.

### Data Minimization Contract
The router sends only a minimized routing objective and lightweight skill metadata. Raw repository contents, source code, diffs, logs, secrets, and full user prompts are not sent by default.

- **`-RoutingObjective` (Preferred)**: A concise, purpose-built task summary generated by the parent orchestrator without raw code, logs, or sensitive payloads (e.g. `"Fix authentication regression in REST API"`).
- **`-TaskObjective` (Deprecated Fallback)**: Conservatively sanitized by stripping fenced/inline code blocks, private keys, bearer/API keys, env assignments, diff headers, stack traces, and bounding length to 300 characters.

Payload structure:
```json
{
  "model": "jev-latest",
  "state": "{\"task\":{\"mode\":\"BUG.FIX\",\"objective\":\"Fix authentication regression in REST API\"}}",
  "questions": {
    "q_0": {
      "type": "noul",
      "instructions": "Given skill 'db-query' (scope: repo). Description: 'Execute read-only queries against databases'. Would loading this skill materially improve the agent's ability to complete this task correctly, rather than merely being superficially related?"
    },
    "q_1": {
      "type": "noul",
      "instructions": "Given skill 'context7-mcp' (scope: kit). Description: 'Fetch current documentation and code examples from Context7'. Would loading this skill materially improve the agent's ability to complete this task correctly, rather than merely being superficially related?"
    }
  }
}
```

---

## 5. Configuration Policies & Thresholds

Configured via parameter `-RoutingPolicy` or environment variable `CODEX_SKILL_ROUTING_POLICY`:

| Policy | Description | Candidate Decisions | Enforcement |
| :--- | :--- | :--- | :--- |
| `off` | Jev is disabled. 0 external calls. Normal workflow behavior preserved. | Unforced candidates marked `unrouted`. Forced remain `forced`. | `enforced: false` for unrouted. Parent retains full authority to resolve skills normally. |
| `advisory` *(default)* | Jev scores candidates. Evaluates relevance and provides non-blocking recommendations. | `select`, `review`, `skip`. Forced remain `forced`. | `enforced: false` across all recommendations. Parent GPT retains sovereign authority to load `skip` or ignore `select`. |
| `enforce` | Jev + thresholds automatically govern implicit candidate selection. | `select`, `skip` applied deterministically; `review` escalated to parent. Forced remain `forced`. | `enforced: true` for `select`, `skip`, and `forced`. `enforced: false` for `review` (escalated). |

### Configurable Thresholds, Limits & Validation Rules
All parameters are validated fail-fast before any discovery, filesystem scan, or network request:
- **`SelectThreshold`** (`0.0` – `1.0`, default `0.70`): Skill provides material improvement; recommended/enforced for loading (`decision: "select"`).
- **`ReviewThreshold`** (`0.0` – `1.0`, default `0.45`): Borderline relevance; flagged for parent review (`decision: "review"`, `enforced: false`). Must satisfy `ReviewThreshold <= SelectThreshold`; configurations where `ReviewThreshold > SelectThreshold` fail immediately with a descriptive error.
- **Skip** (`< ReviewThreshold`): Irrelevant or superficial (`decision: "skip"`). Under `advisory`, `enforced: false`; under `enforce`, `enforced: true`.
- **`MaxSelectedSkills`** (`0` – `100`, default `3`): Caps the number of implicit skills loaded to preserve context budget. Setting to `0` disables automatic selection of implicit skills (all candidates meeting threshold are escalated as `review`). Forced skills do not count toward this cap.
- **`BatchSize`** (`1` – `100`, default `25`): Maximum number of candidate skill questions evaluated in parallel per Jev HTTP request. Non-positive values are rejected.
- **`TimeoutSeconds`** (`1` – `120`, default `10`): Maximum time in seconds for TypeSafe Jev API requests.
- **`CODEX_SKILL_ROUTING_POLICY`**: Normalized case-insensitively to `off`, `advisory`, or `enforce`. Invalid values fail fast with a configuration error instead of silently defaulting.

---

## 6. Output Schema

The router emits a structured object or JSON payload:
```json
{
  "policy": "advisory",
  "status": "ok",
  "latencyMs": 340,
  "jev_calls": 1,
  "candidates_evaluated": 3,
  "summary": {
    "discovered": 4,
    "forced": ["workflows"],
    "unrouted": [],
    "evaluated": 3,
    "selected": ["db-query"],
    "review": ["api-client"],
    "skipped": 1
  },
  "results": [
    { "id": "kit:workflows", "name": "workflows", "decision": "forced", "enforced": true, "score": null },
    { "id": "repo:.agents/skills/db-query", "name": "db-query", "decision": "select", "enforced": false, "score": 0.88 },
    { "id": "repo:packages/api/.agents/skills/api-client", "name": "api-client", "decision": "review", "enforced": false, "score": 0.54 },
    { "id": "kit:custom-tool", "name": "custom-tool", "decision": "skip", "enforced": false, "score": 0.22 }
  ]
}
```

---

## 7. Security and Fail-Safe Contract

- **Credential Isolation**: `TYPESAFE_API_KEY` is read strictly from the runtime environment. It is never logged, printed, mirrored into repository files, or referenced in test fixtures.
- **Fail-Safe Operation**: Timeouts, HTTP 4xx/5xx responses, malformed JSON, or missing credentials log a concise diagnostic notice and fall back gracefully to `decision: "review"`, `enforced: false`, `note: "jev_unavailable"`. Jev errors never produce false `skip` decisions.
