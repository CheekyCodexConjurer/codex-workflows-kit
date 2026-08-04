# Observability Decision

Use this reference before adding, retaining, or requesting instrumentation in a
code-facing task. The default is no new log. A log is useful only when it
answers a named diagnostic or operational question better than existing
evidence.

## Gate

1. State the unanswered question, the failure signature, and the action that a
   result will change.
2. Inspect the nearest existing logger, trace, metric, test, reproduction,
   command output, state snapshot, or persisted record first.
3. Choose exactly one result:
   - `none`: existing evidence is sufficient or the new event has no owner.
   - `temporary`: a bounded diagnostic capture is the cheapest next evidence.
   - `durable`: an operator needs a stable state transition, failure, or
     audit event after the task is complete.
4. For `temporary` or `durable`, write an `obs-contract` before editing.

## Obs contract

`{question,event,correlation,allowed-fields,redaction,level,cap/sampling,sink+TTL,access,off/removal,failure-behavior,validation}`

- Use the project's canonical logger or tracing path. Do not invent a second
  logger, a local dump directory, or a new dependency for a contained task.
- Correlate related work with an existing request, run, trace, job, or attempt
  identifier when one exists.
- Allowlist small, structured fields. Never emit secrets, credentials, raw
  prompts, full tool output, source payloads, personal data, or unbounded
  objects. Refer to a separately governed artifact by identifier and hash when
  a large payload is essential.
- Use level by outcome: TRACE/DEBUG for bounded diagnosis, INFO for useful
  state transition, WARN for recoverable degradation, ERROR for failed action.
- State an event/byte cap or sampling rule. Preserve failures and policy
  violations; do not add repetitive success chatter.
- `access` names the actual access control for the sink, or an explicit
  local-only boundary for a non-persistent capture.
- `off/removal` identifies the disable switch and removal owner/window; the
  temporary capture is removed or disabled when that window closes.
- `failure-behavior` is `fail-open` by default. Use fail-closed only when an
  explicitly approved audit/compliance contract explains the primary-flow
  impact.

## Lifecycle and safety

- Temporary instrumentation is disabled by default, has a clear enablement
  window and removal owner, and uses a sink with an enforceable TTL.
- Durable instrumentation has a named operational consumer and uses the
  project's retention and access controls.
- A comment, TODO, or verbal promise is not a TTL. Identify the actual sink,
  rotation, cleanup, or lifecycle rule that deletes data.
- Logging must not make the primary flow fail, block, retry, or persist state
  differently, unless an explicitly approved audit/compliance contract says
  otherwise.
- No new collector, hook, exporter, external endpoint, or dependency without
  explicit scope. Existing Codex session output, traces, or repository tools
  may be evidence; do not copy their raw content into product logs.

## Mode behavior and handoff

- No-edit work records the `obs-gate` decision or the evidence gap only.
- Code-changing work defaults to `none`; temporary or durable instrumentation
  must satisfy the `obs-contract`.
- Final plans and reviews state why the chosen class is sufficient. Final
  implementation reports how to retrieve it, disable/remove it, enforce
  retention, and validate it.

## Validation

Prove that the event answers the stated question, uses the canonical path,
keeps the default safe, enforces field and volume bounds, has a real retention
mechanism, and cannot break the primary flow. Remove or disable temporary
instrumentation as soon as the approved evidence window closes.
