#!/usr/bin/env node
/**
 * scripts/dev-router-proxy.mjs
 * 
 * Local Dev Router loopback proxy for Codex Desktop App and CLI.
 * Intercepts `POST /v1/responses` requests with `model: "gpt-adaptive"` (or target models),
 * evaluates routing decisions via TypeSafe/Jev System One (choice primitive) or local state/policy,
 * transforms the model and reasoning effort, and transparently streams upstream SSE responses.
 * 
 * Zero external npm dependencies (pure Node.js built-ins).
 */

import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import { URL } from "node:url";

const DEFAULT_PORT = 4040;
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_UPSTREAM = "https://api.openai.com";

// Parse CLI arguments
function parseArgs() {
    const args = process.argv.slice(2);
    const options = {
        port: Number(process.env.DEV_ROUTER_PORT) || DEFAULT_PORT,
        host: process.env.DEV_ROUTER_HOST || DEFAULT_HOST,
        upstream: process.env.DEV_ROUTER_UPSTREAM || DEFAULT_UPSTREAM,
        codexHome: process.env.CODEX_HOME || path.join(process.env.USERPROFILE || process.env.HOME || ".", ".codex"),
    };

    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--port" && args[i + 1]) {
            options.port = Number(args[++i]);
        } else if (args[i] === "--host" && args[i + 1]) {
            options.host = args[++i];
        } else if (args[i] === "--upstream" && args[i + 1]) {
            options.upstream = args[++i];
        } else if (args[i] === "--codex-home" && args[i + 1]) {
            options.codexHome = args[++i];
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

// Model catalog metadata
const ALLOWED_MODELS = {
    Luna: { id: "gpt-5.6-luna", name: "Luna", efforts: ["none", "minimal", "low", "medium", "high", "xhigh"] },
    Sol: { id: "gpt-5.6-sol", name: "Sol", efforts: ["none", "minimal", "low", "medium", "high", "xhigh"] },
    Astra: { id: "gpt-6-astra", name: "Astra", efforts: ["low", "medium", "high", "xhigh"] }
};

const DISALLOWED_MODELS = ["gpt-5.6-terra", "terra"];

function readDevRouterState() {
    try {
        if (fs.existsSync(stateFile)) {
            const raw = fs.readFileSync(stateFile, "utf8");
            const data = JSON.parse(raw);
            return {
                mode: data.mode || "off",
                target: data.target || "effort_only",
                version: data.version || 1
            };
        }
    } catch {
        // Fallback to default
    }
    return { mode: "off", target: "effort_only", version: 1 };
}

function readBaselineConfig() {
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

    return {
        model: baselineModel || "gpt-5.6-sol",
        effort: baselineEffort || "medium"
    };
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

async function invokeJevChoice(objective, target, currentModel, currentEffort, apiKey) {
    if (!apiKey) {
        return null;
    }

    let instructions = "";
    const criteria = {};

    if (target === "effort_only") {
        instructions = `Select the appropriate reasoning effort for this task running on model '${currentModel}'.`;
        const efforts = ["low", "medium", "high", "xhigh"];
        for (const eff of efforts) {
            criteria[eff] = `Reasoning effort ${eff}: balanced for appropriate task difficulty`;
        }
    } else if (target === "model_only") {
        instructions = "Select the best model from the allowlist for this task.";
        criteria["Luna"] = "Luna (gpt-5.6-luna): fast, mechanical, low-risk, simple changes";
        criteria["Sol"] = "Sol (gpt-5.6-sol): balanced implementation, deep debugging, agentic workflow";
        criteria["Astra"] = "Astra (gpt-6-astra): complex architecture, concurrency, high blast radius";
    } else {
        instructions = "Select the optimal model and reasoning effort pair for this task.";
        criteria["Luna:low"] = "Luna with low effort: routine mechanical edits";
        criteria["Luna:medium"] = "Luna with medium effort: standard localized modifications";
        criteria["Sol:medium"] = "Sol with medium effort: standard feature implementation and debugging";
        criteria["Sol:high"] = "Sol with high effort: complex feature work, algorithmic changes";
        criteria["Astra:high"] = "Astra with high effort: critical system architecture, security";
        criteria["Astra:xhigh"] = "Astra with extra-high effort: highest complexity, deadlock/concurrency";
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
                instructions,
                criteria
            }
        }
    };

    return new Promise((resolve) => {
        const timeout = setTimeout(() => {
            resolve(null);
        }, 3000); // Strict 3-second bounded timeout

        try {
            const req = https.request(
                "https://api.typesafe.ai/v1/systemone",
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
                        try {
                            if (res.statusCode >= 200 && res.statusCode < 300) {
                                const parsed = JSON.parse(data);
                                const choice = parsed.answers?.q_route?.choice;
                                resolve(choice || null);
                            } else {
                                resolve(null);
                            }
                        } catch {
                            resolve(null);
                        }
                    });
                }
            );

            req.on("error", () => {
                clearTimeout(timeout);
                resolve(null);
            });

            req.write(JSON.stringify(payload));
            req.end();
        } catch {
            clearTimeout(timeout);
            resolve(null);
        }
    });
}

