#!/usr/bin/env node
import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import { URL } from "node:url";
import {
    canonicalModelName,
    isEffortSupported,
    buildOptionSet,
    decideRoute,
    deriveBoundaryKey,
    isLockValid,
    toUpstreamModelId,
    deriveUpstream
} from "./dev-router-policy.mjs";

const DEFAULT_PORT = 4040;
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_UPSTREAM = "https://api.openai.com";
const DEFAULT_JEV_ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const DEFAULT_JEV_TIMEOUT_MS = 3000;
const ADAPTIVE_MODEL = "gpt-adaptive";
const MAX_CHAIN_ENTRIES = 500;
const RESPONSE_ID_PATTERN = /"id"\s*:\s*"(resp[A-Za-z0-9_-]*)"/g;

function parseArgs() {
    const args = process.argv.slice(2);
    const options = {
        port: Number(process.env.DEV_ROUTER_PORT) || DEFAULT_PORT,
        host: process.env.DEV_ROUTER_HOST || DEFAULT_HOST,
        // Explicit operator/test override; the effective upstream base is
        // resolved later from `preferred_auth_method` / `chatgpt_base_url`.
        upstreamOverride: process.env.DEV_ROUTER_UPSTREAM || null,
        upstreamPath: process.env.DEV_ROUTER_UPSTREAM_PATH || null,
        jevEndpoint: process.env.DEV_ROUTER_JEV_ENDPOINT || DEFAULT_JEV_ENDPOINT,
        jevTimeoutMs: Number(process.env.DEV_ROUTER_JEV_TIMEOUT_MS) || DEFAULT_JEV_TIMEOUT_MS,
        codexHome: process.env.CODEX_HOME || path.join(process.env.USERPROFILE || process.env.HOME || ".", ".codex"),
    };

    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--port" && args[i + 1]) {
            options.port = Number(args[++i]);
        } else if (args[i] === "--host" && args[i + 1]) {
            options.host = args[++i];
        } else if (args[i] === "--upstream" && args[i + 1]) {
            options.upstreamOverride = args[++i];
        } else if (args[i] === "--codex-home" && args[i + 1]) {
            options.codexHome = args[++i];
        } else if (args[i] === "--jev-endpoint" && args[i + 1]) {
            options.jevEndpoint = args[++i];
        } else if (args[i] === "--jev-timeout-ms" && args[i + 1]) {
            options.jevTimeoutMs = Number(args[++i]);
        }
    }

    return options;
}

const config = parseArgs();
const kitDir = path.join(config.codexHome, "codex-workflows-kit");
const stateFile = path.join(kitDir, "dev-router-state.json");
const locksFile = path.join(kitDir, "dev-router-locks.json");
const catalogFile = path.join(kitDir, "model-catalog.json");
const configTomlFile = path.join(config.codexHome, "config.toml");

// The upstream base depends on HOW Codex is authenticated: a ChatGPT account
// must reach the ChatGPT Codex backend, not the public OpenAI API (the public
// `/v1/responses` path 404s there). Derived from the official config keys and
// overridable explicitly; never guessed silently.
const _topLevelConfig = readTopLevelConfig();
const _upstream = deriveUpstream({
    envOverride: config.upstreamOverride,
    chatgptBaseUrl: _topLevelConfig.chatgptBaseUrl,
    preferredAuthMethod: _topLevelConfig.preferredAuthMethod,
    codexHome: config.codexHome
});
config.upstream = _upstream.upstream;
config.upstreamSource = _upstream.source;

const responseChainBoundaries = new Map();
let lastAppliedRoute = null;

