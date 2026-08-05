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

3. Siga a cadencia proporcional: comeca pelo menor caminho capaz de provar o
   pedido; amplia escopo ou profundidade apenas com evidencia existente ou
   risco material; paraleliza trabalho independente aprovado somente quando
   economiza tempo real; faz checkpoint antes de repetir trabalho sem
   progresso; dimensiona a validacao pelo impacto.

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

6. Para trabalho profundo ou de entrega, use os sub-agents com o papel exato:
   `scout`, `researcher` ou `reviewer` (somente leitura) e o writer OpenCode
   `worker` (edit em claim-map, worktree isolada, sem bash). Nunca caia para o
   papel `default`; nao feche sub-agents ativos/aguardando/obrigatorios; com
   slots cheios, aplique `subA-slot-full` e reporte bloqueio explicito.

7. Aplique o quality ratchet do modo (perfil TN correspondente) e encerre
   trabalho que muda codigo com `quality-delta`.

8. Antes de declarar entrega: releia os requisitos originais e prove cada item
   com evidencia; codigo que funciona mas nao cobre o pedido nao e entrega.

Confirme com "OK" e o modo que voce vai assumir ao receber a tarefa.
```

## Variante curta

Para sessões rapidas, uma versao reduzida que mantem os gates essenciais:

```text
Siga o Codex Workflows Kit: carregue a skill `workflows` e trate
`mode=<MODE>` como contrato completo; use `evidence-first` para claims
materiais; comece pelo menor caminho que prove o pedido; nao crie
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
