# Native Sub-agents

## Profiles

The workflow uses only these native profiles:

| Profile | Purpose | Model | Effort | Access |
|---|---|---|---|---|
| `scout` | local evidence and ownership | `gpt-5.6-luna` | `max` | read-only |
| `researcher` | source-grounded research | `gpt-5.6-luna` | `max` | read-only |
| `reviewer` | frozen-diff risk review | `gpt-5.6-luna` | `max` | read-only |

## Handoff

Give every sidecar a bounded question, explicit scope, required evidence, and
return format. Keep fronts independent. The parent waits for required results,
deduplicates evidence, and records remaining uncertainty before deciding.

Sidecars must not edit, write patches, stage, commit, alter configuration, or
delegate again. They report observations, inferences, risks, and the cheapest
next check. The parent is responsible for all changes and validation.

## Cadence

Use one reader for each material independent front. Do not create duplicates,
and do not send a sidecar where direct local inspection is enough. Respect the
runtime capacity; when a required reader cannot run, report the gate as open
instead of claiming completion.
