# Delivery Quality Review Gate

Este documento define o módulo invariante de qualidade de entrega (*delivery review gate*), aplicável obrigatoriamente a todos os modos de escrita de código do Codex Workflows Kit.

---

## 1. Escopo e Invariância

O módulo de qualidade de entrega é um portão de qualidade embutido e invariante, sendo estritamente **ortogonal às flags** e seletores globais (`subagent_backend`, `delegation_policy`, `subagent_strategy` e `subagent_continuation`), operando de forma invariável independentemente da configuração ativa.

Exige validação determinística prévia, congelamento formal do alvo com identidade determinística invariante a staging, prova operacional em tempo de execução (*operational/runtime proof*) quando houver gatilho de risco, avaliação pelo Gate de Adequação da Correção orientada à correção suficiente e sustentável/delimitada e exatamente um revisor independente único por alvo congelado (*single independent reviewer* por *frozen target*), sem que o revisor final único e integrado proíba o estilhaçamento (*sharding*) independente útil de validações determinísticas ou revisões parciais intermediárias (*final unique integrated reviewer does not prohibit useful intermediate independent sharding*). Reparos bloqueantes geram um lote de reparo consolidado no mesmo writer. Revalidações subsequentes realizam uma closure review de delta sobre as correções e o blast radius afetado, revalidando a integridade e target_id. O processo ocorre sem R.A.F.V. automático; o modo `R.A.F.V` permanece estritamente manual sob demanda, nunca automático.

Sob `subagent_continuation = park_and_wake`, quando a execução de revisão ou reparo envolver jobs delegados a subagentes: após concluir todo o trabalho local útil do parent (*after all useful parent work ends*), o parent despacha as frentes em lote, drena o trabalho local útil antes de armar e emite mensagem visível de suspensão ao usuário com a condição determinística de retomada. O encerramento da run com obrigações pendentes é permitido exclusivamente no estado não-terminal `SUSPENDED` após obtenção de `ParkReceipt` armado durável no bridge (sem espera no turno / *zero in-turn wait* e sem polling). Quando o predicado da barreira for satisfeito, vigora o contrato dual comprovado de retomada via CLI (*proven dual CLI wake contract*): para sessão carregada no Desktop (*loaded Desktop session*), enfileira um marcador de metadados com `codex queue` para que o App inicie automaticamente a próxima run; para sessão descarregada (*unloaded session*), utiliza `codex exec resume`, aplicando roteamento determinístico de erro queue-first (*queue-first deterministic error routing*). A carga transportada é estritamente um marcador de metadados confiáveis (sem saída bruta de workers / *no raw worker output*), sem retomada automática de metas pausadas (*no automatic goal resume*), com exatamente uma retomada por geração coalescendo conclusões e supersessão de gerações anteriores descartando marcadores obsoletos. As obrigações de follow e close ocorrem exclusivamente após a retomada (*follow/close obligations only after wake*): ao acordar na nova run iniciada via CLI na mesma task exata, o parent consome com `subagents_follow` os jobs prontos e encerra agentes com `subagents_close`. Estados de falha (recibo desarmado ou `deliveryMode = none`) mantêm o parent ativo; falhas irrecuperáveis de CLI wake bloqueiam; e `active writer` é tratado como entrega diferida durável (`deferred_active_writer`), sendo proibido auto-archive/auto-unload. A aprovação independente de entrega (`APPROVED`) autoriza e aceita writers abertos ociosos com todos os seus jobs aceitos consumidos e avaliados na revisão (*independent approval allows idle open writers with consumed jobs*), permitindo que o mesmo writer permaneça disponível para receber o lote consolidado de correções caso o veredito seja `BLOCKED`. O gate de commit de entrega e a resposta final `DONE` permanecem estritamente impossíveis e bloqueados até que todas as obrigações e jobs sejam consumidos e todos os agentes e trilhas sejam formalmente encerrados (`commit/final requires closure`).

### Modos Aplicáveis:
- `IMPL.AUTO`
- `IMPL`
- `IMPL.PHASE`
- `DELIVER.AUTO`
- `BUG.FIX`
- `DEBUG`

O modo `R.A.F.V` permanece estritamente um modo manual separado acionado explicitamente pelo usuário sob demanda, nunca sendo executado automaticamente como parte deste fluxo padrão pós-entrega.

---

## 2. Fluxo Sequencial de Execução