function stripBom(text) {
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readJsonFile(filePath) {
    return JSON.parse(stripBom(fs.readFileSync(filePath, "utf8")));
}

function normalizeEffort(value) {
    if (typeof value !== "string") {
        return null;
    }
    const trimmed = value.trim().toLowerCase();
    return trimmed || null;
}

function readDevRouterState() {
    try {
        if (fs.existsSync(stateFile)) {
            const data = readJsonFile(stateFile);
            return {
                mode: data.mode || "off",
                target: data.target || "effort_only",
                version: data.version || 1,
                manual_base_model: typeof data.manual_base_model === "string" ? data.manual_base_model.trim() : null,
                manual_base_effort: normalizeEffort(data.manual_base_effort)
            };
        }
    } catch {
        // Fallback to default
    }
    return { mode: "off", target: "effort_only", version: 1, manual_base_model: null, manual_base_effort: null };
}

/**
 * Top-level string values from config.toml that decide how the upstream must be
 * reached. No secret is read: only the model/provider/auth-method selectors.
 */
function readTopLevelConfig() {
    const result = { modelProvider: null, preferredAuthMethod: null, chatgptBaseUrl: null };
    try {
        if (!fs.existsSync(configTomlFile)) return result;
        const lines = fs.readFileSync(configTomlFile, "utf8").split(/\r?\n/);
        let inTopLevel = true;
        for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed.startsWith("#") || trimmed.length === 0) continue;
            if (trimmed.startsWith("[")) {
                inTopLevel = false;
                continue;
            }
            if (!inTopLevel) continue;
            const match = (key) => {
                const m = trimmed.match(new RegExp(`^${key}\\s*=\\s*"([^"]+)"`));
                return m ? m[1].trim() : null;
            };
            result.modelProvider = match("model_provider") ?? result.modelProvider;
            result.preferredAuthMethod = match("preferred_auth_method") ?? result.preferredAuthMethod;
            result.chatgptBaseUrl = match("chatgpt_base_url") ?? result.chatgptBaseUrl;
        }
    } catch {
        // Ignore read errors; the derivation falls back to the public API.
    }
    return result;
}

function readTomlBaseline() {
    let baselineModel = null;
    let baselineEffort = null;

    try {
        if (fs.existsSync(configTomlFile)) {
            const content = fs.readFileSync(configTomlFile, "utf8");
            const lines = content.split(/\r?\n/);
            let inTopLevel = true;

            for (const line of lines) {
                const trimmed = line.trim();
                if (trimmed.startsWith("#") || trimmed.length === 0) continue;
                if (trimmed.startsWith("[")) {
                    inTopLevel = false;
                    continue;
                }
                if (inTopLevel) {
                    const mMatch = trimmed.match(/^model\s*=\s*"([^"]+)"/);
                    if (mMatch) {
                        baselineModel = mMatch[1].trim();
                    }
                    const eMatch = trimmed.match(/^model_reasoning_effort\s*=\s*"([^"]+)"/);
                    if (eMatch) {
                        baselineEffort = eMatch[1].trim();
                    }
                }
            }
        }
    } catch {
        // Ignore read errors
    }

    return { model: baselineModel, effort: baselineEffort };
}

function resolveConcreteBaseline(state, toml) {
    const manualModel = typeof state.manual_base_model === "string" && state.manual_base_model ? state.manual_base_model : null;
    const configModel = toml.model && toml.model !== ADAPTIVE_MODEL ? toml.model : null;
    const manualEffort = normalizeEffort(state.manual_base_effort);
    const configEffort = normalizeEffort(toml.effort);
    return {
        model: manualModel || configModel || null,
        effort: manualEffort || configEffort || null
    };
}

function readLocks() {
    try {
        if (!fs.existsSync(locksFile)) {
            return {};
        }
        const data = readJsonFile(locksFile);
        return data && typeof data === "object" && !Array.isArray(data) ? data : {};
    } catch {
        return {};
    }
}

function writeLock(boundaryKey, lockRecord) {
    if (!boundaryKey) {
        return false;
    }
    try {
        fs.mkdirSync(kitDir, { recursive: true });
        const locks = readLocks();
        locks[boundaryKey] = lockRecord;
        const tempFile = path.join(kitDir, `.dev-router-locks-${process.pid}-${Date.now()}.tmp`);
        fs.writeFileSync(tempFile, JSON.stringify(locks, null, 2), "utf8");
        fs.renameSync(tempFile, locksFile);
        return true;
    } catch (error) {
        console.error(`[DevRouter] lock write failed: ${error.message}`);
        return false;
    }
}

