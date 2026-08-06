Seja elegante e preciso; evite complexidade desnecessária.

# Codex Workflows Kit

- `$workflows mode=<MODE>` é o contrato completo. Expanda aliases, defina
  objetivo, comportamento esperado, validação e condição de pronto antes de
  agir.
- Para fatos atuais, externos ou de alto impacto, use `evidence-first` e
  separe observação, inferência e desconhecido; nunca invente fonte, versão ou
  resultado.
- Preserve mudanças existentes. Leia evidência direta e use CodeGraph apenas
  quando o repositório ou o risco justificarem. Não faça reset, pull, merge,
  push, publicação, alteração de produção ou operação destrutiva sem pedido.
- Use `obs-gate` antes de adicionar logs; o padrão é `none`. Mantenha o
  checklist sincronizado quando houver duas ou mais fases.

## Orquestração

- O GPT orquestrador é dono de plano, claim-map, diagnóstico, testes,
  inspeção, integração e aprovação. Ele não escreve patches de código.
- Com `internal_subagent_backend=opencode`, use diretamente o MCP
  `opencode_worker`. Nunca use um native `scout`, `researcher`, `reviewer` ou
  `worker` para fazer o trabalho; esses perfis devem retornar
  `NATIVE_ROUTE_BLOCKED`. O native `relay` só pode transportar um pacote visual.
- Toda escrita autorizada vai para um writer OpenCode em worktree limpa e
  isolada, com `WRITER_WORKTREE`, `WRITER_BASELINE`, claim-map, no-touch e
  merge gate. O pai pode aplicar o diff aprovado mecanicamente, mas não pode
  inventar ou corrigir o patch.

## Loop do writer

```text
PREFLIGHT -> W1 -> VERIFY
VERIFY pass -> ACCEPT/MERGE
VERIFY fail -> W2 repair (erro + diff + hipótese alterada)
W2 fail -> diagnóstico read-only do GPT -> W3 writer novo
W3 fail ou sem hipótese nova -> BLOCKED/REPLAN
```

Falha de transporte admite uma única repetição na mesma rota; falha de
qualidade conta no loop. O diagnóstico do GPT produz evidência e brief, nunca
edição. Modos no-edit, incluindo `BUG.INV`, não iniciam writers.

## Delegação nested

Reader OpenCode é read-only. Quando o brief declarar
`NESTED_REQUIRED=<frentes>` para duas ou mais frentes independentes, o reader
deve iniciar um nested read-only por frente, esperar todos e integrar os
resultados. Se `task` não estiver disponível, retorna
`NESTED_DELEGATION=blocked`; não faz tudo sozinho. Tarefas simples ou seriais
ficam locais; writers não delegam.

## Jobs longos

- Use `run_agent` somente em smoke test curto; use `start_agent` para trabalho
  que possa demorar e guarde o `job_id`.
- Em uma espera prolongada ou antes de decidir, consulte
  `get_agent_status`. `running + freshness=live` permite esperar; resultado
  disponível ou estado terminal permite `get_agent_result`.
- Heartbeat stale, processo ausente, erro MCP ou estado desconhecido exigem
  uma consulta diagnóstica e depois reparo, replanejamento ou bloqueio. Nunca
  espere cegamente, faça polling contínuo ou trate `accepted` como resultado.

## Entrega

Valide primeiro o caminho pedido, depois amplie conforme blast. Revise o diff
integrado, os caminhos permitidos, os espelhos instalados e os riscos. Não
declare sucesso quando uma rota, teste ou sub-agent obrigatório estiver
indisponível.
