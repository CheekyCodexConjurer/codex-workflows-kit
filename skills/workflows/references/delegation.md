# Subagent Delegation Policies

Esta referência detalha as duas políticas de delegação globais ortogonais (`balanced` e `aggressive`) e sua interação com os seletores de backend (`native` e `deepseek`) para tarefas e sessões do Codex.

---

## 1. Princípios Gerais e Seletores Ortogonais

Existem quatro seletores globais ortogonais e independentes:

1. **`subagent_backend` (`native` | `deepseek`)**:
   - Governa estritamente a família de ferramentas autorizada para delegação.
   - `native`: autoriza subagentes nativos do Codex (`multi_agent_v1__spawn_agent`/`spawn_agent`/`wait_agent`) com `model="gpt-5.6-luna"`, `reasoning_effort="max"` e modo default/normal (`fast_mode = false`); proíbe contato com o SubAgents MCP. Não requer solicitação explícita prévia do usuário.
   - `deepseek`: autoriza as ferramentas do SubAgents MCP (`subagents_spawn`, `subagents_continue`, `subagents_follow`; compatível com `deepseek_continue` como identificador de continuação legado do backend e compatibilidade com aliases `deepseek_*`); proíbe o uso de ferramentas nativas de trabalho pelo parent.
   - Fixação estrita de rota (*route pinning*): fallback silencioso entre backends é estritamente proibido.

2. **`delegation_policy` (`balanced` | `aggressive`)**:
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
     - **Limites do Bridge**: executado estritamente através do conjunto de ferramentas exposto pelo SubAgents MCP (`subagents_spawn`, `subagents_continue`, `subagents_follow`, etc.), sem prometer capacidades que o bridge ainda não expõe (capabilities that the bridge does not yet expose).

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
  - A janela de 900s é estritamente uma janela mínima e limite de espera (*wait limit*), nunca prova de morte do agente ou processo delegado.
  - O parent deve consultar ativamente status, heartbeat e lease antes de inferir indisponibilidade.
  - Takeover de trilha ou sessão só é autorizado com morte provada do processo/agente anterior; estado `unknown` bloqueia o avanço (*gate open/BLOCKED*).
  - Mecanismos de fence (fence tokens), contador de tentativa (*attempt*) e PID impedem escritas obsoletas (*stale writes*).
  - Quiescência do processo/trilha anterior deve ser rigorosamente provada antes de liberar recursos ou abrir nova tentativa.
  - Sem fallback silencioso de rota, provedor ou modelo.
- **Ledger Estável de Requisições**: O parent GPT mantém um ledger estruturado registrando `request_id`, frente de trabalho, identificador do agente/job, estado (`running`, `completed`, `failed`), status de consumo e encerramento explícito.
- **Permissões Estritas por Modo**: O papel e as capacidades do subagente subordinam-se estritamente à matriz de modos do Codex Workflows Kit.
- **Interpretação de Contexto Visual**: O parent GPT interpreta todo `visual_context` (imagens, capturas de tela, mockups) e sintetiza descrições textuais precisas para o subagente, nunca delegando interpretação visual cega.

---

## 2. Política `balanced` (Padrão)

**Foco Principal**: Otimização do tempo de relógio (*wall-clock time*) e eficiência de fluxo.

- **Comportamento do Parent GPT**:
  - Executa tarefas sequenciais, coesas, de integração e de caminho crítico diretamente no contexto principal quando o round-trip de delegação não traria ganho de tempo.
  - Não há fan-out obrigatório: frentes lineares simples permanecem coesas no parent.
  - Gerencia o fluxo crítico, o mapa de dependências e a síntese final.
- **Gatilhos para Delegação**:
  - **Paralelismo Concreto**: Quando duas ou mais frentes independentes podem ser executadas simultaneamente para reduzir o tempo total de resposta.
  - **Especialização Técnica**: Quando a análise de um subsistema isolado ou execução de diagnósticos se beneficia de contexto focado.
  - **Isolamento de Risco e Blast Radius**: Quando a exploração ou teste de caminhos alternativos deve ser contida sem poluir a árvore principal de trabalho.
  - **Compressão e Eficiência de Contexto**: Quando leituras volumosas de logs, traces ou documentação extensa consumiriam a janela de contexto do parent.

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
  - **Fechamento e Timeouts**: Fatias são desenhadas para fechar terminalmente dentro da janela; após timeout ou ausência de fechamento, continua na mesma trilha pedindo inventário mínimo e fatias pequenas de fechamento (*closure slices pequenos*), sendo proibido repetir integralmente a frente ou abrir novo agente substituto.
  - O parent recebe e sintetiza apenas os resultados terminais estruturados para validar e tomar as decisões de roteamento e aceitação.