function recordResponseIds(text, boundaryKey) {
    if (!boundaryKey) {
        return;
    }
    for (const match of text.matchAll(RESPONSE_ID_PATTERN)) {
        responseChainBoundaries.set(match[1], boundaryKey);
        while (responseChainBoundaries.size > MAX_CHAIN_ENTRIES) {
            const oldest = responseChainBoundaries.keys().next().value;
            responseChainBoundaries.delete(oldest);
        }
    }
}

function sanitizeObjective(text) {
    if (!text || typeof text !== "string") return "General task assistance";
    let clean = text
        .replace(/```[a-zA-Z0-9_\-]*\r?\n[\s\S]*?```|```[\s\S]*?```/g, "[code block omitted]")
        .replace(/(?:api[_-]?key|bearer|token|secret|password)\s*[:=\s]\s*['"]?[a-zA-Z0-9_\-\.]{8,}['"]?/gi, "[secret redacted]")
        .replace(/[a-zA-Z]:\\[^\s\r\n\t]+/g, "[path]")
        .replace(/\s+/g, " ")
        .trim();

    if (clean.length > 600) {
        clean = clean.substring(0, 600) + "... [truncated]";
    }
    return clean || "General task assistance";
}

function extractPromptFromInput(input) {
    if (!Array.isArray(input)) return "";
    for (let i = input.length - 1; i >= 0; i--) {
        const item = input[i];
        if (item && item.role === "user" && Array.isArray(item.content)) {
            for (const c of item.content) {
                if (c && c.type === "input_text" && typeof c.text === "string") {
                    return c.text;
                }
                if (c && c.type === "text" && typeof c.text === "string") {
                    return c.text;
                }
            }
        }
    }
    return "";
}

function invokeJevChoice(objective, target, currentModel, currentEffort, apiKey) {
    if (!apiKey) {
        return Promise.resolve({ status: "unavailable", choice: null });
    }

    let optionSet;
    try {
        optionSet = buildOptionSet(target, { baselineModel: currentModel, baselineEffort: currentEffort });
    } catch (error) {
        return Promise.resolve({ status: "invalid_response", choice: null, reason: error.message });
    }
    if (optionSet.incompatible) {
        return Promise.resolve({ status: "incompatible", choice: null, reason: optionSet.reason });
    }

    const payload = {
        model: "jev-latest",
        state: JSON.stringify({
            task: {
                objective: sanitizeObjective(objective),
                surface: "codex_desktop_app"
            }
        }),
        questions: {
            q_route: {
                type: "choice",
                instructions: optionSet.instructions,
                criteria: optionSet.criteria
            }
        }
    };

    return new Promise((resolve) => {
        let settled = false;
        let jevReq = null;
        const finish = (value) => {
            if (!settled) {
                settled = true;
                resolve(value);
            }
        };
        const timeout = setTimeout(() => {
            finish({ status: "timeout", choice: null });
            if (jevReq && !jevReq.destroyed) {
                jevReq.destroy();
            }
        }, config.jevTimeoutMs);

        try {
            const endpoint = new URL(config.jevEndpoint);
            const transport = endpoint.protocol === "https:" ? https : http;
            const req = transport.request(
                endpoint,
                {
                    method: "POST",
                    headers: {
                        "Authorization": `Bearer ${apiKey}`,
                        "Content-Type": "application/json"
                    }
                },
                (res) => {
                    let data = "";
                    res.on("data", chunk => { data += chunk; });
                    res.on("end", () => {
                        clearTimeout(timeout);
                        if (res.statusCode < 200 || res.statusCode >= 300) {
                            finish({ status: "unavailable", choice: null });
                            return;
                        }
                        try {
                            const parsed = JSON.parse(data);
                            const answer = parsed.answers?.q_route;
                            let choice = null;
                            if (typeof answer === "string") {
                                choice = answer;
                            } else if (answer && typeof answer === "object") {
                                choice = answer.choice ?? answer.selected ?? answer.value ?? null;
                            }
                            choice = typeof choice === "string" && choice.trim() ? choice.trim() : null;
                            finish(choice ? { status: "ok", choice } : { status: "invalid_response", choice: null });
                        } catch {
                            finish({ status: "invalid_response", choice: null });
                        }
                    });
                }
            );

            req.on("error", () => {
                clearTimeout(timeout);
                finish({ status: "unavailable", choice: null });
            });

            jevReq = req;
            req.write(JSON.stringify(payload));
            req.end();
        } catch {
            clearTimeout(timeout);
            finish({ status: "unavailable", choice: null });
        }
    });
}

function assertConcreteForUpstream(model) {
    const upstreamModel = toUpstreamModelId(model);
    if (!upstreamModel) {
        console.error(`[DevRouter] FAIL-CLOSED refusing to forward non-concrete model '${model === null || model === undefined ? "" : model}' to upstream.`);
    }
    return upstreamModel;
}

function sendLocalError(res, statusCode, type, message) {
    console.error(`[DevRouter] FAIL-CLOSED ${type}: ${message}`);
    if (res.headersSent) {
        res.end();
        return;
    }
    res.writeHead(statusCode, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message, type, code: statusCode } }));
}

