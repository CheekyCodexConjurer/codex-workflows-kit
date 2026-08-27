# Delivery Quality Review Gate

Este documento define o módulo invariante de qualidade de entrega (*delivery review gate*), aplicável obrigatoriamente a todos os modos de escrita de código do Codex Workflows Kit.

---

## 1. Escopo e Invariância

O módulo de qualidade de entrega é um portão de qualidade embutido e invariante, sendo estritamente **ortogonal às flags** de backend (`subagent_backend`) e de delegação (`delegation_policy`), operando de forma invariável independentemente da configuração ativa.

Exige validação determinística prévia, congelamento formal do alvo com identidade determinística invariante a staging, prova operacional em tempo de execução (*operational/runtime proof*) quando houver gatilho de risco e exatamente um revisor independente único por alvo congelado (*single independent reviewer* por *frozen target*). Reparos bloqueantes geram um lote de reparo consolidado no mesmo writer. Revalidações subsequentes realizam uma closure review de delta sobre as correções e o blast radius afetado, revalidando a integridade e target_id. O processo ocorre sem R.A.F.V. automático; o modo `R.A.F.V` permanece estritamente manual sob demanda, nunca automático.

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
                     ▼ (Máximo 2 rodadas)
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

## 4. Revisão Independente e os 5 Pilares Explícitos

O revisor independente deve ser obrigatoriamente um não-autor em um contexto limpo e isolado somente leitura. Ele realiza a reconstrução dos requisitos originais do usuário e do mapa de alegações (*claim-map*) e avalia o alvo congelado e a prova operacional observada cobrindo obrigatoriamente os **5 pilares explícitos**:

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
      "required_fix": "correção mínima exigida"
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
- **Correção Mínima**: O executor aplica apenas as correções necessárias para sanar os bloqueios relatados.
- **Revalidação Determinística**: Toda a suíte de validação relevante e checagens determinísticas são reexecutadas.
- **Novo Alvo Congelado**: Um novo alvo congelado com `target_id` determinístico invariante a staging e hashes SHA256 atualizados é gerado.
- **Closure Review de Delta**: Uma nova revisão independente (closure review de delta) foca nos bloqueios corrigidos e no raio de impacto afetado (*affected blast radius*), enquanto re-checa e revalida a identidade completa do alvo (`target_id`) e todos os invariantes de integração para evitar regressões (sem restringir a análise exclusivamente ao delta).
- **Limite Estrito de Rodadas**: É permitido um máximo de **duas rodadas de reparo** (máximo 2 rodadas). Se persistirem bloqueios após a segunda rodada, a operação falha fechado (*fail closed*), interrompendo o pipeline e reportando o status ao usuário.

---

## 7. Gate de Commit de Entrega

O commit local de entrega é autorizado **única e exclusivamente** quando todas as seguintes condições forem satisfeitas:
1. O veredito da revisão for `APPROVED`.
2. Houver **zero bloqueios** pendentes (`zero blockers`).
3. Imediatamente antes do staging, verificar a identidade do alvo (`target_id`) a partir da árvore de trabalho e exigir igualdade exata com o alvo aprovado na revisão.
4. Realizar o staging exclusivamente dos arquivos pertencentes ao conjunto de caminhos aprovados do escopo.
5. Imediatamente antes do commit, recomputar a identidade invariante a staging (`target_id`) a partir do estado atual da árvore de trabalho e exigir igualdade exata com o alvo aprovado na revisão; verificar se o conjunto de arquivos no stage (*staged path set*) corresponde exatamente ao conjunto de caminhos aprovados; e verificar que cada *staged blob* coincide com o conteúdo aprovado após a normalização do próprio Git, garantindo que nenhum caminho ou conteúdo não-aprovado esteja no index.
