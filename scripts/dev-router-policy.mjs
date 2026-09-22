import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const policy = require("./dev-router-policy.json");

const MODELS = Array.isArray(policy.models) ? policy.models : [];
const DISALLOWED = Array.isArray(policy.disallowed_for_automatic_routing) ? policy.disallowed_for_automatic_routing : [];
const ALL_VALID_EFFORTS = Array.isArray(policy.all_valid_efforts) ? policy.all_valid_efforts : [];
const PAIR_OPTION_EFFORTS = Array.isArray(policy.model_and_effort_option_efforts) ? policy.model_and_effort_option_efforts : [];
const EFFORT_DESCRIPTIONS = policy.effort_descriptions || {};

const ADAPTIVE_ALIAS = "gpt-adaptive";

function normalizeText(value) {
    return typeof value === "string" ? value.trim() : "";
}

function normalizeEffort(value) {
    const raw = normalizeText(value);
    return raw ? raw.toLowerCase() : null;
}

function sanitizeBaselineModel(value) {
    const raw = normalizeText(value);
    if (!raw || raw.toLowerCase() === ADAPTIVE_ALIAS) {
        return null;
    }
    return raw;
}

function toCanonical(entry) {
    return {
        name: entry.name,
        id: entry.id,
        aliases: Array.isArray(entry.aliases) ? [...entry.aliases] : [],
        supportedEfforts: Array.isArray(entry.supported_efforts) ? [...entry.supported_efforts] : [],
        profile: entry.profile,
        description: entry.description,
        automatic: entry.automatic === true
    };
}

function matchModelEntry(nameOrId) {
    const needle = normalizeText(nameOrId).toLowerCase();
    if (!needle) {
        return null;
    }
    for (const entry of MODELS) {
        if (normalizeText(entry.name).toLowerCase() === needle) {
            return entry;
        }
        if (normalizeText(entry.id).toLowerCase() === needle) {
            return entry;
        }
        for (const alias of (Array.isArray(entry.aliases) ? entry.aliases : [])) {
            if (normalizeText(alias).toLowerCase() === needle) {
                return entry;
            }
        }
    }
    return null;
}

function isDisallowedEntry(entry) {
    if (entry.automatic !== true) {
        return true;
    }
    const id = normalizeText(entry.id).toLowerCase();
    const name = normalizeText(entry.name).toLowerCase();
    return DISALLOWED.some((value) => {
        const needle = normalizeText(value).toLowerCase();
        return needle !== "" && (needle === id || needle === name);
    });
}

export function resolveModel(nameOrId, options = {}) {
    const includeDisallowed = options.includeDisallowed === true;
    const entry = matchModelEntry(nameOrId);
    if (!entry) {
        return null;
    }
    if (!includeDisallowed && isDisallowedEntry(entry)) {
        return null;
    }
    return toCanonical(entry);
}

export function canonicalModelName(nameOrId) {
    const resolved = resolveModel(nameOrId, { includeDisallowed: true });
    return resolved ? resolved.name : null;
}

export function modelEfforts(modelOrName) {
    const resolved = resolveModel(modelOrName, { includeDisallowed: true });
    return resolved ? [...resolved.supportedEfforts] : [];
}

export function isEffortSupported(model, effort) {
    const normalized = normalizeEffort(effort);
    if (!normalized) {
        return false;
    }
    return modelEfforts(model).some((supported) => supported.toLowerCase() === normalized);
}

export function isModelAllowedForAutomaticRouting(model) {
    return resolveModel(model, { includeDisallowed: false }) !== null;
}

export function toUpstreamModelId(model) {
    const raw = normalizeText(model);
    if (!raw || raw.toLowerCase() === ADAPTIVE_ALIAS) {
        return null;
    }
    const resolved = resolveModel(raw, { includeDisallowed: true });
    return resolved ? resolved.id : raw;
}

function automaticModels() {
    return MODELS.filter((entry) => !isDisallowedEntry(entry));
}

function effortDescription(effort) {
    const key = normalizeText(effort).toLowerCase();
    if (Object.prototype.hasOwnProperty.call(EFFORT_DESCRIPTIONS, key)) {
        return EFFORT_DESCRIPTIONS[key];
    }
    return `Reasoning effort: ${effort}`;
}

function effortOptionsForModel(baselineModel) {
    const resolved = resolveModel(baselineModel, { includeDisallowed: true });
    if (!resolved || resolved.supportedEfforts.length === 0) {
        return ["low", "medium", "high"];
    }
    return [...resolved.supportedEfforts];
}

function pairOptions() {
    const pairs = [];
    for (const entry of automaticModels()) {
        for (const effort of entry.supported_efforts) {
            const normalized = normalizeText(effort).toLowerCase();
            if (PAIR_OPTION_EFFORTS.some((allowed) => allowed.toLowerCase() === normalized)) {
                pairs.push(`${entry.name}:${normalized}`);
            }
        }
    }
    return pairs;
}

