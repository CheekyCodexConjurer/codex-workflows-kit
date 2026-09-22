# Subagent Delegation Policies

## Jev delegation gate

Before material work, the parent computes its current policy decision and calls `scripts/subagent-gate.ps1 -Gate delegation` with a compact JSON input. The script's `on` default applies Jev's closed `Choice` among `PARENT_SOLO`, `REUSE_SUBAGENT`, `DELEGATE_SINGLE`, and `DELEGATE_BATCH`; `off` makes no Jev call, and `shadow` reports the recommendation while preserving the current decision. `CODEX_SUBAGENT_JEV_MODE` or `-Mode` selects the mode. The existing backend remains authoritative and appears only in output telemetry, never in Jev's state. `standard` is accepted as an alias for `balanced`.

The parent supplies `current_decision`, selected `backend`, mode, policy, bounded counts and flags. It marks `relevant_worker_available`, `worker_context_warm`, and `worker_route_matches` true only after checking the open worker ledger and route. Trivial work and balanced work without a clear delegation gain use the parent without Jev. Batch is available only with multiple genuinely independent fronts; reuse is available only for a related warm worker on the same route. No-write mode permission and backend capability checks remain mandatory outside this decision gate. A Jev timeout, invalid answer, or low confidence preserves the current policy decision; no provider or backend fallback occurs. Under aggressive, Jev may select parent solo for material work only when delegation cost is explicitly high.

The implementation is `skills/workflows/scripts/subagent-gates.psm1` and its command entry is `skills/workflows/scripts/subagent-gate.ps1`. Invoke `.ps1` files through `scripts/invoke-safe-powershell.ps1` with `-File`, `-NoProfile`, and `-NonInteractive`. Pass only compact enum/boolean/count JSON. The command emits one compact JSON result containing `gate`, `policy`, `decision`, `reason_code`, `jev_called`, `latency_ms`, `worker_reused`, `backend`, `review_result`, `current_decision`, `jev_recommendation`, and `jev_calls_avoided`; it never logs prompts, code, diffs, credentials, or the full Jev response. `shadow` comparisons use `current_decision` and `jev_recommendation`.

Delegation input fields: `policy`, `workflow_mode`, `backend`, `current_decision`, `task_type` (`general|read|implementation|debug|review|research`), `scope` (`local|multi_file|large`), `estimated_files`, `material`, `trivial`, `requires_edit`, `requires_tests`, `requires_architecture`, `independent_fronts`, `fronts_independent`, `context_load` (`low|medium|high`), `relevant_worker_available`, `worker_context_warm`, `worker_route_matches`, and `delegation_cost_high`. Omitted flags are false. A caller must not put user text, paths, source, or diffs into these fields. The backend field is checked for route consistency and emitted only in telemetry.

Esta referência detalha as três políticas de delegação globais ortogonais (`balanced`, `aggressive` e `swarm`) e sua interação com os seletores de backend (`native` e `deepseek`) para tarefas e sessões do Codex.

---

## 1. Princípios Gerais e Seletores Ortogonais

Existem quatro seletores globais ortogonais e independentes:

1. **`subagent_backend` (`native` | `deepseek`)**:
   - Governa estritamente a família de ferramentas autorizada para delegação.
   - `native`: autoriza subagentes nativos do Codex (`multi_agent_v1__spawn_agent`/`spawn_agent`/`wait_agent`) com `model="gpt-5.6-luna"`, `reasoning_effort="max"` e modo default/normal (`fast_mode = false`); proíbe contato com o SubAgents MCP. Não requer solicitação explícita prévia do usuário.
   - `deepseek`: autoriza as ferramentas do SubAgents MCP (`subagents_spawn`, `subagents_spawn_batch`, `subagents_continue`, `subagents_follow`, onde `subagents_spawn_batch` é a tool canônica de swarm e o spawn unitário `subagents_spawn` continua válido fora de ondas ou para uma única frente; compatível com `deepseek_continue` como identificador de continuação legado do backend e compatibilidade com aliases `deepseek_*` incluindo `deepseek_spawn_batch`); proíbe o uso de ferramentas nativas de trabalho pelo parent.
   - Fixação estrita de rota (*route pinning*): fallback silencioso entre backends é estritamente proibido.

2. **`delegation_policy` (`balanced` | `aggressive` | `swarm`)**:
   - Governa a estratégia de divisão de trabalho entre o parent GPT e os subagentes delegados.

