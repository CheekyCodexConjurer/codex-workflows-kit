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

The Dev Router integrates into the Codex Desktop App without binary patching through Codex's official custom model provider configuration: declaring `[model_providers.dev-router]` AND selecting `model_provider = "dev-router"`, plus the model catalog override.

```
Codex Desktop GUI
  │ (User selects "GPT-Adaptive")
  ▼
Codex App Server (JSON-RPC)
  │ (needs model_provider = "dev-router" AND model_catalog_json;
  │  the catalog alone does NOT reach the proxy)
  ▼
Local Loopback Proxy (127.0.0.1:4040)
  │ (Intercepts POST /v1/responses)
  │── mode = 'off'    ──> Forwards a concrete model unchanged
  │── mode = 'shadow' ──> Queries Jev, logs recommendation, routes to baseline
  │── mode = 'on'     ──> Queries Jev choice, rewrites model & effort
  ▼
Upstream (auth-derived: chatgpt.com/backend-api/codex or api.openai.com/v1/responses)
  │ (Streams SSE chunks back to proxy)
  ▼
Codex Desktop GUI (Real-time token streaming)
```

Selecting the provider is mandatory: `model_catalog_json` only makes
`GPT-Adaptive` visible in the selector. If the top-level `model_provider` still
points at the default provider (a catalog-only configuration, `catalog_only` in
the readiness ladder below), Codex sends the alias to the ChatGPT backend and
fails with `The 'gpt-adaptive' model is not supported when using Codex with a
ChatGPT account.` `Register-DevRouterCodexIntegration` writes
`model_provider = "dev-router"` together with the catalog and never rewrites the
user's `model`.

### Composite Model Catalog

`Export-DevRouterModelCatalog` normalizes the official models from the Codex
models cache and registers `gpt-adaptive`. Codex CLI 0.145+ deserializes
`model_catalog_json` as a **sequence of sequences** of `ModelInfo`, so the file
root is a JSON array whose first element is the model group. All of these fields
are mandatory per entry; the legacy `id` / `supported_reasoning_efforts` /
`default_reasoning_effort` keys are rejected outright and make Codex fail to
load ANY configuration.

```json
[
  [
    {
      "slug": "gpt-adaptive",
      "display_name": "GPT-Adaptive",
      "description": "Dynamic parent model and reasoning effort routing via Dev Router and TypeSafe/Jev.",
      "model_provider_id": "dev-router",
      "supported_reasoning_levels": [
        { "effort": "medium", "description": "medium (default)" }
      ],
      "shell_type": "default",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 0,
      "base_instructions": "Dynamic parent model and reasoning effort routing via Dev Router and TypeSafe/Jev.",
      "support_verbosity": true,
      "truncation_policy": { "mode": "tokens", "limit": 10000 },
      "supports_parallel_tool_calls": true,
      "experimental_supported_tools": []
    }
  ]
]
```

`experimental_supported_tools` must serialize as `[]`, never `null`. The catalog
is written as UTF-8 **without BOM** and validated by
`Test-DevRouterModelCatalogShape` before it is registered; if validation fails,
the previous catalog is restored and the export fails closed, so Codex can never
be left unable to load its configuration.

The composite catalog is configured in `$CODEX_HOME/config.toml`:
```toml
model_provider = "dev-router"
model_catalog_json = "C:\\Users\\<user>\\.codex\\codex-workflows-kit\\model-catalog.json"

[model_providers.dev-router]
name = "Dev Router (Adaptive)"
wire_api = "responses"
base_url = "http://127.0.0.1:4040/v1"
requires_openai_auth = true
```

### Provider Selection, Manual Base and Readiness Ladder

Declaring `[model_providers.dev-router]` does not route anything by itself.
`Register-DevRouterCodexIntegration` is transactional and also SELECTS the
provider: it writes `model_provider = "dev-router"` alongside the catalog, and
never rewrites the user's `model`.

Registration sequence (fail-closed):
1. Snapshot the previous top-level `model`, `model_provider`,
   `model_catalog_json`, `model_reasoning_effort` and the previous
   `manual_base_model` / `manual_base_effort` to
   `$CODEX_HOME/codex-workflows-kit/dev-router-integration-backup.json`.
