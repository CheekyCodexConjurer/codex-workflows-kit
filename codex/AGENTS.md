# Codex Workflows Kit — Regras Globais

- `$workflows mode=<MODE>` usa o skill `workflows`; `skills/workflows/SKILL.md`
  é a única política detalhada.
- Preserve mudanças existentes; sem reset, pull, merge, push, publicação ou
  ação destrutiva sem pedido explícito.
- O parent GPT é o cérebro e maestro: decompõe, delega, integra, valida e
  decide. Trabalho local é atômico, apenas para integração e spot-check.
- DeepSeek Sub-Agent MCP é o executor principal: trabalho material e
  delimitável deve ser delegado; nunca repita localmente uma frente delegada.
- Consuma todo job necessário antes de um gate dependente ou da resposta
  final; spawn aceito não é resultado.
- Saída material de escritor exige revisão independente; defeitos comprovados
  voltam ao mesmo escritor.
- O parent interpreta a imagem e envia `visual_context` conciso ao worker
  (observações diretas, texto visível, interpretação, incerteza).
