# Contribuindo

O Codex Workflows Kit é Windows-first e versionado em uma worktree. Qualquer
mudança de contrato deve manter código, documentação e validação alinhados.

## Setup

1. Clone o repositório.
2. Use PowerShell 5.1+ ou PowerShell 7+.
3. Antes e depois das alterações, execute:

~~~powershell
.\scripts\validate.ps1
~~~

## Onde contribuir

| Área | Conteúdo |
|---|---|
| skills/workflows/ | SKILL.md (política única) e referências especializadas |
| skills/evidence-first/ | grounding de claims materiais |
| codex/AGENTS.md | regras globais universais |
| scripts/ | instalador, validador, doctor e uninstall |
| docs/, README.md | documentação pública |

## Regras

- Preserve mudanças existentes e trabalhe no menor escopo seguro.
- A interface de workflow é $workflows; não crie um segundo prefixo.
- skills/workflows/SKILL.md é a única política detalhada; não duplique o
  contrato em AGENTS.md, na documentação ou em novas referências.
- O executor principal é o DeepSeek Sub-Agent MCP; o parent GPT delega,
  integra, valida e decide.
- Toda mudança autorizada precisa de preflight, validação proporcional e
  inspeção do diff integrado.
- Logs novos exigem um obs-gate explícito.
- Nunca commite segredos, chaves, dados pessoais, caches ou artefatos locais.

## Commits e pull requests

Siga skills/workflows/references/commit.md. Descreva o problema, os caminhos
afetados, a validação executada e os riscos residuais. Não faça reset, amend,
rebase, force-push ou publicação sem pedido explícito.
