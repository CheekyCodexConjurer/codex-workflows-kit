Seja elegante e preciso; evite complexidade desnecessária.

Compact syntax: `⇢` left-to-right | `{}` scope/output | `[]` roles/options | `Q` queue | `Σ` scan/map | `∀` each | `→` then | `?` optional by budget/risk.

Global rules:

- Route by task+risk+blast before work; simple tasks stay simple unless evidence forces escalation.
- For `$codex-workflows` or compact modes, use the `codex-workflows` skill and expand aliases from its references.
- Define criteria before action: goal, expected behavior, done condition, validation.
- Read directly related files first; prefer `rg`, CodeGraph, queries, and snippets before broad full-file reads.
- Use the smallest safe change, preserve local patterns, avoid unrelated cleanup/refactor/deps/layers.
- Prefer delete/simplify before abstraction; use canonical owners/helpers/modules; leave no dead/dup/debug/temp/log residue.
- For modern libraries/frameworks/APIs, fetch current docs before coding when syntax/version matters.
- Do not perform destructive/prod/db/reset/force-push/secret/publish operations without explicit confirmation.

Subagents:

- Main agent owns critical path, contracts, integration, and final quality.
- Use subagents only when they improve wall-clock time or evidence quality.
- Spawn/message subagents in background, continue useful local non-overlap work, then join at decision/final/merge gate.
- Required subagents must reply before decision/final. Timeout/slow/not-in-time is not failure; wait again unless user cancels.
- Never close active/waiting/required subagents before integrating their final reply. Close only completed/idle unrelated stale ones.
- Read-only subagents default to 5.4 Mini high; 5.4 Mini xHigh only for deep repo-wide strict audit; never 5.5 xHigh.
- Writable workers require claim-map, no-touch boundaries, validation contract, and merge-gate review.

CodeGraph:

- Use CodeGraph only when cg-worthy: medium/large repo, multi-file/shared/core/unclear task, or search would fan out.
- If `.codegraph` exists, sync quietly before structural exploration.
- If cg-worthy and CodeGraph is installed but missing in repo, run `codegraph init -i` once and keep generated files local/uncommitted.
- If unavailable/stale/no hits, fall back to `rg` and targeted reads.
- Do not update or manage CodeGraph processes during normal repo work; only debug stale/orphan MCP processes when CodeGraph itself is the task.

When receiving compact prompts: preserve order, treat syntax as operational, choose the smallest safe interpretation if ambiguous, and report files, validation, risks, and remaining work.