function buildCriteriaUnfiltered(target, { baselineModel, baselineEffort } = {}) {
    const criteria = {};
    if (target === "effort_only") {
        for (const effort of effortOptionsForModel(baselineModel)) {
            criteria[effort] = effortDescription(effort);
        }
        return criteria;
    }
    if (target === "model_only") {
        for (const entry of automaticModels()) {
            const normalizedEffort = normalizeEffort(baselineEffort);
            if (normalizedEffort && !isEffortSupported(entry.name, normalizedEffort)) {
                continue;
            }
            criteria[entry.name] = `${entry.name} - ${entry.description}`;
        }
        return criteria;
    }
    if (target === "model_and_effort") {
        for (const entry of automaticModels()) {
            for (const effort of entry.supported_efforts) {
                const normalized = normalizeText(effort).toLowerCase();
                if (!PAIR_OPTION_EFFORTS.some((allowed) => allowed.toLowerCase() === normalized)) {
                    continue;
                }
                criteria[`${entry.name}:${normalized}`] = `Model ${entry.name} (${entry.profile}) paired with reasoning effort ${normalized}.`;
            }
        }
        return criteria;
    }
    throw new Error(`Unknown target '${target}'.`);
}

export function buildCriteria(target, options = {}) {
    return buildCriteriaUnfiltered(target, options);
}

export function buildJevInstructions(target, { baselineModel, baselineEffort } = {}) {
    if (target === "effort_only") {
        const name = canonicalModelName(baselineModel) ?? normalizeText(baselineModel);
        return `Select the appropriate reasoning effort for this task running on model '${name}'.`;
    }
    if (target === "model_only") {
        const effort = normalizeEffort(baselineEffort) ?? "";
        return `Select the best model from the allowlist for this task requiring reasoning effort '${effort}'.`;
    }
    if (target === "model_and_effort") {
        return "Select the optimal model and reasoning effort pair from the allowlist for this task.";
    }
    throw new Error(`Unknown target '${target}'.`);
}

export function buildOptionSet(target, { baselineModel, baselineEffort } = {}) {
    const instructions = buildJevInstructions(target, { baselineModel, baselineEffort });
    if (target === "effort_only") {
        const criteria = buildCriteriaUnfiltered(target, { baselineModel, baselineEffort });
        return {
            target,
            instructions,
            options: Object.keys(criteria),
            criteria,
            incompatible: false,
            reason: null
        };
    }
    if (target === "model_only") {
        const criteria = buildCriteriaUnfiltered(target, { baselineModel, baselineEffort });
        const options = Object.keys(criteria);
        if (options.length === 0) {
            const effort = normalizeEffort(baselineEffort) ?? "";
            return {
                target,
                instructions,
                options: [],
                criteria: {},
                incompatible: true,
                reason: `No permitted model supports effort '${effort}'.`
            };
        }
        return { target, instructions, options, criteria, incompatible: false, reason: null };
    }
    if (target === "model_and_effort") {
        const criteria = buildCriteriaUnfiltered(target, { baselineModel, baselineEffort });
        const options = pairOptions();
        return { target, instructions, options, criteria, incompatible: false, reason: null };
    }
    throw new Error(`Unknown target '${target}'.`);
}

function parseFailure(status, reason, model, effort, selectedRaw) {
    return { ok: false, status, model, effort, reason, selectedRaw };
}

