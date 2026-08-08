# Prompt de bootstrap

Copie o texto abaixo para iniciar uma tarefa com o contrato do kit:

~~~text
Use $workflows mode=PLAN.AUTO.

Leia codex/AGENTS.md antes de agir. Para delegação, leia o contrato canônico
skills/workflows/references/backend-policy.md: o backend é resolvido pelo
sufixo subagents=mcp|native (padrão MCP; native opt-in explícito). Preserve
mudanças existentes, defina o objetivo, a validação e a condição de pronto.
Para trabalho não trivial, multi-frente, de contrato/core ou com revisão
explícita, use sub-agentes (scout, researcher ou reviewer) conforme o backend
resolvido. Cada sub-agente deve receber uma frente independente e devolver
evidência compacta; perfis nativos nunca editam, produzem patch, alteram
configuração, fazem staging ou commit.

Siga o ciclo de vida e as obrigações pendentes definidas em backend-policy.md;
não declare sucesso com um gate obrigatório aberto.

O orquestrador integra as evidências e só altera arquivos quando o modo e a
autorização permitirem. Separe observação, inferência e desconhecido; valide o
diff integrado.
~~~
