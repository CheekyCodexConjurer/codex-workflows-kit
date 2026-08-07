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
- Com `internal_subagent_backend=opencode`, o handoff normal de readers,
  reviewers e writers usa a ponte do native `watcher` (`agent_type=watcher`):
  `pai -> watcher -> MCP opencode_worker -> papel OpenCode exato`. O pai nunca
  chama `run_agent`/`start_agent` diretamente para trabalho normal; sua
  exposição é só `get_agent_status`/`get_agent_result`/`cancel_agent` para
  recuperação declarada. `start_agent` destacado é exceção explícita apenas
  depois de declarar a rota e com evidência. Nunca use um native `scout`,
  `researcher`, `reviewer` ou `worker` para fazer o trabalho; esses perfis
  devem retornar `NATIVE_ROUTE_BLOCKED`. O native `relay` só pode transportar
  um pacote visual.
- Fan-out de readers é obrigatório (`sidecar-gate`): tarefa não trivial, duas
  ou mais frentes independentes, pedido explícito de sub-agentes, risco de
  contrato/core ou obrigação explícita de revisão/teste exige um ou mais
  readers read-only, mesmo sem ganho de tempo; frentes obrigatórias nunca são
  absorvidas localmente. Só tarefas estritamente simples e seriais ficam
  locais.
- O native `watcher` é a única exceção textual: `gpt-5.6-luna` com esforço
  `high`, somente para manter uma chamada MCP aberta e devolver o resultado.
  Ele não analisa, edita, revisa nem sobe outros agentes.
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
deve iniciar um nested read-only por frente, esperar todos, integrar os
resultados e retornar `NESTED_DELEGATION=used`. Se `task` não estiver
disponível, retorna `NESTED_DELEGATION=blocked`; não faz tudo sozinho. Tarefas
simples ou seriais ficam locais; writers não delegam.

## Jobs longos

- O pai nunca chama `run_agent`/`start_agent` para trabalho normal; o native
  `watcher` faz a única chamada bloqueante `run_agent` para o handoff normal e
  o pai não fica consultando nem esperando essa chamada. `start_agent` é
  reservado a jobs destacados e recuperação declarados, depois de a rota ser
  definida e a evidência exigir.
- Em uma espera prolongada ou antes de decidir, consulte
  `get_agent_status`. `running + freshness=live` permite esperar; resultado
  disponível ou estado terminal permite `get_agent_result`.
- Heartbeat stale, processo ausente, erro MCP ou estado desconhecido exigem
  uma consulta diagnóstica e depois reparo, replanejamento ou bloqueio. Nunca
  espere cegamente, faça polling contínuo ou trate `accepted` como resultado.
- `MAX_ACTIVE_CHILDREN_PER_CHAT=5` é o cap operacional por chat. Se estiver
  `running`/live, espere e não envie mensagem, `steer`, interrupt ou retry para
  acelerar o MCP. Ao retornar, capture o resultado e feche imediatamente. Só
  feche antes disso com crash confirmado; com slots cheios, recupere apenas
  filhos terminais já capturados.

## Entrega

Valide primeiro o caminho pedido, depois amplie conforme blast. Revise o diff
integrado, os caminhos permitidos, os espelhos instalados e os riscos. Não
declare sucesso quando uma rota, teste ou sub-agent obrigatório estiver
indisponível.
