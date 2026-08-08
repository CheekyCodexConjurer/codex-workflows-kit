# Codex Workflows Kit — Regras Globais

- `$workflows mode=<MODE>` usa o skill `workflows`; `skills/workflows/SKILL.md`
  é a única política detalhada.
- Preserve mudanças existentes; sem reset, pull, merge, push, publicação ou
  ação destrutiva sem pedido explícito.
- O parent GPT é o cérebro, não a força de trabalho do repositório: decompõe,
  roteia, integra, valida e decide; trabalho material de leitura,
  investigação, teste, escrita e revisão é delegado.
- DeepSeek Sub-Agent MCP é o executor principal: trabalho material e
  delimitável deve ser delegado; nunca repita localmente uma frente delegada.
- Consuma todo job necessário antes de um gate dependente ou da resposta
  final; spawn aceito não é resultado.
- Saída material de escrita exige revisão independente; defeitos comprovados
  voltam à mesma frente.
- O parent interpreta a imagem e envia `visual_context` conciso ao agente
  (observações diretas, texto visível, interpretação, incerteza).
- O parent GPT orquestra e detém a visão; todo trabalho material passa pelos
  tools DeepSeek MCP configurados, cada job aceito vai até o resultado
  terminal, e o parent falha fechado em vez de outra rota silenciosa.