function readBoundaryKey(req, parsedBody) {
    const header = (name) => {
        const value = req.headers[name];
        return typeof value === "string" ? value : (Array.isArray(value) ? value[0] : null);
    };
    const conversationId = parsedBody.conversation_id
        || parsedBody.metadata?.conversation_id
        || header("x-conversation-id")
        || parsedBody.prompt_cache_key;
    const previousResponseId = parsedBody.previous_response_id || header("x-previous-response-id");
    const responseChainRoot = previousResponseId ? (responseChainBoundaries.get(previousResponseId) ?? null) : null;
    const requestSessionId = header("x-session-id") || parsedBody.session_id;
    return {
        boundaryKey: deriveBoundaryKey({ conversationId, responseChainRoot, previousResponseId, requestSessionId }),
        previousResponseId
    };
}

async function handleResponses(req, res) {
    const bodyChunks = [];
    req.on("data", chunk => bodyChunks.push(chunk));
    req.on("end", async () => {
        let bodyBuffer = Buffer.concat(bodyChunks);
        let parsedBody = null;

        try {
            parsedBody = JSON.parse(bodyBuffer.toString("utf8"));
        } catch {
            // Not JSON: forward untouched so a malformed payload still reaches upstream
        }

        const state = readDevRouterState();
        const toml = readTomlBaseline();
        const baseline = resolveConcreteBaseline(state, toml);

        if (!parsedBody || typeof parsedBody !== "object" || Array.isArray(parsedBody)) {
            return forwardToUpstream(req, res, bodyBuffer, null);
        }

        const rawIncoming = typeof parsedBody.model === "string" ? parsedBody.model.trim() : "";
        const incomingModel = rawIncoming || "";
        const requestedEffort = normalizeEffort(parsedBody.reasoning?.effort);
        const isAdaptive = incomingModel === "" || incomingModel === ADAPTIVE_MODEL;
        const concreteIncoming = isAdaptive ? null : toUpstreamModelId(incomingModel);
        const effectiveModel = concreteIncoming || baseline.model;
        const effectiveEffort = requestedEffort ?? baseline.effort;
        const needsRewrite = state.mode === "on" || state.mode === "shadow" || isAdaptive;

        if (!needsRewrite) {
            const upstreamReject = assertConcreteForUpstream(concreteIncoming || incomingModel);
            if (!upstreamReject) {
                return sendLocalError(res, 400, "dev_router_missing_base", "The request model is not a concrete model the proxy may forward upstream.");
            }
            parsedBody.model = upstreamReject;
            bodyBuffer = Buffer.from(JSON.stringify(parsedBody), "utf8");
            lastAppliedRoute = { model: upstreamReject, effort: requestedEffort, boundaryKey: null };
            console.log(`[DevRouter] route boundary=none mode=${state.mode} target=${state.target} incoming=${incomingModel || "none"} jev=skipped final=${upstreamReject}/${requestedEffort ?? "none"} status=off`);
            return forwardToUpstream(req, res, bodyBuffer, null);
        }

        if (!effectiveModel) {
            return sendLocalError(res, 400, "dev_router_missing_base", `The Dev Router ${state.mode} mode requires a concrete base model (set manual_base_model in dev-router-state.json or a top-level model in config.toml). It will never invent one.`);
        }

        const objective = extractPromptFromInput(parsedBody.input);
        const { boundaryKey } = readBoundaryKey(req, parsedBody);
        const surfaceHeader = req.headers["x-dev-router-surface"];
        const surface = typeof surfaceHeader === "string" && surfaceHeader.toLowerCase() === "workflow" ? "workflow" : "alignment";
        const scope = surface === "alignment" ? "turn" : "workflow";

        let finalModel = effectiveModel;
        let finalEffort = effectiveEffort;
        let statusLabel = state.mode;
        let jevMark = "skipped";
        let appliedLock = null;

        if (state.mode === "on") {
            const locks = boundaryKey ? readLocks() : {};
            const existing = boundaryKey ? locks[boundaryKey] : null;

            if (existing && isLockValid(existing, { mode: state.mode, target: state.target, surface, executionId: null, turnId: null })) {
                const lockedModel = typeof existing.locked_model === "string" && existing.locked_model.trim() ? existing.locked_model.trim() : null;
                const lockedEffort = normalizeEffort(existing.locked_effort);
                if (lockedModel && (!lockedEffort || isEffortSupported(lockedModel, lockedEffort))) {
                    finalModel = lockedModel;
                    finalEffort = lockedEffort ?? effectiveEffort;
                    statusLabel = "locked";
                } else {
                    statusLabel = "locked_incompatible";
                    console.error(`[DevRouter] lock boundary=${boundaryKey} stores an invalid model/effort pair; keeping the concrete base.`);
                }
            } else if (!boundaryKey && lastAppliedRoute) {
                finalModel = lastAppliedRoute.model;
                finalEffort = lastAppliedRoute.effort ?? effectiveEffort;
                statusLabel = "sticky_last_route";
            } else if (!boundaryKey) {
                return sendLocalError(res, 400, "dev_router_no_boundary", "The Dev Router cannot derive a boundary key and has no prior applied route to preserve. It never invents a route.");
            } else {
                const apiKey = process.env.TYPESAFE_API_KEY;
                const jev = await invokeJevChoice(objective, state.target, effectiveModel, effectiveEffort, apiKey);
                jevMark = jev.status === "incompatible" ? "skipped" : "called";
                const decision = decideRoute({
                    mode: "on",
                    target: state.target,
                    baseline: { model: effectiveModel, effort: effectiveEffort },
                    requestedEffort,
                    jevChoice: jev.choice,
                    jevStatus: jev.status
                });
                if (!decision.model) {
                    return sendLocalError(res, 400, "dev_router_missing_base", "The Dev Router decision has no concrete model to forward.");
                }
                const pairSupported = !decision.effort || isEffortSupported(decision.model, decision.effort);
                if (!pairSupported) {
                    finalModel = effectiveModel;
                    finalEffort = effectiveEffort;
                    statusLabel = "incompatible";
                    console.error(`[DevRouter] decision pair ${decision.model}/${decision.effort} is not supported; keeping the concrete base.`);
                } else {
                    finalModel = decision.model;
                    finalEffort = decision.effort;
                    statusLabel = decision.status;
                }
                appliedLock = {
                    conversation_id: boundaryKey,
                    scope,
                    execution_id: null,
                    turn_id: null,
                    locked_model: canonicalModelName(finalModel) || finalModel,
                    locked_effort: finalEffort,
                    mode: state.mode,
                    target: state.target,
                    locked_at_utc: new Date().toISOString(),
                    reason: decision.isFallback ? "proxy_fallback" : "proxy_route"
                };
                writeLock(boundaryKey, appliedLock);
            }
        } else if (state.mode === "shadow") {
            statusLabel = "shadow";
            jevMark = "shadow";
            const apiKey = process.env.TYPESAFE_API_KEY;
            invokeJevChoice(objective, state.target, effectiveModel, effectiveEffort, apiKey)
                .then((jev) => {
                    const shadowDecision = decideRoute({
                        mode: "shadow",
                        target: state.target,
                        baseline: { model: effectiveModel, effort: effectiveEffort },
                        requestedEffort,
                        jevChoice: jev.choice,
                        jevStatus: jev.status
                    });
                    const recommendation = shadowDecision.model
                        ? `${shadowDecision.model}/${shadowDecision.effort ?? "none"}`
                        : "none";
                    console.log(`[DevRouter] shadow recommendation=${recommendation} status=${jev.status} boundary=${boundaryKey || "none"}`);
                })
                .catch(() => {});
        } else {
            statusLabel = "off";
        }

        const upstreamModel = assertConcreteForUpstream(finalModel);
        if (!upstreamModel) {
            return sendLocalError(res, 400, "dev_router_missing_base", "The resolved route has no concrete model that can be forwarded upstream.");
        }

        parsedBody.model = upstreamModel;
        if (state.mode !== "off" || finalEffort) {
            if (!parsedBody.reasoning) parsedBody.reasoning = {};
            if (finalEffort) {
                parsedBody.reasoning.effort = finalEffort;
            }
        }
        bodyBuffer = Buffer.from(JSON.stringify(parsedBody), "utf8");
        lastAppliedRoute = { model: upstreamModel, effort: finalEffort, boundaryKey };

        console.log(`[DevRouter] route boundary=${boundaryKey || "none"} mode=${state.mode} target=${state.target} incoming=${incomingModel || "none"} jev=${jevMark} final=${upstreamModel}/${finalEffort ?? "none"} status=${statusLabel}`);
        return forwardToUpstream(req, res, bodyBuffer, boundaryKey);
    });
}