2. Build and validate the composite catalog (`Test-DevRouterModelCatalogShape`).
3. Deploy the proxy and the canonical policy files to the kit directory.
4. Start the proxy and require a healthy `/health` BEFORE writing the provider,
   so a dead port is never registered.
5. Seed a concrete `manual_base_model`: an explicit `-ManualBaseModel`, else an
   existing manual base, else a concrete top-level `model`.
6. Write `model_provider = "dev-router"`, `model_catalog_json` and the provider
   block, and validate the generated config with the real `codex debug models`.
7. Roll the whole change back on any failure.

`manual_base_model` / `manual_base_effort` separate the concrete base the proxy
falls back to from the local alias `gpt-adaptive`. The alias is never a base:
without a concrete `manual_base_model` (or a concrete top-level `model`),
registration fails closed with a clear message instead of inventing `Sol`.

`Unregister-DevRouterCodexIntegration` restores the exact previous top-level
values from the managed backup, removes only the Dev Router provider block and
its catalog, and stops only the proxy this kit owns (pid file). Custom
providers, profiles and unrelated definitions are preserved.

#### Readiness Ladder

`Get-DevRouterIntegrationReadiness` (also embedded in `Get-DevRouterStatus`
under `readiness`) reports a machine-checkable ladder that never claims `ready`
without proof:

| Status | Meaning |
| :--- | :--- |
| `inactive` | No catalog and no provider selection. |
| `catalog_only` | Catalog registered but the provider is NOT selected — the exact original Desktop bug: `GPT-Adaptive` is visible in the dropdown but every request goes to the default provider. |
| `provider_registered` | Provider selected but the proxy is not responding; requests would fail. |
| `degraded` | Provider selected and proxy running, but proxy health or a concrete manual base is missing. |
| `ready` | Catalog valid + provider actually SELECTED + proxy healthy + concrete manual base available. |

Status keys:

| Key | Meaning |
| :--- | :--- |
| `integration_status` | Ladder value above. |
| `provider_selected` | Top-level `model_provider` is `dev-router`. |
| `catalog_valid` | `model-catalog.json` passes structural validation. |
| `proxy_health` | `/health` answered `status = ok`. |
| `manual_base_available` | A resolvable concrete manual base exists. |
| `upstream_host` / `upstream_path` | Effective upstream after auth-based derivation. |
| `upstream_source` | Why that upstream was chosen (`env:DEV_ROUTER_UPSTREAM`, `config.chatgpt_base_url`, `auth-method:chatgpt` or `default:public-api`). |

When the ladder is not `ready`, `effective_mode` reports `bypass` instead of a
false `on`.

### Loopback Proxy Service (`scripts/dev-router-proxy.mjs`)

The proxy is a dependency-free Node.js service running locally on `127.0.0.1:4040`. It is a managed background process: `Register-DevRouterCodexIntegration` starts it and fails closed (full rollback) unless `/health` is healthy BEFORE the provider is selected, so a dead port is never registered; operators start and stop it explicitly with `scripts/switch-dev-router.ps1 -StartProxy` / `-StopProxy`. It detaches from the registering shell (the Desktop outlives the terminal) and logs to `dev-router-proxy.log` / `dev-router-proxy.err.log` in the kit directory.

