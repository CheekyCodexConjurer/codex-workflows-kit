# Dev Router Reference

Automatic parent model and reasoning effort routing using TypeSafe/Jev semantic judgment across ALINHAMENTO and workflow modes in Codex App.

---

## 1. Overview and Core Philosophy

The **Dev Router** optimizes parent orchestrator performance, cost, and responsiveness by dynamically selecting the model and/or reasoning effort based on task complexity, risks, and turn characteristics.

Key principles:
1. **Universal Operation**: Operates both in explicit workflow modes (`mode=<MODE>`) and during interactive `ALINHAMENTO` conversations, without requiring explicit workflow invocation to be activated.
2. **Independent Orthogonal Selectors**: Separates `mode` (`off`, `shadow`, `on`) and `target` (`effort_only`, `model_only`, `model_and_effort`). `enabled` is not a separate source of truth. Initial installed state is `mode = off`, `target = effort_only`.
3. **Strict Model Allowlist**: Evaluates and routes exclusively among `Luna` (`gpt-5.6-luna`), `Sol` (`gpt-5.6-sol`), and `Astra` (`gpt-6-astra`). `Terra` (`gpt-5.6-terra`) is strictly prohibited from automatic classification, selection, and fallback targets; manual pass-through of user baseline `Terra` is supported without mutation.
4. **Target Axis Containment**: Jev is queried only about the axes permitted by the active target. When `target = effort_only`, the user's manual model is strictly preserved. When `target = model_only`, the user's manual effort is strictly preserved.
5. **Sanitized Context Projection**: Only lightweight structural metadata is submitted for classification. Full prompts, source code blocks, file paths, and secret tokens are stripped. Image presence is projected via a boolean flag (`has_images`) without sending image data.
6. **Thread-Isolated Scope Locking**: `ALINHAMENTO` conversations lock route decisions per user turn (`scope = 'turn'`). Explicit workflow executions lock route decisions per workflow execution (`scope = 'workflow'`). Locks are keyed by thread/conversation ID and validated against mode, target, and scope.
7. **Native Desktop App Integration (`GPT-Adaptive`)**: Codex Desktop App GUI exposes `GPT-Adaptive` directly in the model selector dropdown ("Selecionar modelo") via a composite model catalog and local loopback proxy (`127.0.0.1:4040`). When selected, the proxy dynamically resolves the turn via Dev Router, rewrites model and reasoning effort parameters, and streams responses without binary patching.
8. **Concurrency & Mutex Synchronization**: All state mutations and lock evaluations are synchronized across processes and threads using a named OS mutex (`Global\DevRouterSyncMutex`).
9. **Fail-Safe Baseline Fallback**: Any error (timeout, HTTP 401/429/5xx, offline state, missing credentials, proxy unreachable) immediately falls back to the user's manual baseline configuration. There is zero universal fallback to Astra.

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
| `Luna` | `gpt-5.6-luna` | Fast, token-efficient, routine parent and lightweight operations |
| `Sol` | `gpt-5.6-sol` | Balanced performance for general development and orchestration |
| `Astra` | `gpt-6-astra` | High-capability flagship for architecture, critical reviews, and complex debugging |

> [!CAUTION]
> **Terra (`gpt-5.6-terra`)** is strictly disallowed from all Dev Router automatic classification options, selections, and fallback targets. Manual pass-through of user baseline `Terra` is supported without mutation or crash.

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

### TypeSafe Choice Contract & Criteria Map

Questions to Jev are formulated using an ordered criteria map (`criteria = [ordered]@{ ... }`) rather than unstructured lists, per TypeSafe specifications:
- **`effort_only` criteria**: evaluates task complexity, depth of reasoning needed, risk of regressions, and need for deep planning.
- **`model_only` criteria**: evaluates architectural scope, context window demand, tool-use complexity, and instruction precision.
- **`model_and_effort` criteria**: evaluates joint model-effort trade-offs balancing latency, token consumption, and reasoning depth.

Classification parses real `confidence` and `probabilities` scores from the TypeSafe response. If Jev returns low confidence or an invalid enum, Dev Router gracefully falls back to baseline.

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
   - **Incompatible Combinations**: If the user's manual baseline effort is not supported by any allowed model, Dev Router returns `status = 'incompatible'` and falls back to baseline without re-opening unauthorized models.

3. **`model_and_effort`**:
   - The choice query presents allowlisted pairs (e.g., `Luna:low`, `Sol:medium`, `Astra:high`).
   - Pairs with unauthorized models (e.g. `Terra`) or unsupported effort combinations are strictly excluded from the options manifest.

---

## 5. Context Sanitization & Privacy

To prevent prompt bloat and data leakage, `Invoke-DevRouterTurn` applies strict projection filters via `New-DevRouterContextProjection`:
- **Code Removal**: All fenced code blocks (``` ... ```) and inline code are stripped.
- **Secret Redaction**: API keys, bearer tokens, passwords, and private identifiers are redacted.
- **Path Stripping**: Absolute and relative filesystem paths are stripped from text.
- **Length Bounds**: Input text is truncated to a safe diagnostic summary (maximum 500 characters).
- **Vision Containment**: Image attachments are represented only by the boolean flag `has_images = $true` with count; raw image bytes and URLs are never sent.

