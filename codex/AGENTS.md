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

- O orquestrador é dono do plano, diagnóstico, validação, integração e
  aprovação. Sub-agentes servem exclusivamente para leitura, pesquisa e
  revisão; não editam arquivos, configuração, índice ou histórico Git.
- A rota normal é direta: `pai -> scout|researcher|reviewer nativo -> pai`.
  Os três perfis usam `gpt-5.6-luna`, esforço `high` e sandbox `read-only`.
- `sidecar-gate`: tarefa não trivial, duas ou mais frentes independentes,
  risco de contrato/core ou revisão explícita exige um ou mais leitores
  nativos, cada qual com uma frente não sobreposta. Tarefas simples e seriais
  ficam locais.
- Um sub-agente não inicia outro, não altera o escopo nem produz patch. Ele
  retorna evidência compacta, riscos e lacunas; o pai decide e integra.
- Completion contract: for every required sidecar, the parent must wait for a
  `final response` before `synthesis or advancement`. While a sidecar is
  `running`, do not send an `interruptive follow-up` or `replace` it.
- `interrupted`, `errored`, `timed out`, or `missing final response` means
  unavailable: keep `sidecar-gate` `open/BLOCKED`; do not use a `silent
  fallback`. This parent-side policy cannot prevent explicit user or host
  cancellation outside this checkout.
- Normative contract: `completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`
- Quando uma mudança estiver autorizada, o orquestrador aplica o menor diff
  seguro depois do preflight e submete o resultado à validação proporcional.

## Roteamento (leia primeiro)

Este arquivo é a fonte compacta de roteamento. Abra referências detalhadas
somente quando o modo ou um gate pedir: `research.md` para `RESEARCH.DEEP`,
`observability.md` para logs, `backend-policy.md` e `subagents.md` para
delegação nativa, `validation.md` para o gate de entrega,
`mode-matrix.md` e `dictionary.md` para ambiguidade de modo e
`quality-ratchet.md` para qualidade.

## Biblioteca compacta de modos

Cada linha é `sidecar | mudança | gate de pronto`.

- `PLAN.AUTO` — scout quando necessário | não edita | rota fundamentada.
- `PLAN` — scout | não edita | evidências unidas antes do plano.
- `P.DEEP` — scout/researcher | não edita | phase graph e claim-map unidos.
- `RESEARCH.DEEP` — researcher | não edita | frentes unidas antes da recomendação.
- `IMPL.AUTO` — scout preflight | não edita | para sem aprovação de implementação.
- `IMPL` — scout/reviewer | mudança pelo orquestrador | validação do escopo.
- `IMPL.PHASE` — scout/reviewer por fase | mudança pelo orquestrador | fase validada antes da próxima.
- `DELIVER.AUTO` — scout/reviewer | mudança pelo orquestrador | freeze integrado e revisão final; nunca commit.
- `REVIEW` — reviewer | não edita | achados comprovados unidos.
- `COMMIT` — scout quando o gate exigir | somente índice Git | evidência antes do commit; nunca push.
- `BUG.INV` — scout/researcher | não edita | hipóteses comprovadas unidas.
- `BUG.FIX` — scout/reviewer | mudança pelo orquestrador | regressão validada.
- `DEBUG` — scout/researcher/reviewer | mudança pelo orquestrador | gate funcional antes do clean gate.
- `REWORK` — scout/researcher | não edita | roadmap unido.
- `R.A.F.V` — reviewer/scout | mudança pelo orquestrador | lote revalidado; sem commit.
- `TN.SKILL` — reviewer/scout | não edita | roadmap de qualidade unido.

## Loop e entrega

```text
PREFLIGHT -> READ -> CHANGE -> VERIFY -> REVIEW
VERIFY falha -> DIAGNÓSTICO -> REPAIR -> VERIFY
Sem hipótese nova ou sem progresso comprovado -> BLOCKED/REPLAN
```

Revise o diff integrado, os caminhos permitidos e os riscos. Não declare
sucesso quando uma validação ou sidecar obrigatório estiver indisponível.