O processo de revisão de entrega ocorre imediatamente após a conclusão do trabalho de implementação e segue rigorosamente a sequência:

```
[Validação Determinística]
         │
         ▼
[Congelamento do Alvo (Frozen Target)]
         │
         ▼
[Prova Operacional Delimitada (quando houver gatilho de risco)]
         │
         ▼
[Revisão Independente Estruturada (5 Pilares: Alvo + Runtime)]
         │
         ├───► [Veredito: APPROVED] ──► [Commit de Entrega Fechado]
         │
          └───► [Veredito: BLOCKED]
                      │
                      ▼ (Reparo Orientado a Evidência / Anti-Loop Ledger)
               [Lote Único Consolidado de Reparo]
                      │
                      ▼
               [Revalidação & Delta Re-Revisão]
```

---

## 3. Especificação do Alvo Congelado (*Frozen Target*)

Antes de submeter o trabalho à revisão independente, o alvo deve ser formalmente congelado registrando:
- **Baseline**: estado inicial do repositório antes do início da tarefa (commit SHA base, branch, upstream).
- **Status de Conteúdo Relativo ao HEAD (`head_status`)**: status exato de conteúdo relativo ao HEAD para os arquivos pertencentes ao escopo da frente (`M`, `A`, `D`), independente de colocação no index/stage.
- **Diff Integrado / Patch SHA256 (`diff_sha256`)**: diff integrado contra o HEAD e hashes de arquivos novos/não-rastreados pertencentes ao escopo e seu hash SHA256.
- **Hashes SHA256 por Arquivo (`file_sha256`)**: mapa ordenado de caminhos e hashes SHA256 do conteúdo de cada arquivo modificado ou criado no escopo.
- **Evidência de Validação Determinística (`validation`)**: logs, saídas e comandos exatos de teste e checagem de formatação e integridade (`git diff --check`).
- **Evidência de Working Tree / Porcelain (`raw_porcelain`)**: estado bruto de porcelain/index capturado como evidência observacional, explicitamente fora do digest.

### Identidade do Alvo (`target_id`):
O `target_id` é obrigatoriamente um digest determinístico (SHA256) derivado da identidade do baseline + status de conteúdo relativo ao HEAD (`head_status`) + `diff_sha256` integrado + mapa ordenado `file_sha256` (SHA256). A identidade do alvo é estritamente **invariante a staging** (*staging-invariant*), **invariante ao code page do host** (*host-code-page-invariant*) e **sensível a conteúdo** (*content-sensitive*): a colocação dos arquivos no index (`git add`) não altera o `target_id`, pois a colocação no index é excluída do digest, e stdout textual do Git usado no digest é normalizado como UTF-8. É estritamente proibido o uso de identificador baseado apenas em timestamp (`never timestamp-only`).

A árvore de trabalho permanece estritamente congelada durante a revisão. Qualquer edição concorrente de conteúdo invalida o alvo e exige novo congelamento e revalidação.

---

## 3.1. Portão de Prova Operacional em Tempo de Execução (*Operational / Runtime Proof Gate*)

Após o congelamento do alvo (`target_id`) e antes da revisão independente, deve ser coletada uma prova operacional delimitada (*bounded scoped operational proof*) no alvo exato congelado sempre que houver gatilho de risco.

### Gatilhos de Risco (*Trigger Conditions*):
A prova operacional é obrigatória única e exclusivamente quando a entrega congelada afetar:
1. **Processo, Daemon ou Serviço Ativo (*live process/daemon/service*)**: inicialização de listeners, ciclo de vida, sinais de término, readiness probes e health checks.
2. **Persistência de Dados ou Migração (*persistence or migration*)**: esquemas relacionais, transações, locks, WAL, integridade referencial e reconciliação com bancos legados.
3. **Concorrência e Semântica Exata (*concurrency/exactly-once*)**: race conditions, processamento paralelo, spool durável, recuperação e proteção contra duplicidade.
4. **Roteamento de Provedores ou Modelos (*provider/model routing*)**: matriz de backends, handshakes de transporte, timeouts e tratamento de falhas.
5. **Integração Externa (*external integration*)**: contratos de APIs externas, protocolos de rede e subprocessos gerenciados.
6. **Comportamento Sensível a Escala e Volume (*behavior sensitive to realistic data volume/resource scale*)**: algoritmos, filtros, ordenações, starvation de recursos ou operações síncronas sob volume de dados representativo do ambiente real.

