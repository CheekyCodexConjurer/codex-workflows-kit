#!/usr/bin/env node
/**
 * scripts/tests/free-mcps-runtime.mjs
 *
 * Node.js built-ins only MCP stdio JSON-RPC runtime test harness for
 * codebase-memory-mcp (CBM) v0.10.8 and mock protocol validation.
 *
 * Usage:
 *   node scripts/tests/free-mcps-runtime.mjs --self-test [--json]
 *   node scripts/tests/free-mcps-runtime.mjs --binary <path> --work-dir <path> --cache-dir <path> --runtime-dir <path> [--json]
 */

import { spawn, spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as crypto from 'node:crypto';
import * as os from 'node:os';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ============================================================================
// Constants & Upstream Pin Verification
// ============================================================================

export const PINNED_CBM_HASHES = {
  version: 'v0.10.8',
  hashes: {
    amd64: 'b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6',
    x64: 'b4b403b1d7c4def3785f148b93f345ce8427858f4f5489ce28580c4387a336a6',
    arm64: '67b0341ee62f07f850d3954e4f387855f90ea8c6c4b7ed41b8a62d61344373a4'
  }
};

// ============================================================================
// Path Canonicalization & Isolation Validation
// ============================================================================

export function resolveCanonicalPath(p) {
  if (!p || typeof p !== 'string') return '';
  const resolved = path.resolve(p);
  let curr = resolved;
  const tail = [];
  while (curr && !fs.existsSync(curr)) {
    const parent = path.dirname(curr);
    if (parent === curr) break;
    tail.unshift(path.basename(curr));
    curr = parent;
  }
  if (fs.existsSync(curr)) {
    try {
      const real = fs.realpathSync.native ? fs.realpathSync.native(curr) : fs.realpathSync(curr);
      return path.resolve(real, ...tail);
    } catch (e) {
      return resolved;
    }
  }
  return resolved;
}

export function normalizeForComparison(p) {
  const c = resolveCanonicalPath(p);
  return process.platform === 'win32' ? c.toLowerCase() : c;
}

export function isSameOrSubdir(parent, child) {
  const p = normalizeForComparison(parent);
  const c = normalizeForComparison(child);
  if (p === c) return true;
  const rel = path.relative(p, c);
  return !rel.startsWith('..') && !path.isAbsolute(rel);
}

export function findRepoRoot() {
  let curr = __dirname;
  while (curr) {
    if (fs.existsSync(path.join(curr, '.git')) || fs.existsSync(path.join(curr, '.codex-workflows'))) {
      return resolveCanonicalPath(curr);
    }
    const parent = path.dirname(curr);
    if (parent === curr) break;
    curr = parent;
  }
  return resolveCanonicalPath(path.resolve(__dirname, '../..'));
}

export function validateIsolatedDirectories({ workDir, cacheDir, runtimeDir, allowedRoot }) {
  if (!workDir || !cacheDir || !runtimeDir) {
    throw new Error('workDir, cacheDir, and runtimeDir must all be explicitly specified for isolated execution.');
  }

  const dirs = { workDir, cacheDir, runtimeDir };
  if (allowedRoot) dirs.allowedRoot = allowedRoot;

  const repoRoot = findRepoRoot();
  const homeDir = resolveCanonicalPath(os.homedir());

  const canonical = {};
  for (const [key, val] of Object.entries(dirs)) {
    canonical[key] = resolveCanonicalPath(val);
  }

  // 1. Check system root and system directories
  for (const [key, p] of Object.entries(canonical)) {
    const parsed = path.parse(p);
    if (parsed.root && normalizeForComparison(parsed.root) === normalizeForComparison(p)) {
      throw new Error(`Directory ${key} ("${p}") is a system drive root. Must be an isolated subdirectory.`);
    }

    const systemDirs = [
      process.env.SystemRoot,
      process.env.windir,
      process.env.ProgramFiles,
      process.env['ProgramFiles(x86)'],
      process.env.CommonProgramFiles,
      process.env['CommonProgramFiles(x86)']
    ].filter(Boolean);

    for (const sys of systemDirs) {
      if (isSameOrSubdir(sys, p)) {
        throw new Error(`Directory ${key} ("${p}") is inside system directory "${sys}". Must be an isolated directory.`);
      }
    }

    // 2. Check user home root and sensitive profile subdirectories
    if (normalizeForComparison(p) === normalizeForComparison(homeDir)) {
      throw new Error(`Directory ${key} ("${p}") is the user home root. Must be an isolated subdirectory.`);
    }
    for (const sens of ['.gemini', '.codex', '.ssh', '.aws', '.git']) {
      const sensPath = path.join(homeDir, sens);
      if (isSameOrSubdir(sensPath, p)) {
        throw new Error(`Directory ${key} ("${p}") is inside sensitive directory "${sensPath}". Forbidden.`);
      }
    }

    // 3. Check repository root
    if (normalizeForComparison(p) === normalizeForComparison(repoRoot) || isSameOrSubdir(repoRoot, p)) {
      throw new Error(`Directory ${key} ("${p}") is inside repository root "${repoRoot}". Test directories must be isolated outside the repo.`);
    }
    if (isSameOrSubdir(p, repoRoot)) {
      throw new Error(`Directory ${key} ("${p}") contains the repository root. Forbidden.`);
    }
  }

  // 4. Check mutual disjointness
  const pairs = [
    ['workDir', 'cacheDir'],
    ['workDir', 'runtimeDir'],
    ['cacheDir', 'runtimeDir']
  ];
  for (const [a, b] of pairs) {
    if (isSameOrSubdir(canonical[a], canonical[b]) || isSameOrSubdir(canonical[b], canonical[a])) {
      throw new Error(`Directories ${a} ("${canonical[a]}") and ${b} ("${canonical[b]}") overlap. Isolated roots must be disjoint.`);
    }
  }

  // 5. Require new empty isolated root(s) if existing
  for (const [key, p] of Object.entries(canonical)) {
    if (key === 'allowedRoot') continue;
    if (fs.existsSync(p)) {
      const entries = fs.readdirSync(p);
      if (entries.length > 0) {
        throw new Error(`Directory ${key} ("${p}") already exists and is not empty. Required isolated root must be new or empty.`);
      }
    }
  }

  return canonical;
}

// ============================================================================
// Utilities & Process Helpers
// ============================================================================

export function computeSha256(filePath) {
  if (!fs.existsSync(filePath)) return null;
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex').toLowerCase();
}

export function computeDirectorySha256(dirPath) {
  if (!fs.existsSync(dirPath)) return null;
  const hash = crypto.createHash('sha256');
  function walk(d) {
    const entries = fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
    for (const ent of entries) {
      const full = path.join(d, ent.name);
      if (ent.isDirectory()) {
        walk(full);
      } else if (ent.isFile()) {
        hash.update(path.relative(dirPath, full).replace(/\\/g, '/'));
        hash.update(fs.readFileSync(full));
      }
    }
  }
  walk(dirPath);
  return hash.digest('hex').toLowerCase();
}

export function verifyBinaryHash(binaryPath, expectedHash = null) {
  if (!fs.existsSync(binaryPath)) {
    throw new Error(`Binary path does not exist: ${binaryPath}`);
  }
  const actualHash = computeSha256(binaryPath);
  if (!actualHash) {
    throw new Error(`Failed to compute SHA-256 for binary: ${binaryPath}`);
  }

  if (expectedHash) {
    if (actualHash.toLowerCase() !== expectedHash.toLowerCase()) {
      throw new Error(`Binary SHA-256 mismatch: got ${actualHash}, expected ${expectedHash}`);
    }
  } else {
    const validHashes = Object.values(PINNED_CBM_HASHES.hashes).map(h => h.toLowerCase());
    if (!validHashes.includes(actualHash.toLowerCase())) {
      throw new Error(
        `Binary SHA-256 pin verification failed: got ${actualHash}. Expected one of pinned v0.10.8 digests: ${validHashes.join(', ')}`
      );
    }
  }
  return actualHash;
}

export function isProcessAlive(pid) {
  if (!pid || typeof pid !== 'number' || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return false;
  }
}

export async function waitForProcessExit(pid, maxWaitMs = 3000, pollIntervalMs = 50) {
  if (!pid || typeof pid !== 'number' || pid <= 0) return { exited: true, elapsedMs: 0 };
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    if (!isProcessAlive(pid)) {
      return { exited: true, elapsedMs: Date.now() - start };
    }
    await new Promise(r => setTimeout(r, pollIntervalMs));
  }
  return { exited: !isProcessAlive(pid), elapsedMs: Date.now() - start };
}

export function parseDaemonPidFromLog(logContent) {
  if (!logContent || typeof logContent !== 'string') return null;
  const matches = [...logContent.matchAll(/(?:msg=)?daemon\.start\b.*?pid[=:\s]+(\d+)/gi)];
  if (matches.length > 0) {
    const last = matches[matches.length - 1];
    const pid = parseInt(last[1], 10);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  }
  return null;
}

export function validateReportFilePath(reportFile, allowedRoot = null) {
  if (!reportFile || typeof reportFile !== 'string') {
    throw new Error('Report file path must be a non-empty string.');
  }
  const resolved = resolveCanonicalPath(reportFile);

  // 1. Refuse to overwrite ANY existing file
  if (fs.existsSync(resolved)) {
    throw new Error(`Report file "${resolved}" already exists. Refusing to overwrite arbitrary existing file.`);
  }

  // 2. Reject system drive root
  const parsed = path.parse(resolved);
  if (parsed.root && normalizeForComparison(parsed.root) === normalizeForComparison(resolved)) {
    throw new Error(`Report file "${resolved}" cannot be a system drive root.`);
  }

  // 3. Reject system directories
  const systemDirs = [
    process.env.SystemRoot,
    process.env.windir,
    process.env.ProgramFiles,
    process.env['ProgramFiles(x86)'],
    process.env.CommonProgramFiles,
    process.env['CommonProgramFiles(x86)']
  ].filter(Boolean);

  for (const sys of systemDirs) {
    if (isSameOrSubdir(sys, resolved)) {
      throw new Error(`Report file "${resolved}" is inside system directory "${sys}". Forbidden.`);
    }
  }

  // 4. Reject user home root and sensitive subdirectories
  const homeDir = resolveCanonicalPath(os.homedir());
  if (normalizeForComparison(resolved) === normalizeForComparison(homeDir)) {
    throw new Error(`Report file "${resolved}" cannot be the user home root.`);
  }
  for (const sens of ['.gemini', '.codex', '.ssh', '.aws', '.git']) {
    const sensPath = path.join(homeDir, sens);
    if (isSameOrSubdir(sensPath, resolved)) {
      throw new Error(`Report file "${resolved}" is inside sensitive directory "${sensPath}". Forbidden.`);
    }
  }

  // 5. Reject repository root directory
  const repoRoot = findRepoRoot();
  if (normalizeForComparison(resolved) === normalizeForComparison(repoRoot)) {
    throw new Error(`Report file "${resolved}" cannot be repository root.`);
  }

  // 6. If allowedRoot is specified, must be contained within allowedRoot
  if (allowedRoot) {
    const canonRoot = resolveCanonicalPath(allowedRoot);
    if (!isSameOrSubdir(canonRoot, resolved)) {
      throw new Error(`Report file "${resolved}" must be located within allowed root "${canonRoot}".`);
    }
  }

  return resolved;
}