- **`GET /health`**: Health status check returning `{ "status": "ok", "service": "dev-router-proxy" }`.
- **`GET /v1/models`**: Returns the active model catalog for Codex App Server.
- **`POST /v1/responses`**: Receives requests from Codex Desktop with the user's authentic ChatGPT session bearer token:
  - If `body.model` is `gpt-adaptive`: sanitizes objective, checks Dev Router state, resolves concrete model and reasoning effort via Jev choice or baseline, updates `body.model` and `body.reasoning.effort`.
  - Concrete models pass through unchanged: with `mode = off` a manually selected concrete model keeps its model and effort, and with `state.target = effort_only` the proxy routes it by effort only — the model never changes. `gpt-adaptive` is not required to activate effort routing.
  - **Sticky routing**: the decision is locked per boundary (`conversation_id`, response-chain `previous_response_id`, or `session_id`) in the same `dev-router-locks.json` the PowerShell core uses. Tool continuations inside the same turn reuse the locked route and never re-query Jev; a new boundary allows a new decision. Without a reliable boundary the proxy preserves the active route, and fails closed (local HTTP 400) if there is none.
  - **Alias guard**: `gpt-adaptive` is a local alias and can NEVER reach the upstream. If no concrete base model is configured (`manual_base_model` in the state, or a concrete top-level `model` in `config.toml`), the proxy answers `400 dev_router_missing_base` locally instead of inventing `Sol`.
  - Upstream request is forwarded transparently with original headers. The upstream base is derived from the Codex configuration instead of being hardcoded: `DEV_ROUTER_UPSTREAM` (explicit override), then the official `chatgpt_base_url`, then `preferred_auth_method = "chatgpt"` → `https://chatgpt.com/backend-api/codex`, otherwise the public `https://api.openai.com`. A base that already carries a path keeps it and only gets `/responses` appended (ChatGPT auth therefore uses `/backend-api/codex/responses`, while the public API keeps `/v1/responses`); `DEV_ROUTER_UPSTREAM_PATH` overrides the suffix entirely. `/health` reports `upstream_host`, `upstream_path`, `upstream_source`, `model_provider` and `preferred_auth_method` (never a credential).
  - Response chunks are streamed back to Codex Desktop in real time.
  - Abort handling attaches to `res.on('close')` guarded by `!res.writableEnded` to prevent premature client socket resets.

### Deterministic testing

`DEV_ROUTER_JEV_ENDPOINT` redirects the Jev call to a local mock so conformance
tests never touch the live TypeSafe endpoint. `scripts/test-dev-router-proxy.ps1`
drives the real proxy against a mock upstream and a mock Jev and asserts routing,
stickiness, the alias guard, fail-closed cases, Terra handling and the upstream
path shape (39 assertions, zero live calls).

### Surface Status Inspection

`Get-DevRouterStatus` provides an authoritative inspection record:

```powershell
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Status
```

Output:
```
=== Dev Router Status ===
Configured Mode:     on
Effective Mode:      on
Target:              effort_only
Integration Status:  ready
Baseline Model:      gpt-5.6-luna
Baseline Effort:     medium
Effective Model:     gpt-5.6-luna
Effective Effort:    high
Pending Change:      False
Route Lock Scope:    turn
Scope:               parent orchestrator in alignment and workflow

Notes: Dev Router is the effective Codex provider; the proxy is healthy on 127.0.0.1:4040 and forwards to chatgpt.com/backend-api/codex/responses (source=auth-method:chatgpt).
```

`Get-DevRouterStatus` also exposes the readiness fields under `readiness`:
`integration_status`, `provider_selected`, `catalog_valid`, `proxy_health`,
`manual_base_available`, `upstream_host`, `upstream_path` and
`upstream_source` (see the readiness ladder above). It never reports
`integration active` without that proof.

### Manual Desktop Validation

1. Start the proxy (registering the integration first when needed):
   ```powershell
   pwsh -NoProfile -File scripts/switch-dev-router.ps1 -StartProxy
   ```
2. Confirm the readiness ladder reaches `ready` (provider selected, proxy
   healthy, concrete manual base available):
   ```powershell
   pwsh -NoProfile -File scripts/switch-dev-router.ps1 -Status
   ```
3. In the Codex Desktop, select `GPT-Adaptive` in "Selecionar modelo" and send:
   `Responda somente DESKTOP_ADAPTIVE_OK.`
4. Verify in `$CODEX_HOME/codex-workflows-kit/dev-router-proxy.log` a route line
   with `incoming=gpt-adaptive` and a concrete `final=<concrete model>`,
   followed by `upstream_status=200`.

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

# Register / unregister the Desktop provider (transactional, with rollback)
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -RegisterIntegration
pwsh -NoProfile -File scripts/switch-dev-router.ps1 -UnregisterIntegration

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