3. **`subagent_strategy` (`worker` | `critical`)**:
   - Governa o modelo de cooperação e o rigor analítico dos subagentes delegados. A flag pública permanece estritamente binária: `worker` ou `critical` (sem expor `adaptive` publicamente).
   - `worker` (padrão): worker preserva o fluxo atual (worker mantém o fluxo atual) onde subagentes auxiliam o parent sob a política de delegação ativa.
   - `critical`: executa análise independente e adaptativa por profundidade internamente (independent analysis and adaptive-by-depth analysis internally), onde GPT e Gemini analisam independentemente, trocam evidências, contradições (contradictions) e lacunas (gaps), culminando em síntese GPT (GPT synthesis) mandatória pelo parent, com fencing e ownership delimitado de escopo e caminhos, sem edição concorrente (no concurrent edit) entre múltiplos agentes, e com fixação estrita de rota sem troca automática de rota ou provedor (sem troca automática de rota/provedor; no automatic route fallback).
   - A estratégia nunca concede escrita (strategy never grants write); no ALINHAMENTO vigora somente leitura.
   - **Contrato de Integração (*Integration Contract*)**: subordinado à matriz de modos, opera através de:
     - **Recibo Estruturado (*Receipt / Recibo*)**: confirmação estruturada de entrega e consumo de cada job delegado.
     - **Pacote de Evidências Decisórias (*Decision Evidence Packet*)**: pacote pequeno contendo target/diff congelado, regiões críticas, evidências de validação/revisão, contradições e lacunas.
     - **Progresso Semântico (*Semantic Progress*)**: acompanhamento por marcos semânticos de evolução na trilha persistente sem polling destrutivo nem inferência precipitada de indisponibilidade.
     - **Saída Antecipada (*Early-Exit*)**: interrupção limpa assim que uma evidência determinante ou bloqueio for provado, evitando custo e latência desnecessários.
     - **Limites do Bridge**: executado estritamente através do conjunto de ferramentas exposto pelo SubAgents MCP (`subagents_spawn`, `subagents_spawn_batch`, `subagents_continue`, `subagents_follow`, etc.), sem prometer capacidades que o bridge ainda não expõe (capabilities that the bridge does not yet expose).

4. **`subagent_continuation` (`active_follow` | `park_and_wake`)**:
   - Governa a continuidade da sessão e a capacidade de suspensão durável (*Sub-agent Autonomy*).
   - `active_follow` (padrão): é o único modo que espera dentro da run (*waits inside the run*). O parent mantém acompanhamento síncrono ativo com `subagents_follow` até a conclusão dos jobs, sem encerrar o turno do Codex prematuramente. Preserva o fluxo atual e a compatibilidade retroativa.
   - `park_and_wake` (Sub-agent Autonomy): opera sem qualquer espera interna (*zero in-turn waiting*). Após concluir todo o trabalho local útil do parent (*after all useful parent work ends*), o parent despacha todas as frentes materiais independentes em lote e drena todo trabalho local útil (*drain useful local work*) antes de armar.
     - **Armação Imediata e Encerramento como SUSPENDED**: Uma chamada bem-sucedida a `subagents_park` (ou `deepseek_park`) arma uma barreira durável de retomada no SQLite/outbox e retorna imediatamente um `ParkReceipt` (sem manter chamadas abertas e sem espera dentro da run). O parent emite uma mensagem visível de suspensão ao usuário (*user-visible suspension message*) informando a condição de retomada que acordará a task, e encerra o turno/run atual exclusivamente no estado não-terminal `SUSPENDED` respaldado pelo recibo armado.
     - **Predicados Determinísticos de Retomada**: O parent escolhe o menor predicado suficiente para a próxima decisão:
       - `ALL` (padrão): acorda quando todos os jobs estacionados atingirem estado terminal ou exceção.
       - `ANY`: acorda quando qualquer um dos jobs estacionados concluir.
       - `QUORUM(k)`: exige quorum delimitado onde `1 <= k <= contagem de jobs estacionados`; acorda quando pelo menos k jobs concluírem.
       - `REQUIRED(job ids)`: exige um subconjunto não vazio dos jobs estacionados; acorda quando todos os jobs requeridos concluírem.
       - Exceções (`failed`, `aborted`, `timed_out`, `needs_approval`) acordam imediatamente por padrão para prevenir deadlock e starvation.
       - O bridge avalia o predicado integralmente antes de reivindicar a barreira; é estritamente proibida retomada parcial prematura antes que o predicado seja satisfeito.
     - **Retomada Externa via Contrato Dual CLI (*Proven Dual CLI Wake Contract*)**: Quando o predicado da barreira for satisfeito, o bridge inicia uma nova run via CLI na mesma task exata através de duas rotas determinísticas:
       - **Sessão Carregada no Desktop (*loaded Desktop session*)**: enfileira um marcador de metadados via `codex queue` (`codex queue <task-id> ...`), fazendo com que o App Desktop Codex inicie automaticamente a próxima run sem intervenção do usuário (*so App automatically starts next run*).
       - **Sessão Descarregada (*unloaded session*)**: invoca a retomada diretamente via processo com `codex exec resume` (`codex exec resume <task-id>`).
       - **Roteamento Determinístico de Erro Queue-First (*Queue-First Deterministic Error Routing*)**: o bridge tenta primariamente o enfileiramento com `codex queue`; se a sessão não estiver carregada no Desktop, se o Desktop App estiver desconectado ou se o comando rejeitar por sessão descarregada (*session unloaded / not found in App*), roteia de forma determinística e imediata para `codex exec resume`.
     - **Invariantes Estritos de Execução**:
       - **Zero In-Turn Wait e Sem Polling (*no in-turn wait, no polling*)**: opera sem qualquer espera dentro da run e sem chamadas bloqueantes abertas; não há polling de modelo ou status.
       - **Carga Útil Estritamente de Metadados (*Metadata-Only Marker / No Raw Worker Output*)**: o payload de retorno e o marcador enfileirado contêm estritamente metadados confiáveis (id de estacionamento, geração, IDs de jobs prontos, status, hashes de resultado, contagem pendente e ação de follow requerida), nunca texto de resposta do subagente (*never worker result text*) nem instruções sintéticas do usuário (*no synthetic user prompt instructions*).
       - **Titularidade de Metas Separada (*No Automatic Goal Resume*)**: a titularidade de pausa de metas (*goals*) permanece separada; a continuação da conversa/task não exige um goal ativo e a retomada via CLI nunca retoma automaticamente um goal pausado manualmente pelo usuário (*never automatically resumes a paused goal*).
       - **Obrigações de Follow e Close Apenas Pós-Retomada (*follow/close obligations only after wake*)**: ao acordar na nova run, o parent chama `subagents_follow` para consumir apenas os jobs listados como prontos/requeridos e `subagents_close` para encerrar agentes concluídos exclusivamente após a retomada na nova run (*only after wake*). É estritamente proibido tentar consumir ou fechar obrigações antes do wake. A resposta final `DONE` continua estritamente proibida até que todas as obrigações requeridas sejam consumidas e os agentes encerrados.
     - **Condição para Encerramento de Turno e Estados de Falha (*Turn Ending and Failure States*)**:
       - **Condição para Encerramento de Turno**: o encerramento do turno com obrigações pendentes é autorizado exclusivamente no estado não-terminal `SUSPENDED` após obter um `ParkReceipt` que comprove continuação armada externamente. Se o recibo retornar `deliveryMode = none` ou desarmado, o parent deve permanecer ativo (*remain active*) e resolver as obrigações no próprio turno.
       - **Falha na Armação**: se `subagents_park` não conseguir armar a barreira com autoridade comprovada sobre a thread originária ou retornar `deliveryMode = none` ou desarmado, o parent falha fechado, não pode encerrar o turno como `SUSPENDED` e deve permanecer ativo (*remain active*) para resolver as obrigações no próprio turno.
       - **Falha de Invocação de Retomada CLI**: se a execução de retomada via CLI falhar permanentemente, o avanço transiciona para estado de bloqueio determinístico (`BLOCKED`), registrado no debug ledger, sem fallback silencioso para `active_follow`.
       - **Exceções em Workers Estacionados**: estados terminais anômalos (`failed`, `aborted`, `timed_out`, `needs_approval`) satisfazem ou disparam a barreira imediatamente por padrão para evitar deadlock.
       - **Conflito de Active Writer (*deferred_active_writer*)**: a existência de um `active writer` no Desktop indica entrega diferida durável (*durable deferred delivery*), nunca falha terminal, fallback ou permissão para arquivar ou descarregar a task (é estritamente proibido *auto-archive* e *auto-unload*). O bridge mantém recuo exponencial com jitter (*backoff*) e aciona a nova run assim que a run anterior liberar o lock.
     - **Exatamente Uma Retomada e Supersessão (*Exactly-Once and Supersession*)**:
       - **Exatamente Uma Retomada por Geração (*one wake per barrier generation*)**: conclusões simultâneas de jobs dentro da mesma geração são coalescidas atomicamente; wakes duplicados para a mesma geração são estritamente proibidos.
       - **Supersessão de Gerações (*generation supersession*)**: ao acordar na nova run, se o parent precisar re-estacionar jobs restantes chamando `subagents_park`, é gerada uma nova geração de barreira que formalmente supersede as anteriores. Quaisquer marcadores em fila, eventos ou mensagens de gerações anteriores obsoletas são descartados e ignorados deterministicamente, impedindo ativações espúrias ou fora de ordem.
   - Invariante de neutralidade do bridge: o bridge opera como transporte neutro e nunca lê flags de AGENTS.md nem decide aprovação de workflow; acorda apenas com metadados confiáveis.
   - Invariante de isolamento de repositórios consumidores: não injeta flags ou metadados nos repositórios dos usuários.
   - Invariante do Gemini: emite eventos de progresso e conclusão de workers, mas nunca controla o chat ou objetivo do Codex.