export function parseChoice(choice, target, { baselineModel, baselineEffort } = {}) {
    const safeBaselineModel = sanitizeBaselineModel(baselineModel);
    const baselineName = canonicalModelName(safeBaselineModel) ?? safeBaselineModel;
    const baselineEffortValue = normalizeEffort(baselineEffort);
    const optionSet = buildOptionSet(target, { baselineModel: safeBaselineModel, baselineEffort: baselineEffortValue });
    const raw = normalizeText(choice);

    if (!raw) {
        return parseFailure("invalid_choice", "Empty choice returned by Jev.", baselineName, baselineEffortValue, null);
    }
    if (optionSet.incompatible) {
        return parseFailure("pair_incompatible", optionSet.reason, baselineName, baselineEffortValue, raw);
    }

    const matched = optionSet.options.find((option) => option.toLowerCase() === raw.toLowerCase());
    if (!matched) {
        if (target === "effort_only") {
            const candidate = normalizeEffort(raw);
            if (candidate && ALL_VALID_EFFORTS.some((value) => value.toLowerCase() === candidate)) {
                return parseFailure("pair_incompatible", `Effort '${candidate}' is not supported by model '${baselineName}'.`, baselineName, baselineEffortValue, raw);
            }
            return parseFailure("invalid_choice", `Choice '${raw}' was not in permitted options: (${optionSet.options.join(", ")}).`, baselineName, baselineEffortValue, raw);
        }
        if (target === "model_only") {
            if (resolveModel(raw, { includeDisallowed: true })) {
                return parseFailure("disallowed_model", `Model '${raw}' is not in the automatic routing allowlist.`, baselineName, baselineEffortValue, raw);
            }
            return parseFailure("invalid_choice", `Choice '${raw}' was not in permitted options: (${optionSet.options.join(", ")}).`, baselineName, baselineEffortValue, raw);
        }
        const parts = raw.split(":");
        if (parts.length !== 2) {
            return parseFailure("invalid_format", `Invalid Model:Effort pair '${raw}'.`, baselineName, baselineEffortValue, raw);
        }
        const modelRaw = normalizeText(parts[0]);
        const effortRaw = normalizeEffort(parts[1]);
        const resolved = resolveModel(modelRaw, { includeDisallowed: true });
        if (!resolved || !isModelAllowedForAutomaticRouting(resolved.name)) {
            return parseFailure("disallowed_model", `Model '${modelRaw}' is not in the automatic routing allowlist.`, baselineName, baselineEffortValue, raw);
        }
        if (!isEffortSupported(resolved.name, effortRaw)) {
            return parseFailure("pair_incompatible", `Model '${resolved.name}' does not support effort '${effortRaw}'.`, baselineName, baselineEffortValue, raw);
        }
        return parseFailure("invalid_choice", `Choice '${raw}' was not in permitted options: (${optionSet.options.join(", ")}).`, baselineName, baselineEffortValue, raw);
    }

    if (target === "effort_only") {
        return { ok: true, status: "ok", model: baselineName, effort: normalizeEffort(matched), reason: "jev_choice", selectedRaw: matched };
    }
    if (target === "model_only") {
        const resolved = resolveModel(matched, { includeDisallowed: true });
        if (!resolved || !isModelAllowedForAutomaticRouting(resolved.name)) {
            return parseFailure("disallowed_model", `Model '${matched}' is not in the automatic routing allowlist.`, baselineName, baselineEffortValue, matched);
        }
        return { ok: true, status: "ok", model: resolved.name, effort: baselineEffortValue, reason: "jev_choice", selectedRaw: matched };
    }
    const parts = matched.split(":");
    const resolvedModel = resolveModel(parts[0], { includeDisallowed: true });
    return {
        ok: true,
        status: "ok",
        model: resolvedModel ? resolvedModel.name : normalizeText(parts[0]),
        effort: normalizeEffort(parts[1]),
        reason: "jev_choice",
        selectedRaw: matched
    };
}

const TRANSPORT_FAILURE_STATUSES = ["unavailable", "timeout", "invalid_response", "error"];

export function decideRoute({ mode, target, baseline, requestedEffort, jevChoice, jevStatus } = {}) {
    const baselineModel = sanitizeBaselineModel(baseline?.model);
    const baselineEffort = normalizeEffort(baseline?.effort);
    const requested = normalizeEffort(requestedEffort);
    const baseEffort = requested ?? baselineEffort;
    const statusIn = normalizeText(jevStatus).toLowerCase();
    const rawChoice = normalizeText(jevChoice) || null;
    const transportFailure = TRANSPORT_FAILURE_STATUSES.includes(statusIn);

    if (mode === "off") {
        return {
            model: baselineModel,
            effort: baseEffort,
            status: "off",
            isFallback: false,
            reason: "router_off",
            jevCalled: false
        };
    }

    if (mode === "shadow") {
        return {
            model: baselineModel,
            effort: baseEffort,
            status: transportFailure ? statusIn : "shadow",
            isFallback: false,
            reason: "shadow_observation",
            jevCalled: true
        };
    }

    if (mode !== "on") {
        return {
            model: baselineModel,
            effort: baseEffort,
            status: "invalid_mode",
            isFallback: true,
            reason: `Unsupported mode '${mode}'.`,
            jevCalled: false
        };
    }

    if (!baselineModel) {
        return {
            model: null,
            effort: baseEffort,
            status: "missing_baseline",
            isFallback: true,
            reason: "No concrete baseline model is available.",
            jevCalled: false
        };
    }

    if (statusIn === "incompatible" && !rawChoice) {
        return {
            model: baselineModel,
            effort: baseEffort,
            status: "incompatible",
            isFallback: true,
            reason: "Jev options are incompatible with the requested effort.",
            jevCalled: false
        };
    }

    if (transportFailure || !rawChoice) {
        const status = transportFailure ? statusIn : "invalid_response";
        return {
            model: baselineModel,
            effort: baseEffort,
            status,
            isFallback: true,
            reason: transportFailure ? `Jev ${status}.` : "Jev returned no usable choice.",
            jevCalled: true
        };
    }

    let parsed;
    try {
        parsed = parseChoice(rawChoice, target, { baselineModel, baselineEffort: baseEffort });
    } catch (error) {
        return {
            model: baselineModel,
            effort: baseEffort,
            status: "invalid_response",
            isFallback: true,
            reason: error instanceof Error ? error.message : String(error),
            jevCalled: true
        };
    }
    if (!parsed.ok) {
        return {
            model: baselineModel,
            effort: baseEffort,
            status: parsed.status === "pair_incompatible" ? "incompatible" : "invalid_response",
            isFallback: true,
            reason: parsed.reason,
            jevCalled: true
        };
    }

    return {
        model: parsed.model,
        effort: parsed.effort ?? baseEffort,
        status: "ok",
        isFallback: false,
        reason: parsed.reason || "jev_choice",
        jevCalled: true
    };
}

