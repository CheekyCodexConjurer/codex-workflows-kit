# Plano de Implementação: Rearchitetura de Workflows — Seletores Ortogonais e Qualidade de Entrega

- **Data**: 2026-08-26
- **Status**: Em Execução (Fase 5 Concluída / Fase 6 em Validação)
- **Autoridade**: Codex Workflows Kit Architecture
- **Alvo**: `codex-workflows-prompt-pad` (Codex & Antigravity)

---

## 1. Visão Geral e Escopo

Este plano detalha a execução orientada a testes (TDD) para implementar os dois seletores globais ortogonais (`subagent_backend` e `delegation_policy`), o módulo de qualidade de entrega (*delivery review gate* com 5 pilares explícitos e pacote estruturado), a migração para o Schema 5 de instalação e os scripts transacionais de alternância de políticas.

---

## 2. Fases de Execução e Status

### Fase 1: Testes Comportamentais Focados (RED) — [Concluída]
- Cenários estruturados em `scripts/test-safe-profile-gate.ps1`:
  - Migração de schema 4 para schema 5 com default `delegation_policy = balanced`.
  - Quatro combinações válidas dos seletores (`native`/`deepseek` x `balanced`/`aggressive`).
  - Alternância de backend preservando política de delegação ativa.
  - Alternância de política de delegação preservando backend ativo e `config.toml`.
  - Bloco de runtime ativo presente apenas no `AGENTS.md` global instalado; template estático no repositório.
  - Idempotência de alternâncias e reinstalações.
  - Bloqueio de drift e integridade transacional com rollback automático.
  - Falha fechada (*fail-closed*) em seletores ausentes, inválidos ou inconsistentes.
  - Paridade entre PowerShell Core e Windows PowerShell 5.1.
  - Preservação e restauração correta na desinstalação.
- Falhas RED registradas e verificadas contra a implementação pendente.

### Fase 2: Módulo de Roteamento e Schema 5 (`backend-routing.psm1`) — [Concluída]
- Funções de estado de delegação (`Assert-CodexDelegationState`, `New-CodexDelegationState`).
- Parsing, geração e validação do bloco de runtime em `AGENTS.md` (`Get-CodexRuntimeBlockInfo`, `Set-CodexAgentsManagedBlockText`, `Assert-CodexAgentsRuntimeBlock`).
- Asserções de `install-state.json` atualizadas para suportar e validar Schema 5.

### Fase 3: Scripts de Alternância Transacional — [Concluída]
- `scripts/switch-subagent-policy.ps1` com `-Policy balanced|aggressive` e `-Status`.
- `scripts/switch-subagent-backend.ps1` com atualização do bloco de runtime no `AGENTS.md` instalado, suporte a `-Status` e rollback transacional.

### Fase 4: Instalador, Doctor, Desinstalador e Validador — [Concluída]
- `scripts/install.ps1` renderiza o bloco de runtime no `AGENTS.md` global e grava o estado Schema 5.
- `scripts/doctor.ps1` valida o estado Schema 5, o bloco de runtime em `AGENTS.md` e a consistência cruzada.
- `scripts/uninstall.ps1` suporta Schema 5 e remove o bloco gerenciado preservando conteúdos do usuário.
- `scripts/validate.ps1` verifica as invariantes do novo modelo e os novos contratos de revisão de entrega e delegação.

### Fase 5: Políticas, Referências e Documentação Canônica — [Concluída]
- Referências estruturadas:
  - `skills/workflows/references/delegation.md`: contratos detalhados de `balanced` e `aggressive`, persistência vs. recuperação pós-fechamento.
  - `skills/workflows/references/delivery-review.md`: congelamento de alvo com identidade determinística invariante a staging e ao code page do host (`target_id`: baseline, HEAD-relative status, diff integrado com stdout Git normalizado como UTF-8, hashes per-file; raw porcelain externo), revisor independente não-autor, revisão estruturada (5 pilares), pacote estruturado, re-revisão delta cobrindo blast radius e gate de commit com verificação de staged path set e staged blobs contra o conteúdo aprovado.
- `skills/workflows/SKILL.md`: roteamento conciso para referências, ciclo de vida policy-aware, matriz de modos e auditoria final com alvo congelado e revisão aprovada.
- `skills/workflows/references/validation.md` e `skills/workflows/references/commit.md`: integração explícita com o delivery review gate e preservação do modo `R.A.F.V` separado.
- Template `codex/AGENTS.md`: regras compactas atualizadas com seletores ortogonais, qualidade de entrega e fan-out condicional.
- `ahk/codex_prompt_pad.ahk` e `README.md`: Prompt Pad fino e stateless com modificador `Ctrl` para controle dos seletores, documentação de arquitetura orientada a seletores e premissa de checkout root.
- `docs/superpowers/specs/2026-08-26-workflow-rearchitecture-design.md`: especificação técnica alinhada com as decisões arquiteturais.

### Fase 6: Execução de Testes e Validação do Checkout — [Em Execução]
- Executar `scripts/validate.ps1 -SkipInstalled -SkipGateTests` (GREEN).
- Executar `git diff --check` para garantir conformidade de formatação e sem resíduos.
- Preservar escopo de checkout: sem install global, sem revisão final independente, sem stage, sem commit e sem push.