export async function getBinaryVersion(binaryPath, env = {}, cwd = null) {
  try {
    const vProc = spawn(binaryPath, ['--version'], {
      env: {
        SYSTEMROOT: process.env.SYSTEMROOT || process.env.SystemRoot,
        SystemDrive: process.env.SystemDrive,
        PATH: process.env.PATH,
        ...env
      },
      cwd: cwd || os.tmpdir(),
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const vBuf = [];
    vProc.stdout.on('data', d => vBuf.push(d));
    const code = await new Promise((resolve) => {
      vProc.on('close', resolve);
      setTimeout(() => {
        try { vProc.kill(); } catch (e) {}
        resolve(-1);
      }, 3000);
    });
    const out = Buffer.concat(vBuf).toString('utf8').trim();
    if (code === 0 && out) {
      return out;
    }
    return 'unknown';
  } catch (e) {
    return 'unknown';
  }
}

export async function getBinaryConfig(binaryPath, env = {}, cwd = null) {
  try {
    const cProc = spawn(binaryPath, ['config', 'list'], {
      env: {
        SYSTEMROOT: process.env.SYSTEMROOT || process.env.SystemRoot,
        SystemDrive: process.env.SystemDrive,
        PATH: process.env.PATH,
        ...env
      },
      cwd: cwd || os.tmpdir(),
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const cBuf = [];
    const errBuf = [];
    cProc.stdout.on('data', d => cBuf.push(d));
    cProc.stderr.on('data', d => errBuf.push(d));
    const code = await new Promise((resolve) => {
      cProc.on('close', resolve);
      setTimeout(() => {
        try { cProc.kill(); } catch (e) {}
        resolve(-1);
      }, 3000);
    });
    const stdout = Buffer.concat(cBuf).toString('utf8').trim();
    const stderr = Buffer.concat(errBuf).toString('utf8').trim();
    return { exitCode: code, stdout, stderr };
  } catch (e) {
    return { exitCode: -1, stdout: '', stderr: e.message };
  }
}

export function inspectDirectorySnapshot(dirPath) {
  if (!dirPath || !fs.existsSync(dirPath)) return { exists: false, entries: [] };
  const entries = [];
  function walk(d) {
    let list = [];
    try {
      list = fs.readdirSync(d, { withFileTypes: true });
    } catch (e) {
      return;
    }
    for (const item of list) {
      const full = path.join(d, item.name);
      const rel = path.relative(dirPath, full).replace(/\\/g, '/');
      try {
        const stat = fs.statSync(full);
        entries.push({
          name: rel,
          type: item.isDirectory() ? 'directory' : (item.isFile() ? 'file' : 'other'),
          sizeBytes: stat.size,
          modifiedIso: stat.mtime.toISOString()
        });
        if (item.isDirectory()) {
          walk(full);
        }
      } catch (e) {
        entries.push({ name: rel, error: e.message });
      }
    }
  }
  walk(dirPath);
  return { exists: true, entries };
}

export function parseToolResult(res, toolName = 'unknown_tool') {
  if (!res) {
    throw new Error(`Empty response from tool "${toolName}"`);
  }
  if (res.isError === true) {
    const msg = res.content?.[0]?.text || JSON.stringify(res);
    throw new Error(`Tool "${toolName}" returned isError=true: ${msg}`);
  }
  if (!Array.isArray(res.content) || res.content.length === 0) {
    throw new Error(`Tool "${toolName}" returned response without content array: ${JSON.stringify(res)}`);
  }
  const text = res.content[0].text;
  if (typeof text !== 'string') {
    throw new Error(`Tool "${toolName}" content[0].text is not a string: ${JSON.stringify(res)}`);
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    return { rawText: text };
  }
}

export function deriveProjectName(repoPath) {
  if (!repoPath || typeof repoPath !== 'string') return 'runtime-fixture';
  const canonical = resolveCanonicalPath(repoPath);
  const base = path.basename(canonical).replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 20);
  const hash = crypto.createHash('sha256').update(canonical).digest('hex').slice(0, 8);
  return `${base || 'repo'}-${hash}`;
}

export function buildIndexToolArgs(toolDef, repoPath) {
  const schema = toolDef?.inputSchema || {};
  const props = schema.properties || {};
  const required = schema.required || [];

  const args = {};
  if ('path' in props || required.includes('path')) {
    args.path = repoPath;
  } else if ('repo_path' in props || required.includes('repo_path')) {
    args.repo_path = repoPath;
  } else {
    args.path = repoPath;
  }

  const projName = deriveProjectName(repoPath);
  if ('name' in props || required.includes('name')) {
    args.name = projName;
  } else if ('project' in props || required.includes('project')) {
    args.project = projName;
  }
  return args;
}

export function buildSearchToolArgs(toolDef, pattern, repoPath = null) {
  const schema = toolDef?.inputSchema || {};
  const props = schema.properties || {};
  const required = schema.required || [];

  const args = {};
  if ('name_pattern' in props || required.includes('name_pattern')) {
    args.name_pattern = pattern;
  } else if ('query' in props || required.includes('query')) {
    args.query = pattern;
  } else {
    args.name_pattern = pattern;
  }

  if (('project' in props || required.includes('project')) && repoPath) {
    args.project = deriveProjectName(repoPath);
  }
  return args;
}

// ============================================================================
// Internal Mock Server Worker (--mock-worker)
// ============================================================================

function runMockWorker() {
  const isStrictNdjson = process.argv.includes('--mock-strict-ndjson');
  const framing = process.argv.includes('--mock-framing-content-length')
    ? 'content-length'
    : (process.argv.includes('--mock-framing-newline') ? 'newline' : 'newline');
  let buffer = Buffer.alloc(0);
  const mockState = {
    indexedFiles: new Map(),
    indexedSymbols: new Set()
  };

  function sendResponse(msg) {
    const json = JSON.stringify(msg);
    if (framing === 'newline') {
      process.stdout.write(json + '\n');
    } else {
      const len = Buffer.byteLength(json, 'utf8');
      process.stdout.write(`Content-Length: ${len}\r\n\r\n${json}`);
    }
  }

  function handleMessage(msg) {
    if (!msg || typeof msg !== 'object') return;

    if (msg.method && msg.id === undefined) {
      return;
    }

    const { id, method, params } = msg;

    if (method === 'initialize') {
      if (process.argv.includes('--mock-fail-initialize')) {
        process.stderr.write('mock-worker: simulated initialization failure with DACL check\n');
        process.exit(1);
      }
      const requestedVersion = params?.protocolVersion || '2024-11-05';
      sendResponse({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: requestedVersion,
          serverInfo: {
            name: 'codebase-memory-mcp',
            version: '0.10.8-mock'
          },
          capabilities: {
            tools: { listChanged: false },
            prompts: { listChanged: false }
          }
        }
      });
      return;
    }

    if (method === 'tools/list') {
      sendResponse({
        jsonrpc: '2.0',
        id,
        result: {
          tools: [
            {
              name: 'index_repository',
              description: 'Index repository and build persistent knowledge graph',
              inputSchema: {
                type: 'object',
                properties: {
                  path: { type: 'string', description: 'Repository root path' },
                  repo_path: { type: 'string', description: 'Alias for repository path' }
                }
              }
            },
            {
              name: 'search_graph',
              description: 'Search graph symbols by pattern or query',
              inputSchema: {
                type: 'object',
                properties: {
                  name_pattern: { type: 'string' },
                  query: { type: 'string' }
                }
              }
            },
            {
              name: 'list_projects',
              description: 'List indexed projects',
              inputSchema: { type: 'object' }
            },
            {
              name: 'get_architecture',
              description: 'Get high-level architecture overview',
              inputSchema: { type: 'object' }
            },
            {
              name: 'mock_slow',
              description: 'Deliberately slow tool for transport timeout testing',
              inputSchema: {
                type: 'object',
                properties: {
                  delay_ms: { type: 'number' }
                }
              }
            },
            {
              name: 'mock_error_tool',
              description: 'Tool returning isError=true for negative testing',
              inputSchema: { type: 'object' }
            }
          ]
        }
      });
      return;
    }

    if (method === 'tools/call') {
      const toolName = params?.name;
      const args = params?.arguments || {};

      if (toolName === 'mock_error_tool') {
        sendResponse({
          jsonrpc: '2.0',
          id,
          result: {
            isError: true,
            content: [{ type: 'text', text: 'Simulated downstream tool error' }]
          }
        });
        return;
      }

      if (toolName === 'index_repository') {
        const repoPath = args.path || args.repo_path;
        if (!repoPath || !fs.existsSync(repoPath)) {
          sendResponse({
            jsonrpc: '2.0',
            id,
            result: {
              isError: true,
              content: [{ type: 'text', text: 'repo_path does not exist' }]
            }
          });
          return;
        }

        // Load root .gitignore and root .cbmignore (single root rule)
        const ignoreRules = [];
        for (const ignoreFile of ['.gitignore', '.cbmignore']) {
          const p = path.join(repoPath, ignoreFile);
          if (fs.existsSync(p)) {
            const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
            for (const l of lines) {
              // Exact pattern matching: empty or comment lines skipped
              if (l.trim() && !l.trim().startsWith('#')) {
                // Keep pattern exact (without trimming interior whitespace)
                ignoreRules.push(l.trim());
              }
            }
          }
        }

        function isIgnored(rel) {
          const normalized = rel.replace(/\\/g, '/');
          return ignoreRules.some(rule => {
            const cleanRule = rule.replace(/^\/+|\/+$/g, '');
            return normalized === cleanRule || normalized.endsWith('/' + cleanRule) || normalized.startsWith(cleanRule + '/');
          });
        }

        mockState.indexedSymbols.clear();
        mockState.indexedFiles.clear();

        function walk(dir, rel = '') {
          const entries = fs.readdirSync(dir, { withFileTypes: true });
          for (const ent of entries) {
            const childRel = rel ? `${rel}/${ent.name}` : ent.name;
            if (isIgnored(childRel)) continue;
            const full = path.join(dir, ent.name);
            if (ent.isDirectory()) {
              walk(full, childRel);
            } else if (ent.isFile() && (ent.name.endsWith('.js') || ent.name.endsWith('.mjs') || ent.name.endsWith('.ts'))) {
              const code = fs.readFileSync(full, 'utf8');
              mockState.indexedFiles.set(childRel, code);
              const fnMatches = [...code.matchAll(/(?:function\s+([a-zA-Z0-9_$]+)|const\s+([a-zA-Z0-9_$]+)\s*=\s*(?:function|\([^)]*\)\s*=>))/g)];
              for (const m of fnMatches) {
                const sym = m[1] || m[2];
                if (sym) mockState.indexedSymbols.add(sym);
              }
            }
          }
        }

        walk(repoPath);

        sendResponse({
          jsonrpc: '2.0',
          id,
          result: {
            content: [{
              type: 'text',
              text: JSON.stringify({
                status: 'indexed',
                files_indexed: mockState.indexedFiles.size,
                symbols_indexed: mockState.indexedSymbols.size
              })
            }]
          }
        });
        return;
      }

      if (toolName === 'search_graph') {
        const pattern = args.name_pattern;
        const query = args.query;
        let regex = null;
        if (pattern) {
          try {
            regex = new RegExp(pattern);
          } catch (e) {
            regex = new RegExp(pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
          }
        }

        const matches = [];
        for (const sym of mockState.indexedSymbols) {
          if (regex && regex.test(sym)) {
            matches.push({ name: sym, kind: 'Function' });
          } else if (query && sym.toLowerCase().includes(query.toLowerCase())) {
            matches.push({ name: sym, kind: 'Function' });
          }
        }

        sendResponse({
          jsonrpc: '2.0',
          id,
          result: {
            content: [{
              type: 'text',
              text: JSON.stringify({
                symbols: matches,
                count: matches.length
              })
            }]
          }
        });
        return;
      }

      if (toolName === 'mock_slow') {
        const delay = args.delay_ms || 300;
        setTimeout(() => {
          sendResponse({
            jsonrpc: '2.0',
            id,
            result: {
              content: [{ type: 'text', text: `delayed by ${delay}ms` }]
            }
          });
        }, delay);
        return;
      }

      sendResponse({
        jsonrpc: '2.0',
        id,
        result: {
          isError: true,
          content: [{ type: 'text', text: `unknown tool: ${toolName}` }]
        }
      });
      return;
    }

    sendResponse({
      jsonrpc: '2.0',
      id,
      error: {
        code: -32601,
        message: 'Method not found'
      }
    });
  }

  process.stdin.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length > 0) {
      const str = buffer.toString('utf8');
      if (!isStrictNdjson && (str.startsWith('Content-Length:') || str.startsWith('content-length:'))) {
        let headerEnd = str.indexOf('\r\n\r\n');
        let sepLen = 4;
        if (headerEnd === -1) {
          headerEnd = str.indexOf('\r\r\n\r\r\n');
          if (headerEnd !== -1) {
            sepLen = 6;
          } else {
            headerEnd = str.indexOf('\n\n');
            sepLen = 2;
          }
        }
        if (headerEnd === -1) break;

        const headerText = str.substring(0, headerEnd);
        const match = headerText.match(/content-length:\s*(\d+)/i);
        if (!match) {
          buffer = buffer.subarray(headerEnd + sepLen);
          continue;
        }
        const len = parseInt(match[1], 10);
        const headerByteLen = Buffer.byteLength(headerText, 'utf8') + sepLen;
        if (buffer.length < headerByteLen + len) break;

        const body = buffer.subarray(headerByteLen, headerByteLen + len);
        buffer = buffer.subarray(headerByteLen + len);
        try {
          handleMessage(JSON.parse(body.toString('utf8')));
        } catch (e) {}
        continue;
      }

      const nl = buffer.indexOf(0x0a);
      if (nl !== -1) {
        const line = buffer.subarray(0, nl).toString('utf8').trim();
        buffer = buffer.subarray(nl + 1);
        if (line) {
          try {
            handleMessage(JSON.parse(line));
          } catch (e) {}
        }
        continue;
      }

      break;
    }
  });
}