export function deriveBoundaryKey({ conversationId, responseChainRoot, previousResponseId, requestSessionId } = {}) {
    const candidates = [conversationId, responseChainRoot, previousResponseId, requestSessionId];
    for (const candidate of candidates) {
        const value = normalizeText(candidate);
        if (value) {
            return value;
        }
    }
    return null;
}

function lockValue(lock, snakeKey, camelKey) {
    if (Object.prototype.hasOwnProperty.call(lock, snakeKey)) {
        return lock[snakeKey];
    }
    if (camelKey && Object.prototype.hasOwnProperty.call(lock, camelKey)) {
        return lock[camelKey];
    }
    return undefined;
}

export function isLockValid(lock, { mode, target, surface, executionId, turnId } = {}) {
    if (!lock || typeof lock !== "object") {
        return false;
    }
    const lockMode = lockValue(lock, "mode", "mode");
    if (lockMode !== undefined && String(lockMode ?? "") !== String(mode ?? "")) {
        return false;
    }
    const lockTarget = lockValue(lock, "target", "target");
    if (lockTarget !== undefined && String(lockTarget ?? "") !== String(target ?? "")) {
        return false;
    }
    const scope = String(lockValue(lock, "scope", "scope") ?? "");
    if (surface === "workflow") {
        if (scope !== "workflow") {
            return false;
        }
        const lockedExecution = lockValue(lock, "execution_id", "executionId");
        if (normalizeText(executionId) && lockedExecution !== undefined && String(lockedExecution ?? "") !== String(executionId)) {
            return false;
        }
        return true;
    }
    if (scope !== "turn") {
        return false;
    }
    const lockedTurn = lockValue(lock, "turn_id", "turnId");
    if (normalizeText(turnId) && lockedTurn !== undefined && String(lockedTurn ?? "") !== String(turnId)) {
        return false;
    }
    return true;
}

/**
 * Canonical ChatGPT / OpenAI backend bases. The ChatGPT-auth Codex backend is
 * NOT the public API host: the installed CLI resolves it to
 * `<chatgpt-host>/backend-api/codex` (verified against the binary's own base
 * table and live: the public `/v1/responses` path 404s there). The Dev Router
 * must never guess for a ChatGPT account.
 */
export const OPENAI_PUBLIC_UPSTREAM = "https://api.openai.com";
export const CHATGPT_CODEX_UPSTREAM = "https://chatgpt.com/backend-api/codex";

/**
 * Resolves the upstream base for the local proxy.
 *
 * Priority (never invents for a ChatGPT account):
 *  1. explicit operator/test override (`DEV_ROUTER_UPSTREAM`);
 *  2. the official `chatgpt_base_url` config value when set;
 *  3. the ChatGPT backend when the configured auth method is `chatgpt`;
 *  4. the public OpenAI API otherwise.
 *
 * Returns `{ upstream, source }` so status/logging can report WHY a host was
 * chosen without exposing credentials.
 */
export function deriveUpstream({ envOverride, chatgptBaseUrl, preferredAuthMethod, codexHome } = {}) {
    const override = normalizeText(envOverride);
    if (override) {
        return { upstream: override, source: "env:DEV_ROUTER_UPSTREAM" };
    }
    const configured = normalizeText(chatgptBaseUrl);
    if (configured) {
        return { upstream: configured, source: "config.chatgpt_base_url" };
    }
    const authMethod = normalizeText(preferredAuthMethod).toLowerCase();
    if (authMethod === "chatgpt") {
        return { upstream: CHATGPT_CODEX_UPSTREAM, source: "auth-method:chatgpt" };
    }
    if (authMethod) {
        return { upstream: OPENAI_PUBLIC_UPSTREAM, source: `auth-method:${authMethod}` };
    }
    return {
        upstream: OPENAI_PUBLIC_UPSTREAM,
        source: normalizeText(codexHome) ? "default:public-api" : "default:public-api"
    };
}