### Invariantes Comuns a Ambas as Políticas:
- **Ciclo de Vida de Completude (*Completion Lifecycle*)**: Todo job delegado deve ser consumido com resposta terminal e resultado terminal antes de um gate dependente ou da resposta final.
- **Contrato de Liveness e Status (*Liveness and Status Contract*)**:
  - Remoção de timeout rígido de conclusão: jobs aceitos e saudáveis podem rodar indefinidamente sob eventos, heartbeat e lease ativas (*accepted and healthy jobs can run indefinitely under events/heartbeat/lease*).
  - Nenhuma janela de 900s/20m/25m prova falha ou dispara graceful finalize ou abort (*no window of 900s, 20m, or 25m proves failure or triggers graceful finalize/abort; no 900s/20m/25m window proves failure*).
  - Sob `park_and_wake`, encerra a run e acorda por evento ou predicado, sem polling e sem deadline de modelo (*ends run and wakes on event/predicate, zero polling, no model deadline*).
  - Lease expirada sozinha não prova morte (*expired lease alone does not prove death*); takeover de trilha ou terminalização exige verificação de PID, heartbeat, fence token, quiescência comprovada ou erro terminal persistido.
  - Timeouts bounded de transporte, handshake, health e connect são preservados, diferenciando-os explicitamente do execution timeout (*preserve bounded transport, handshake, health, and connect timeouts; explicitly differentiated from execution timeout*).
  - O parent deve consultar ativamente status, heartbeat e lease antes de inferir indisponibilidade; estado `unknown` bloqueia o avanço (*gate open/BLOCKED*).
  - Mecanismos de fence (fence tokens), contador de tentativa (*attempt*) e PID impedem escritas obsoletas (*stale writes*).
  - Quiescência do processo/trilha anterior deve ser rigorosamente provada antes de liberar recursos ou abrir nova tentativa.
  - Sem fallback silencioso de rota, provedor ou modelo.
