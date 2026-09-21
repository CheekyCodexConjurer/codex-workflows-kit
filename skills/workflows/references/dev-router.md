# Dev Router Reference

Automatic parent model and reasoning effort routing using TypeSafe/Jev semantic judgment across ALINHAMENTO and workflow modes in Codex App.

---

## 1. Overview and Core Philosophy

The **Dev Router** optimizes parent orchestrator performance, cost, and responsiveness by dynamically selecting the model and/or reasoning effort based on task complexity, risks, and turn characteristics.

Key principles:
1. **Universal Operation**: Operates both in explicit workflow modes (`mode=<MODE>`) and during interactive `ALINHAMENTO` conversations, without requiring explicit workflow invocation to be activated.
2. **Independent Orthogonal Selectors**: Separates `mode` (`off`, `shadow`, `on`) and `target` (`effort_only`, `model_only`, `model_and_effort`). `enabled` is not a separate source of truth.
3. **Strict Model Allowlist**: Evaluates and routes exclusively among `Luna` (`gpt-5.6-luna`), `Sol` (`gpt-5.6-sol`), and `Astra` (`gpt-6-astra`). `Terra` (`gpt-5.6-terra`) is strictly prohibited from classification, selection, and fallback.
4. **Target Axis Containment**: Jev is queried only about the axes permitted by the active target. When `target = effort_only`, the user's manual model is strictly preserved. When `target = model_only`, the user's manual effort is strictly preserved.
5. **Sanitized Context Projection**: Only lightweight structural metadata is submitted for classification. Full prompts, source code blocks, file paths, and secret tokens are stripped. Image presence is projected via a boolean flag (`has_images`) without sending image data.
6. **Thread-Isolated Scope Locking**: `ALINHAMENTO` conversations lock route decisions per user turn (`scope = 'turn'`). Explicit workflow executions lock route decisions per workflow execution (`scope = 'workflow'`). Locks are keyed by thread/conversation ID to prevent cross-conversation leakage.
7. **Honest Surface Integration**: Codex Desktop App GUI lacks a public dynamic injection IPC without binary patching (which is prohibited). The GUI adapter honestly reports `integration_status = 'unintegrated'` with `effective_mode = 'bypass'`, while CLI harness execution (`codex exec -m ... -c model_reasoning_effort=...`) applies dynamic routing.
8. **Fail-Safe Baseline Fallback**: Any error (timeout, HTTP 401/429/5xx, offline state, missing credentials) immediately falls back to the user's manual baseline configuration. There is zero universal fallback to Astra.

---

## 2. Independent Selectors

The Dev Router configuration is stored globally at `$CODEX_HOME/codex-workflows-kit/dev-router-state.json`.

### Mode Selector

| Mode | Behavior |
| :--- | :--- |
| `off` (default) | Dev Router is completely dormant. User manual baseline is returned. No Jev calls or projections are made. |
| `shadow` | Dev Router classifies the turn via Jev, logs the recommended route to state, but applies the user manual baseline without mutating runtime parameters. |
| `on` | Dev Router classifies the turn via Jev, records the route lock, and applies the selected model and/or reasoning effort to the execution surface. |

### Target Selector

| Target | Jev Query Scope | Model Action | Effort Action |
| :--- | :--- | :--- | :--- |
| `effort_only` (default) | Reasoning effort levels only (`minimal`, `low`, `medium`, `high`, `xhigh`) | **Preserved**: User's baseline model is untouched | Dynamically selected by Jev |
| `model_only` | Model candidates only (`Luna`, `Sol`, `Astra`) | Dynamically selected by Jev | **Preserved**: User's baseline effort is untouched |
| `model_and_effort` | Allowlisted model and effort pairs | Dynamically selected by Jev | Dynamically selected by Jev |

---

## 3. Model & Reasoning Effort Catalog

### Model Allowlist

| Friendly Name | Technical Model ID | Description |
| :--- | :--- | :--- |
| `Luna` | `gpt-5.6-luna` | Fast, token-efficient, primary worker and routine parent |
| `Sol` | `gpt-5.6-sol` | Balanced performance for general development and orchestration |
| `Astra` | `gpt-6-astra` | High-capability flagship for architecture, critical reviews, and complex debugging |

> [!CAUTION]
> **Terra (`gpt-5.6-terra`)** is strictly disallowed from all Dev Router classification options, selections, and fallback targets.

### Supported Reasoning Efforts

Reasoning effort strings must match the exact deserializer enum expected by the Codex execution harness:
- `none`
- `minimal`
- `low`
- `medium`
- `high`
- `xhigh`

---

## 4. Jev Choice Policy & Target Scoping

