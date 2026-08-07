# Workflow Dictionary

- `sidecar-gate`: require one or more native read-only sidecars for a
  non-trivial, multi-front, shared/core, or explicitly reviewed task.
- `claim-map`: `{scope, invariants, allowed-paths, no-touch, validation, risks}`
  recorded before an authorized change.
- `preflight`: direct evidence that identifies the affected path and the
  failure signature before editing.
- `integrated-freeze`: one stable diff after targeted validation and before a
  review batch.
- `review-batch`: read-only review of the same frozen result; actionable
  findings need evidence, impact, affected path, safer direction, and
  validation.
- `clean-gate`: acceptance, required validation, and all proven in-scope
  findings are closed.
- `replan-gate`: stop and return to planning when scope, contract, evidence,
  or validation invalidates the active delivery contract.
- `obs-gate`: choose `none`, `temporary`, or `durable` before adding logging;
  `none` is the default.
- `quality-first-subA`: use native evidence sidecars only where their separate
  perspective materially closes a required gate.
