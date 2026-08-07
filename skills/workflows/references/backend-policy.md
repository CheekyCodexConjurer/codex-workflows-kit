# Native Sidecar Policy

## Contract

The workflow route is direct and native:

```text
orchestrator -> scout | researcher | reviewer -> orchestrator
```

Every sidecar is a read-only evidence role. The installed profile pins
`gpt-5.6-luna`, `model_reasoning_effort = "high"`, and
`sandbox_mode = "read-only"`.

The orchestrator owns task decomposition, synthesis, changes, testing, diff
inspection, and final approval. A sidecar never edits files or configuration,
stages or commits Git changes, generates a patch, or starts another agent.

## Selection

- `scout`: local ownership, call paths, tests, risks, and targeted evidence.
- `researcher`: external or repository facts that need source-quality review.
- `reviewer`: frozen diff, regression, validation, architecture, and security
  risk.

## Completion gate

Completion contract: for every required sidecar, the parent must wait for a
`final response` before `synthesis or advancement`. While a sidecar is
`running`, do not send an `interruptive follow-up` or `replace` it.
`interrupted`, `errored`, `timed out`, or `missing final response` means
unavailable: keep `sidecar-gate` `open/BLOCKED`; do not use a `silent fallback`.
Normative contract: `completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`

Use one role per non-overlapping front. A task that is non-trivial, has two or
more independent fronts, affects a shared contract, or requests review must
pass `sidecar-gate`. Do not delegate a simple serial task just to fill a
quota.

## Change boundary

For a write-authorized mode, the parent first records a claim-map with scope,
invariants, allowed paths, no-touch paths, validation, and known risks. It
then makes the smallest safe change, verifies it, and asks a native reviewer
to inspect the frozen result when required by the mode.

If a required sidecar is unavailable, the corresponding gate remains open.
Do not substitute a different provider, model, permission level, or writer.
