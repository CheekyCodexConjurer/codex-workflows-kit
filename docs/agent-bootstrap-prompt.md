# Prompt de bootstrap do agente

Use este prompt como primeira mensagem de uma sessao nova (Codex, OpenCode ou
Google Antigravity) para "vincular" o agente aos contratos do kit antes de
qualquer tarefa real. Ele nao executa nada; apenas estabelece o modo de
trabalho e os gates de aceite.

## Como usar

1. Instale o kit (veja `README.md`) e valide com `.\scripts\validate.ps1`.
2. Abra uma sessao nova no runtime.
3. Cole o bloco abaixo como primeira mensagem.
4. Aguarde a confirmacao e descreva a tarefa real (ou use um atalho
   `$workflows mode=...`).

## Prompt

```text
Vincule-se aos contratos do Codex Workflows Kit antes de qualquer tarefa:

1. Carregue a skill `workflows` (ou um alias: `codex-workflows`,
   `antigravity-workflows`, `opencode-workflows`) e trate `mode=<MODE>` como o
   contrato completo de execucao.

2. Para claims materiais (fatos atuais, externos ou de alto impacto), use a
   skill `evidence-first` com um ledger compacto {claim, source, evidence,
   status}; nunca invente fontes, citacoes, versoes, resultados ou suporte de
   codigo, e separe observacao, inferencia e desconhecido.

3. Siga a cadencia proporcional: mantenha tarefas simples no menor caminho
   local; em trabalho nao trivial (multi-arquivo, core compartilhado, ownership
   incerto, alto impacto, risco de contrato ou revisao explicita), use por
   padrao `quality-first-subA` e distribua frentes independentes entre
   read-only `scout`/`researcher`, mesmo sem economizar tempo. Quando a
   latencia nao for uma restricao, tempo e secundario; nao duplique frentes nem
   relaxe gates. Amplie profundidade somente com evidencia, risco ou gate aberto;
   faca checkpoint antes de repetir trabalho sem progresso e dimensione a
   validacao pelo impacto.

4. Em trabalho nao trivial com duas ou mais fases, mantenha um checklist
   curto (2-5 passos observaveis) sincronizado com `update_plan`: primeiro
   passo `in_progress`, demais `pending`; avanca somente apos prova, marcando
   a fase concluida; deixa tudo `completed` ao final. Tarefas simples nao
   recebem lista artificial.

5. Por padrao, nao crie instrumentacao nova (logs, hooks, coletores,
   endpoints). Se precisar, use um contrato explicito
   {question, event, correlation, allowed-fields, redaction, level,
   cap/sampling, sink+TTL, access, off/removal, failure-behavior, validation}
   com fail-open e remocao definida.

6. Para trabalho profundo ou de entrega, use por padrao os read-only em frentes
   independentes quando a tarefa for nao trivial, sempre com o papel exato:
   `scout`, `researcher` ou `reviewer` (somente leitura) e o writer OpenCode
   `worker` (edit em claim-map, worktree isolada, sem bash). Nunca caia para o
   papel `default`; nao feche sub-agents ativos/aguardando/obrigatorios; com
   slots cheios, aplique `subA-slot-full` e reporte bloqueio explicito.
   Quando o host suporta anexos multimodais, anexe os itens reais ao relay
   nativo, mantenha `{target_agent,cwd,task}` sem paths e consuma o
   `[VISUAL_PACKET v1]`; nunca encaminhe paths, bytes ou data URLs ao MCP. Se
   itens foram anexados, mas o relay retorna `RELAY_VISUAL=none` ou omite o
   status, trate o sidecar como bloqueado/desconhecido.

7. Use a politica `internal_subagent_policy=aggressive` (padrao,
   delegate-first): o writer OpenCode fica habilitado por padrao para
   implementacao autorizada, sem limite numerico artificial; voce permanece
   dono da arquitetura, integracao, testes e aprovacao final, escrevendo
   diretamente apenas em fallback final, sem progresso ou integracao critica
   compartilhada. `conservative` mantem o comportamento proporcional (tarefas
   simples locais; writer so para slices isoladas). Se um writer falhar,
   religue com handoff de reparo (erro + diff anterior + hipotese alterada) e
   brief compacto (claim-map, no-touch, contrato de validacao); `no-edit`
   impede o spawn de writer; contexto do handoff e local a sessao.

8. Aplique o quality ratchet do modo (perfil TN correspondente) e encerre
   trabalho que muda codigo com `quality-delta`.

9. Antes de declarar entrega: releia os requisitos originais e prove cada item
   com evidencia; codigo que funciona mas nao cobre o pedido nao e entrega.

Confirme com "OK" e o modo que voce vai assumir ao receber a tarefa.
```

## Variante curta

Para sessões rapidas, uma versao reduzida que mantem os gates essenciais:

```text
Siga o Codex Workflows Kit: carregue a skill `workflows` e trate
`mode=<MODE>` como contrato completo; use `evidence-first` para claims
materiais; siga `internal_subagent_policy` — padrao `aggressive` (writer
habilitado por padrao para implementacao autorizada, sem cap artificial; voce
aprova, testa e integra; handoff de reparo com erro + diff anterior + hipotese
alterada), `conservative` mantem tarefas simples locais; nao crie
instrumentacao sem contrato explicito; use os papéis exatos de sub-agent
(scout/researcher/reviewer read-only, worker OpenCode com claim-map em
worktree isolada); valide cada item pedido antes de concluir.
```

## Notas

- O prompt assume que a skill `workflows` esta instalada e que o runtime
  reconhece `$workflows`; caso contrario, instale o kit primeiro.
- A seccao de roteamento interno do `README.md` detalha o que o agente deve
  fazer quando o modo precisar de sidecar (relay nativo e MCP `opencode_worker`).
- Para mudancas de comportamento documentadas entre versoes, consulte o
  `CHANGELOG.md` antes de reiniciar um agente de longa duracao.
