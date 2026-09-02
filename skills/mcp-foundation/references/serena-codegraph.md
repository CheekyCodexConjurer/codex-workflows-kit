# Serena & CodeGraph Operational Policy

Centralized management, lifecycle, and usage constraints for Serena and CodeGraph MCP servers across all workflow modes.

## Maintenance Preflight by Mode

All workflow modes perform an MCP maintenance preflight before operational actions. Maintenance authority strictly aligns with mode capabilities and write permissions:

1. **Universal Preflight**: Every workflow mode executes a maintenance preflight to verify server readiness and index freshness.
2. **No-MCP-Write / Read-Only Modes** (`PLAN`, `PLAN.AUTO`, `P.DEEP`, `RESEARCH.DEEP`, `REVIEW`, `COMMIT`, `BUG.INV`, `REWORK`, `TN.SKILL`, and implicit `ALINHAMENTO`):
   - Status-only verification (`apenas verificam`).
   - Strictly no index modification, no synchronization, no background writes, and no stateful mutations.
   - `COMMIT` may operate on the Git index under its separate git-only contract, but never mutates an MCP index.
   - If an index is absent or stale, use available read tools or fall back to targeted `rg` without triggering updates.
3. **Implementation / Write Delivery Modes** (`IMPL`, `IMPL.AUTO`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`, `DEBUG`, `R.A.F.V`):
   - May synchronize CodeGraph (`codegraph sync`) when status explicitly indicates delay, stale state, or pending updates (`quando o status indicar atraso`).
   - Follow the strict **status -> sync -> recheck** lifecycle:
     1. Probe status using `codegraph status --json`.
     2. If stale or pending updates are reported, execute incremental synchronization (`codegraph sync`).
     3. After synchronization, verify status again (`verificar novamente / recheck`).
     4. If synchronization fails, errors, or returns unknown status (`falha/unknown`), terminate the attempt immediately, log a warning, and fall back to Serena symbol exploration and `rg` (`Serena/rg com aviso`).
4. **Prohibitions Across All Modes**:
   - **No Auto-Init / No Auto-Reindex**: Never initialize or reindex automatically when `.codegraph` is missing (`sem auto-init / não reindexar automaticamente`). Full indexing (`codegraph index`) and project initialization (`codegraph init`) require explicit human operator requests.
   - **No Auto-Upgrade**: Never perform automatic package, binary, or tool upgrades (`sem auto-upgrade / não fazer upgrade de pacote`).
   - **No Auto-Restart**: Never restart MCP servers automatically (`sem auto-restart / não reiniciar MCPs`), except for the strictly authorized DeepSeek daemon exception defined in `references/lifecycle.md`.

## CodeGraph Operation Contract

- **Status Inspection**: Always check index state using `status --json`.
- **Incremental Synchronization**: Execute `codegraph sync` exclusively when an index already exists and reports stale or pending status. Never run background sync on healthy up-to-date indexes.
- **Full Indexing and Initialization**: `codegraph index` and `codegraph init` are exclusively operator-invoked commands; never execute them autonomously.
- **Structural Exploration**: Direct structural queries must invoke `codegraph_explore` directly.
- **Project Boundary & Index Existence**:
  - CodeGraph is active ONLY if `.codegraph` exists in the repository root OR an explicit `projectPath` parameter pointing to an existing index is provided.
- If `.codegraph` is absent and no explicit `projectPath` exists, skip CodeGraph immediately and fall back cleanly to Serena and targeted `rg`.

## Deterministic Maintenance Decision

The decision helper `Get-CodexCodeGraphMaintenanceDecision` keeps the lifecycle
machine-checkable: a fresh/ready index returns `none`; stale/pending returns
`sync` only in a write mode; every read-only mode returns `inspect`; and a
failure or unknown state returns `fallback` to Serena/`rg` with an explicit
warning. A successful sync must still run the required recheck before work
continues.

## Serena Operation Contract

- **Project Scoping**: Serena must be invoked with the project directory of the current working directory (`--project-from-cwd`).
- **Instance Isolation**: Run one instance per project/client by default (`uma instância por projeto/cliente por padrão`). Do not share a global singleton across all repositories (`sem singleton global para todos os repositórios`).
- **Configuration Verification**: Confirm configuration and project state read-only (`confirmação read-only de configuração/projeto`) before invocation.
- **Process Safety**: Strictly NO automatic `taskkill`, `Stop-Process`, or wildcard process sweeps (`sem taskkill/restart automático`). Terminating Serena requires an explicit human request and verified process ownership/idleness (see `references/lifecycle.md`).
- **Mode Restrictions**:
  - In read-only modes and `ALINHAMENTO`: strictly enforce `no-onboarding` (never invoke `onboarding`) and `no-memories` (never invoke `write_memory`, `delete_memory`, `rename_memory`, or `edit_memory`). Reading memories (`read_memory`, `list_memories`) is permitted.
  - Symbol and content editing (`replace_content`, `replace_in_files`, `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, `rename_symbol`, `safe_delete_symbol`): permitted ONLY in explicit write delivery modes (`edição somente em modos explícitos de escrita`).

## COMMIT & Ignore Interaction

- **Git-Only Scope**: The `COMMIT` workflow mode remains strictly git-only. It never modifies `.gitignore` and never updates MCP indexes (`nunca altera .gitignore nem atualiza índices MCP`).
- **Candidate Classification**: `Get-CodexCommitCandidates` inspects all candidates across staged, unstaged, and untracked sets. If candidate files match local overrides, generated artifacts, runtime caches, or secrets, block the commit gate without modifying the Git index (`bloquear sem mudar o index`), reporting the path, category, and suggested ignore rule.
- **Hybrid Ignore Policy for Serena**:
  - Shared project configurations (`.serena/project.yml`, `.serena/.gitignore`) are opt-in for version control.
  - Local overrides (`.serena/project.local.*`), runtime caches (`.serena/cache/`), memory stores (`.serena/memories/`), and runtime logs (`.serena/logs/`) must be ignored.
  - `.codegraph/` remains local and ignored in repository `.gitignore`.
