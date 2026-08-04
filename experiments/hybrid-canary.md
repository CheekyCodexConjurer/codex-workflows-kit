# Hybrid canary

This is a manual, reversible evaluation of `hybrid=canary`. It is not a
benchmark claim and does not add product instrumentation.

## Contract

Run each task twice from equivalent clean worktrees:

1. `hybrid=off` — current route and native writer baseline.
2. `hybrid=canary` — V4 Flash readers and the explicit safe-edit writer route.

Keep the user prompt, repository revision, acceptance criteria, allowed files,
and validation commands identical. The main GPT agent remains the orchestrator
and judge in both runs.

The canary writer must receive different absolute `HYBRID_WORKTREE` and
`HYBRID_MAIN_CHECKOUT` paths, the expected full commit id in
`HYBRID_BASELINE`, and a claim map. Before editing, it must prove that its Git
top-level is the supplied worktree, that `git rev-parse HEAD` equals
`HYBRID_BASELINE`, that `git status --porcelain` is empty, and that the
baseline matches the parent expectation. The parent inspects the diff and test output before
accepting it: run `git -C <worktree> diff --check`, inspect only claim-map
paths, run the assigned validation, and apply only the accepted diff/hunks to
the main checkout. Stop the run if the writer touches an unapproved path,
tries to commit/push/merge, accesses an external directory, or reports
success without evidence.

Start mutable hybrid writers serially for the initial canary. A prior concurrent
H1/H2 attempt left H2 with empty hybrid markers and had to be discarded; only
after a separate concurrency-isolation probe passes may the parent use at most two
writers at once. The parent must wait for or stop a writer before starting
another when the active cap is reached.

## Runtime notes

- The benchmark's native result-bearing GPT profiles are `gpt-5.4-mini` with
  `xhigh`; verify the installed `worker`, `scout`, `reviewer`, and `researcher`
  profiles before measuring. The native `relay` remains `gpt-5.4-mini` with
  `high` as the transport profile for MCP activation.
- A prior MCP launch returned `spawn opencode ENOENT` even though the local
  executable was present; keep the route blocked until the MCP process/session
  is reloaded and H0 passes. Do not convert that failure into a quality or
  savings result.
- Do not count a blocked concurrent attempt as model quality. Record it as
  protocol reliability/rework and use the sequential retry as the paired
  acceptance result.

Before H1, run a harmless H0 preflight against the real `opencode_hybrid_worker`
server to confirm that the `writer` agent is discoverable, the configured
`safe-edit` route can execute the allowed validation command, the supplied
worktree reports an empty `git status --porcelain`, and the response uses the
`HYBRID_WRITER_*` envelope. H0 must not edit a file. A static config check is
not a substitute for this runtime probe.

Both MCP servers must remain stateless for this experiment. Each task attempt
starts a fresh native relay and MCP conversation; do not persist or pass a
session identifier, and do not reuse a completed relay for a later prompt.

## Task matrix

Use at least one task from each row. A small set of five tasks is enough for a
first decision.

| ID | Shape | Example task | Expected signal |
| --- | --- | --- | --- |
| H1 | Control | Explain a contained failure and propose a one-file fix without editing. | Hybrid should not add meaningful overhead. |
| H2 | Mechanical | Add or repair a focused validator assertion plus its documentation. | Cheap writer path and low rework. |
| H3 | Multi-file | Add a bounded workflow rule across the skill, reference, and validator. | Context reduction without contract drift. |
| H4 | Debug | Reproduce one failing check, identify the root cause, and implement the smallest fix. | Compare first-pass success and repair rounds. |
| H5 | Coupled | Change a shared routing contract with tests and backward-compatibility checks. | Hybrid may lose; quality is the gate. |

## Record

For every run, record the session/task id and:

- main-model calls, visible usage/window pressure, and compactions when
  available;
- total agent calls, elapsed time, and approximate total usage when exposed;
- first-pass acceptance, tests/lint/typecheck results, rework rounds, and user
  interventions;
- out-of-scope edits, blocked gates, regressions, and reviewer findings.

Do not infer savings from total tokens alone: the target is lower use of the
principal model without a material quality or latency penalty.

## Decision gate

Keep `hybrid=canary` opt-in unless the paired sample shows no critical quality
regression, all acceptance checks pass, and the reduction in principal-model
usage is material enough to justify the extra routing and worktree overhead.
If results are mixed, keep the flag available and expand the sample only with
tasks that expose the unresolved risk; do not change the default route from a
single favorable task.