function resolveModelId(name) {
    if (!name) return "gpt-5.6-sol";
    const lower = name.toLowerCase();
    if (lower.includes("luna")) return "gpt-5.6-luna";
    if (lower.includes("astra")) return "gpt-6-astra";
    if (lower.includes("sol")) return "gpt-5.6-sol";
    return name;
}

// Request Handler
async function handleResponses(req, res) {
    let bodyChunks = [];
    req.on("data", chunk => bodyChunks.push(chunk));
    req.on("end", async () => {
        let bodyBuffer = Buffer.concat(bodyChunks);
        let parsedBody = null;
        let isGptAdaptive = false;

        try {
            parsedBody = JSON.parse(bodyBuffer.toString("utf8"));
            isGptAdaptive = (parsedBody && parsedBody.model === "gpt-adaptive");
        } catch {
            // Not JSON or parse error, pass through unmodified
        }

        const state = readDevRouterState();
        const baseline = readBaselineConfig();

        let finalModel = baseline.model;
        let finalEffort = baseline.effort;

        if (isGptAdaptive && parsedBody) {
            const promptText = extractPromptFromInput(parsedBody.input);
            const requestedEffort = parsedBody.reasoning?.effort || baseline.effort;

            if (state.mode === "off") {
                finalModel = baseline.model;
                finalEffort = requestedEffort;
            } else if (state.mode === "shadow") {
                finalModel = baseline.model;
                finalEffort = requestedEffort;
                // Shadow evaluation in background
                const apiKey = process.env.TYPESAFE_API_KEY;
                if (apiKey) {
                    invokeJevChoice(promptText, state.target, finalModel, finalEffort, apiKey).then(rec => {
                        if (rec) {
                            console.log(`[DevRouter Shadow] Jev recommendation for prompt: ${rec}`);
                        }
                    }).catch(() => {});
                }
            } else if (state.mode === "on") {
                const apiKey = process.env.TYPESAFE_API_KEY;
                const choice = await invokeJevChoice(promptText, state.target, baseline.model, requestedEffort, apiKey);

                if (choice) {
                    if (state.target === "effort_only") {
                        finalModel = baseline.model;
                        finalEffort = choice.toLowerCase();
                    } else if (state.target === "model_only") {
                        finalModel = resolveModelId(choice);
                        finalEffort = requestedEffort;
                    } else if (state.target === "model_and_effort") {
                        const parts = choice.split(":");
                        if (parts.length === 2) {
                            finalModel = resolveModelId(parts[0]);
                            finalEffort = parts[1].toLowerCase();
                        }
                    }
                } else {
                    // Fallback to baseline
                    finalModel = baseline.model;
                    finalEffort = requestedEffort;
                }
            }

            // Apply transformed model and reasoning effort
            parsedBody.model = finalModel;
            if (!parsedBody.reasoning) parsedBody.reasoning = {};
            parsedBody.reasoning.effort = finalEffort;

            bodyBuffer = Buffer.from(JSON.stringify(parsedBody), "utf8");
            console.log(`[DevRouter] Routed gpt-adaptive -> model=${finalModel}, effort=${finalEffort} (mode=${state.mode}, target=${state.target})`);
        }

        // Prepare upstream request
        const upstreamUrl = new URL(`${config.upstream}/v1/responses`);
        const isHttps = upstreamUrl.protocol === "https:";
        const transport = isHttps ? https : http;

        const forwardHeaders = { ...req.headers };
        forwardHeaders.host = upstreamUrl.host;
        forwardHeaders["content-length"] = bodyBuffer.length;

        // Strip hop-by-hop headers
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
                upstreamRes.pipe(res);
            }
        );

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
    });
}

function handleModels(req, res) {
    try {
        if (fs.existsSync(catalogFile)) {
            const catalog = fs.readFileSync(catalogFile, "utf8");
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
    const baseline = readBaselineConfig();

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
        status: "ok",
        service: "dev-router-proxy",
        port: config.port,
        host: config.host,
        upstream: config.upstream,
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

    // Default 404
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: "Not found", code: 404 } }));
});

server.listen(config.port, config.host, () => {
    console.log(`[DevRouter] Proxy listening on http://${config.host}:${config.port}`);
    console.log(`[DevRouter] Upstream: ${config.upstream}`);
    console.log(`[DevRouter] Codex Home: ${config.codexHome}`);
});

process.on("SIGINT", () => {
    server.close(() => process.exit(0));
});
process.on("SIGTERM", () => {
    server.close(() => process.exit(0));
});