- **Ledger Estável de Requisições**: O parent GPT mantém um ledger estruturado registrando `request_id`, frente de trabalho, identificador do agente/job, estado (`running`, `completed`, `failed`), status de consumo e encerramento explícito.
- **Permissões Estritas por Modo**: O papel e as capacidades do subagente subordinam-se estritamente à matriz de modos do Codex Workflows Kit.
- **Interpretação de Contexto Visual**: O parent GPT interpreta todo `visual_context` (imagens, capturas de tela, mockups) e sintetiza descrições textuais precisas para o subagente, nunca delegando interpretação visual cega.
- **Repasse de Contexto Curado aos Subagentes**: Ao despachar frentes delegadas, o parent fornece o recorte relevante da tarefa (arquivos candidatos, símbolos afetados e contexto do erro ou contrato) diretamente no prompt ou parâmetros de contexto (`contextFiles`), evitando que subagentes comecem a vasculhar a raiz do repositório do zero. O subagente valida o código nas fontes originais, mas aproveita a localização já obtida.
- **Economia de Tokens na Delegação (Token Economy & Session Continuity)**:
  - **Continuidade de Sessão com Retenção de Contexto**: O bridge persiste o identificador de sessão do worker (`provider_conversation_id`) e repassa `--conversation <id>` nas rodadas subsequentes do mesmo agente, preservando o histórico em memória do assistente sem reenviar instruções e regras do zero.
  - **Despacho Delta em Continuações**: Em continuações (`subagents_continue`), o prompt gerado omite o boilerplate repetitivo de regras de operação, workspace e cabeçalhos de protocolo, emitindo apenas o bloco conciso `Continuation Task: ...` e os arquivos de contexto adicionais estritamente necessários.
  - **Projeção Compacta de Follow**: O retorno de `subagents_follow` entrega uma **carga serializada limitada por orçamento de bytes configurável** (`compactFollowMaxBytes`, bootstrap 8 KiB; a invariante é `Buffer.byteLength(JSON.stringify(compact), "utf8") <= orçamento`, nunca um tamanho fixo garantido em KB). O pacote é a projeção versionada `CompactWorkerResultV1` com `claims` delimitadas (resumo <= 1.000 caracteres, até 10 arquivos, até 10 testes, até 5 riscos), `mandatoryEvidence` classificada deterministicamente, receipt mínimo, `tokens` (quando observáveis) e `detailsRef`. O dump maciço de `progress` e o envelope bruto não sanitizado da resposta padrão são sempre omitidos do transporte; o resultado completo continua persistido localmente no arquivo privado do job e é obtido sob demanda.
  - **Evidência Obrigatória Nunca é Silenciada**: Falha de teste, teste obrigatório não executado, permissão requerida, `unresolved`, falha do worker, completude parcial, mudança fora de escopo, validação ausente, risco marcado como blocker/critical, conflito entre claim do worker e evidência, e erro operacional são classificados como evidência mandatória e entram antes de qualquer conteúdo opcional. Se a evidência mandatória sozinha exceder o orçamento, o bridge falha fechado (`decisionReady: false`, `decisionReason: "mandatory_evidence_overflow"`, `mandatoryDetailCount` e `mandatorySections`) em vez de truncar em silêncio. Um `SUCCESS` do provider não é aprovação semântica: `provider_execution_status`, o status declarado pelo worker e a evidência de validação são reportados separadamente.
  - **Detecção de Truncamento no `detailsRef`**: `hasMoreDetails` é verdadeiro sempre que qualquer seção foi reduzida para transporte, incluindo resumo truncado, e o `detailsRef` também publica contagens sem despejar conteúdo (`summaryTruncated`, `filesTotal`, `testsTotal`, `risksTotal`, `evidenceTotal`, `mandatoryDetailCount`).
  - **Recuperação Sob Demanda Paginada**: A ferramenta `subagents_recover_result` suporta parâmetros `section` (`summary`, `files`, `tests`, `risks`, `unresolved`, `diff`, `evidence`, `full`, `raw`), `offset` e `limit`. A consulta `summary` devolve apenas o resumo e metadados mínimos — o texto bruto do worker só é acessível pela seção explicitamente nomeada `raw`. Toda página é limitada por orçamento de bytes (`recoverPageMaxBytes`) e informa `offset`, `returnedCount`, `totalCount`, `hasMore`, `nextOffset` e `serializedBytes`; `limit` sozinho não controla bytes.
  - **Telemetria Estruturada e Semântica Não-Cumulativa de Delta**: Métricas de uso do worker (`worker_input_tokens`, `worker_output_tokens`, `worker_thinking_tokens`, `worker_cached_input_tokens`, `worker_total_tokens`) são persistidas por job com a semântica explícita ao lado do número: `usageScope` (`cumulative_conversation`, `per_turn`, `unknown`) e `usageSource` (`observed`, `derived`, `unavailable`). O `agy.exe` reporta totais **cumulativos** por conversa; portanto o delta incremental de um turno só é calculado (`usageSource: derived`) quando o mesmo `provider_conversation_id` e o mesmo escopo cumulativo estão comprovados. Em conversa nova, reset de sessão ou escopo desconhecido, os valores observados são preservados sem subtração — nenhum delta falso é produzido. Campo ausente permanece `null` (desconhecido), nunca `0`; `thinking_tokens` e `cache_read_tokens` são reportados separadamente e nunca somados de volta ao output/total quando o provider já informa `total_tokens`.