*Escopo de Aplicação dos Gatilhos*: Os gatilhos aplicam-se unicamente a processos em execução, daemons de background, persistência real em disco/banco ou serviços de rede ativos no host; funções estáticas puras, rotinas utilitárias e testes unitários sem servidores ativos não disparam prova operacional.

### Evidência Observada e Não Configuração (*Observed Evidence, Not Config*):
A prova operacional deve consistir estritamente em evidência observada em tempo de execução (*observed runtime evidence*), nunca em inspeção estática de configurações ou suposições. Deve capturar:
- Latência de inicialização e prontidão de processos e rotas (ex.: medição de tempo de resposta de `GET /health` e readiness probes).
- Estado persistente verificado e comportamento sob volume/escala de dados representativo.
- Identidade exata do artefato/binário em execução comprovando que corresponde ao `target_id` congelado.

### Regra de Falha Fechada (*Fail Closed on Missing / Unsafe / Unauthorized Proof*):
Se a prova operacional exigida for indisponível, insegura, não-autorizada pelo usuário ou não-representativa da escala real:
- É expressamente proibido inventar evidências ou presumir aprovação (*never invent, never assume pass*).
- O veredito da revisão permanece obrigatoriamente **`BLOCKED`** até que a prova empírica seja apresentada ou o usuário aprove explicitamente a alteração de escopo ou limitação documentada.
- É estritamente proibido ampliar autoridade implicitamente (*never broaden authority*) ou executar ações destrutivas ou em produção sem autorização explícita.

### Rejeição de Falso-Verde Estático:
O revisor independente deve obrigatoriamente rejeitar falsos-verdes estáticos (*static-only / test-only false greens*). Cobertura unitária ou validação determinística verde não substitui a prova operacional quando qualquer gatilho de risco estiver presente.

---

## 3.2. Gate de Adequação da Correção (*Correction Adequacy Gate*)

O Gate de Adequação da Correção é um portão de qualidade transversal para defeitos e entregas, que substitui formalmente a meta semântica de "correção mínima" por **"correção suficiente e sustentável/delimitada"**.

### Princípios e Substituição Semântica:
- **Correção Suficiente**: atinge e elimina comprovadamente a causa-raiz identificada, prevenindo recorrências do mesmo defeito.
- **Sustentável**: preserva a integridade estrutural do subsistema sem acumular débito técnico oculto nem adotar patches paliativos frágeis.
- **Delimitada**: respeita estritamente o limite de *blast radius* (apenas os caminhos aprovados do escopo), o portão de refatoração oportuna (`tn-paydown-gate`), o portão de replanejamento (`replan-gate`), a política de reparo orientada a evidência e o registro obrigatório em `.scratchpad/debug_ledger.md` (anti-loop: hipótese testável, observação discriminante esperada, delta observado e próxima decisão; admissão distingue nova hipótese e observação esperada antes de delta versus pós-resultado com delta/falsificação; ausência de delta ou informação exige direção diagnóstica diferente, nunca retentativa idêntica ou proliferação de worker swarm; sem limite numérico fixo ou contadores disfarçados).

### Eventos de Acionamento (*Event Triggers*):
O gate é acionado estritamente em eventos determinísticos (**nunca a cada turno**, sem *per-turn polling* ou *turn chatter*) e opera **sem trocar automaticamente de modo** (a transição de modo permanece prerrogativa explícita do usuário):
1. **`pre-first-edit` (Antes da primeira edição com bug)**: acionado antes de iniciar modificações no código para corrigir defeito, classificando a causa-raiz e o tipo de intervenção necessária.
2. **`falha` (`failure`)**: acionado ao observar falha em teste determinístico, quebra de build ou regressão durante o ciclo de correção.
3. **`causa estrutural` (`structural cause`)**: acionado ao constatar que o defeito decorre de modelo de dados inadequado, quebra de contrato arquitetural ou débito causal profundo.
4. **`expansão de escopo` (`scope expansion`)**: acionado ao detectar necessidade de alterar arquivos ou contratos além dos caminhos originalmente atribuídos.
5. **`pré-revisão` (`pre-review`)**: acionado imediatamente antes de congelar o alvo para a revisão independente de entrega.

