# Changelog

Todas as mudancas notaveis do Codex Workflows Kit sao registradas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versoes ainda nao publicadas ficam em `Unreleased`.

## [Unreleased]

### Added

- Pré-processamento visual nativo opcional no relay: anexos reais geram um
  `[VISUAL_PACKET v1]` textual para o MCP, sem encaminhar paths, bytes ou data
  URLs de imagens; falha de leitura permanece bloqueada.
- Documentacao publica: `README.md` reescrito para apresentar o kit,
  `docs/architecture.md`, `docs/security.md`,
  `docs/agent-bootstrap-prompt.md`, `LICENSE` (MIT), `CONTRIBUTING.md`,
  `SECURITY.md` e `CHANGELOG.md`.
- Interface pública do instalador: `-Profile safe|full|minimal`,
  `-ConfigureMcp`, `-InstallAhk`, `-InstallAntigravity`,
  `-InstallScheduledTask`, `-Force` e `-WhatIf`, com backup antes de
  sobrescrever.
- Comandos `scripts/doctor.ps1` (diagnostico somente leitura) e
  `scripts/uninstall.ps1` (remocao com `-WhatIf`).

### Changed

- `README.md` documenta agora o produto como kit publico Windows-first, com
  instalacao parametrizada e secoes de seguranca e limitacoes.
- A delegacao passa a ser quality-first em tarefas nao triviais: read-only
  scouts/researchers cobrem frentes independentes por padrao mesmo sem ganho de
  latencia; tarefas simples permanecem locais e writers continuam isolados por
  claim-map.
- O perfil `full` documenta seus destinos Antigravity; o perfil `safe` continua
  sem MCP, OpenCode, tarefa agendada ou AHK por padrão.
- O instalador preserva o identificador de marketplace existente
  `codex-workflows-local` para evitar duplicação em upgrades.

## [0.1.0] - 2026-08-05

### Added

- Skill canonica `workflows` (Codex, Antigravity e OpenCode) com aliases de
  compatibilidade e referencias: dictionary, mode-matrix, runtime-adapters,
  backend-policy, quality-ratchet, observability, commit, research,
  subagents e validation.
- Skill condicional `evidence-first` para claims materiais.
- Perfis nativos `relay`, `scout`, `researcher`, `reviewer` e `worker` com
  variantes de esforco (`low`, `high`, `xhigh`, `max`).
- DefinicOes OpenCode `scout.md`, `researcher.md`, `reviewer.md` (readers com
  `edit: deny`) e `worker.md` (writer com `edit: allow` e limites de
  claim-map/worktree).
- `codex/AGENTS.md` com regras globais compactas.
- Plugin `mcp-foundation`: allowlist (CodeGraph, Context7, OpenAI Developer
  Docs), marketplace local, hook de auditoria `SessionStart` com TTL de 24
  horas, mantenedor e tarefa semanal reaproveitada.
- Prompt pad AutoHotkey com atalhos NUM para modos `$workflows`.
- `scripts/install.ps1` (instalacao com backup) e `scripts/validate.ps1`
  (validacao de estrutura e contratos).