---

## 2. Política `balanced` (Padrão / Política Universal do Orquestrador)

**Foco Principal**: Economia máxima de tokens, alta precisão e eficiência de fluxo (*wall-clock time*).

- **Comportamento do Orquestrador (Parent)**:
  - **Solo por Padrão**: O Orquestrador executa tarefas sequenciais, coesas, de diagnóstico, criação e edição de código diretamente no contexto principal. Não há delegação automática para tarefas comuns.
  - **Gatilhos Estritos para Delegação**: O acionamento de subagentes é restrito a dois cenários:
    1. **Compressão e Blindagem de Contexto**: Leituras massivas de arquivos, logs ou documentação extensa que entupiriam a janela de contexto do Orquestrador.
    2. **Paralelismo Concreto e Independente**: Duas ou mais frentes de pesquisa/diagnóstico 100% independentes sem dependência sequencial mútua.
  - **Retorno Filtrado (Thin Handoff - Máx. 5 Linhas)**: Subagentes são estritamente proibidos de retornar código bruto, arquivos completos ou transcrições longas. O retorno deve conter apenas o status, conclusões pontuais e referências exatas.
  - **Edição Centralizada e Sem Telefone sem Fio**: Apenas o Orquestrador aplica modificações nos arquivos de produção. Subagentes operam estritamente em leitura, exploração e diagnóstico. Proibida delegação sequencial encadeada.
  - **Fatias Delimitadas e Escopo Cirúrgico**: Proibido despachar tarefas de escopo amplo ou aberto. O Orquestrador fornece arquivos-alvo explícitos, perguntas atômicas e critérios de saída antecipada (*early-exit*). Para pulverização massiva, utilizar explicitamente `swarm`.

---

## 3. Política `aggressive`

**Foco Principal**: Desoneração máxima de tokens e carga cognitiva do Parent GPT (*token offload*).

- **Comportamento do Parent GPT**:
  - Sob `aggressive`, o parent atua como arquiteto, decisor, integrador e gatekeeper (architect, decider, integrator, and gatekeeper).
  - Consome um pacote pequeno de evidência decisória (*decision evidence packet*: target/diff congelado, regiões críticas, evidências de testes/revisão, conflitos), sem refazer bulk delegado (*never redo delegated bulk*) nem duplicar trabalho material no contexto principal.
- **Estratégia de Execução**:
  - Todo trabalho material é delegado ao backend de subagentes selecionado.
  - **Trilhas Coesas e Persistentes**: Mantém uma trilha persistente por frente coesa (*one persistent track per cohesive front*) continuando a mesma sessão aberta via `subagents_continue` (compatível com `deepseek_continue` ou controle de sessão nativo), sem `allow_respawn`.
  - **Sem Microdelegação**: Proibida microdelegação (*no microdelegation*); abre nova trilha apenas para deliverable independentemente aceitável (*new track only for independently acceptable deliverable*) ou rejeitável.
  - **Fan-Out Antecipado em Lote**: Mapeia todas as frentes materiais independentes e as lança em lote (*batch spawn*) antes do primeiro comando de espera (`follow`/`wait`), maximizando a taxa de transferência.
  - **Fechamento e Continuidade**: Fatias são desenhadas para fechar terminalmente; sob eventos/heartbeat/lease, job aceito e saudável pode rodar indefinidamente; se ocorrer ausência de fechamento ou erro terminal comprovado, continua na mesma trilha pedindo inventário mínimo e fatias pequenas de fechamento (*closure slices pequenos*), sendo proibido repetir integralmente a frente ou abrir novo agente substituto.
  - O parent recebe e sintetiza apenas os resultados terminais estruturados para validar e tomar as decisões de roteamento e aceitação.

---

## 4. Política `swarm` (Adaptive Swarm)

**Foco Principal**: Decomposição em ondas do DAG (*DAG waves*), fan-out lógico elástico (*elastic logical fan-out*), maximização do paralelismo útil e autonomia dinâmica com suspensão durável (*dynamic wake*).

