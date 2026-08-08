# Backend Policy

This is the single detailed canonical policy for `$workflows` orchestration
and delegation. Other workflow files point to it and do not duplicate the
lifecycle.

## Resolution

- `$workflows mode=<MODE>` is the complete contract: the selected mode defines
  change authorization, required evidence, validation, and the done gate.
- Trailing explicit override: `subagents=mcp|native`. The default local backend is
  `subagents=mcp`; `native` is explicit opt-in only.
- Parent GPT is the decomposer, router, maestro, synthesizer, integrator, and
  final validator. DeepSeek is the primary backend for substantial bounded
  delegated reading, investigation, research, reproduction, testing,
  implementation, and review when the current mode permits it. Keep trivial
  serial work local.
- Readers run under `analyze` or `test`; writers run under `edit` and only
  when the mode authorizes change. No-edit modes never edit, stage, or
  commit.

## Canonical lifecycle

```text
DECOMPOSE -> DELEGATE -> CONTINUE -> COLLECT -> REACT -> VERIFY -> SYNTHESIZE
```

- DECOMPOSE: split the task into bounded fronts; keep trivial serial work
  local; decide which fronts need delegation.
- DELEGATE: `deepseek_spawn` one worker per independent front. Every
  required delegated task creates one pending obligation.
- CONTINUE: continue useful independent orchestration after spawning: launch
  other materially independent fronts when useful and process already
  available results; do not wait immediately. Following up one specific
  worker after its result is the `deepseek_continue` tool, not lifecycle
  CONTINUE.
- COLLECT: join results when a gate depends on them or no useful independent
  work remains.
- REACT: decide from collected evidence; route defects back to the same
  worker via `deepseek_continue`, re-plan, or stop.
- VERIFY: prove the affected behavior with the mode's validation; inspect the
  integrated diff; request an independent review when the mode requires it.
- SYNTHESIZE: integrate evidence and changes; do not advance before the
  delegation audit passes.

## Tool semantics

- `deepseek_spawn`: open an independent front. One worker per front; never
  duplicate a front.
- `deepseek_continue`: follow up the same front after a result,
  clarification, correction, or review. Do not spawn a replacement for the
  same front.
- `deepseek_follow`: consume a worker's result when no useful independent
  work remains or a gate depends on it. Follow is the normal close of a
  required task.
- `deepseek_consult`: take an exceptional snapshot of a running worker only;
  never poll. Prefer `deepseek_follow`.
- `deepseek_abort`: stop a worker only when the front is obsolete or the
  stop is explicit; consume the pending obligation as `aborted`.
- `deepseek_close`: retire a worker after its result is consumed.
- `deepseek_recover_result`: delivery recovery only; never use it to re-open
  or re-run a finished front.

## Pending obligation and delegation audit

- Every required delegated task creates one pending obligation.
- Before a dependent gate, synthesis, completion, or the final response
  advances, run the delegation audit: every required task must be consumed as
  `completed`, `completed_partial`, `failed`, `timed_out`, `aborted`, or
  `explicitly unavailable-blocked`.
- Never treat an accepted spawn as a result. The spawn is a promise; the
  consumed terminal state is evidence.
- If a required worker is still running and no useful independent work
  remains, `deepseek_follow` it.
- If new evidence makes a pending task irrelevant, declassify it and
  `deepseek_abort`/`deepseek_close` appropriately instead of ritual waiting.

## Review after a writer

After a material writer output, the parent inspects it and asks an independent
reviewer on the same resolved backend. Concrete defects return to the same
writer via `deepseek_continue`; the writer fixes, re-verifies, and reports
back for a delta review.

## Visual context

The parent GPT owns vision. When visual input is relevant, inspect the image
yourself and pass a concise `visual_context` to the worker: task-relevant
direct observations, visible text, interpretation, and uncertainty. Do not
delegate image interpretation blindly when the parent provides better visual
evidence.

## Examples (conceptual, dynamic)

These are dynamic routes, not fixed plans: the parent decides each step from
current evidence, runtime capacity, and the mode's done gate. There are no
fixed reader counts, quotas, schedulers, state databases, counters, or
mode-specific backend decision tables.

### BUG.INV (no-edit)

```text
DECOMPOSE: symptom -> repro + root-cause hypotheses
DELEGATE:  deepseek_spawn repro front; deepseek_spawn code-path front
CONTINUE:  continue orchestration: process arriving results; spawn an extra front only when a gap appears
COLLECT:   deepseek_follow a required reader only when no useful work remains or a gate depends on it
REACT:     rank hypotheses by evidence; drop unsupported ones
VERIFY:    no-edit: hypotheses proven against repo evidence
SYNTHESIZE: joined evidence report routes to BUG.FIX
```

### DEBUG (edit authorized)

```text
DECOMPOSE: symptom -> repro + hypothesis + fix boundary
DELEGATE:  deepseek_spawn repro reader; deepseek_spawn code-path reader; writer deferred
CONTINUE:  repro evidence lands first -> deepseek_spawn the writer (edit) while the code-path reader keeps running
COLLECT:   deepseek_follow remaining readers when no useful independent work remains
REACT:     functional gate, then clean gate
VERIFY:    after the material writer output, deepseek_spawn an independent reviewer; concrete defects return to the same writer via deepseek_continue
SYNTHESIZE: deliver with risks and remaining uncertainty
```

## Completion gate

Completion contract: for every required sidecar, the parent must wait for a
`final response` before `synthesis or advancement`. While a sidecar is
`running`, do not send an `interruptive follow-up` or `replace` it.
`interrupted`, `errored`, `timed out`, or `missing final response` means
unavailable: keep `sidecar-gate` `open/BLOCKED`; do not use a `silent fallback`.
Normative contract: `completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`

## Native profiles (opt-in only)

Under `subagents=native`, the workflow uses only the native read-only
profiles, each pinned to `gpt-5.6-luna` with
`model_reasoning_effort = "high"` and `sandbox_mode = "read-only"`:

- `scout`: local ownership, call paths, tests, risks, and targeted evidence.
- `researcher`: external or repository facts that need source-quality review.
- `reviewer`: frozen diff, regression, validation, architecture, and security
  risk.

Native profiles never edit files or configuration, stage or commit Git
changes, generate a patch, or start another agent. They are not the default;
native is explicit opt-in.

## Change boundary

For a write-authorized mode, the parent first records a claim-map with scope,
invariants, allowed paths, no-touch paths, validation, and known risks. The
parent may integrate an authorized writer output or make a minimal safe
change itself; DeepSeek is primary for substantial bounded implementation
work. It then verifies the result and asks an independent reviewer to inspect
the frozen result when the mode requires it.

If a required worker is unavailable, the corresponding gate remains open. Do
not substitute a different provider, model, permission level, or writer.

## Safety

- No-edit modes never change files.
- `COMMIT` touches only the Git index and never pushes.
- `DELIVER.AUTO` ends at the reviewed integrated diff and never commits.
- No reset, pull, merge, push, publication, or destructive action without
  explicit request.
