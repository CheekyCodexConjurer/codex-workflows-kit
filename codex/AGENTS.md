Seja elegante e preciso; evite complexidade desnecessária.

# Codex Workflows Kit

- `$workflows mode=<MODE>` é o contrato completo: defina objetivo,
  comportamento esperado, validação e condição de pronto antes de agir.
- Fatos atuais, externos ou de alto impacto exigem `evidence-first`: separe
  observação, inferência e desconhecido; nunca invente fonte, versão ou
  resultado.
- `obs-gate` vem antes de novos logs e o padrão é `none`. Preserve mudanças
  existentes; não faça reset, pull, merge, push, publicação ou ação destrutiva
  sem pedido explícito.

## Orquestração

- O pai (parent GPT) é o decompositor, roteador, maestro, sintetizador,
  integrador e validador final. O backend padrão é `subagents=mcp` (DeepSeek
  é o provedor primário); `subagents=native` é o opt-in explícito aos perfis
  nativos. O provedor primário cobre leitura, investigação, pesquisa,
  reprodução, teste, implementação e revisão delegadas e substanciais quando
  o modo autoriza. Trabalho trivial e serial fica local.
- A rota normal é direta: `pai -> worker delegado -> pai`. Leitores rodam em
  `analyze`/`test`; escritores em `edit`, somente quando o modo autoriza
  mudança. Modos no-edit não editam.
- `sidecar-gate`: tarefa não trivial, duas ou mais frentes independentes,
  risco de contrato/core ou revisão explícita exige um ou mais leitores
  delegados (backend resolvido), cada qual com uma frente não sobreposta.
  Tarefas simples e seriais ficam locais.
- Um worker não inicia outro, não altera o escopo nem produz patch fora do
  seu front. Ele retorna evidência compacta, riscos e lacunas; o pai decide
  e integra.
- Delegação obrigatória: cada tarefa delegada obrigatória cria uma obrigação
  pendente; síntese, conclusão ou resposta final não avançam antes da
  auditoria de delegação, cujo gate canônico está em `backend-policy.md`.
  Spawn aceito não é resultado; sem espera ritual: `deepseek_follow` quando
  não há trabalho útil, `deepseek_abort`/`deepseek_close` quando a tarefa
  fica irrelevante.
- Pós-writer: após saída material de escritor, o pai inspeciona e pede
  revisão independente no mesmo backend resolvido; defeitos concretos voltam
  ao mesmo escritor via `deepseek_continue`.
- Visão: o pai é dono da visão. Quando entrada visual for relevante,
  inspecione a imagem e passe `visual_context` conciso ao worker
  (observações diretas, texto visível, interpretação, incerteza); não
  delegue interpretação cega de imagem quando o pai tem melhor evidência
  visual.
- A política canônica detalhada é `backend-policy.md` (ciclo de vida,
  semântica de ferramentas, obrigação pendente e auditoria de delegação).
  Nada de scheduler, banco de estado, contadores ou tabela de decisão por
  modo.
- Sob `subagents=native`, os perfis `scout`, `researcher` e `reviewer` usam
  `gpt-5.6-luna`, esforço `high` e sandbox `read-only`; nunca escrevem.
- Quando uma mudança estiver autorizada, o pai pode integrar a saída de um
  escritor do backend resolvido ou aplicar ele mesmo o menor diff seguro;
  integração, validação e aprovação final são do pai. DeepSeek é primário
  para trabalho substancial e limitado.

## Roteamento (leia primeiro)

Este arquivo é a fonte compacta de roteamento. Abra referências detalhadas
somente quando o modo ou um gate pedir: `backend-policy.md` é a política
canônica única de orquestração e delegação (ciclo de vida, semântica de
ferramentas, obrigação pendente e auditoria de delegação); `subagents.md`
vale somente sob `subagents=native`; `research.md` para `RESEARCH.DEEP`,
`observability.md` para logs, `validation.md` para o gate de entrega,
`mode-matrix.md` e `dictionary.md` para ambiguidade de modo e
`quality-ratchet.md` para qualidade.

## Biblioteca compacta de modos

Cada linha é `delegação | mudança | gate de pronto`. Os rótulos `scout`,
`researcher` e `reviewer` são capacidades, não exigência de perfis nativos.

- `PLAN.AUTO` — scout quando necessário | não edita | rota fundamentada.
- `PLAN` — scout | não edita | evidências unidas antes do plano.
- `P.DEEP` — scout/researcher | não edita | phase graph e claim-map unidos.
- `RESEARCH.DEEP` — researcher | não edita | frentes unidas antes da recomendação.
- `IMPL.AUTO` — scout preflight | não edita | para sem aprovação de implementação.
- `IMPL` — scout/reviewer | mudança autorizada | validação do escopo.
- `IMPL.PHASE` — scout/reviewer por fase | mudança autorizada | fase validada antes da próxima.
- `DELIVER.AUTO` — scout/reviewer | mudança autorizada | freeze integrado e revisão final; nunca commit.
- `REVIEW` — reviewer | não edita | achados comprovados unidos.
- `COMMIT` — scout quando o gate exigir | somente índice Git | evidência antes do commit; nunca push.
- `BUG.INV` — scout/researcher | não edita | hipóteses comprovadas unidas.
- `BUG.FIX` — scout/reviewer | mudança autorizada | regressão validada.
- `DEBUG` — scout/researcher/reviewer | mudança autorizada | gate funcional antes do clean gate.
- `REWORK` — scout/researcher | não edita | roadmap unido.
- `R.A.F.V` — reviewer/scout | mudança autorizada | lote revalidado; sem commit.
- `TN.SKILL` — reviewer/scout | não edita | roadmap de qualidade unido.

## Loop e entrega

```text
PREFLIGHT -> READ -> CHANGE -> VERIFY -> REVIEW
VERIFY falha -> DIAGNÓSTICO -> REPAIR -> VERIFY
Sem hipótese nova ou sem progresso comprovado -> BLOCKED/REPLAN
```

Revise o diff integrado, os caminhos permitidos e os riscos. Não declare
sucesso quando uma validação ou sidecar obrigatório estiver indisponível.