- **Filosofia do Swarm (Swarm Philosophy)**:
  - **Maximizar o Paralelismo Útil via Estilhaçamento (Sharding)**: Maximizar o paralelismo útil pulverizando e estilhaçando tanto tarefas quanto fases, testes e revisões sempre que forem independentes (*maximize useful parallelism by sharding tasks AND phases/tests/reviews whenever independent*). Toda frente de trabalho, checagem, validação determinística ou revisão que não dependa causalmente de outra deve ser desacoplada e disparada em paralelo.
  - **Agentes Tratados como Efetivamente Gratuitos**: Subagentes são tratados como recursos com custo marginal computacional desprezível; portanto, o parent não economiza nem conserva a contagem de agentes (*agents are treated as effectively free so do not conserve agent count*). Jamais contraia ou limite artificialmente o número de frentes independentes prontas por uma premissa de parcimônia de agentes.
  - **Fan-Out Lógico Sem Limite Rígido**: O fan-out lógico não tem mínimo, máximo nem faixa/range fixo de agentes na política (*logical fanout has no fixed min/max/range; no min/max agents in policy; sem número fixo*). A amplitude da onda é dimensionada puramente pela quantidade de fatias prontas e independentes descobertas no DAG.
  - **Disparo em Onda Antes de Esperar**: Todas as frentes prontas e independentes da onda do DAG são disparadas em lote em uma onda antes de qualquer comando de espera (*spawn all ready independent fronts in a wave before waiting*), seja follow, wait ou barreira de estacionamento.
  - **Retenção de Precisão e Disciplina Operacional**: A pulverização agressiva nunca sacrifica o rigor de engenharia (*retain precision through atomic ownership, dependency/resource constraints, GPT-only synthesis, validation and independent review*):
    - **Propriedade Atômica (Atomic Ownership)**: Cada writer opera sobre conjunto estritamente disjunto de arquivos ou diretórios (*atomic ownership; writers apenas com ownership disjunto, worktrees ou recursos exclusivos*).
    - **Restrições Reais de Dependência e Recursos**: Frentes respeitam as restrições causais e a exclusividade de recursos do sistema (*dependency/resource constraints*).
    - **Síntese Exclusiva GPT-Only**: Apenas o GPT parent integra evidências, decide aceitação ou rejeição e emite o direcionamento final (*GPT-only synthesis; GPT parent é o único orquestrador, decisor, integrador e gatekeeper*).
    - **Validação Determinística e Revisão Independente**: Alvo congelado, testes determinísticos diretos e revisão independente sem falsos-verdes estáticos (*validation and independent review*).
- **Anti-Padrões e Restrições Negativas do Swarm**:
  - **Proibido Trabalho Duplicado ou Não-Acionável**: Não disparar trabalho duplicado nem frentes especulativas ou não-acionáveis (*do not spawn duplicate/non-actionable work*); todo subagente deve possuir deliverable claro e terminalmente aceitável ou rejeitável. Em ciclos de reparo sob a política orientada a evidência, a ausência de delta observado exige obrigatoriamente direção diagnóstica diferente, sendo estritamente proibida retentativa idêntica ou proliferação redundante de worker swarm sem nova hipótese testável (*lack of delta requires different diagnostic direction, not duplicate retry or worker swarm duplication*).
  - **Proibido Paralelizar Dependências Verdadeiras**: Não paralelizar dependências causais reais ou verdadeiras (*do not parallelize true dependencies*); frentes dependentes devem ser sequenciadas em ondas subsequentes do DAG.
  - **Proibido Escritas Concorrentes sob a Mesma Propriedade**: Proibido realizar escritas concorrentes sobre o mesmo arquivo ou escopo de propriedade (*do not parallelize concurrent writes to same ownership*); sem worktree ou ownership segregado, a mutação permanece estritamente serial.
  - **Proibido Micro-Estilhaçamento**: Proibido o micro-estilhaçamento artificial de tarefas coesas, sequenciais ou de arquivo único (*do not micro-shard cohesive or single-file tasks*); tarefas lineares devem permanecer na mesma trilha persistente para evitar a sobrecarga inútil de coordenação de processos. A pulverização elástica em ondas do DAG reserva-se estritamente a frentes materialmente independentes e disjuntas.
  - **Revisão Swarm em Rodada Única e Respeito a P0-P2**: A onda de revisão do swarm opera em passada única estruturada (*single-turn swarm review*); havendo validação determinística verde e ausência de defeitos comprovados de P0 a P2, a onda de entrega fecha e aprova imediatamente, sendo estritamente proibido abrir ciclos iterativos ou réplicas subjetivas no swarm para debater detalhes cosméticos ou estilísticos (P3/P4).
  - **Proibido Navegação Pesada no Parent e Delegação de Prova de UI**: É estritamente proibido ao GPT parent instanciar sessões interativas de navegador, executar automação pesada de browser ou ingerir dumps de DOM/screenshots extensos diretamente no chat principal (*parent never runs heavy browser sessions or ingests raw visual dumps*). Em tarefas que envolvam páginas web, interfaces de usuário ou rotas de frontend (como no AERA), o parent delega a verificação de navegador localmente ao worker através da ordem de serviço. O worker executa os testes automatizados headless/Playwright na máquina, captura a evidência visual (*screenshot*) salva como artefato visível no projeto (`.scratchpad/ui_proof.png` ou pasta de artefatos) e retorna ao parent estritamente o pacote conciso de evidência (*Evidence Packet*) com o resultado determinístico e link do artefato, poupando tokens do parent.
- **Comportamento do Parent GPT**:
  - Sob `delegation_policy = swarm`, o GPT parent é o único orquestrador, decisor, integrador e gatekeeper (*sole orchestrator, decider, integrator, and gatekeeper*).
  - Constrói ondas do DAG (*DAG waves*) prontas para execução.
  - Pulveriza todas as fatias ready e independentes úteis para menor wall-clock, sem número fixo de agentes (*pulverizes all ready and useful independent slices for lowest wall-clock, no fixed number*), pulverizando apenas fatias materialmente independentes (*pulverizes only materially independent*) e terminalmente aceitáveis ou rejeitáveis; trabalho coeso e sequencial fica na mesma trilha (*cohesive/sequential work stays on the same track*).
