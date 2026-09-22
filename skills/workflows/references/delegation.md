# Orquestração adaptativa

A orquestração adaptativa é o comportamento padrão. Os únicos seletores
persistidos são `subagent_backend` (`native` ou `deepseek`) e
`subagent_continuation` (`active_follow` ou `park_and_wake`). O backend
selecionado fixa a família de ferramentas, modelo e rota; nenhuma decisão
adaptativa troca backend ou provedor.

## Decisões por evento

No FRAME e após nova frente, resultado consumido, bloqueio, mudança de escopo,
contradição ou pré-revisão, o parent registra duas decisões separadas:

| Execução | Condição |
|---|---|
| GPT direto | Trabalho realmente imediato e coeso, sem ganho material de delegação |
| Reusar worker | Sessão aberta e ociosa, continuidade confirmada pelo provedor, contexto relevante, escopo compatível, fontes atuais |
| Delegar uma frente | Trabalho material delimitado, com objetivo, ownership e aceite claros |
| Delegar em paralelo | Frentes independentes, ownership disjunto ou isolamento, capacidade observada e ganho de tempo esperado positivo |
| Decisão do parent | Objetivo ou escopo ambíguo; investigação delimitada pode fornecer a evidência necessária |

A revisão sempre verifica permissões, dependências, ownership, fonte atual e
validação. Modos de escrita exigem alvo congelado, prova operacional quando
acionada e revisão independente. Segurança, concorrência, contrato público,
ambiguidade e contradição exigem análise direcionada do GPT. O implementador
não é o revisor independente na mesma conversa. Jev nunca dispensa esses gates.

No ALINHAMENTO, somente leitura e sem cerimônia formal; inspeção delegada só
quando a resposta depender materialmente do repositório, com consumo e
fechamento no ledger. Nenhum dos metadados é criado no workspace durante essa
inspeção; se a leitura exigir mutação, falha fechado. Em `COMMIT`, nenhuma
edição de conteúdo é autorizada.

O script `../scripts/decide-orchestration.ps1`, chamado pelo helper
`invoke-safe-powershell.ps1`, produz uma recomendação e o fingerprint da
entrada. O parent confirma o objetivo, desenho, risco e tempo esperado, aplica
o resultado no despacho real e conserva autoridade para decisões difíceis.
Reutilize a decisão só enquanto contrato, evidências e capacidades forem os
mesmos. O código rejeita edição em modo sem escrita, dependências não
consumidas e autoria sem ownership explícito. O parent não passa histórico,
arquivos completos, logs brutos ou segredos à decisão.

## Jev

O cliente TypeSafe existente avalia perguntas `noul` estreitas em lote:
suficiência de escopo, pertinência de contexto de worker e necessidade de
análise semântica adicional. Envie objetivo curto, sinais sanitizados e
candidatos válidos. Questões determinadas por regras não chamam Jev.
`off` desliga somente a assistência Jev; `shadow` mede sem alterar a
execução. Ambos são controles técnicos, não modos públicos de orquestração.
Timeout, resposta inválida ou indisponibilidade mantêm regras conservadoras e
julgamento GPT. Jev não inventa dependência, não concede permissão, não escolhe
backend nem aprova código. Confira o contrato oficial antes de mudar chamadas.

## Ordem de serviço e retorno

A ordem de serviço é compacta e versionada. Use campos relevantes:

- `objective`
- `scope/ownership`
- `context_refs`
- `design_decisions`
- `invariants`
- `acceptance_criteria` com IDs estáveis
- `validation_commands`
- `escalation_conditions`

O parent fornece decisões e limites, sem ditar a implementação linha a linha.
Se a abordagem não estiver decidida, delegue investigação delimitada. O worker
pode investigar, implementar, testar e corrigir dentro da autorização.
Contradição, ampliação de escopo ou mudança de contrato exigem escalada.
Continuações citam a versão e enviam somente o delta quando a memória do
provedor foi confirmada; caso contrário, reenviam o contrato necessário.
Requisitos não são truncados silenciosamente para caber em orçamento.

