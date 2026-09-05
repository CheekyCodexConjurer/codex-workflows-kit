# Segurança operacional

## Princípios

- Execute somente o checkout local revisado.
- Preserve mudanças existentes e evite operações destrutivas.
- O padrão para logs novos é none; qualquer exceção exige obs-gate.
- A governança de subagentes é regida por quatro seletores globais ortogonais:
  `subagent_backend` (`native` com `gpt-5.6-luna` ou `deepseek` técnico via SubAgents MCP),
  `delegation_policy` (`balanced` otimizando wall-clock time, `aggressive` otimizando desoneração de tokens, ou `swarm` com ondas do DAG, fan-out lógico elástico, dynamic wake e fail-closed batch preflight),
  `subagent_strategy` (`worker` padrão ou `critical` com análise independente e adaptativa por profundidade internamente, identificação de contradições/lacunas, síntese GPT, fencing e sem edição concorrente; sem troca automática de rota/provedor e sem concessão de escrita no ALINHAMENTO), e
  `subagent_continuation` (`active_follow` ou `park_and_wake` com Sub-agent Autonomy).
- A orquestração falha fechado: matriz ausente, inválida ou indisponibilidade de ferramentas bloqueia a execução sem fallback silencioso entre provedores.
- O parent GPT é o maestro que delega, integra, valida e decide.
- Modos de escrita exigem o módulo de entrega com alvo congelado (frozen target), validação determinística e revisão independente obrigatória com veredito APPROVED antes do commit local fechado.

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