- **Fronteira Global de Prontidão e Reutilização de Dependências Consumidas (*Global-Ready Frontier & Consumed Dependency Reuse*)**:
  - **Completude Orientada a Dependências (*Dependency-Scoped Completion*)**: A completude é governada por escopo de dependência causal; barreiras globais entre ondas independentes são proibidas (*global barrier across independent waves is forbidden*). Não existem barreiras de fase arbitrárias exceto gates explícitos do usuário sob o modo `IMPL.PHASE` (*no phase barriers except explicit IMPL.PHASE user gates*).
  - **Avanço por Prefixo Seguro (*Safe Prefix & Global-Ready Frontier*)**: O avanço na fronteira de prontidão ocorre assim que as dependências causais diretas de uma frente forem satisfeitas e consumidas: o consumo das dependências A e Bprep autoriza o lançamento imediato de Btail mesmo enquanto uma frente não relacionada C permanecer não consumida (*actual A/Bprep consumed means Btail may launch while C unconsumed*). O prefixo seguro deve distinguir explicitamente preparação somente leitura (*read-only preparation*) de edições dependentes e asserções de teste (*dependent edits / test assertions*), preservando rigorosamente os gates de modo (*preserve mode gates*, como gates explícitos de `IMPL.PHASE` e delivery review), sem nunca adivinhar schemas desconhecidos (*never guess unknown schema*; fail-closed sob inconsistência).
  - **Reutilização Versionada de Dependências e Invalidação Seletiva (*Versioned Consumed Dependency Reuse & Selective Invalidation*)**: Resultados de dependências consumidas são versionados e reutilizados por frentes a jusante sem reexecução redundante, governados por conjunto de leitura (*readset*), hashes de fontes (*source hashes*) e revisão consumida (*consumed revision*). A invalidação seletiva não se limita a entradas upstream diretas: alterações nas próprias entradas (*own input changes*), alterações de política (*policy changes*) ou alterações contratuais (*contract changes*) também invalidam a dependência consumida. A invalidação propaga-se estritamente aos dependentes transitivamente afetados (*transitively affected dependents only*), enquanto frentes independentes e inalteradas retêm seu estado e reutilização sem reexecução (*unchanged independent retain*).
  - **Ciclo de Fechamento de Escritores (*Writer Closure Cycle*)**: Escritores permanecem abertos até a revisão de entrega independente: a aprovação independente de entrega autoriza writers abertos ociosos com jobs consumidos (`independent approval allows idle open writers with consumed jobs`), mas escritores não podem ser fechados antes da revisão de entrega (`cannot close writers before review; no writer premature close`). O commit de entrega e a resposta final `DONE` exigem o encerramento formal de todos os agentes e obrigações pendentes (`commit/final requires closure`).
  - **Invariante de Semântica e Schema**: Sem agentes fixos, sem alteração de semântica do bridge nem de schemaVersion (`no fixed agents, no bridge semantics/schema`).
- **Fan-Out Lógico Elástico e Perfis de Agente**:
  - Opera com fan-out lógico elástico (*elastic logical fan-out*), sem mínimo nem máximo de agentes na política (*no min/max agents in policy*), sem número fixo de agentes.
  - O número de agentes e frentes é governado dinamicamente por custo, dependências, exclusividade de recursos, risco de integração e latência.
  - Readers podem fan-out (*readers can fan out*); writers apenas com ownership disjunto, worktrees ou recursos exclusivos (*disjoint ownership, worktrees, or exclusive resources*; writers continuam exigindo ownership disjunto), sem concorrência desordenada.
- **Backpressure Físico e Preflight Gate**:
  - O backpressure e créditos físicos pertencem ao bridge (*backpressure/credits belong to bridge; adaptive physical credit/backpressure safety*); o parent gerencia a topologia lógica.
  - Preflight swarm operacionalmente inequívoco: sob o backend `deepseek`, o parent deve confirmar tanto que `subagents_spawn_batch` está callable quanto que a superfície autoritativa de status/health do bridge anuncia capability `batch_scheduler` (*batch scheduler capability*); ausência ou inconsistência bloqueia com falha fechada (*fails closed if absent or inconsistent*), jamais rebaixando para aggressive sem comando explícito (sem fallback silencioso para aggressive). O helper PowerShell isolado modela a verificação mas não deve ser apresentado como se sozinho provasse o daemon real em runtime.
  - Sob `deepseek`, `subagents_spawn_batch` (alias `deepseek_spawn_batch`) é a tool canônica para ondas do DAG no swarm, enquanto o spawn unitário `subagents_spawn` continua válido fora de ondas ou para uma única frente.
  - O backend native respeita capacidade exposta (*native respects exposed capacity*).
- **Dynamic Wake e Barreira de Suspensão**:
  - Sob `subagent_continuation = park_and_wake`, despacha frentes independentes da onda e arma barreira com predicados determinísticos `REQUIRED`, `QUORUM`, `ALL` e `ANY`.
  - Jobs que não acordam continuam obrigações (*unawakened jobs remain obligations*) e devem ser consumidos e encerrados antes da conclusão.
