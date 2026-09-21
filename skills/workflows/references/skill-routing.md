# Skill Routing Reference

Optional semantic skill routing gate executed during the `FRAME` stage of the canonical workflow lifecycle, before `FANOUT`.

---

## 1. Overview and Core Philosophy

In large repositories or multi-skill environments, exposing dozens of full `SKILL.md` documents to the orchestrator creates context bloat, increases prompt token overhead, and introduces distraction.

The skill routing gate solves this by evaluating candidate skills before their full instructions or references are loaded:
1. **Lightweight Catalog**: Only lightweight frontmatter metadata (`name`, `description`, `scope`, `path`) is inspected initially.
2. **System One Semantic Judgment (Jev)**: TypeSafe/Jev acts as a fast, non-autoregressive evaluator using the `noul` (boolean probability) primitive to determine whether loading a candidate skill materially improves task completion.
3. **Orchestrator Sovereignty**: The parent GPT orchestrator retains ultimate routing authority. Jev never executes code, designs plans, or overrides workflow rules.
4. **Sub-Agent Execution**: DeepSeek Sub-Agent MCP remains the workforce for material tasks.

```text
USER
  ↓
workflow execution mode=<MODE>
  ↓
FRAME
  ├── identify explicitly requested skills (marked forced)
  ├── discover candidate skills (kit + repo)
  ├── build lightweight catalog (frontmatter only)
  ├── evaluate relevance via TypeSafe/Jev (noul primitive)
  └── parent GPT resolves final route (forced, select, review, skip)
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

### A. Codex Workflows Kit Skills
- Discovered dynamically via `~/.codex/codex-workflows-kit/install-state.json` (or the repository `skills/` directory when running in development mode).
- Does not rely on hardcoded skill lists. Any newly installed or added kit skill is automatically discovered.
- Stable ID prefix: `kit:<name>` (e.g. `kit:workflows`, `kit:evidence-first`, `kit:mcp-foundation`, `kit:context7-mcp`, `kit:codebase-memory-mcp`).

### B. Repository Skills
- Discovered by scanning `.agents/skills` at the repository root and within subpackages/monorepo subdirectories (e.g. `packages/service/.agents/skills/`).
- Respects project hierarchy to avoid collisions between skills of identical names located in different scopes.
- Stable ID format: `repo:<relative-path>` (e.g. `repo:.agents/skills/database`, `repo:packages/api/.agents/skills/backend-api`).

---

## 3. Mandatory Policies & Forced Skills

The following skills bypass Jev evaluation entirely and are marked with `decision = "forced"` (`score = null`):
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
- **Latency profile**: 70ms – 500ms typical.

### Semantic Question
The relevance question is fully semantic and self-contained:
> *"Given the current task, workflow mode, and skill description, would loading this skill materially improve the agent's ability to complete the task correctly, rather than merely being superficially related to the topic?"*

### Minimal Sanitized Payload
Only task metadata and skill metadata are transmitted.
```json
{
  "model": "jev-latest",
  "state": "{\"task\":{\"mode\":\"BUG.FIX\",\"objective\":\"Fix regression in backtest calculation\"},\"skill\":{\"name\":\"lean-backtest\",\"description\":\"Use when implementing or debugging Lean backtests\",\"scope\":\"repo\"}}",
  "questions": {
    "materially_improves_task": {
      "type": "noul",
      "instructions": "Given the current task, workflow mode, and skill description, would loading this skill materially improve the agent's ability to complete the task correctly, rather than merely being superficially related to the topic?"
    }
  }
}
```
**Strict Data Minimization**: The router never transmits repository source code, file contents, git history, diffs, patches, environment variables, user data, or full `SKILL.md` content.

---

## 5. Configuration Policies & Thresholds

Configured via parameter `-RoutingPolicy` or environment variable `CODEX_SKILL_ROUTING_POLICY`:

| Policy | Description | Behavior under API Failure / Missing Key |
| :--- | :--- | :--- |
| `off` | Jev is disabled. No external calls. | Normal workflow behavior without external routing. |
| `advisory` *(default)* | Jev scores candidates. Parent GPT reviews recommendations and retains authority. | Logs warning; candidates default to review; workflow continues cleanly. |
| `enforce` | Scores automatically dictate `select`, `review`, or `skip`. Ambiguities escalate to parent GPT. | Fail-safe: gate escalates to parent GPT rather than blocking workflow. |

### Configurable Thresholds & Limits
- **`SelectThreshold`** (`>= 0.70`): Skill provides material improvement; recommended for loading (`decision: "select"`).
- **`ReviewThreshold`** (`0.45` – `< 0.70`): Borderline relevance; flagged for parent review (`decision: "review"`).
- **Skip** (`< 0.45`): Superficially related or irrelevant (`decision: "skip"`).
- **`MaxSelectedSkills`** (default `3`): Caps the number of implicit skills loaded to preserve context budget. If more than 3 exceed `0.70`, top-ranked skills are selected and the remainder marked `review`. Forced skills do not count toward this cap.

---

## 6. Output Schema

The router emits a structured object or JSON payload:
```json
[
  { "id": "kit:workflows", "name": "workflows", "decision": "forced", "score": null },
  { "id": "repo:.agents/skills/database", "name": "database", "decision": "select", "score": 0.88 },
  { "id": "kit:codebase-memory-mcp", "name": "codebase-memory-mcp", "decision": "review", "score": 0.54 },
  { "id": "kit:context7-mcp", "name": "context7-mcp", "decision": "skip", "score": 0.22 }
]
```

---

## 7. Security and Fail-Safe Contract

- **Credential Isolation**: `TYPESAFE_API_KEY` is read strictly from the runtime environment. It is never logged, printed, mirrored into repository files, or referenced in test fixtures.
- **Fail-Safe Operation**: Timeouts, HTTP 4xx/5xx responses, malformed JSON, or missing credentials log a concise diagnostic notice and fall back gracefully to parent GPT assessment without crashing or blocking the workflow.