/**
 * Builds the upstream `/responses` URL.
 *
 * The request line is NOT always `${base}/v1/responses`: the public OpenAI API
 * serves it under `/v1`, while the ChatGPT-auth Codex backend serves it under
 * `https://chatgpt.com/backend-api/codex/responses`. Blindly appending
 * `/v1/responses` produced a 404 for every ChatGPT-auth user (verified live).
 * A base that already carries a path keeps it and only gets `/responses`
 * appended; a bare host gets the public `/v1/responses` shape.
 * `DEV_ROUTER_UPSTREAM_PATH` overrides the suffix entirely.
 */
function buildUpstreamUrl(upstreamBase, overridePath) {
    const base = new URL(upstreamBase);
    const trimmedPath = base.pathname.replace(/\/+$/, "");
    const suffix = overridePath
        ? (overridePath.startsWith("/") ? overridePath : `/${overridePath}`)
        : (trimmedPath.length > 0 ? `${trimmedPath}/responses` : "/v1/responses");
    return new URL(suffix + base.search, base.origin);
}

function forwardToUpstream(req, res, bodyBuffer, boundaryKey) {
    const upstreamUrl = buildUpstreamUrl(config.upstream, config.upstreamPath);
    const isHttps = upstreamUrl.protocol === "https:";
    const transport = isHttps ? https : http;

    const forwardHeaders = { ...req.headers };
    forwardHeaders.host = upstreamUrl.host;
    forwardHeaders["content-length"] = bodyBuffer.length;

    delete forwardHeaders["connection"];
    delete forwardHeaders["keep-alive"];

    const upstreamReq = transport.request(
        upstreamUrl,
        {
            method: req.method,
            headers: forwardHeaders
        },
        (upstreamRes) => {
            res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
            let sniffBuffer = "";
            upstreamRes.on("data", (chunk) => {
                if (boundaryKey) {
                    sniffBuffer = (sniffBuffer + chunk.toString("utf8")).slice(-65536);
                    recordResponseIds(sniffBuffer, boundaryKey);
                }
                res.write(chunk);
            });
            upstreamRes.on("end", () => {
                if (boundaryKey) {
                    recordResponseIds(sniffBuffer, boundaryKey);
                }
                res.end();
            });
            upstreamRes.on("error", () => {
                res.destroy();
            });
            // Non-secret execution proof: the caller can confirm the request
            // really reached the backend without inspecting any content.
            upstreamRes.once("response", () => {});
        }
    );

    upstreamReq.on("response", (upstreamRes) => {
        console.log(`[DevRouter] upstream_status=${upstreamRes.statusCode} host=${upstreamUrl.host} path=${upstreamUrl.pathname}`);
    });

    upstreamReq.on("error", (err) => {
        console.error(`[DevRouter Upstream Error] ${err.message}`);
        if (!res.headersSent) {
            res.writeHead(502, { "Content-Type": "application/json" });
            res.end(JSON.stringify({
                error: {
                    message: `Dev Router failed to connect to upstream: ${err.message}`,
                    type: "dev_router_upstream_error",
                    code: 502
                }
            }));
        }
    });

    res.on("close", () => {
        if (!res.writableEnded && !upstreamReq.destroyed) {
            upstreamReq.destroy();
        }
    });

    upstreamReq.write(bodyBuffer);
    upstreamReq.end();
}

