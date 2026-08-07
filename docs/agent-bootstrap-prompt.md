# Prompt de bootstrap

Copie o texto abaixo para iniciar uma tarefa com o contrato do kit:

~~~text
Use $workflows mode=PLAN.AUTO.

Leia codex/AGENTS.md antes de agir. Preserve mudanças existentes, defina o
objetivo, a validação e a condição de pronto. Para trabalho não trivial,
multi-frente, de contrato/core ou com revisão explícita, use sub-agentes
nativos read-only (scout, researcher ou reviewer), todos em Luna High. Cada
sub-agente deve receber uma frente independente, devolver evidência compacta e
nunca editar, produzir patch, alterar configuração, fazer staging ou commit.

O pai deve aguardar a resposta final de cada sidecar obrigatório; não o
interrompa enquanto estiver executando. Interrupção, erro, timeout ou ausência
de resposta deixa o sidecar-gate aberto, sem fallback silencioso.

O orquestrador integra as evidências e só altera arquivos quando o modo e a
autorização permitirem. Separe observação, inferência e desconhecido; valide o
diff integrado e não declare sucesso com um gate obrigatório aberto.
~~~
