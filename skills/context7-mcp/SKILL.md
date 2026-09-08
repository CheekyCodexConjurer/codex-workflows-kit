---
name: context7-mcp
description: Fetch current documentation and code examples from Context7 for external libraries, frameworks, SDKs, or APIs when syntax, versions, or setup details are needed. Activates for library lookups, API queries, or version migration questions.
---

# Context7 MCP

Canonical guidance for fetching current documentation and code examples from Context7 via its global credential-free endpoint (`https://mcp.context7.com/mcp`).

## Automatic Preflight and Use

The parent and every sub-agent must check Context7 availability during the
canonical MCP preflight and select it automatically when current external
documentation is relevant. Context7 has no repository index to initialize or
refresh: once availability is proven, use the mandatory resolve -> query flow
only for a concrete documentation trigger, and fail closed to official docs
when the service is unavailable.

## Operational Baseline & Pricing Contract

- **Official Sources**: [Context7 upstream](https://raw.githubusercontent.com/upstash/context7/master/README.md) and [Context7 Plans](https://context7.com/plans).
- **Free Tier Only**: Global credential-free endpoint only. No OAuth, no `ctx7 setup`, no Pro tier, no private repository parsing, no paid overage. Never access, read, or modify client auth caches, tokens, or profiles.
- **Quota Baseline**: As of 2026-09 plans documentation, Free includes 1,000 API calls/month, plus 20 bonus daily calls once depleted. This is a dated historical baseline, NOT a permanent anonymous SLA. Do not equate unauthenticated usage (`auth_status=not_logged_in`) with a free logged account.
- **Availability Scope**: Missing tools in a workspace do not warrant per-repository installation (`npm install`, local configs). Context7 is a global host service; use only where host runtime is proven.

## Two-Phase Tool Workflow

Always follow the atomic two-phase workflow: `resolve-library-id` -> `query-docs`.

### Phase 1: Resolve Library Identifier (`resolve-library-id`)

1. **Version / Name != Library ID Rule**:
   - A library name, package name, or version string (e.g., `React`, `React 19.2.7`, `next@14`, `vue 3.4`) is strictly **NOT** a Context7 `libraryId`.
   - **Strict Prohibition on Inferring/Fabricating IDs**: NEVER construct, synthesize, or infer a `/org/project` or `/org/repo/version` identifier from package names or semver (e.g., NEVER invent `/react/react/v19.2.7` when given `React 19.2.7`). Context7 library IDs are server-assigned identifiers that must come exclusively from `resolve-library-id` or explicit user-provided input.
2. **Prerequisite Rule**: Resolving is mandatory before calling `query-docs` unless an exact library ID was already returned by `resolve-library-id` earlier in the current task/session, or the user explicitly provided a library ID in `/org/project` or `/org/project/version` format. If the user provides only a library name and/or version without an explicit library ID, you MUST call `resolve-library-id` first. Never bypass resolution.
3. **Resolution Parameters**:
   - Call `resolve-library-id` with:
     - `libraryName`: Exact official library name (e.g., `React`, `Next.js`, `Prisma`, `Supabase`).
     - `query`: Focused concrete topic string to rank relevance (e.g., `useActionState hook signature`).
   - **No Placeholder Queries**: NEVER use placeholder strings (e.g., `<topico atomico>`, `<topic>`, `<concept>`, `[query]`). If the user prompt omits a specific topic/concept, identify the concrete concept from context or ask the user what topic they want to inspect before querying.
4. **Session Reuse**: Reuse resolved library IDs across the same task/package session. If tool runtime requires repeating resolve across contexts, document it.
5. **Call Budget**: Maximum 3 calls per question.

### Phase 2: Query Documentation (`query-docs`)

1. Call `query-docs` with:
   - `libraryId`: Authoritatively resolved Context7 library ID (returned by `resolve-library-id` or explicitly provided by user).
   - `query`: Atomic, concrete, sanitized concept string (NEVER a placeholder like `<topico atomico>`).
2. **Query Content & Sanitization Boundary**:
   - Query must be concrete, atomic, and scoped to a single concept (e.g., `React useEffect cleanup`, `Express JWT middleware`).
   - **Prompt User If Topic Absent**: If the user only specified a library/version without indicating what topic, hook, or API to consult, ask the user for the topic rather than guessing or sending placeholder queries.
   - **Strict Sanitization**: Never transmit raw user prompts, uncurated queries, conversation history, proprietary codebase snippets, secrets, API keys, tokens, or PII. (Remediates legacy guidance that improperly recommended forwarding full user questions).
3. **Source & Version Mismatch Verification**:
   - Inspect returned source URLs and version metadata.
   - Tagged library IDs (e.g., `/react/react/v19.2.7` if returned by resolve) may return links pointing to `main` branch rather than the requested tag.
   - If a source link points to `main` or a differing version, explicitly declare the version mismatch to the user. Never assume or guarantee tag parity without verification.
4. **Call Budget**: Maximum 3 calls per question.

## Multi-Worker Deduplication, Packet Reuse & No-Write Safety

- **Shared Packet**: Workers coordinate lookups using a shared evidence packet:
  `{libraryId, version, query, source, date, limits}`
- **Single Owner**: Exactly one worker owns the lookup for a given question; peer workers consume the evidence packet to prevent duplicate queries and quota exhaustion.
- **Packet Reuse vs. Repeated Query (Zero Calls)**:
  - When a complete documentation packet has already been retrieved for the library/topic, and the required answer is already available in the session or shared packet, reuse the packet directly with **ZERO calls** (`zero calls`).
  - Do NOT repeat queries or make duplicate tool calls when documentation is already available.
  - Making an additional query is permitted only when answering a genuinely new, distinct technical question not covered by the existing documentation packet, adhering to the 3-call budget.
- **No-Write Boundary**: In read-only or no-write modes (`ALINHAMENTO`, `PLAN`, `COMMIT`), do not write local disk caches, metadata files, or repo artifacts. Shared packets must remain in-memory or in transit messages.

## Error Handling & Quota Exhaustion (401 / 403 / 429)

When encountering HTTP 401, 403, or 429:
1. **Stop Immediately**: Cease Context7 calls; do not initiate retry storms, backoff loops, or repetitive polling.
2. **No Paid Escalation**: Never advise purchasing a key, upgrading to Pro, or entering billing credentials.
3. **No Model Switch**: Do not change AI models or backend providers as a fallback.
4. **Disclosed Alternative**: Disclose quota/access exhaustion to the user and switch to official project documentation websites (e.g., official docs URLs) as the standard manual fallback.