O retorno lista `criterion_id`, estado `atendido`, `falhou` ou
`não verificado`, e `evidence_refs` vinculadas à versão exata do diff ou
resultado. Separe afirmações do worker de fatos observados pelo bridge.
Conserve resultado completo persistido, projeção compacta com orçamento real
de bytes, paginação, recibo, telemetria e evidências obrigatórias. Comando
negado, falha, validação ausente, evidência velha ou conflito não somem do
resumo. Se houver defeito, continue na mesma trilha com orientação específica
e nova observação discriminante; não repita o trabalho inteiro.

## Fronteiras

### Continuação e liveness

`active_follow` é o único modo que espera dentro da run: acompanha jobs via
`subagents_follow` até o resultado terminal. Em `park_and_wake`, depois de
despachar frentes independentes e drenar trabalho local útil, o parent arma
`subagents_park` com predicados `ANY`, `ALL`, `QUORUM(k)` (1 <= k <= total)
ou `REQUIRED` (subconjunto não vazio). `park_and_wake` retorna imediatamente
`ParkReceipt`, emite mensagem visível de suspensão com a condição de retomada
e encerra o turno com obrigações pendentes exclusivamente como `SUSPENDED` com recibo
externamente armado. `deliveryMode=none` ou unarmed exige permanecer ativo.
É permitido encerrar o turno com obrigações pendentes exclusivamente em
`SUSPENDED` com `ParkReceipt` armado.

Uma única retomada por geração ocorre somente quando o predicado se satisfaz.
Ela inicia nova run via CLI na mesma task: `codex queue` para task carregada,
`codex exec resume` para descarregada. O wake carrega metadados confiáveis,
nunca texto de subagente. `active writer` é entrega diferida durável
(`deferred_active_writer`), nunca licença para auto-archive ou auto-unload.
Após acordar, use `subagents_follow` para consumir apenas jobs prontos e o parent fecha
agentes depois da integração. Meta/goal tem titularidade separada. A resposta
final `DONE` segue proibida com qualquer obrigação aberta.

Jobs aceitos e saudáveis não têm timeout rígido de execução. Heartbeat, lease,
PID, attempt, fence e quiescência fundamentam liveness e retomada; lease
expirada sozinha não prova morte. Timeouts de transporte, handshake, health e
connect permanecem limitados. Estado desconhecido bloqueia avanço sem mudar
backend, rota, modelo ou provedor.

O parent GPT é o único arquiteto, integrador e decisor. O backend MCP é
transporte/executor neutro: admite jobs, preserva sessões, estado, recibos e
evidências, sem ler seletores para aprovar trabalho nem controlar a conversa.
O adapter native segue o mesmo contrato conceitual conforme sua capacidade
real; não se presumem campos ou persistência que ele não exponha.

Frentes independentes podem avançar quando suas dependências diretas tiveram
resultado terminal consumido. Recursos exclusivos e arquivos compartilhados
impedem escrita paralela sem isolamento. Não há quantidade fixa de agentes;
coordenação, latência e retrabalho têm custo. O bridge governa backpressure.
Para reusar um resultado consumido, registre a revisão consumida, o readset
versionado e os hashes das fontes consultadas. Mudança nos próprios inputs,
no contrato ou na política invalida apenas dependentes transitivamente
afetados; frentes independentes sem mudança conservam o resultado. Um prefixo
seguro de preparação somente leitura pode avançar enquanto dependências de
edição aguardam; testes que afirmem comportamento dependente esperam o
resultado consumido. Não adivinhe esquema ou contrato desconhecido.
Todo job aceito permanece obrigação até follow terminal e fechamento formal
do agente. `park_and_wake` exige recibo armado e retomada na mesma tarefa;
`active_follow` acompanha no turno. Erros e estado desconhecido bloqueiam
avanço dependente, sem fallback silencioso.

Antes de aprovação, valide o alvo exato e o comportamento afetado. O revisor
independente recebe ordem de serviço, diff e evidências observadas. Aprovação
não pode depender só de resumo ou de teste alegado. Reparo exige evidência nova;
sem delta, escolha direção diagnóstica diferente, sem retentativa idêntica ou
duplicação de worker. Commit local e resposta
final requerem todas as obrigações consumidas e agentes fechados.
