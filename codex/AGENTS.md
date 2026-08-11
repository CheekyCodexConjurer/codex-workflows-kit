# Codex Workflows Kit — Regras Globais

- `$workflows mode=<MODE>` usa o skill `workflows`; `skills/workflows/SKILL.md`
  é a única política detalhada. `$workflows` acrescenta o ciclo e os modos,
  mas não é condição para selecionar o MCP: sem `$workflows`, a delegação
  continua usando o DeepSeek Sub-Agent MCP — e vale mesmo quando o usuário não
  menciona `$workflows`, sub-agentes ou delegação.
- Preserve mudanças existentes; sem reset, pull, merge, push, publicação ou ação destrutiva sem pedido explícito.
- O parent GPT é o cérebro, não a força de trabalho do repositório: decompõe,
  roteia, integra, valida e decide; trabalho material de leitura,
  investigação, teste, escrita e revisão é delegado ao DeepSeek MCP por
  padrão, com ou sem `$workflows`.
- Trabalho local do parent é atômico: formular a delegação, integrar
  resultados e conferir/verificar alegações; nunca refazer localmente uma
  frente material delegada.
- Roteamento: todo pedido não qualificado de sub-agentes, agentes, delegação,
  trabalho, leitura, escrita, exploração ou revisão — incluindo os aliases
  comuns `workers`, `readers`, `writers`, `explorers`, `reviewers` — usa
  `deepseek_spawn`/`deepseek_continue`/`deepseek_follow`, com ou sem
  `$workflows`.
- Ferramentas nativas `multi_agent_v1__spawn_agent`/`spawn_agent`/
  `wait_agent` são proibidas, exceto quando o usuário pedir explicitamente
  sub-agentes nativos do Codex; agentes de supervisão do sistema (ex.:
  Guardian) não são trabalhadores e ficam isentos do roteamento e do ciclo
  de vida de workers — a isenção nunca autoriza o parent a invocar
  ferramentas nativas de trabalho.
- DeepSeek Sub-Agent MCP é o executor principal: trabalho material e
  delimitável deve ser delegado; nunca repita localmente uma frente delegada.
- Consuma todo job aceito antes de um gate dependente ou da resposta final;
  feche explicitamente todo agente terminado; sem obrigações pendentes ou em
  aberto.
- O writer fica aberto/continuável até a revisão independente e as correções
  comprovadas; defeitos provados voltam à mesma frente; feche só depois:
  o writer não está terminado antes de revisão e correções concluídas.
- O parent interpreta a imagem e envia `visual_context` conciso ao agente
  (observações diretas, texto visível, interpretação, incerteza).
- O parent GPT orquestra e detém a visão; todo trabalho material passa pelos
  tools DeepSeek MCP configurados, cada job aceito vai até o
  resultado terminal, e o parent falha fechado — inclusive quando os tools
  DeepSeek estão indisponíveis — em vez de outra rota silenciosa.
