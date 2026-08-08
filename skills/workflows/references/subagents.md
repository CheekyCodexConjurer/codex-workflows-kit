# Native Sub-agents

This reference applies only under the explicit opt-in `subagents=native`.
Backend resolution, the canonical lifecycle, tool semantics, and the
delegation audit live in `backend-policy.md`; do not duplicate them here.

## Profiles

Under `subagents=native`, the workflow uses only these native profiles:

| Profile | Purpose | Model | Effort | Access |
|---|---|---|---|---|
| `scout` | local evidence and ownership | `gpt-5.6-luna` | `high` | read-only |
| `researcher` | source-grounded research | `gpt-5.6-luna` | `high` | read-only |
| `reviewer` | frozen-diff risk review | `gpt-5.6-luna` | `high` | read-only |

Native profiles are read-only: they never edit, write patches, stage, commit,
alter configuration, or delegate again. They report observations, inferences,
risks, and the cheapest next check. The parent owns all changes and
validation.

## Handoff

Give every worker a bounded question, explicit scope, required evidence, and
return format. Keep fronts independent. The parent joins required results,
deduplicates evidence, and records remaining uncertainty before deciding.

## Cadence

Use one reader for each material independent front. Do not create duplicates,
and do not send a worker where direct local inspection is enough. Respect the
runtime capacity; when a required reader cannot run, report the gate as open
(`explicitly unavailable-blocked`) instead of claiming completion.

## Completion gate

Mandatory delegated work follows the canonical completion and
pending-obligation gate in `backend-policy.md`; native profiles never bypass
it.