---

## 4. Delegação no Estado Implícito ALINHAMENTO

No ALINHAMENTO (estado implícito quando não há modo explícito de workflow ativo):
- **Conversa Simples e Sem Cerimônia**: Permanece direta no parent GPT sem spawn de subagentes, sem cerimônia de workflow (sem planos formais, specs, todo lists, gates ou classificação de delivery), sem narrar roteamento interno e sem inspeção do repositório a menos que haja dependência material real. Respostas em português do Brasil compacto com confirmação curta de entendimento. Em transcrições de áudio, normaliza ruído óbvio com premissas explícitas, perguntando apenas se houver ambiguidade material. Quando ação for o próximo passo, recomenda o modo explícito exato de workflow.
- **Delegação Condicional Somente Leitura**: Subagentes são autorizados condicionalmente exclusivamente para tarefas de inspeção somente leitura do repositório quando a resposta depender materialmente do repositório e a escala do repositório, frentes de busca concorrentes e independentes ou compressão volumosa de contexto trouxerem ganho material de velocidade ou qualidade.
- **Escopo e Restrições**: Devem utilizar estritamente o backend global selecionado (`subagent_backend`), capacidade estritamente `analyze`/`read`, sem fallback de backend, sem acionar ferramentas/ativações que criem metadados ou estado no workspace (falha fechado se a leitura exigir mutação), seguindo o ciclo normal de ledger de requisições, consumo e fechamento de lifecycle. A estratégia nunca concede escrita; vigora estritamente somente leitura.
- **Estreitamento da Política**: Esta regra constitui um estreitamento delimitado e uma exceção à política `aggressive` apenas sob `ALINHAMENTO`; execuções sob modos explícitos de workflow retêm integralmente a política configurada (`balanced` ou `aggressive`).

---

## 5. Persistência de Sessão vs. Recuperação

- **Continuação Normal (Persistência de Trilha)**:
  - Uma trilha persistente continua normalmente o mesmo agente/sessão aberto com `subagents_continue` (compatível com `deepseek_continue` e compatibilidade com aliases `deepseek_*`), sem usar `allow_respawn`.
- **Recuperação Excepcional (`allow_respawn=true`)**:
  - O uso de `allow_respawn=true` é estritamente uma operação de recuperação pós-fechamento após um agente ter sido encerrado com um resultado terminal persistido válido.
  - Restrito ao mesmo pedido, escopo, cwd, ownership e modelo originais.
  - Nunca deve ser utilizado ou descrito como método rotineiro de persistência de sessão.
  - Recuperação de jobs `running`, abortados ou sem resultado terminal persistido permanece estritamente proibida.

---

## 6. Instalação e Escopo de Configuração

- A instalação global preserva/instala a flag selecionada como aggressive (ou balanced) na configuração de usuário (`~/.codex/config.toml`).
- Não injeta flags em repos consumidores: repositórios de trabalho e projetos dos usuários nunca recebem flags injetadas ou arquivos de configuração no workspace.

---

## 7. Matriz de Decisão Rápida

| Critério | `balanced` (Padrão) | `aggressive` |
| :--- | :--- | :--- |
| **Meta Principal** | Menor tempo total de entrega (*wall-clock time*) | Menor consumo de tokens do parent GPT (*token offload*) |
| **Papel do Parent** | Executor direto no caminho crítico e integrador | Arquiteto, decisor, integrador e gatekeeper |
| **Trabalho Sequencial/Coeso** | Executado diretamente pelo Parent GPT se eficiente | Delegado a subagente persistente por frente coesa |
| **Pesquisa e Exploração** | Híbrida: direta se concisa, delegada se ampla/volumosa | Sempre delegada |
| **Escrita e Edição** | Direta se linear/crítica, delegada se paralelizável | Sempre delegada (sem refazer bulk delegado) |
| **Revisão e Validação** | Validação determinística direta + revisão por modo | Validação e revisão via subagentes dedicados |
| **Backend de Execução** | Determinado por `subagent_backend` | Determinado por `subagent_backend` |
| **Fan-Out de Delegação** | Condicional (paralelismo real / risco / contexto) | Exaustivo em lote para frentes independentes |
