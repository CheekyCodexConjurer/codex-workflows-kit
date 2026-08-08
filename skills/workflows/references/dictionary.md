# Workflow Dictionary

- `sidecar-gate`: require one or more delegated read-only workers (backend
  resolved by `backend-policy.md`) for a non-trivial, multi-front,
  shared/core, or explicitly reviewed task.
- `claim-map`: `{scope, invariants, allowed-paths, no-touch, validation, risks}`
  recorded before an authorized change.
- `preflight`: direct evidence that identifies the affected path and the
  failure signature before editing.
- `integrated-freeze`: one stable diff after targeted validation and before a
  review batch.
- `review-batch`: read-only review of the same frozen result on the resolved
  backend; actionable findings need evidence, impact, affected path, safer
  direction, and validation. Concrete defects return to the same writer via
  `deepseek_continue`.
- `clean-gate`: acceptance, required validation, and all proven in-scope
  findings are closed.
- `replan-gate`: stop and return to planning when scope, contract, evidence,
  or validation invalidates the active delivery contract.
- `obs-gate`: choose `none`, `temporary`, or `durable` before adding logging;
  `none` is the default.
- `quality-first-subA`: use delegated evidence workers only where their
  separate perspective materially closes a required gate.
- `lifecycle`: `DECOMPOSE -> DELEGATE -> CONTINUE -> COLLECT -> REACT ->
  VERIFY -> SYNTHESIZE`; canonical detail in `backend-policy.md`.
- `pending-obligation`: created by every required delegated task; consumed
  only as `completed`, `completed_partial`, `failed`, `timed_out`,
  `aborted`, or `explicitly unavailable-blocked`.
- `delegation-audit`: before a dependent gate, synthesis, completion, or the
  final response advances, prove every required task is consumed; never treat
  an accepted spawn as a result.
- `deepseek_spawn`: open an independent front.
- `deepseek_continue`: keep the same front after a result, clarification,
  correction, or review.
- `deepseek_follow`: consume a result when no useful independent work remains
  or a gate depends on it.
- `deepseek_consult`: exceptional snapshot of a running worker; never poll.
- `deepseek_abort`: stop an obsolete or explicitly stopped front; consume as
  `aborted`.
- `deepseek_close`: retire a worker after its result is consumed.
- `deepseek_recover_result`: delivery recovery only.
- `visual_context`: parent-owned vision passed to a worker as concise direct
  observations, visible text, interpretation, and uncertainty.