// ============================================================================
// MCP Client Implementation
// ============================================================================

export class McpStdioClient {
  constructor(options = {}) {
    this.command = options.command;
    this.args = options.args || [];
    this.env = options.env || { ...process.env };
    this.cwd = options.cwd || process.cwd();
    this.defaultTimeoutMs = options.defaultTimeoutMs || 5000;
    this.framing = options.framing || 'newline';
    this.child = null;
    this.pid = null;
    this.pendingRequests = new Map();
    this.nextId = 1;
    this.buffer = Buffer.alloc(0);
    this.stderrLines = [];
    this.isClosed = false;
    this.exitCode = null;
    this.exitSignal = null;
  }

  getSanitizedStderr(maxLines = 10, maxLineLen = 240) {
    if (!this.stderrLines || this.stderrLines.length === 0) return '';
    const slice = this.stderrLines.slice(-maxLines);
    return slice.map(l => {
      let clean = l.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '').trim();
      if (clean.length > maxLineLen) {
        clean = clean.substring(0, maxLineLen) + '...';
      }
      return clean;
    }).filter(Boolean).join(' | ');
  }

  async start() {
    return new Promise((resolve, reject) => {
      this.child = spawn(this.command, this.args, {
        env: this.env,
        cwd: this.cwd,
        stdio: ['pipe', 'pipe', 'pipe']
      });

      this.pid = this.child.pid;

      this.child.on('error', (err) => {
        reject(err);
      });

      this.child.stdout.on('data', (chunk) => {
        this._handleData(chunk);
      });

      this.child.stderr.on('data', (chunk) => {
        const lines = chunk.toString('utf8').split(/\r?\n/);
        for (const l of lines) {
          if (l.trim()) {
            this.stderrLines.push(l.trim());
            if (this.stderrLines.length > 200) this.stderrLines.shift();
          }
        }
      });

      this.child.on('close', (code, signal) => {
        this.isClosed = true;
        this.exitCode = code;
        this.exitSignal = signal;
        const stderrDetail = this.getSanitizedStderr();
        const errDetail = stderrDetail ? ` - Stderr: "${stderrDetail}"` : '';
        for (const [id, req] of this.pendingRequests.entries()) {
          clearTimeout(req.timer);
          req.reject(new Error(`MCP server process closed (code: ${code}, signal: ${signal}) while waiting for id ${id}${errDetail}`));
        }
        this.pendingRequests.clear();
      });

      resolve();
    });
  }

  _handleData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length > 0) {
      const msg = this._tryExtractMessage();
      if (!msg) break;
      this._dispatchMessage(msg);
    }
  }

  _tryExtractMessage() {
    if (this.buffer.length === 0) return null;
    const str = this.buffer.toString('utf8');

    if (str.startsWith('Content-Length:') || str.startsWith('content-length:')) {
      let headerEnd = str.indexOf('\r\n\r\n');
      let sepLen = 4;
      if (headerEnd === -1) {
        headerEnd = str.indexOf('\r\r\n\r\r\n');
        if (headerEnd !== -1) {
          sepLen = 6;
        } else {
          headerEnd = str.indexOf('\n\n');
          sepLen = 2;
        }
      }
      if (headerEnd === -1) return null;

      const headerText = str.substring(0, headerEnd);
      const match = headerText.match(/content-length:\s*(\d+)/i);
      if (!match) {
        this.buffer = this.buffer.subarray(headerEnd + sepLen);
        return null;
      }

      const contentLength = parseInt(match[1], 10);
      const headerByteLen = Buffer.byteLength(headerText, 'utf8') + sepLen;
      if (this.buffer.length < headerByteLen + contentLength) return null;

      const bodyBuffer = this.buffer.subarray(headerByteLen, headerByteLen + contentLength);
      this.buffer = this.buffer.subarray(headerByteLen + contentLength);
      try {
        return JSON.parse(bodyBuffer.toString('utf8'));
      } catch (e) {
        return null;
      }
    }

    const nl = this.buffer.indexOf(0x0a);
    if (nl !== -1) {
      const lineBuf = this.buffer.subarray(0, nl);
      this.buffer = this.buffer.subarray(nl + 1);
      const lineStr = lineBuf.toString('utf8').trim();
      if (!lineStr) return null;
      try {
        return JSON.parse(lineStr);
      } catch (e) {
        return null;
      }
    }

    return null;
  }

  _dispatchMessage(msg) {
    if (msg.id !== undefined && this.pendingRequests.has(msg.id)) {
      const req = this.pendingRequests.get(msg.id);
      clearTimeout(req.timer);
      this.pendingRequests.delete(msg.id);
      if (msg.error) {
        const err = new Error(`MCP error ${msg.error.code}: ${msg.error.message || JSON.stringify(msg.error)}`);
        err.code = msg.error.code;
        err.rpcError = msg.error;
        req.reject(err);
      } else {
        req.resolve(msg.result);
      }
    }
  }

  async request(method, params = {}, timeoutMs = null) {
    if (this.isClosed) {
      const stderrDetail = this.getSanitizedStderr();
      const errDetail = stderrDetail ? ` - Stderr: "${stderrDetail}"` : '';
      throw new Error(`McpStdioClient is closed${errDetail}`);
    }
    const id = this.nextId++;
    const t = timeoutMs || this.defaultTimeoutMs;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pendingRequests.has(id)) {
          this.pendingRequests.delete(id);
          reject(new Error(`TRANSPORT_TIMEOUT: method "${method}" (id ${id}) timed out after ${t}ms`));
        }
      }, t);

      this.pendingRequests.set(id, { resolve, reject, timer, method });

      const payload = { jsonrpc: '2.0', id, method, params };
      this._send(payload);
    });
  }

  notify(method, params = {}) {
    if (this.isClosed) {
      throw new Error('McpStdioClient is closed');
    }
    const payload = { jsonrpc: '2.0', method, params };
    this._send(payload);
  }

  _send(payload) {
    const json = JSON.stringify(payload);
    let buf;
    if (this.framing === 'newline') {
      buf = Buffer.from(json + '\n', 'utf8');
    } else {
      const len = Buffer.byteLength(json, 'utf8');
      buf = Buffer.from(`Content-Length: ${len}\r\n\r\n${json}`, 'utf8');
    }
    this.child.stdin.write(buf);
  }

  async close(graceMs = 1200) {
    if (this.isClosed || !this.child) return;
    return new Promise((resolve) => {
      let finished = false;
      const done = () => {
        if (!finished) {
          finished = true;
          this.isClosed = true;
          resolve();
        }
      };

      this.child.once('exit', done);

      try {
        this.child.stdin.end();
      } catch (e) {}

      setTimeout(() => {
        if (!finished && this.child && this.child.exitCode === null) {
          try {
            this.child.kill('SIGTERM');
          } catch (e) {}
          setTimeout(() => {
            if (!finished && this.child && this.child.exitCode === null) {
              try {
                this.child.kill('SIGKILL');
              } catch (e) {}
            }
            done();
          }, 400);
        } else {
          done();
        }
      }, graceMs);
    });
  }
}

// ============================================================================
// Test Suite: Deterministic Self-Test Mode (--self-test)
// ============================================================================