### Taxonomia de Decisões de Adequação:
1. **`LOCAL_FIX`**: causa-raiz restrita a um único ponto ou função local, sem impacto arquitetural; correção direta no mesmo componente com validação direcionada.
2. **`ROBUST_FIX`**: causa-raiz exige tratamento defensivo e sustentável no componente dentro do blast radius aprovado; paydown pré-existente só sob `tn-paydown-gate`.
3. **`REWORK`**: causa-raiz estrutural ou design inadequado onde fixes incrementais degradam a arquitetura; interrompe edições e recomenda o modo explícito `REWORK` para roadmap de reengenharia sustentável.
4. **`RESEARCH`**: causa-raiz desconhecida ou dependente de incerteza técnica externa; recomenda o modo explícito `RESEARCH.DEEP` para investigação em fontes primárias antes de novas edições.
5. **`RESEARCH_THEN_REWORK`**: incerteza externa combinada com necessidade de redesenho estrutural; recomenda `RESEARCH.DEEP` seguido de `REWORK`.
6. **`BLOCKED`**: violação de invariantes, ausência de prova operacional obrigatória sob gatilho de risco, bloqueio genuíno de autoridade, acesso ou decisão do usuário, ausência de caminho seguro acionável, ou tentativa de retentativa sem evidência/delta; falha fechado.

### Fronteira de Transporte Neutro do Bridge MCP:
O SubAgents MCP e o daemon bridge permanecem estritamente como **transporte neutro** (`neutral transport`). Reutilizam contratos existentes (`EvidenceBundle`, `ExecutionReceipt`, `ProgressSnapshot`, heartbeat, lease, fence tokens, relations `correction` e `review`). Nenhuma regra de workflow, lógica de portão de adequação ou poder de decisão/aprovação reside no bridge (**nenhuma regra de workflow ou aprovação no bridge**).

### Estratégia de Subagentes (`critical` vs `worker`):
- Sob `subagent_strategy = critical`: GPT e Gemini analisam independentemente a causa-raiz e proposta de correção, trocam evidências, contradições e lacunas, e submetem à síntese GPT mandatória pelo parent GPT, sem edição concorrente e com fencing estrito de escopo. Pinned routing sem troca automática de rota/provedor.
- Sob `subagent_strategy = worker`: o worker mantém o fluxo atual auxiliando o parent com avaliação pontual nos eventos do gate.
- Ambas as estratégias nunca concedem escrita em modos no-write ou no ALINHAMENTO.

---

## 4. Revisão Independente e os 5 Pilares Explícitos

O revisor independente deve ser obrigatoriamente um não-autor em um contexto limpo e isolado somente leitura. Ele realiza a reconstrução dos requisitos originais do usuário e do mapa de alegações (*claim-map*) e avalia o alvo congelado e a prova operacional observada cobrindo obrigatoriamente os **5 pilares explícitos**. A existência de um revisor final integrado e único por alvo congelado não proíbe o estilhaçamento (*sharding*) intermediário independente útil de checagens, testes determinísticos ou auditorias parciais (*final unique integrated reviewer does not prohibit useful intermediate independent sharding*):

1. **Pilar 1: Requisitos e Completude (*Requirements / Completeness*)**
   - Conformidade rigorosa com a solicitação do usuário e o mapa de alegações.
   - Ausência de omissões de escopo ou funcionalidades incompletas.

2. **Pilar 2: Caminhos Primários, Alternativos e Compatibilidade Histórica (*Primary + Alternate + Historical Compatibility Paths*)**
   - Corretude do caminho principal de execução.
   - Robustez de caminhos alternativos e compatibilidade com fluxos legados ou dados históricos.

3. **Pilar 3: Casos Negativos, Falhas, Concorrência e Segurança (*Negative / Failure / Concurrency / Security*)**
   - Tratamento adequado de erros, entradas inválidas e estados de falha.
   - Ausência de condições de corrida, concorrência insegura, comandos destrutivos ou vazamento de segredos.

4. **Pilar 4: Robustez de Testes, Prova Operacional e Resistência a Falso-Verde (*Test Strength, Operational Proof & False-Green Resistance*)**
   - Cobertura de testes focada no comportamento alterado e validação determinística.
   - Presença e conformidade da prova operacional em tempo de execução (*operational/runtime proof*) quando acionada por gatilhos de risco (processo ativo, persistência, concorrência, roteamento, integração externa ou escala/volume de dados).
   - Resistência comprovada a falsos-positivos (*false greens*), rejeitando explicitamente aprovações baseadas apenas em testes estáticos (*static-only/test-only false greens*) diante de mudanças operacionais.

