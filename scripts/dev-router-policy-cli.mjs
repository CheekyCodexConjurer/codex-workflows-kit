#!/usr/bin/env node
import {
    resolveModel,
    modelEfforts,
    isEffortSupported,
    isModelAllowedForAutomaticRouting,
    buildOptionSet,
    buildCriteria,
    buildJevInstructions,
    parseChoice,
    decideRoute,
    deriveBoundaryKey,
    isLockValid,
    toUpstreamModelId
} from "./dev-router-policy.mjs";

const OPERATIONS = {
    resolveModel: (request) => resolveModel(request.nameOrId, { includeDisallowed: request.includeDisallowed === true }),
    modelEfforts: (request) => modelEfforts(request.modelOrName),
    isEffortSupported: (request) => isEffortSupported(request.model, request.effort),
    isModelAllowedForAutomaticRouting: (request) => isModelAllowedForAutomaticRouting(request.model),
    toUpstreamModelId: (request) => toUpstreamModelId(request.model),
    buildOptionSet: (request) => buildOptionSet(request.target, {
        baselineModel: request.baselineModel,
        baselineEffort: request.baselineEffort
    }),
    buildCriteria: (request) => buildCriteria(request.target, {
        baselineModel: request.baselineModel,
        baselineEffort: request.baselineEffort
    }),
    buildJevInstructions: (request) => buildJevInstructions(request.target, {
        baselineModel: request.baselineModel,
        baselineEffort: request.baselineEffort
    }),
    parseChoice: (request) => parseChoice(request.choice, request.target, {
        baselineModel: request.baselineModel,
        baselineEffort: request.baselineEffort
    }),
    decideRoute: (request) => decideRoute({
        mode: request.mode,
        target: request.target,
        baseline: request.baseline,
        requestedEffort: request.requestedEffort,
        jevChoice: request.jevChoice,
        jevStatus: request.jevStatus
    }),
    deriveBoundaryKey: (request) => deriveBoundaryKey({
        conversationId: request.conversationId,
        responseChainRoot: request.responseChainRoot,
        previousResponseId: request.previousResponseId,
        requestSessionId: request.requestSessionId
    }),
    isLockValid: (request) => isLockValid(request.lock, {
        mode: request.mode,
        target: request.target,
        surface: request.surface,
        executionId: request.executionId,
        turnId: request.turnId
    })
};

function readStdin() {
    return new Promise((resolve, reject) => {
        let data = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", (chunk) => { data += chunk; });
        process.stdin.on("end", () => resolve(data));
        process.stdin.on("error", reject);
    });
}

async function main() {
    const input = await readStdin();
    const request = JSON.parse(input);
    const operation = request && request.op;
    if (!operation || !Object.prototype.hasOwnProperty.call(OPERATIONS, operation)) {
        throw new Error(`Unknown policy operation '${operation}'.`);
    }
    const result = OPERATIONS[operation](request);
    process.stdout.write(JSON.stringify({ ok: true, result }));
    process.exit(0);
}

main().catch((error) => {
    process.stdout.write(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }));
    process.exit(1);
});