- **Rollback Seguro e Versionamento**:
  - Rollback seguro: antes de instalar/downgrade para uma versão legada que não conheça swarm, trocar explicitamente para aggressive (`.\scripts\switch-subagent-policy.ps1 -Policy aggressive`).
  - Não aumente schemaVersion (*no schemaVersion bump*); o schema de estado permanece na versão 5.

---

## 5. Delegação no Estado Implícito ALINHAMENTO

No ALINHAMENTO (estado implícito quando não há modo explícito de workflow ativo):
- **Conversa Simples e Sem Cerimônia**: Permanece direta no parent GPT sem spawn de subagentes, sem cerimônia de workflow (sem planos formais, specs, todo lists, gates ou classificação de delivery), sem narrar roteamento interno e sem inspeção do repositório a menos que haja dependência material real. Respostas em português do Brasil compacto com confirmação curta de entendimento. Em transcrições de áudio, normaliza ruído óbvio com premissas explícitas, perguntando apenas se houver ambiguidade material. Quando ação for o próximo passo, recomenda o modo explícito exato de workflow.
- **Delegação Condicional Somente Leitura**: Subagentes são autorizados condicionalmente exclusivamente para tarefas de inspeção somente leitura do repositório quando a resposta depender materialmente do repositório e a escala do repositório, frentes de busca concorrentes e independentes ou compressão volumosa de contexto trouxerem ganho material de velocidade ou qualidade.
- **Escopo e Restrições**: Devem utilizar estritamente o backend global selecionado (`subagent_backend`), capacidade estritamente `analyze`/`read`, sem fallback de backend, sem acionar ferramentas/ativações que criem metadados ou estado no workspace (falha fechado se a leitura exigir mutação), seguindo o ciclo normal de ledger de requisições, consumo e fechamento de lifecycle. A estratégia nunca concede escrita; vigora estritamente somente leitura.
- **Estreitamento da Política**: Esta regra constitui um estreitamento delimitado e uma exceção às políticas `aggressive` e `swarm` apenas sob `ALINHAMENTO`; execuções sob modos explícitos de workflow retêm integralmente a política configurada (`balanced`, `aggressive` ou `swarm`).

---

## 6. Persistência de Sessão vs. Recuperação

- **Continuação Normal (Persistência de Trilha)**:
  - Uma trilha persistente continua normalmente o mesmo agente/sessão aberto com `subagents_continue` (compatível com `deepseek_continue` e compatibilidade com aliases `deepseek_*`), sem usar `allow_respawn`.
- **Recuperação Excepcional (`allow_respawn=true`)**:
  - O uso de `allow_respawn=true` é estritamente uma operação de recuperação pós-fechamento após um agente ter sido encerrado com um resultado terminal persistido válido.
  - Restrito ao mesmo pedido, escopo, cwd, ownership e modelo originais.
  - Nunca deve ser utilizado ou descrito como método rotineiro de persistência de sessão.
  - Recuperação de jobs `running`, abortados ou sem resultado terminal persistido permanece estritamente proibida.

---

## 7. Instalação e Escopo de Configuração

- A instalação global preserva/instala a flag selecionada como aggressive, balanced ou swarm na configuração de usuário (`~/.codex/config.toml`).
- Não injeta flags em repos consumidores: repositórios de trabalho e projetos dos usuários nunca recebem flags injetadas ou arquivos de configuração no workspace.

---

## 8. Matriz de Decisão Rápida

| Critério | `balanced` (Padrão) | `aggressive` | `swarm` (Adaptive Swarm) |
| :--- | :--- | :--- | :--- |
| **Meta Principal** | Menor tempo total de entrega (*wall-clock time*) | Menor consumo de tokens do parent GPT (*token offload*) | Pulverização dinâmica em ondas do DAG (*DAG waves*), maximizando paralelismo útil por estilhaçamento de tarefas E fases/testes/revisões independentes |
| **Papel do Parent** | Executor direto no caminho crítico e integrador | Arquiteto, decisor, integrador e gatekeeper | Único orquestrador, decisor, integrador e gatekeeper (síntese exclusiva GPT-only) |
| **Trabalho Sequencial/Coeso** | Executado diretamente pelo Parent GPT se eficiente | Delegado a subagente persistente por frente coesa | Mesma trilha persistente para frentes coesas |
| **Pesquisa e Exploração** | Híbrida: direta se concisa, delegada se ampla/volumosa | Sempre delegada | Ondas paralelas de readers com fan-out elástico |
| **Escrita e Edição** | Direta se linear/crítica, delegada se paralelizável | Sempre delegada (sem refazer bulk delegado) | Writers com ownership disjunto ou worktrees |
| **Revisão e Validação** | Validação determinística direta + revisão por modo | Validação e revisão via subagentes dedicados | Validação e revisão desacopladas da onda |
| **Backend de Execução** | Determinado por `subagent_backend` | Determinado por `subagent_backend` | Preflight batch scheduler (deepseek: subagents_spawn_batch callable + capability batch_scheduler na superfície autoritativa de status/health) ou capacidade exposta (`native`) |
| **Fan-Out de Delegação** | Condicional (paralelismo real / risco / contexto) | Exaustivo em lote para frentes independentes | Elástico sem min/max/faixa fixa; agentes tratados como efetivamente gratuitos sem conservar contagem; todas as frentes prontas em onda antes de esperar |