function handleModels(req, res) {
    try {
        if (fs.existsSync(catalogFile)) {
            const catalog = stripBom(fs.readFileSync(catalogFile, "utf8"));
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(catalog);
            return;
        }
    } catch {
        // Fall through to default catalog
    }

    const defaultCatalog = [
        {
            id: "gpt-adaptive",
            display_name: "GPT-Adaptive",
            description: "Adaptive intelligent model routing powered by TypeSafe/Jev",
            model_provider_id: "dev-router",
            supported_reasoning_efforts: ["none", "low", "medium", "high", "xhigh", "max", "ultra"],
            default_reasoning_effort: "medium"
        }
    ];

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(defaultCatalog));
}

function handleHealth(req, res) {
    const state = readDevRouterState();
    const toml = readTomlBaseline();
    const baseline = resolveConcreteBaseline(state, toml);
    const topLevel = readTopLevelConfig();
    const upstreamUrl = buildUpstreamUrl(config.upstream, config.upstreamPath);

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
        status: "ok",
        service: "dev-router-proxy",
        port: config.port,
        host: config.host,
        upstream: config.upstream,
        // Non-secret routing introspection used by readiness checks.
        upstream_host: upstreamUrl.host,
        upstream_path: upstreamUrl.pathname,
        upstream_source: config.upstreamSource,
        model_provider: topLevel.modelProvider,
        preferred_auth_method: topLevel.preferredAuthMethod,
        mode: state.mode,
        target: state.target,
        baseline_model: baseline.model,
        baseline_effort: baseline.effort
    }));
}

const server = http.createServer((req, res) => {
    const parsedUrl = new URL(req.url, `http://${req.headers.host || "127.0.0.1"}`);
    const pathname = parsedUrl.pathname;

    if (req.method === "GET" && pathname === "/health") {
        return handleHealth(req, res);
    }

    if (req.method === "GET" && (pathname === "/v1/models" || pathname === "/models")) {
        return handleModels(req, res);
    }

    if (pathname === "/v1/responses" || pathname === "/responses") {
        return handleResponses(req, res);
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: "Not found", code: 404 } }));
});

server.listen(config.port, config.host, () => {
    const upstreamUrl = buildUpstreamUrl(config.upstream, config.upstreamPath);
    console.log(`[DevRouter] Proxy listening on http://${config.host}:${config.port}`);
    // Host/path only: never log Authorization, cookies or prompt content.
    console.log(`[DevRouter] Upstream: ${upstreamUrl.protocol}//${upstreamUrl.host}${upstreamUrl.pathname} (source=${config.upstreamSource})`);
    console.log(`[DevRouter] Codex Home: ${config.codexHome}`);
});

process.on("SIGINT", () => {
    server.close(() => process.exit(0));
});
process.on("SIGTERM", () => {
    server.close(() => process.exit(0));
});