---

## 6. Scope Locking, Concurrency & Thread Isolation

Routing must not drift inconsistently mid-workflow or thrash between sub-steps.

- **`ALINHAMENTO`**: Lock scope is `turn`. Each user prompt acquires a route lock that expires upon turn completion, allowing natural adaptation as the user changes topics.
- **Explicit Workflows (`mode=<MODE>`)**: Lock scope is `workflow`. The route selected during the initial `FRAME` phase is locked for the entire duration of the workflow execution until the done gate, explicit cancellation, or release.
- **Thread Isolation**: All locks are stored in `dev-router-locks.json` keyed by `thread_id` (or `conversation_id`). State in one conversation cannot alter, read, or overwrite locks belonging to another conversation.
- **Lock Invalidation**: Route locks are validated against active `mode`, `target`, `scope`, and thread/turn IDs. Changing `mode` or `target` invalidates stale locks immediately.
- **Concurrency Synchronization**: All state and lock reads/writes are wrapped in `Invoke-DevRouterSynchronized` using a system-wide named Mutex (`Global\DevRouterSyncMutex`) to eliminate race conditions between the proxy server, background CLI executions, and manual shell invocations.

---

## 7. Native Desktop App Integration (`GPT-Adaptive`) & Loopback Proxy

The Dev Router integrates into the Codex Desktop App without binary patching through Codex's official custom model provider configuration and model catalog overrides.

```
Codex Desktop GUI
  │ (User selects "GPT-Adaptive")
  ▼
Codex App Server (JSON-RPC)
  │ (Reads model_catalog_json pointing to dev-router provider)
  ▼
Local Loopback Proxy (127.0.0.1:4040)
  │ (Intercepts POST /v1/responses)
  │── mode = 'off'    ──> Rewrites to user baseline model & effort
  │── mode = 'shadow' ──> Queries Jev, logs recommendation, routes to baseline
  │── mode = 'on'     ──> Queries Jev choice, rewrites model & effort
  ▼
Upstream API (api.openai.com/v1/responses)
  │ (Streams SSE chunks back to proxy)
  ▼
Codex Desktop GUI (Real-time token streaming)
```

### Composite Model Catalog

`Export-DevRouterModelCatalog` caches official OpenAI models and registers `gpt-adaptive`:

```json
{
  "id": "gpt-adaptive",
  "name": "GPT-Adaptive",
  "description": "Dynamic parent model and reasoning effort routing via Dev Router and TypeSafe/Jev.",
  "model_provider_id": "dev-router",
  "supports_reasoning_effort": true
}
```

This composite catalog is configured in `$CODEX_HOME/config.toml`:
```toml
model_catalog_json = "C:\\Users\\<user>\\.codex\\codex-workflows-kit\\dev-router-catalog.json"

[model_providers.dev-router]
name = "Dev Router (Adaptive)"
wire_api = "responses"
base_url = "http://127.0.0.1:4040/v1"
requires_openai_auth = true
```

### Loopback Proxy Service (`scripts/dev-router-proxy.mjs`)

The proxy is a dependency-free Node.js service running locally on `127.0.0.1:4040`:
- **`GET /health`**: Health status check returning `{ "status": "ok", "service": "dev-router-proxy" }`.
- **`GET /v1/models`**: Returns the active model catalog for Codex App Server.
- **`POST /v1/responses`**: Receives requests from Codex Desktop with the user's authentic ChatGPT session bearer token:
  - If `body.model` is `gpt-adaptive`: sanitizes objective, checks Dev Router state, resolves concrete model and reasoning effort via Jev choice or baseline, updates `body.model` and `body.reasoning.effort`.
  - Upstream request is forwarded transparently with original headers to the upstream provider (`api.openai.com`).
  - Response chunks are streamed back to Codex Desktop in real time.
  - Abort handling attaches to `res.on('close')` guarded by `!res.writableEnded` to prevent premature client socket resets.

### Surface Status Inspection

`Get-DevRouterStatus` provides an authoritative inspection record:

```powershell
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Status
```

Output:
```
Dev Router Status
=================
Configured Mode:    on
Effective Mode:     on
Target:             effort_only
Integration Status: integrated
Proxy Status:       running (port 4040)
Baseline Model:     gpt-5.6-luna
Baseline Effort:    medium
Effective Model:    gpt-5.6-luna
Effective Effort:   high
Route Lock Scope:   turn
Catalog Override:   configured
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
# Switch mode and target
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Mode on -Target effort_only

# Inspect status
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Status

# Control loopback proxy lifecycle explicitly
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -StartProxy
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -StopProxy
```

---

## 9. Fail-Safe Fallback Contract

Under all failure modes:
1. Jev service unreachable or timeout
2. HTTP 401 Unauthorized, 429 Rate Limit, or 5xx Server Error
3. Missing or expired Jev credentials
4. Unparseable or malformed choice response
5. Proxy offline or unreachable

The Dev Router immediately falls back to the user's manual baseline configuration (`effective_model = baseline_model`, `effective_effort = baseline_effort`). It **never** falls back to Astra, never throws an unhandled exception, and never blocks user interaction or streams corrupt data to Codex Desktop.
