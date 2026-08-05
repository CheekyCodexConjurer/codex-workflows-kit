# Contribuindo

Obrigado por contribuir com o Codex Workflows Kit. Este projeto e
Windows-first, versionado em uma worktree, e qualquer mudanca nos contratos
precisa manter o validador verde.

## Setup

1. Clone o repositorio.
2. Nao e necessario instalar dependencias; basta Windows com PowerShell 5.1+.
3. Rode a validacao antes e depois das suas mudancas:

```powershell
.\scripts\validate.ps1
```

## Onde contribuir

| Area | O que vive la |
|---|---|
| `skills/workflows/` | modos, referencias e contratos do roteador |
| `skills/evidence-first/` | verificacao de claims materiais |
| `agents/` e `agents/opencode/` | perfis nativos e definicoes OpenCode |
| `plugins/mcp-foundation/` | allowlist MCP, hook de auditoria e mantenedor |
| `scripts/` | instalador, validador, doctor e uninstall |
| `docs/`, `README.md` | documentacao publica |

## Regras

- **Windows-first**: scripts em PowerShell 5.1+; nao quebre
  `validate.ps1` — ele e a especificacao executavel dos contratos.
- **Interfaces**: ao mudar uma interface (instalador, modos, permissao de
  agentes, MCP), atualize `README.md`, `docs/` e `CHANGELOG.md` na mesma
  mudanca.
- **Edicoes de writer**: use claim-map, worktree isolada e baseline; nunca
  edite o checkout principal nem arquivos fora do escopo.
- **Observabilidade**: por padrao, nenhuma instrumentacao nova; logs exigem
  contrato explicito (ver `skills/workflows/references/observability.md`).
- **Sem segredos**: nunca commite tokens, chaves ou dados pessoais.
- **Escopo**: mudancas pequenas e reversiveis; evite refactors sem relacao com
  a mudanca.

## Commits

Siga o contrato em `skills/workflows/references/commit.md`:

```text
type(scope): resumo imperativo

Context: comportamento factual e motivo.
Validation: verificacoes executadas e resultado.
Operator: Codex
```

- Classifique todos os caminhos candidatos (staged, unstaged e untracked);
  bloqueie sem alterar o index qualquer coisa que pareca segredo, gerada,
  cache ou local.
- Nunca force-push; nao faça reset/amend/rebase para recuperar.

## Pull requests

1. Descreva o problema e a motivacao no PR.
2. Liste a validacao executada (`validate.ps1` e testes manuais relevantes).
3. Aponte os arquivos afetados e qualquer impacto em documentacao.
4. Mudancas na interface pública do instalador (perfis, flags, doctor,
   uninstall) precisam refletir o contrato documentado no `README.md`.

## Issues

- Use issues para bugs, duvidas e melhorias de documentacao.
- Vulnerabilidades nao devem ser reportadas em issues publicas — veja
  `SECURITY.md`.