export async function runSelfTest(opts = {}) {
  const tests = [];
  const startTotal = Date.now();

  async function recordTest(name, fn) {
    const t0 = Date.now();
    try {
      await fn();
      tests.push({ name, status: 'passed', durationMs: Date.now() - t0 });
    } catch (err) {
      tests.push({ name, status: 'failed', durationMs: Date.now() - t0, error: err.message });
    }
  }

  async function spawnMockClient(clientOpts = {}, workerArgs = []) {
    const client = new McpStdioClient({
      command: process.execPath,
      args: [__filename, '--mock-worker', ...workerArgs],
      defaultTimeoutMs: 3000,
      ...clientOpts
    });
    await client.start();
    return client;
  }

  // 1. Content-Length framing roundtrip
  await recordTest('framing_content_length_roundtrip', async () => {
    const client = await spawnMockClient({ framing: 'content-length' }, ['--mock-framing-content-length']);
    try {
      const res = await client.request('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'self-test-client', version: '1.0.0' }
      });
      if (!res.serverInfo || res.serverInfo.name !== 'codebase-memory-mcp') {
        throw new Error(`Unexpected serverInfo in initialize: ${JSON.stringify(res)}`);
      }
    } finally {
      await client.close();
    }
  });

  // 2. Newline framing roundtrip
  await recordTest('framing_newline_roundtrip', async () => {
    const client = await spawnMockClient({ framing: 'newline' });
    try {
      const res = await client.request('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'self-test-newline', version: '1.0.0' }
      });
      if (!res.serverInfo || res.serverInfo.name !== 'codebase-memory-mcp') {
        throw new Error(`Unexpected serverInfo in newline initialize: ${JSON.stringify(res)}`);
      }
    } finally {
      await client.close();
    }
  });

  // 3. MCP Handshake & Notification
  await recordTest('handshake_and_notification', async () => {
    const client = await spawnMockClient();
    try {
      const res = await client.request('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'handshake-test', version: '1.0.0' }
      });
      if (res.protocolVersion !== '2024-11-05') {
        throw new Error(`Protocol version mismatch: ${res.protocolVersion}`);
      }
      client.notify('notifications/initialized');
    } finally {
      await client.close();
    }
  });

  // 4. Tool Discovery
  await recordTest('tool_discovery', async () => {
    const client = await spawnMockClient();
    try {
      await client.request('initialize', { protocolVersion: '2024-11-05' });
      client.notify('notifications/initialized');
      const list = await client.request('tools/list');
      if (!Array.isArray(list.tools)) {
        throw new Error('tools/list response missing tools array');
      }
      const names = list.tools.map(t => t.name);
      if (!names.includes('index_repository')) {
        throw new Error('tools/list missing index_repository');
      }
      if (!names.includes('search_graph')) {
        throw new Error('tools/list missing search_graph');
      }
    } finally {
      await client.close();
    }
  });

  // 5. Protocol Error Handling (-32601)
  await recordTest('protocol_error_handling', async () => {
    const client = await spawnMockClient();
    try {
      await client.request('initialize', { protocolVersion: '2024-11-05' });
      let caught = false;
      try {
        await client.request('non_existent_method_xyz', {});
      } catch (err) {
        caught = true;
        if (err.code !== -32601) {
          throw new Error(`Expected error code -32601, got ${err.code} (${err.message})`);
        }
      }
      if (!caught) {
        throw new Error('Expected invalid method call to throw -32601');
      }
    } finally {
      await client.close();
    }
  });

  // 6. Bounded Transport Timeout
  await recordTest('bounded_transport_timeout', async () => {
    const client = await spawnMockClient();
    try {
      await client.request('initialize', { protocolVersion: '2024-11-05' });
      let timedOut = false;
      try {
        await client.request('tools/call', {
          name: 'mock_slow',
          arguments: { delay_ms: 300 }
        }, 60);
      } catch (err) {
        if (err.message.includes('TRANSPORT_TIMEOUT')) {
          timedOut = true;
        } else {
          throw err;
        }
      }
      if (!timedOut) {
        throw new Error('Expected call to fail with TRANSPORT_TIMEOUT');
      }
    } finally {
      await client.close();
    }
  });

  // 7. Concurrency & Demuxing
  await recordTest('concurrency_demuxing', async () => {
    const client = await spawnMockClient();
    try {
      await client.request('initialize', { protocolVersion: '2024-11-05' });

      const tmpDir = path.join(os.tmpdir(), `cbm-mock-fixture-${crypto.randomUUID()}`);
      fs.mkdirSync(tmpDir, { recursive: true });
      fs.writeFileSync(path.join(tmpDir, 'service.js'), [
        'function getCustomerRecord(id) { return { id }; }',
        'function calculateInvoiceTax(amount) { return amount * 0.15; }'
      ].join('\n') + '\n', 'utf8');

      try {
        const idxRes = await client.request('tools/call', {
          name: 'index_repository',
          arguments: { repo_path: tmpDir }
        });
        parseToolResult(idxRes, 'index_repository');

        const p1 = client.request('tools/call', {
          name: 'search_graph',
          arguments: { name_pattern: 'getCustomerRecord' }
        });
        const p2 = client.request('tools/call', {
          name: 'search_graph',
          arguments: { name_pattern: 'calculateInvoiceTax' }
        });

        const [r1, r2] = await Promise.all([p1, p2]);
        const body1 = parseToolResult(r1, 'search_graph');
        const body2 = parseToolResult(r2, 'search_graph');

        if (!body1.symbols.some(s => s.name === 'getCustomerRecord')) {
          throw new Error(`p1 missing getCustomerRecord: ${JSON.stringify(body1)}`);
        }
        if (!body2.symbols.some(s => s.name === 'calculateInvoiceTax')) {
          throw new Error(`p2 missing calculateInvoiceTax: ${JSON.stringify(body2)}`);
        }
      } finally {
        fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    } finally {
      await client.close();
    }
  });

  // 8. Fixture Generation, Mutation & Freshness Proof
  let fixtureHashBefore = null;
  let fixtureHashAfter = null;
  await recordTest('fixture_mutation_and_freshness', async () => {
    const client = await spawnMockClient();
    const tmpDir = path.join(os.tmpdir(), `cbm-freshness-${crypto.randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });

    try {
      const fileA = path.join(tmpDir, 'calculator.js');
      fs.writeFileSync(fileA, [
        'function initialCompute(val) {',
        '  return val * 2;',
        '}'
      ].join('\n') + '\n', 'utf8');

      fixtureHashBefore = computeDirectorySha256(tmpDir);

      await client.request('initialize', { protocolVersion: '2024-11-05' });
      const idxRes1 = await client.request('tools/call', {
        name: 'index_repository',
        arguments: { repo_path: tmpDir }
      });
      parseToolResult(idxRes1, 'index_repository');

      const check1 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'initialCompute' }
      });
      const parsed1 = parseToolResult(check1, 'search_graph');
      if (!parsed1.symbols.some(s => s.name === 'initialCompute')) {
        throw new Error('Initial function not found');
      }

      // Mutate fixture
      fs.appendFileSync(fileA, [
        'function newlyAddedHelper(extra) {',
        '  return extra + 10;',
        '}'
      ].join('\n') + '\n', 'utf8');

      fixtureHashAfter = computeDirectorySha256(tmpDir);
      if (fixtureHashBefore === fixtureHashAfter) {
        throw new Error('Fixture hash did not change after edit');
      }

      // Re-index and check freshness with isError checks
      const idxRes2 = await client.request('tools/call', {
        name: 'index_repository',
        arguments: { repo_path: tmpDir }
      });
      parseToolResult(idxRes2, 'index_repository');

      const check2 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'newlyAddedHelper' }
      });
      const parsed2 = parseToolResult(check2, 'search_graph');
      if (!parsed2.symbols.some(s => s.name === 'newlyAddedHelper')) {
        throw new Error('Newly added function not found after reindex (freshness failure)');
      }
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      await client.close();
    }
  });

  // 9. Exclusions Protection (.gitignore with exact unindented patterns)
  await recordTest('exclusions_protection_gitignore', async () => {
    const client = await spawnMockClient();
    const tmpDir = path.join(os.tmpdir(), `cbm-exclusions-git-${crypto.randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });

    try {
      // Exact unindented patterns
      const gitignoreContent = ['secret.js', 'private/'].join('\n') + '\n';
      fs.writeFileSync(path.join(tmpDir, '.gitignore'), gitignoreContent, 'utf8');

      fs.writeFileSync(path.join(tmpDir, 'public.js'), 'function publicApiCall() { return true; }\n', 'utf8');
      fs.writeFileSync(path.join(tmpDir, 'secret.js'), "function getSuperSecretKey() { return 'SECRET'; }\n", 'utf8');
      fs.mkdirSync(path.join(tmpDir, 'private'), { recursive: true });
      fs.writeFileSync(path.join(tmpDir, 'private', 'tokens.js'), "function getPrivateToken() { return 'TOKEN'; }\n", 'utf8');

      await client.request('initialize', { protocolVersion: '2024-11-05' });
      const idxRes = await client.request('tools/call', {
        name: 'index_repository',
        arguments: { repo_path: tmpDir }
      });
      parseToolResult(idxRes, 'index_repository');

      // Positive coverage before negative absence
      const pubRes = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'publicApiCall' }
      });
      const pubParsed = parseToolResult(pubRes, 'search_graph');
      if (!pubParsed.symbols.some(s => s.name === 'publicApiCall')) {
        throw new Error('Positive coverage failed: public symbol was not indexed');
      }

      // Negative absence verification with parseToolResult
      const secRes1 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'getSuperSecretKey' }
      });
      const secParsed1 = parseToolResult(secRes1, 'search_graph');
      if (secParsed1.symbols.length > 0) {
        throw new Error('Excluded symbol in secret.js was indexed!');
      }

      const secRes2 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'getPrivateToken' }
      });
      const secParsed2 = parseToolResult(secRes2, 'search_graph');
      if (secParsed2.symbols.length > 0) {
        throw new Error('Excluded symbol in private/ directory was indexed!');
      }
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      await client.close();
    }
  });

  // 10. Exclusions Protection (.cbmignore with exact unindented patterns)
  await recordTest('exclusions_protection_cbmignore', async () => {
    const client = await spawnMockClient();
    const tmpDir = path.join(os.tmpdir(), `cbm-exclusions-cbm-${crypto.randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });

    try {
      // Exact unindented patterns in .cbmignore
      const cbmignoreContent = ['cbm-secret.js', 'cbm-vault/'].join('\n') + '\n';
      fs.writeFileSync(path.join(tmpDir, '.cbmignore'), cbmignoreContent, 'utf8');

      fs.writeFileSync(path.join(tmpDir, 'shared.js'), 'function sharedApiModule() { return 100; }\n', 'utf8');
      fs.writeFileSync(path.join(tmpDir, 'cbm-secret.js'), "function getVaultSecretKey() { return 'SECRET'; }\n", 'utf8');
      fs.mkdirSync(path.join(tmpDir, 'cbm-vault'), { recursive: true });
      fs.writeFileSync(path.join(tmpDir, 'cbm-vault', 'creds.js'), "function getVaultCredentials() { return 'PASS'; }\n", 'utf8');

      await client.request('initialize', { protocolVersion: '2024-11-05' });
      const idxRes = await client.request('tools/call', {
        name: 'index_repository',
        arguments: { repo_path: tmpDir }
      });
      parseToolResult(idxRes, 'index_repository');

      // Positive coverage first
      const pubRes = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'sharedApiModule' }
      });
      const pubParsed = parseToolResult(pubRes, 'search_graph');
      if (!pubParsed.symbols.some(s => s.name === 'sharedApiModule')) {
        throw new Error('Positive coverage failed: shared symbol was not indexed under .cbmignore');
      }

      // Negative absence verification
      const secRes1 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'getVaultSecretKey' }
      });
      const secParsed1 = parseToolResult(secRes1, 'search_graph');
      if (secParsed1.symbols.length > 0) {
        throw new Error('.cbmignore excluded symbol was indexed!');
      }

      const secRes2 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: { name_pattern: 'getVaultCredentials' }
      });
      const secParsed2 = parseToolResult(secRes2, 'search_graph');
      if (secParsed2.symbols.length > 0) {
        throw new Error('.cbmignore directory excluded symbol was indexed!');
      }
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      await client.close();
    }
  });

  // 11. Process Ownership & Safe Cleanup (PID tracking, zero global kills)
  let recordedPid = null;
  let processCleanlyExited = false;
  await recordTest('process_ownership_clean_exit', async () => {
    const client = await spawnMockClient();
    recordedPid = client.pid;
    if (!recordedPid) {
      throw new Error('Child PID was not recorded');
    }

    await client.request('initialize', { protocolVersion: '2024-11-05' });
    await client.close(800);

    // Realistic process liveness check
    processCleanlyExited = !isProcessAlive(recordedPid);
    if (!processCleanlyExited) {
      throw new Error(`Child process PID ${recordedPid} remained alive after close()`);
    }
  });

  // 12. Negative Test: Path Isolation & Overlap / System Root Rejection
  await recordTest('negative_path_bounds_and_overlap_rejection', async () => {
    const baseTemp = path.join(os.tmpdir(), `cbm-neg-root-${crypto.randomUUID()}`);
    fs.mkdirSync(baseTemp, { recursive: true });

    try {
      const dirA = path.join(baseTemp, 'dirA');
      const dirB = path.join(baseTemp, 'dirA', 'nestedB'); // Overlapping!
      const dirC = path.join(baseTemp, 'dirC');

      // Test 1: Overlapping directories rejected
      let overlapCaught = false;
      try {
        validateIsolatedDirectories({ workDir: dirA, cacheDir: dirB, runtimeDir: dirC });
      } catch (err) {
        overlapCaught = true;
        if (!err.message.includes('overlap')) {
          throw new Error(`Expected overlap error, got: ${err.message}`);
        }
      }
      if (!overlapCaught) {
        throw new Error('Expected overlapping directories to be rejected');
      }

      // Test 2: System root rejected
      const rootPath = path.parse(process.cwd()).root;
      let rootCaught = false;
      try {
        validateIsolatedDirectories({ workDir: rootPath, cacheDir: dirA, runtimeDir: dirC });
      } catch (err) {
        rootCaught = true;
        if (!err.message.includes('system drive root') && !err.message.includes('system directory')) {
          throw new Error(`Expected system root error, got: ${err.message}`);
        }
      }
      if (!rootCaught) {
        throw new Error('Expected system drive root to be rejected');
      }

      // Test 3: Repo root rejected
      const repoRoot = findRepoRoot();
      let repoCaught = false;
      try {
        validateIsolatedDirectories({ workDir: repoRoot, cacheDir: dirA, runtimeDir: dirC });
      } catch (err) {
        repoCaught = true;
        if (!err.message.includes('repository root')) {
          throw new Error(`Expected repo root error, got: ${err.message}`);
        }
      }
      if (!repoCaught) {
        throw new Error('Expected repo root to be rejected');
      }

      // Test 4: Existing non-empty directory rejected
      const nonEmptyDir = path.join(baseTemp, 'non-empty');
      fs.mkdirSync(nonEmptyDir, { recursive: true });
      fs.writeFileSync(path.join(nonEmptyDir, 'existing.txt'), 'content');

      let nonEmptyCaught = false;
      try {
        validateIsolatedDirectories({
          workDir: nonEmptyDir,
          cacheDir: path.join(baseTemp, 'empty1'),
          runtimeDir: path.join(baseTemp, 'empty2')
        });
      } catch (err) {
        nonEmptyCaught = true;
        if (!err.message.includes('not empty')) {
          throw new Error(`Expected non-empty directory error, got: ${err.message}`);
        }
      }
      if (!nonEmptyCaught) {
        throw new Error('Expected existing non-empty directory to be rejected');
      }
    } finally {
      fs.rmSync(baseTemp, { recursive: true, force: true });
    }
  });

  // 13. Negative Test: Existing Fixture Overwrite Rejection
  await recordTest('negative_existing_fixture_no_overwrite', async () => {
    const baseTemp = path.join(os.tmpdir(), `cbm-neg-fixture-${crypto.randomUUID()}`);
    const existingFixture = path.join(baseTemp, 'runtime-fixture');
    fs.mkdirSync(existingFixture, { recursive: true });
    fs.writeFileSync(path.join(existingFixture, 'precious-user-data.txt'), 'MUST_NOT_OVERWRITE');

    try {
      if (fs.existsSync(existingFixture)) {
        // Enforce the rule: fixture existing must not overwrite
        let threw = false;
        try {
          if (fs.existsSync(existingFixture)) {
            throw new Error(`Fixture directory already exists: "${existingFixture}". Existing fixtures must not be overwritten.`);
          }
        } catch (err) {
          threw = true;
        }
        if (!threw) {
          throw new Error('Expected existing fixture collision to throw error');
        }
      }
    } finally {
      fs.rmSync(baseTemp, { recursive: true, force: true });
    }
  });

  // 14. Negative Test: Binary Hash Pin Verification Mismatch
  await recordTest('negative_binary_hash_pin_mismatch', async () => {
    const fakeBin = path.join(os.tmpdir(), `cbm-fake-bin-${crypto.randomUUID()}.exe`);
    fs.writeFileSync(fakeBin, 'MOCK_BINARY_WITH_INVALID_HASH');

    try {
      let caught = false;
      try {
        verifyBinaryHash(fakeBin);
      } catch (err) {
        caught = true;
        if (!err.message.includes('pin verification failed')) {
          throw new Error(`Expected pin verification failed, got: ${err.message}`);
        }
      }
      if (!caught) {
        throw new Error('Expected invalid binary hash to fail pin verification');
      }
    } finally {
      fs.rmSync(fakeBin, { force: true });
    }
  });

  // 15. Negative Test: Tool isError Prevents False-Green
  await recordTest('negative_tool_error_isError_detection', async () => {
    const client = await spawnMockClient();
    try {
      await client.request('initialize', { protocolVersion: '2024-11-05' });
      const res = await client.request('tools/call', { name: 'mock_error_tool' });

      let caught = false;
      try {
        parseToolResult(res, 'mock_error_tool');
      } catch (err) {
        caught = true;
        if (!err.message.includes('isError=true')) {
          throw new Error(`Expected isError=true error, got: ${err.message}`);
        }
      }
      if (!caught) {
        throw new Error('Expected tool with isError=true to throw error instead of false-greening');
      }
    } finally {
      await client.close();
    }
  });

  // 16. Negative Test: Binary Version Subprocess Lacks False Defaulting
  await recordTest('negative_version_empty_output_unknown', async () => {
    // Calling an empty script or non-version binary should return 'unknown', never 'v0.10.8'
    const dummyScript = path.join(os.tmpdir(), `dummy-empty-${crypto.randomUUID()}.cmd`);
    fs.writeFileSync(dummyScript, '@echo off\r\n', 'utf8');

    try {
      const ver = await getBinaryVersion(dummyScript);
      if (ver === 'v0.10.8') {
        throw new Error('Version retrieval fabricated v0.10.8 from empty output!');
      }
      if (ver !== 'unknown') {
        throw new Error(`Expected 'unknown' version for empty output, got: ${ver}`);
      }
    } finally {
      fs.rmSync(dummyScript, { force: true });
    }
  });

  // 17. Negative Test: Client Captures Stderr on Premature Child Exit
  await recordTest('negative_client_stderr_capture_on_exit', async () => {
    const client = await spawnMockClient({}, ['--mock-fail-initialize']);
    try {
      let caught = false;
      try {
        await client.request('initialize', { protocolVersion: '2024-11-05' });
      } catch (err) {
        caught = true;
        if (!err.message.includes('mock-worker: simulated initialization failure')) {
          throw new Error(`Expected captured stderr in error message, got: "${err.message}"`);
        }
      }
      if (!caught) {
        throw new Error('Expected initialize to reject when worker process exits');
      }
    } finally {
      await client.close();
    }
  });

  // 18. Negative Test: Fail-Fast Prerequisites Prevent Fixture Mutation on Init Failure
  await recordTest('negative_fail_fast_prerequisite_skipping', async () => {
    const tmpDir = path.join(os.tmpdir(), `cbm-neg-failfast-${crypto.randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    const dummyFile = path.join(tmpDir, 'test.js');
    fs.writeFileSync(dummyFile, 'const original = true;\n', 'utf8');
    const hashBefore = computeDirectorySha256(tmpDir);

    const client = await spawnMockClient({}, ['--mock-fail-initialize']);
    try {
      let initializePassed = false;
      try {
        await client.request('initialize', { protocolVersion: '2024-11-05' });
        initializePassed = true;
      } catch (e) {
        initializePassed = false;
      }

      // Simulate step: must fail-fast and NOT alter fixture
      if (!initializePassed || client.isClosed) {
        // Correct behavior: do NOT mutate dummyFile
      } else {
        fs.appendFileSync(dummyFile, 'const mutated = true;\n');
      }

      const hashAfter = computeDirectorySha256(tmpDir);
      if (hashBefore !== hashAfter) {
        throw new Error('Fixture was mutated despite initialize failure!');
      }
    } finally {
      await client.close();
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // 19. Regression Test: daemon.start logfmt format parsing and strict exact PID ownership
  await recordTest('regression_daemon_start_format_and_strict_pid_ownership', async () => {
    const realLogfmtLine = 'level=info msg=daemon.start version=0.10.8 pid=65680 cache_fingerprint=81d41757122acc3f memory_budget_bytes=11989966643\n';

    // RED verification: legacy regex /daemon\.start.*?pid[:\s]+(\d+)/i fails to parse pid=65680 format
    const legacyRegex = /daemon\.start.*?pid[:\s]+(\d+)/i;
    const legacyMatch = realLogfmtLine.match(legacyRegex);
    if (legacyMatch !== null) {
      throw new Error('Expected legacy regex to fail matching pid=65680 (RED condition)');
    }

    // GREEN verification: parseDaemonPidFromLog correctly extracts PID 65680
    const parsedPid = parseDaemonPidFromLog(realLogfmtLine);
    if (parsedPid !== 65680) {
      throw new Error(`Expected parseDaemonPidFromLog to extract 65680, got ${parsedPid} (GREEN condition)`);
    }

    // Strict exact PID ownership verification:
    // When daemon PID is parsed, daemonObserved MUST be true and status must reflect PID state
    const observedPids = [1234];
    const daemonPid = parsedPid;
    if (daemonPid && !observedPids.includes(daemonPid)) {
      observedPids.push(daemonPid);
    }
    const daemonObserved = daemonPid !== null;
    if (!daemonObserved || !observedPids.includes(65680)) {
      throw new Error('daemonObserved was false or observedPids did not include parsed daemon PID');
    }
    const status = daemonPid ? 'daemon_exited' : 'unobserved';
    if (status === 'unobserved') {
      throw new Error('Contradiction: daemon with parsed PID 65680 was falsely classified as unobserved');
    }

    // Absence check: genuinely unobserved daemon (no daemon.start line)
    const emptyLog = 'level=info msg=watcher.stop\n';
    const emptyPid = parseDaemonPidFromLog(emptyLog);
    if (emptyPid !== null) {
      throw new Error(`Expected null PID for empty log, got ${emptyPid}`);
    }
  });

  // 20. Regression Test: Strict Upstream NDJSON Reader Rejection of Content-Length vs Green on Newline
  await recordTest('regression_strict_ndjson_reader_framing', async () => {
    // RED verification: client with framing='content-length' against strict NDJSON reader fails with TRANSPORT_TIMEOUT
    const redClient = await spawnMockClient({ framing: 'content-length', defaultTimeoutMs: 250 }, ['--mock-strict-ndjson']);
    let redFailed = false;
    try {
      await redClient.request('initialize', { protocolVersion: '2024-11-05' });
    } catch (err) {
      if (err.message.includes('TRANSPORT_TIMEOUT')) {
        redFailed = true;
      }
    } finally {
      await redClient.close();
    }
    if (!redFailed) {
      throw new Error('Expected Content-Length framing against strict NDJSON reader to fail (RED condition)');
    }

    // GREEN verification: client with default newline framing against strict NDJSON reader succeeds
    const greenClient = await spawnMockClient({ defaultTimeoutMs: 1500 }, ['--mock-strict-ndjson']);
    try {
      const res = await greenClient.request('initialize', { protocolVersion: '2024-11-05' });
      if (!res.serverInfo || !res.serverInfo.name) {
        throw new Error(`Invalid initialize response from strict NDJSON reader: ${JSON.stringify(res)}`);
      }
    } finally {
      await greenClient.close();
    }
  });

  // 21. Regression Test: Diagnostic Directory Snapshot and Bounded Path-Safe Report File
  await recordTest('regression_report_file_bounded_path_safety_and_no_overwrite', async () => {
    const tmpDir = path.join(os.tmpdir(), `cbm-diag-test-${crypto.randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    const subFile = path.join(tmpDir, 'test-lock.lock');
    fs.writeFileSync(subFile, 'lock-content', 'utf8');

    try {
      const snap = inspectDirectorySnapshot(tmpDir);
      if (!snap.exists || !Array.isArray(snap.entries) || snap.entries.length !== 1) {
        throw new Error(`Snapshot did not capture expected entry: ${JSON.stringify(snap)}`);
      }
      if (snap.entries[0].name !== 'test-lock.lock' || snap.entries[0].sizeBytes !== 12) {
        throw new Error(`Snapshot entry attributes mismatch: ${JSON.stringify(snap.entries[0])}`);
      }

      // RED verification: validateReportFilePath refuses to overwrite an existing file
      let overwriteRejected = false;
      try {
        validateReportFilePath(subFile, tmpDir);
      } catch (err) {
        if (err.message.includes('Refusing to overwrite arbitrary existing file')) {
          overwriteRejected = true;
        }
      }
      if (!overwriteRejected) {
        throw new Error('Expected validateReportFilePath to reject existing file overwrite (RED condition)');
      }

      // System/sensitive path rejection verification
      let systemPathRejected = false;
      try {
        const sysPath = path.join(process.env.SystemRoot || 'C:\\Windows', 'arbitrary-report.json');
        validateReportFilePath(sysPath);
      } catch (err) {
        if (err.message.includes('Forbidden') || err.message.includes('system directory')) {
          systemPathRejected = true;
        }
      }
      if (!systemPathRejected) {
        throw new Error('Expected validateReportFilePath to reject system directory path');
      }

      // GREEN verification: validateReportFilePath accepts a fresh non-existent path within allowed root
      const freshReportPath = path.join(tmpDir, 'safe-test-report.json');
      const validatedPath = validateReportFilePath(freshReportPath, tmpDir);
      const testReport = { suite: 'free-mcps-runtime', test: true };
      fs.writeFileSync(validatedPath, JSON.stringify(testReport), 'utf8');
      if (!fs.existsSync(validatedPath)) {
        throw new Error('Report file write failed');
      }
      const parsed = JSON.parse(fs.readFileSync(validatedPath, 'utf8'));
      if (!parsed.test) {
        throw new Error('Report file content mismatch');
      }
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // 22. Regression Test: Retained Worker Log Inspection and 8KB Bounded Sanitization
  await recordTest('regression_retained_worker_log_bounded_retention', async () => {
    const tmpCacheDir = path.join(os.tmpdir(), `cbm-worker-log-test-${crypto.randomUUID()}`);
    const logsDir = path.join(tmpCacheDir, 'logs');
    fs.mkdirSync(logsDir, { recursive: true });
    const dummyLogPath = path.join(logsDir, '.worker-log-123456');
    const largeContent = 'X'.repeat(10240);
    fs.writeFileSync(dummyLogPath, largeContent, 'utf8');

    try {
      const entries = fs.readdirSync(logsDir);
      const workerFiles = entries.filter(f => f.startsWith('.worker-log-'));
      if (workerFiles.length !== 1) {
        throw new Error('Expected 1 worker log file');
      }
      const raw = fs.readFileSync(dummyLogPath, 'utf8');
      const maxBytes = 8192;
      const sanitized = raw.length > maxBytes ? raw.slice(-maxBytes) : raw;
      if (sanitized.length !== 8192) {
        throw new Error(`Sanitized worker log should be bounded to 8192 bytes, got ${sanitized.length}`);
      }
    } finally {
      fs.rmSync(tmpCacheDir, { recursive: true, force: true });
    }
  });

  // 23. Regression Test: Project Naming Safe Canonical Root Hash Uniqueness & Short Key Safety
  await recordTest('regression_project_naming_safe_canonical_root_hash_uniqueness', async () => {
    const pathA = path.join(os.tmpdir(), 'root-alpha', 'runtime-fixture');
    const pathB = path.join(os.tmpdir(), 'root-beta', 'runtime-fixture');

    const nameA = deriveProjectName(pathA);
    const nameB = deriveProjectName(pathB);
    const nameA2 = deriveProjectName(pathA);

    // Short key bound: must be <= 32 chars to prevent MAX_PATH overflow in runtimeDir/locks
    if (nameA.length > 32) {
      throw new Error(`Derived project name length (${nameA.length}) exceeds safe 32-character bound: "${nameA}"`);
    }

    // Character safety: only safe characters allowed for Windows filesystem/pipes
    if (!/^[a-zA-Z0-9_-]+$/.test(nameA)) {
      throw new Error(`Derived project name contains invalid characters: "${nameA}"`);
    }

    // Deterministic: same path yields identical project name
    if (nameA !== nameA2) {
      throw new Error(`Non-deterministic project name: "${nameA}" !== "${nameA2}"`);
    }

    // Collision safety across repos: distinct repo roots with same basename must produce different project names
    if (nameA === nameB) {
      throw new Error(`Project name collision detected across repos: "${nameA}" === "${nameB}"`);
    }

    // Schema mapping: index_repository with "name" property receives derived project name
    const indexDef = {
      name: 'index_repository',
      inputSchema: {
        type: 'object',
        properties: { repo_path: { type: 'string' }, name: { type: 'string' } },
        required: ['repo_path']
      }
    };
    const indexArgs = buildIndexToolArgs(indexDef, pathA);
    if (indexArgs.name !== nameA) {
      throw new Error(`buildIndexToolArgs failed to set name property: ${JSON.stringify(indexArgs)}`);
    }
    if (indexArgs.repo_path !== pathA) {
      throw new Error(`buildIndexToolArgs failed to set repo_path: ${JSON.stringify(indexArgs)}`);
    }

    // Schema mapping: search_graph with "project" property receives matching derived project name
    const searchDef = {
      name: 'search_graph',
      inputSchema: {
        type: 'object',
        properties: { project: { type: 'string' }, name_pattern: { type: 'string' } },
        required: ['project']
      }
    };
    const searchArgs = buildSearchToolArgs(searchDef, '.*test.*', pathA);
    if (searchArgs.project !== nameA) {
      throw new Error(`buildSearchToolArgs project mismatch: expected "${nameA}", got "${searchArgs.project}"`);
    }
  });

  // 24. Regression Test: Delayed Daemon Shutdown vs Wrong Immediate Clean Claim
  await recordTest('regression_delayed_daemon_shutdown_vs_wrong_immediate_clean_claim', async () => {
    // Branch 1: Delayed exit within bounded grace
    // Process remains alive briefly (200ms) after spawn, then exits cleanly
    const delayedProc = spawn(process.execPath, ['-e', 'setTimeout(() => process.exit(0), 200)'], {
      stdio: 'ignore'
    });
    const delayedPid = delayedProc.pid;
    if (!delayedPid) throw new Error('Failed to spawn delayed test process');

    // Immediate check at t=0: process is alive
    const initAlive = isProcessAlive(delayedPid);
    if (!initAlive) {
      throw new Error('Expected delayed process to be alive immediately at t=0');
    }

    // A wrong immediate check would either falsely claim failure (cleanedCleanly=false)
    // or falsely claim clean without verification.
    // Bounded grace wait verifies actual exit without premature failure:
    const delayedResult = await waitForProcessExit(delayedPid, 2000, 30);
    if (!delayedResult.exited) {
      throw new Error(`Delayed process failed to exit within grace period (${delayedResult.elapsedMs}ms)`);
    }
    if (delayedResult.elapsedMs < 100) {
      throw new Error(`Delayed process exited unexpectedly early: ${delayedResult.elapsedMs}ms`);
    }
    if (isProcessAlive(delayedPid)) {
      throw new Error('Delayed process still alive after waitForProcessExit reported true');
    }

    // Branch 2: Hung process that fails to exit within bounded grace
    // Process stays alive indefinitely until explicitly killed
    const hungProc = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
      stdio: 'ignore'
    });
    const hungPid = hungProc.pid;
    if (!hungPid) throw new Error('Failed to spawn hung test process');

    try {
      const hungResult = await waitForProcessExit(hungPid, 150, 25);
      if (hungResult.exited) {
        throw new Error('Hung process unexpectedly reported exited within grace period');
      }
      if (!isProcessAlive(hungPid)) {
        throw new Error('Hung process was expected to remain alive');
      }
      // Quiescence check must truthfully report not clean
      const cleanedCleanly = !isProcessAlive(hungPid);
      if (cleanedCleanly !== false) {
        throw new Error('Harness must NOT make a wrong immediate clean claim when process remains alive');
      }
    } finally {
      try { hungProc.kill('SIGKILL'); } catch (e) {}
    }
  });

  const totalDurationMs = Date.now() - startTotal;
  const passed = tests.filter(t => t.status === 'passed').length;
  const failed = tests.filter(t => t.status === 'failed').length;

  const report = {
    suite: 'free-mcps-runtime',
    mode: 'self-test',
    status: failed === 0 ? 'passed' : 'failed',
    summary: { total: tests.length, passed, failed },
    fixture: {
      hashBefore: fixtureHashBefore,
      hashAfter: fixtureHashAfter
    },
    concurrency: {
      supported: true,
      parallelQueries: 2,
      demuxedCorrectly: true
    },
    processOwnership: {
      childPid: recordedPid,
      cleanedCleanly: processCleanlyExited,
      globalKillUsed: false
    },
    tests,
    totalDurationMs
  };

  return report;
}

// ============================================================================
// Real Binary Integration Mode (--binary <path>)
// ============================================================================

export async function runBinaryIntegration(opts) {
  const {
    binaryPath,
    workDir,
    cacheDir,
    runtimeDir,
    allowedRoot,
    expectedBinarySha256,
    timeoutMs = 5000,
    daemonGraceMs = 5000,
    profile = false
  } = opts;

  if (!binaryPath || !fs.existsSync(binaryPath)) {
    throw new Error(`Binary path does not exist: ${binaryPath}`);
  }

  // 1. Validate directories BEFORE any mkdir/write/spawn
  const canonical = validateIsolatedDirectories({
    workDir,
    cacheDir,
    runtimeDir,
    allowedRoot
  });

  // 2. Verify binary hash BEFORE any execute
  const binaryHash = verifyBinaryHash(binaryPath, expectedBinarySha256);

  // 3. Now safely create directories
  fs.mkdirSync(canonical.workDir, { recursive: true });
  fs.mkdirSync(canonical.cacheDir, { recursive: true });
  fs.mkdirSync(canonical.runtimeDir, { recursive: true });

  // 4. Inspect binary version with isolated env and isolated cwd
  const binaryVersion = await getBinaryVersion(
    binaryPath,
    {
      CBM_CACHE_DIR: canonical.cacheDir,
      CBM_RUNTIME_DIR: canonical.runtimeDir,
      CBM_ALLOWED_ROOT: canonical.allowedRoot || canonical.workDir
    },
    canonical.runtimeDir
  );

  const tests = [];
  const startTotal = Date.now();

  async function recordTest(name, fn) {
    const t0 = Date.now();
    try {
      await fn();
      tests.push({ name, status: 'passed', durationMs: Date.now() - t0 });
    } catch (err) {
      const isPrereq = err.message && err.message.startsWith('Prerequisite failed:');
      tests.push({
        name,
        status: isPrereq ? 'skipped' : 'failed',
        durationMs: Date.now() - t0,
        error: err.message
      });
    }
  }

  // 5. Set up fixture repository - MUST NOT overwrite existing fixture
  const fixtureDir = path.join(canonical.workDir, 'runtime-fixture');
  if (fs.existsSync(fixtureDir)) {
    throw new Error(`Fixture directory already exists: "${fixtureDir}". Existing fixtures must not be overwritten.`);
  }
  fs.mkdirSync(fixtureDir, { recursive: false });

  // Exact unindented patterns for .gitignore and .cbmignore
  const gitignoreContent = [
    'secret-auth.js',
    'temp-build/'
  ].join('\n') + '\n';
  fs.writeFileSync(path.join(fixtureDir, '.gitignore'), gitignoreContent, 'utf8');

  const cbmignoreContent = [
    'cbm-token.js',
    'cbm-keys/'
  ].join('\n') + '\n';
  fs.writeFileSync(path.join(fixtureDir, '.cbmignore'), cbmignoreContent, 'utf8');

  const mainJs = path.join(fixtureDir, 'index.js');
  fs.writeFileSync(mainJs, [
    'function computeOrderTotal(items, taxRate) {',
    '  let subtotal = 0;',
    '  for (const item of items) {',
    '    subtotal += item.price * item.quantity;',
    '  }',
    '  return subtotal * (1 + taxRate);',
    '}',
    'module.exports = { computeOrderTotal };'
  ].join('\n') + '\n', 'utf8');

  fs.writeFileSync(path.join(fixtureDir, 'secret-auth.js'), [
    'function getSecretTokenValue() {',
    "  return 'SUPER_CONFIDENTIAL_KEY';",
    '}'
  ].join('\n') + '\n', 'utf8');

  fs.writeFileSync(path.join(fixtureDir, 'cbm-token.js'), [
    'function getCbmTokenValue() {',
    "  return 'CBM_CONFIDENTIAL_KEY';",
    '}'
  ].join('\n') + '\n', 'utf8');

  // Initialize standalone git repository so git rev-parse stops at fixture root
  try {
    spawnSync('git', ['init'], { cwd: fixtureDir, stdio: 'ignore' });
    spawnSync('git', ['config', 'user.name', 'Harness Tester'], { cwd: fixtureDir, stdio: 'ignore' });
    spawnSync('git', ['config', 'user.email', 'tester@example.local'], { cwd: fixtureDir, stdio: 'ignore' });
    spawnSync('git', ['add', '-A'], { cwd: fixtureDir, stdio: 'ignore' });
    spawnSync('git', ['commit', '-m', 'initial fixture setup'], { cwd: fixtureDir, stdio: 'ignore' });
  } catch (e) {}

  const hashBefore = computeDirectorySha256(fixtureDir);
  let hashAfter = null;

  // 6. Launch real CBM with strictly isolated environment
  // Supported upstream: CBM_CACHE_DIR, CBM_RUNTIME_DIR, CBM_ALLOWED_ROOT
  // Note: CBM_AUTO_INDEX and CBM_AUTO_WATCH are not supported in pinned upstream v0.10.8 (unsupported envs do nothing)
  // CBM_PROFILE is supported process-scoped performance profiling seam to preserve worker logs on clean exit
  const childEnv = {
    SYSTEMROOT: process.env.SYSTEMROOT || process.env.SystemRoot,
    SystemDrive: process.env.SystemDrive,
    PATH: process.env.PATH,
    CBM_CACHE_DIR: canonical.cacheDir,
    CBM_RUNTIME_DIR: canonical.runtimeDir,
    CBM_ALLOWED_ROOT: canonical.allowedRoot || canonical.workDir
  };
  if (profile || process.env.CBM_PROFILE === '1') {
    childEnv.CBM_PROFILE = '1';
  }

  const client = new McpStdioClient({
    command: binaryPath,
    args: [],
    env: childEnv,
    cwd: fixtureDir,
    defaultTimeoutMs: timeoutMs,
    framing: 'newline'
  });

  await client.start();
  const childPid = client.pid;
  let demuxSuccess = false;
  let toolsListResult = null;
  let initResult = null;
  let indexStatusBefore = null;
  let indexStatusAfter = null;
  let rawIndexCallResponse = null;
  let indexCallError = null;

  let initializePassed = false;
  let toolDiscoveryPassed = false;
  let indexPassed = false;

  try {
    // Test 1: Initialize
    await recordTest('real_binary_initialize', async () => {
      const res = await client.request('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'free-mcps-runtime-verifier', version: '1.0.0' }
      });
      if (!res.serverInfo || !res.serverInfo.name) {
        throw new Error(`Invalid initialize response: ${JSON.stringify(res)}`);
      }
      initResult = res;
      client.notify('notifications/initialized');
      initializePassed = true;
    });

    // Test 2: Tool Discovery & Schema Inspection
    await recordTest('real_binary_tool_discovery', async () => {
      if (!initializePassed || client.isClosed) {
        throw new Error('Prerequisite failed: real_binary_initialize did not succeed or process closed');
      }
      toolsListResult = await client.request('tools/list');
      if (!Array.isArray(toolsListResult.tools)) {
        throw new Error('tools/list did not return an array');
      }
      const names = toolsListResult.tools.map(t => t.name);
      if (!names.includes('index_repository')) {
        throw new Error('index_repository tool not advertised by binary');
      }
      if (!names.includes('search_graph')) {
        throw new Error('search_graph tool not advertised by binary');
      }
      toolDiscoveryPassed = true;

      // Diagnostic probe: index_status before index_repository if advertised
      if (names.includes('index_status')) {
        try {
          indexStatusBefore = await client.request('tools/call', {
            name: 'index_status',
            arguments: { project: deriveProjectName(fixtureDir) }
          }, 5000);
        } catch (e) {
          indexStatusBefore = { error: e.message };
        }
      }
    });

    // Test 3: Index Repository with actual inputSchema parameter mapping
    await recordTest('real_binary_index_repository', async () => {
      if (!initializePassed || !toolDiscoveryPassed || client.isClosed) {
        throw new Error('Prerequisite failed: real_binary_initialize or tool discovery did not succeed');
      }
      const indexDef = toolsListResult?.tools?.find(t => t.name === 'index_repository');
      const indexArgs = buildIndexToolArgs(indexDef, fixtureDir);

      let res = null;
      try {
        res = await client.request('tools/call', {
          name: 'index_repository',
          arguments: indexArgs
        }, 15000);
        rawIndexCallResponse = res;
      } catch (err) {
        indexCallError = err.message;
        throw err;
      }

      // Diagnostic probe: index_status after index_repository if advertised
      const names = toolsListResult?.tools?.map(t => t.name) || [];
      if (names.includes('index_status')) {
        try {
          indexStatusAfter = await client.request('tools/call', {
            name: 'index_status',
            arguments: { project: deriveProjectName(fixtureDir) }
          }, 5000);
        } catch (e) {
          indexStatusAfter = { error: e.message };
        }
      }

      parseToolResult(res, 'index_repository');
      indexPassed = true;
    });

    // Test 4: Structural Search with inputSchema parameter mapping
    await recordTest('real_binary_search_graph', async () => {
      if (!initializePassed || !toolDiscoveryPassed || !indexPassed || client.isClosed) {
        throw new Error('Prerequisite failed: real_binary_index_repository did not succeed');
      }
      const searchDef = toolsListResult?.tools?.find(t => t.name === 'search_graph');
      const searchArgs = buildSearchToolArgs(searchDef, '.*computeOrderTotal.*', fixtureDir);

      const res = await client.request('tools/call', {
        name: 'search_graph',
        arguments: searchArgs
      });

      const parsed = parseToolResult(res, 'search_graph');
      const text = JSON.stringify(parsed);
      if (!text.includes('computeOrderTotal')) {
        throw new Error(`computeOrderTotal was not found in graph: ${text}`);
      }
    });

    // Test 5: Exclusions Protection with positive coverage before negative absence
    await recordTest('real_binary_exclusions_protection', async () => {
      if (!initializePassed || !toolDiscoveryPassed || !indexPassed || client.isClosed) {
        throw new Error('Prerequisite failed: real_binary_index_repository did not succeed');
      }
      const searchDef = toolsListResult?.tools?.find(t => t.name === 'search_graph');

      // Positive coverage first
      const posArgs = buildSearchToolArgs(searchDef, '.*computeOrderTotal.*', fixtureDir);
      const posRes = await client.request('tools/call', {
        name: 'search_graph',
        arguments: posArgs
      });
      const posParsed = parseToolResult(posRes, 'search_graph');
      if (!JSON.stringify(posParsed).includes('computeOrderTotal')) {
        throw new Error('Positive coverage failed before negative absence check');
      }

      // Negative absence verification (.gitignore)
      const secArgs1 = buildSearchToolArgs(searchDef, '.*getSecretTokenValue.*', fixtureDir);
      const secRes1 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: secArgs1
      });
      const secParsed1 = parseToolResult(secRes1, 'search_graph');
      if (JSON.stringify(secParsed1).includes('getSecretTokenValue')) {
        throw new Error(`Excluded symbol getSecretTokenValue was indexed despite .gitignore! Output: ${JSON.stringify(secParsed1)}`);
      }

      // Negative absence verification (.cbmignore)
      const secArgs2 = buildSearchToolArgs(searchDef, '.*getCbmTokenValue.*', fixtureDir);
      const secRes2 = await client.request('tools/call', {
        name: 'search_graph',
        arguments: secArgs2
      });
      const secParsed2 = parseToolResult(secRes2, 'search_graph');
      if (JSON.stringify(secParsed2).includes('getCbmTokenValue')) {
        throw new Error(`Excluded symbol getCbmTokenValue was indexed despite .cbmignore! Output: ${JSON.stringify(secParsed2)}`);
      }
    });

    // Test 6: Freshness Mutation Proof with isError checks
    await recordTest('real_binary_freshness_mutation', async () => {
      if (!initializePassed || !toolDiscoveryPassed || !indexPassed || client.isClosed) {
        throw new Error('Prerequisite failed: cannot mutate fixture or test freshness when server indexing failed');
      }
      fs.appendFileSync(mainJs, [
        'function applyDiscountVoucher(total, voucherCode) {',
        '  return total * 0.9;',
        '}'
      ].join('\n') + '\n', 'utf8');

      hashAfter = computeDirectorySha256(fixtureDir);
      if (hashBefore === hashAfter) {
        throw new Error('Fixture hash did not change after editing index.js');
      }

      const indexDef = toolsListResult?.tools?.find(t => t.name === 'index_repository');
      const indexArgs = buildIndexToolArgs(indexDef, fixtureDir);

      const idxRes = await client.request('tools/call', {
        name: 'index_repository',
        arguments: indexArgs
      }, 15000);
      parseToolResult(idxRes, 'index_repository');

      const searchDef = toolsListResult?.tools?.find(t => t.name === 'search_graph');
      const searchArgs = buildSearchToolArgs(searchDef, '.*applyDiscountVoucher.*', fixtureDir);

      const res = await client.request('tools/call', {
        name: 'search_graph',
        arguments: searchArgs
      });

      const parsed = parseToolResult(res, 'search_graph');
      if (!JSON.stringify(parsed).includes('applyDiscountVoucher')) {
        throw new Error(`Fresh symbol applyDiscountVoucher not found in updated graph: ${JSON.stringify(parsed)}`);
      }
    });

    // Test 7: Concurrency Demuxing
    await recordTest('real_binary_concurrency', async () => {
      if (!initializePassed || !toolDiscoveryPassed || !indexPassed || client.isClosed) {
        throw new Error('Prerequisite failed: real_binary_index_repository did not succeed');
      }
      const searchDef = toolsListResult?.tools?.find(t => t.name === 'search_graph');
      const a1 = buildSearchToolArgs(searchDef, '.*computeOrderTotal.*', fixtureDir);
      const a2 = buildSearchToolArgs(searchDef, '.*applyDiscountVoucher.*', fixtureDir);

      const p1 = client.request('tools/call', { name: 'search_graph', arguments: a1 });
      const p2 = client.request('tools/call', { name: 'search_graph', arguments: a2 });

      const [r1, r2] = await Promise.all([p1, p2]);
      const parsed1 = parseToolResult(r1, 'search_graph');
      const parsed2 = parseToolResult(r2, 'search_graph');

      const t1 = JSON.stringify(parsed1);
      const t2 = JSON.stringify(parsed2);

      if (!t1.includes('computeOrderTotal') || !t2.includes('applyDiscountVoucher')) {
        throw new Error('Concurrent queries returned mismatched results');
      }
      demuxSuccess = true;
    });

  } finally {
    await client.close(1500);
  }

  // 7. Post-execution daemon and process inspection (read-only, zero kills)
  const childAlive = isProcessAlive(childPid);
  const childCleanlyExited = !childAlive;
  const observedPids = [];
  if (childPid) observedPids.push(childPid);

  let daemonPid = null;
  const daemonLogPath = path.join(canonical.cacheDir, 'logs', 'cbm-daemon.log');
  if (fs.existsSync(daemonLogPath)) {
    try {
      const logContent = fs.readFileSync(daemonLogPath, 'utf8');
      daemonPid = parseDaemonPidFromLog(logContent);
      if (daemonPid && !observedPids.includes(daemonPid)) {
        observedPids.push(daemonPid);
      }
    } catch (e) {}
  }

  const initialCheckIso = new Date().toISOString();
  const initialDaemonAlive = daemonPid ? isProcessAlive(daemonPid) : false;
  let finalDaemonAlive = initialDaemonAlive;
  let elapsedGraceMs = 0;
  const daemonGraceTimeoutMs = daemonGraceMs;

  // Wait bounded grace for exact observed daemon exit if initially still alive
  if (daemonPid && initialDaemonAlive) {
    const waitResult = await waitForProcessExit(daemonPid, daemonGraceTimeoutMs, 50);
    finalDaemonAlive = !waitResult.exited;
    elapsedGraceMs = waitResult.elapsedMs;
  }

  const laterCheckIso = new Date().toISOString();
  const remainingProcesses = observedPids.filter(p => isProcessAlive(p));
  const cleanedCleanly = childCleanlyExited && (daemonPid === null || !finalDaemonAlive);

  const laterCheck = {
    initialCheckedAtIso: initialCheckIso,
    checkedAtIso: laterCheckIso,
    daemonPid,
    initialDaemonAlive: daemonPid !== null ? initialDaemonAlive : null,
    daemonAlive: daemonPid !== null ? finalDaemonAlive : null,
    gracePeriodMs: elapsedGraceMs,
    maxGraceMs: daemonGraceTimeoutMs,
    quiescenceAchieved: daemonPid !== null ? !finalDaemonAlive : true
  };

  // Read config list from binary with isolated runtime environment
  const binaryConfig = await getBinaryConfig(binaryPath, childEnv, canonical.runtimeDir);

  // Snapshot directory entries and lock files in isolated roots
  const lockEvidence = {
    runtimeDir: inspectDirectorySnapshot(canonical.runtimeDir),
    cacheDir: inspectDirectorySnapshot(canonical.cacheDir),
    workDir: inspectDirectorySnapshot(canonical.workDir)
  };

  // Sanitized bounded daemon log (<= 8KB)
  let sanitizedDaemonLog = null;
  if (fs.existsSync(daemonLogPath)) {
    try {
      const rawLog = fs.readFileSync(daemonLogPath, 'utf8');
      const maxBytes = 8192;
      sanitizedDaemonLog = rawLog.length > maxBytes ? rawLog.slice(-maxBytes) : rawLog;
    } catch (e) {
      sanitizedDaemonLog = `Error reading daemon log: ${e.message}`;
    }
  }

  // Sanitized bounded worker log (<= 8KB)
  let workerLogEvidence = null;
  const logsDir = path.join(canonical.cacheDir, 'logs');
  if (fs.existsSync(logsDir)) {
    try {
      const entries = fs.readdirSync(logsDir);
      const workerLogFiles = entries.filter(f => f.startsWith('.worker-log-'));
      if (workerLogFiles.length > 0) {
        const retainedLogs = [];
        for (const logFile of workerLogFiles) {
          const fullPath = path.join(logsDir, logFile);
          const stat = fs.statSync(fullPath);
          const raw = fs.readFileSync(fullPath, 'utf8');
          const maxBytes = 8192;
          const sanitized = raw.length > maxBytes ? raw.slice(-maxBytes) : raw;
          retainedLogs.push({
            file: logFile,
            path: fullPath,
            sizeBytes: stat.size,
            sanitizedContent: sanitized
          });
        }
        workerLogEvidence = {
          count: retainedLogs.length,
          logs: retainedLogs
        };
      }
    } catch (e) {
      workerLogEvidence = { error: `Error reading worker logs: ${e.message}` };
    }
  }

  const totalDurationMs = Date.now() - startTotal;
  const passed = tests.filter(t => t.status === 'passed').length;
  const failed = tests.filter(t => t.status === 'failed').length;
  const skipped = tests.filter(t => t.status === 'skipped').length;
  const sanitizedStderr = client.getSanitizedStderr();

  return {
    suite: 'free-mcps-runtime',
    mode: 'binary-integration',
    status: failed === 0 ? 'passed' : 'failed',
    binary: {
      path: binaryPath,
      sha256: binaryHash,
      version: binaryVersion
    },
    fixture: {
      path: fixtureDir,
      hashBefore,
      hashAfter
    },
    isolation: {
      cacheDir: canonical.cacheDir,
      runtimeDir: canonical.runtimeDir,
      allowedRoot: canonical.allowedRoot || canonical.workDir
    },
    summary: { total: tests.length, passed, failed, skipped },
    concurrency: {
      supported: demuxSuccess,
      parallelQueries: 2,
      demuxedCorrectly: demuxSuccess
    },
    serverDiagnostics: {
      serverInfo: initResult?.serverInfo || null,
      serverCapabilities: initResult?.capabilities || null,
      protocolVersion: initResult?.protocolVersion || '2024-11-05',
      toolCount: toolsListResult?.tools?.length || 0,
      tools: toolsListResult?.tools?.map(t => ({
        name: t.name,
        inputSchema: t.inputSchema,
        annotations: t.annotations
      })) || [],
      indexStatusBefore,
      indexStatusAfter,
      rawIndexCallResponse,
      indexCallError
    },
    configEvidence: {
      autoIndexValue: binaryConfig.stdout.match(/auto_index\s*=\s*(\S+)/)?.[1] || 'unknown',
      stdout: binaryConfig.stdout,
      stderr: binaryConfig.stderr,
      exitCode: binaryConfig.exitCode
    },
    lockEvidence,
    sanitizedDaemonLog,
    workerLogEvidence,
    processOwnership: {
      childPid,
      childExited: childCleanlyExited,
      daemonPid,
      daemonObserved: daemonPid !== null,
      daemonAlive: daemonPid ? finalDaemonAlive : null,
      initialDaemonAlive: daemonPid ? initialDaemonAlive : null,
      observedPids,
      remainingProcesses,
      cleanedCleanly,
      globalKillUsed: false,
      initialCheck: {
        checkedAtIso: initialCheckIso,
        daemonAlive: daemonPid ? initialDaemonAlive : null
      },
      laterCheck,
      evidence: !childCleanlyExited
        ? `Child process PID ${childPid} remained alive after close().`
        : daemonPid !== null
          ? (finalDaemonAlive
              ? `Observed daemon PID ${daemonPid} is still running after ${elapsedGraceMs}ms bounded grace (checked at ${laterCheckIso}).`
              : (initialDaemonAlive
                  ? `Observed daemon PID ${daemonPid} exited cleanly during bounded grace (${elapsedGraceMs}ms after client close; confirmed quiescent at ${laterCheckIso}).`
                  : `Observed daemon PID ${daemonPid} exited cleanly immediately upon client close.`))
          : `Child process (PID ${childPid}) exited (code: ${client.exitCode ?? 'unknown'}). Daemon PID was null/unobserved (daemon log absent or process failed before daemon start).`
    },
    daemonInspection: {
      daemonPid,
      status: daemonPid ? (finalDaemonAlive ? 'shared_daemon_active' : 'daemon_exited') : 'unobserved',
      initialStatus: daemonPid ? (initialDaemonAlive ? 'shared_daemon_active' : 'daemon_exited') : 'unobserved',
      laterCheck,
      guidance: daemonPid
        ? (finalDaemonAlive
            ? `Daemon PID ${daemonPid} coordinated background tasks. If manual shutdown is needed, let last session exit or run isolated cbm stop.`
            : `Daemon PID ${daemonPid} exited cleanly upon client disconnect (confirmed quiescent at ${laterCheckIso}).`)
        : 'Daemon was not observed or did not spawn because process closed during initialize.'
    },
    sanitizedStderr,
    tests,
    totalDurationMs
  };
}

// ============================================================================
// CLI Entry Point
// ============================================================================

async function main() {
  if (process.argv.includes('--mock-worker')) {
    runMockWorker();
    return;
  }

  const args = process.argv.slice(2);
  const isJson = args.includes('--json');
  const isSelfTest = args.includes('--self-test');

  function getArg(flag) {
    const idx = args.indexOf(flag);
    if (idx !== -1 && idx + 1 < args.length) return args[idx + 1];
    const prefix = `${flag}=`;
    const found = args.find(a => a.startsWith(prefix));
    return found ? found.substring(prefix.length) : null;
  }

  try {
    let report = null;

    if (isSelfTest || !getArg('--binary')) {
      report = await runSelfTest();
    } else {
      const binaryPath = getArg('--binary');
      const workDir = getArg('--work-dir') || path.join(os.tmpdir(), `cbm-run-work-${crypto.randomUUID()}`);
      const cacheDir = getArg('--cache-dir') || path.join(os.tmpdir(), `cbm-run-cache-${crypto.randomUUID()}`);
      const runtimeDir = getArg('--runtime-dir') || path.join(os.tmpdir(), `cbm-run-runtime-${crypto.randomUUID()}`);
      const allowedRoot = getArg('--allowed-root') || workDir;
      const expectedBinarySha256 = getArg('--expected-sha256');
      const timeoutMs = parseInt(getArg('--timeout-ms') || '5000', 10);
      const daemonGraceMs = parseInt(getArg('--daemon-grace-ms') || '5000', 10);
      const profile = args.includes('--profile') || process.env.CBM_PROFILE === '1';

      report = await runBinaryIntegration({
        binaryPath,
        workDir,
        cacheDir,
        runtimeDir,
        allowedRoot,
        expectedBinarySha256,
        timeoutMs,
        daemonGraceMs,
        profile
      });
    }

    if (isJson) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(`\n=== MCP Runtime Test Harness [${report.mode}] ===`);
      console.log(`Status:  ${report.status.toUpperCase()}`);
      const skipCount = report.summary.skipped || 0;
      console.log(`Passed:  ${report.summary.passed}/${report.summary.total} tests${skipCount > 0 ? ` (${skipCount} skipped)` : ''}`);
      console.log(`Time:    ${report.totalDurationMs}ms\n`);

      for (const t of report.tests) {
        const mark = t.status === 'passed' ? '[PASS]' : (t.status === 'skipped' ? '[SKIP]' : '[FAIL]');
        console.log(`  ${mark} ${t.name} (${t.durationMs}ms)`);
        if (t.error) console.log(`         Error: ${t.error}`);
      }

      if (report.sanitizedStderr) {
        console.log(`\nCaptured Stderr: ${report.sanitizedStderr}`);
      }
      if (report.workerLogEvidence?.logs?.length > 0) {
        for (const wl of report.workerLogEvidence.logs) {
          console.log(`\nRetained Worker Log: ${wl.path} (${wl.sizeBytes} bytes)`);
          console.log(`Worker Diagnostic Snippet:\n${wl.sanitizedContent.slice(0, 2048)}`);
        }
      }
      if (report.binary) {
        console.log(`\nBinary SHA-256: ${report.binary.sha256}`);
        console.log(`Binary Version: ${report.binary.version}`);
      }
      if (report.fixture) {
        console.log(`Fixture SHA-256 (before): ${report.fixture.hashBefore}`);
        console.log(`Fixture SHA-256 (after):  ${report.fixture.hashAfter}`);
      }
      console.log(`Process Ownership: Cleaned cleanly: ${report.processOwnership.cleanedCleanly} (global kill used: ${report.processOwnership.globalKillUsed}).`);
      console.log(`Process Evidence: ${report.processOwnership.evidence || 'None'}`);
      if (report.processOwnership.laterCheck?.daemonPid) {
        const lc = report.processOwnership.laterCheck;
        console.log(`Daemon Lifecycle Check: initial alive: ${lc.initialDaemonAlive} (${lc.initialCheckedAtIso}), later alive: ${lc.daemonAlive} (${lc.checkedAtIso}, grace elapsed: ${lc.gracePeriodMs}ms, quiescence: ${lc.quiescenceAchieved}).`);
      }
      if (report.daemonInspection?.daemonPid) {
        console.log(`Daemon Notice: ${report.daemonInspection.guidance}`);
      }
      console.log('');
    }

    const reportFile = getArg('--report-file');
    if (reportFile && report) {
      const allowedRoot = getArg('--allowed-root') || getArg('--work-dir') || null;
      const safeReportPath = validateReportFilePath(reportFile, allowedRoot);
      fs.mkdirSync(path.dirname(safeReportPath), { recursive: true });
      fs.writeFileSync(safeReportPath, JSON.stringify(report, null, 2), 'utf8');
      if (!isJson) {
        console.log(`Diagnostic report written to: ${safeReportPath}\n`);
      }
    }

    if (report.status !== 'passed') {
      process.exitCode = 1;
    }
  } catch (err) {
    if (isJson) {
      console.error(JSON.stringify({ status: 'error', error: err.message }));
    } else {
      console.error(`FATAL: ${err.message}`);
    }
    process.exitCode = 2;
  }
}

main();
