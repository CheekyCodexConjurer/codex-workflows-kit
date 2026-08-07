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
| skills/workflows/ | modos, referências e contrato do roteador |
| skills/evidence-first/ | grounding de claims materiais |
| agents/ | perfis nativos somente leitura |
| codex/AGENTS.md | regras globais compactas |
| scripts/ | instalador, validador, doctor e uninstall |
| docs/, README.md | documentação pública |

## Regras

- Preserve mudanças existentes e trabalhe no menor escopo seguro.
- A interface de workflow é $workflows; não crie um segundo prefixo.
- Os sub-agentes são nativos e read-only. Não lhes atribua escrita, patches,
  alterações de configuração, staging ou commits.
- Toda mudança autorizada precisa de preflight, validação proporcional e
  inspeção do diff integrado.
- Logs novos exigem um obs-gate explícito.
- Nunca commite segredos, chaves, dados pessoais, caches ou artefatos locais.

## Commits e pull requests

Siga skills/workflows/references/commit.md. Descreva o problema, os caminhos
afetados, a validação executada e os riscos residuais. Não faça reset, amend,
rebase, force-push ou publicação sem pedido explícito.