Routing decisions use the TypeSafe/Jev `choice` primitive with a versioned, offline choice policy (`dev-router-v1`).

### Target Scoping Rules

1. **`effort_only`**:
   - The choice query presents options strictly corresponding to effort levels for the current baseline model:
     - `minimal`: trivial greetings, single-line queries, casual conversation
     - `low`: simple lookups, quick syntax questions
     - `medium`: standard feature development, ordinary explanations
     - `high`: multi-file logic, test writing, bug hunting
     - `xhigh`: complex architecture, multi-system integration, deep concurrency
   - The model is **never** presented as a choice and **never** modified.

2. **`model_only`**:
   - The choice query presents options strictly corresponding to allowlisted models (`Luna`, `Sol`, `Astra`).
   - The reasoning effort is **never** presented as a choice and **never** modified.

3. **`model_and_effort`**:
   - The choice query presents allowlisted pairs (e.g., `Luna:low`, `Sol:medium`, `Astra:high`).
   - Pairs with unauthorized models (e.g. `Terra`) are excluded from the options manifest.

---

## 5. Context Sanitization & Privacy

To prevent prompt bloat and data leakage, `Invoke-DevRouterTurn` applies strict projection filters via `New-DevRouterContextProjection`:
- **Code Removal**: All fenced code blocks (``` ... ```) and inline code are stripped.
- **Secret Redaction**: API keys, bearer tokens, passwords, and private identifiers are redacted.
- **Path Stripping**: Absolute and relative filesystem paths are stripped from text.
- **Length Bounds**: Input text is truncated to a safe diagnostic summary (maximum 500 characters).
- **Vision Containment**: Image attachments are represented only by the boolean flag `has_images = $true` with count; raw image bytes and URLs are never sent.

---

## 6. Scope Locking & Thread Isolation

Routing must not drift inconsistently mid-workflow or thrash between sub-steps.

- **`ALINHAMENTO`**: Lock scope is `turn`. Each user prompt acquires a route lock that expires upon turn completion, allowing natural adaptation as the user changes topics.
- **Explicit Workflows (`mode=<MODE>`)**: Lock scope is `workflow`. The route selected during the initial `FRAME` phase is locked for the entire duration of the workflow execution until the done gate, explicit cancellation, or release.
- **Thread Isolation**: All locks are stored in `dev-router-locks.json` keyed by `thread_id` (or `conversation_id`). State in one conversation cannot alter, read, or overwrite locks belonging to another conversation.

---

## 7. Surface Integration & Status Reporting

`Get-DevRouterStatus` provides an authoritative inspection record:

```json
{
  "configured_mode": "on",
  "effective_mode": "bypass",
  "target": "effort_only",
  "integration_status": "unintegrated",
  "baseline_model": "gpt-5.6-luna",
  "baseline_effort": "medium",
  "effective_model": "gpt-5.6-luna",
  "effective_effort": "medium",
  "pending_change": false,
  "route_lock_scope": null,
  "notes": "Codex Desktop App GUI has no dynamic external model injection IPC; operating in bypass mode."
}
```

- **Codex Desktop App GUI**: Honestly marked `integration_status = 'unintegrated'` with `effective_mode = 'bypass'` to avoid misrepresenting capabilities or patching proprietary app binaries.
- **CLI Harness**: `integration_status = 'integrated'`, applying flags:
  ```powershell
  codex exec -m $effectiveModel -c "model_reasoning_effort=`"$effectiveEffort`""
  ```

---

## 8. Hotkeys & Prompt Pad Integration

AutoHotkey shortcuts in `ahk/codex_prompt_pad.ahk`:

| Hotkey | Action |
| :--- | :--- |
| `!Numpad1` | Switch Dev Router mode to `off` |
| `!Numpad2` | Switch Dev Router mode to `shadow` |
| `!Numpad3` | Switch Dev Router target to `effort_only` |
| `!Numpad4` | Switch Dev Router target to `model_only` |
| `!Numpad5` | Switch Dev Router target to `model_and_effort` |
| `!Numpad0` | Inspect Dev Router status |

CLI switcher:
```powershell
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Mode on -Target effort_only
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Status
```

---

## 9. Fail-Safe Fallback Contract

Under all failure modes:
1. Jev service unreachable or timeout
2. HTTP 401 Unauthorized, 429 Rate Limit, or 5xx Server Error
3. Missing or expired Jev credentials
4. Unparseable or malformed choice response

The Dev Router immediately falls back to the user's manual baseline configuration (`effective_model = baseline_model`, `effective_effort = baseline_effort`). It **never** falls back to Astra, never throws an unhandled exception, and never blocks user interaction.