5. **Pilar 5: Integração, Invariantes, Retrocompatibilidade e Escopo (*Integration / Invariants / Backcompat / Scope*)**
   - Preservação de padrões locais e contratos de arquitetura do repositório.
   - Ausência de refatorações cosméticas não solicitadas, dependências desnecessárias, arquivos órfãos ou alterações fora de escopo.

---

## 5. Esquema Estruturado do Pacote de Revisão (*Review Packet Schema*)

O revisor emite formalmente um pacote de revisão estruturado contendo:

```json
{
  "target_id": "sha256-deterministic-digest-over-staging-invariant-target-identity",
  "target_evidence": {
    "baseline": "commit-sha-or-base-identity",
    "head_status": { "path/to/file": "M | A | D" },
    "diff_sha256": "sha256-of-integrated-diff",
    "file_sha256": { "path/to/file": "hash..." },
    "validation": "test_command_output_and_commands",
    "raw_porcelain": "git-status-porcelain-observational-evidence-outside-digest",
    "operational_proof": {
      "triggered": true,
      "triggers": ["live process/daemon/service", "data volume/resource scale"],
      "observed_evidence": "GET /health readiness latency < 500ms observed against 3.3M event store",
      "artifact_identity": "sha256-of-executed-target"
    }
  },
  "verdict": "APPROVED | BLOCKED",
  "pillar_checks": {
    "P1_requirements": "PASS | FAIL: justificativa",
    "P2_compatibility_paths": "PASS | FAIL: justificativa",
    "P3_negative_security": "PASS | FAIL: justificativa",
    "P4_test_strength": "PASS | FAIL: justificativa (inclui prova operacional quando exigida)",
    "P5_integration_scope": "PASS | FAIL: justificativa"
  },
  "blockers": [
    {
      "id": "BLK-01",
      "claim": "alegação violada",
      "path": "caminho/do/arquivo",
      "evidence": "evidência observada",
      "reproduction": "passos para reprodução do defeito",
      "required_fix": "correção necessária para remover o bloqueio e satisfazer a adequação suficiente e sustentável/delimitada"
    }
  ],
  "advisories": [
    "observação não impeditiva 1"
  ]
}
```

---

## 6. Ciclo de Reparo Consolidado (quando `BLOCKED`)

