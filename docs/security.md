# Segurança operacional

## Princípios

- Execute somente o checkout local revisado.
- Preserve mudanças existentes e evite operações destrutivas.
- O padrão para logs novos é none; qualquer exceção exige obs-gate.
- O backend de sub-agentes é resolvido pelo sufixo `subagents=mcp|native`
  (padrão MCP; native opt-in explícito), conforme
  skills/workflows/references/backend-policy.md. Perfis nativos permanecem
  read-only: não têm autorização para editar, produzir patches, mexer em
  configuração, staging ou commits.
- O orquestrador valida o diff integrado antes de entregar.

## Instalação segura

Use primeiro o dry-run quando o destino for novo:

~~~powershell
.\scripts\install.ps1 -Profile safe -WhatIf
~~~

O instalador cria backup com timestamp antes de substituir conteúdo gerenciado.
Use -Force apenas depois de revisar um AGENTS.md existente. Caminhos raiz não
são aceitos como destino.

## Dados e credenciais

- Nunca inclua tokens, chaves, dados pessoais, prompts completos ou logs sem
  limite em commits ou relatórios.
- Não trate uma configuração ou um hash como prova de comportamento. Faça a
  verificação focada que o modo exigir.
- Registre incerteza e bloqueie quando uma evidência obrigatória não estiver
  disponível.

## Remoção

Confira primeiro:

~~~powershell
.\scripts\uninstall.ps1 -WhatIf
~~~

Sem -Force, arquivos gerenciados modificados são preservados para revisão.