- **Lote Único Consolidado no Writer**: Todos os bloqueios identificados no pacote de revisão são consolidados em um lote de reparo consolidado no mesmo writer que executou a implementação original.
- **Correção Suficiente e Sustentável/Delimitada**: O executor aplica a correção necessária para eliminar a causa-raiz de forma sustentável e satisfazer a adequação sem remendos paliativos, mantendo estritamente o limite de blast radius, `tn-paydown-gate`, `replan-gate` e a política de reparo orientada a evidência.
- **Política de Reparo Orientada a Evidência (*Evidence-Based Repair Policy*)**:
  - **Continuidade por Evidência Útil e Distinção entre Admissão e Pós-Resultado**: A continuidade do reparo é governada pela produção de novas evidências úteis e hipóteses testáveis, nunca por um contador numérico arbitrário. Terceira rodada de reparo ou tentativas subsequentes são expressamente permitidas e admitidas enquanto houver nova hipótese testável distinta. Distingue-se formalmente a admissão pré-execução do registro pós-resultado:
    - **Fase de Admissão Pré-Execução (*Admission*)**: Para admitir qualquer tentativa de reparo proposta (incluindo terceira rodada ou subsequentes), o executor deve formular uma nova hipótese testável distinta (*new distinct testable hypothesis*), definir uma observação discriminante esperada (*expected discriminating observation*) e planejar um experimento seguro autorizado (*authorized safe experiment*). Na admissão pré-execução, o delta observado ainda não está disponível (*observed delta not yet available*); exigir delta antes da execução é um erro conceitual e de desenho que impediria novos experimentos legítimos. A admissão é aprovada desde que haja caminho seguro e hipótese distinta em direção diagnóstica não-estagnada.
    - **Fase de Registro Pós-Resultado (*Post-Result*)**: Após executar o experimento autorizado, registra-se a evidência observada (*observed evidence*) como delta observado (*observed delta*). Hipótese falsificada ou estreitamento de possibilidades causais (*falsified hypothesis or narrowed possibilities*) conta validamente como informação útil (*counts as information*), mesmo que o sintoma superficial permaneça o mesmo. Apenas a retentativa idêntica sem informação nova (*identical no-information retry*) em mesma direção estagnada é estritamente proibida e exige mudança mandatória de abordagem (*change approach* para direção diagnóstica diferente ou replanejamento).
  - **Ledger Anti-Loop Obrigatório (`.scratchpad/debug_ledger.md`)**: A cada tentativa de reparo, o executor deve obrigatoriamente registrar quatro campos estruturados:
    1. **Hipótese (*hypothesis*)**: explicação testável, fundamentada e distinta do mecanismo da falha ou bloqueio (definida na admissão).
    2. **Observação Discriminante Esperada (*expected discriminating observation*)**: resultado mensurável e específico esperado se a hipótese for verdadeira (definida na admissão).
    3. **Delta Observado (*observed delta*)**: variação concreta e verificável nas evidências, logs, testes ou comportamento do sistema após a intervenção, incluindo hipótese falsificada ou possibilidades estreitadas (registrado no pós-resultado).
    4. **Próxima Decisão (*next decision*)**: avanço para validação, congelamento de novo alvo, nova hipótese distinta ou mudança de rota.
  - **Ausência de Delta Exige Mudança de Direção Diagnóstica**: Constatada ausência de delta ou informação nova (falha idêntica ou estagnação sem novas evidências nem estreitamento de hipótese), é estritamente proibida retentativa idêntica (*duplicate retry*) ou proliferação cega de agentes via worker swarm. Exige-se mudança mandatória para uma direção diagnóstica diferente (*different diagnostic direction*) ou transição para replanejamento (`replan-gate` / decisão `REWORK` ou `RESEARCH`).
  - **Critérios Estritos de Parada (*Stop Conditions*)**: A interrupção e falha fechada (*fail closed* / `BLOCKED`) ocorrem **única e exclusivamente** sob:
    1. Bloqueio genuíno de autoridade, credenciais/acesso externo ou decisão de negócio do usuário que não possa ser resolvida no escopo concedido.
    2. Constatação de que não há alternativa viável ou sem caminho seguro acionável (*no safe actionable path forward*). A persistência de bloqueios após tentativas sucessivas sem delta observado ou sem estreitamento causal comprova a inexistência de caminho seguro acionável no escopo concedido, impondo parada imediata em `BLOCKED` e consulta ao usuário para evitar repetições especulativas.
    - É estritamente proibido o uso de limite numérico fixo (como o limite arbitrário anterior de 2 rodadas), substitutos configuráveis ocultos ou contadores numéricos disfarçados de portão semântico.
- **Revalidação Determinística**: Toda a suíte de validação relevante e checagens determinísticas são reexecutadas.
- **Novo Alvo Congelado**: Um novo alvo congelado com `target_id` determinístico invariante a staging e hashes SHA256 atualizados é gerado.
- **Closure Review de Delta**: Uma nova revisão independente (closure review de delta) foca nos bloqueios corrigidos e no raio de impacto afetado (*affected blast radius*), enquanto re-checa e revalida a identidade completa do alvo (`target_id`) e todos os invariantes de integração para evitar regressões (sem restringir a análise exclusivamente ao delta).

---

## 7. Gate de Commit de Entrega

O commit local de entrega é autorizado **única e exclusivamente** quando todas as seguintes condições forem satisfeitas:
1. O veredito da revisão for `APPROVED`.
2. Houver **zero bloqueios** pendentes (`zero blockers`).
3. Imediatamente antes do staging, verificar a identidade do alvo (`target_id`) a partir da árvore de trabalho e exigir igualdade exata com o alvo aprovado na revisão.
4. Realizar o staging exclusivamente dos arquivos pertencentes ao conjunto de caminhos aprovados do escopo.
5. Imediatamente antes do commit, recomputar a identidade invariante a staging (`target_id`) a partir do estado atual da árvore de trabalho e exigir igualdade exata com o alvo aprovado na revisão; verificar se o conjunto de arquivos no stage (*staged path set*) corresponde exatamente ao conjunto de caminhos aprovados; e verificar que cada *staged blob* coincide com o conteúdo aprovado após a normalização do próprio Git, garantindo que nenhum caminho ou conteúdo não-aprovado esteja no index.
6. Todas as obrigações e jobs delegados foram integralmente consumidos e todos os agentes escritores e revisores foram formalmente encerrados (`commit/final requires closure`). Uma vez emitido o veredito `APPROVED`, o parent encerra os writers e revisores abertos (`subagents_close`), satisfazendo o encerramento formal antes de executar o commit e a resposta final `DONE`.
