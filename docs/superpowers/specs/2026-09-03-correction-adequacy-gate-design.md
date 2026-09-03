# Especificação de Design: Gate de Adequação da Correção (Correction Adequacy Gate)

- **Data**: 2026-09-03
- **Status**: Aprovado
- **Autoridade**: Codex Workflows Kit Architecture
- **Alvo**: `codex-workflows-prompt-pad` (Codex & Antigravity)

---

## 1. Objetivo

Substituir a meta semântica de "correção mínima" por **"correção suficiente e sustentável/delimitada"** em todos os contratos de workflow e revisão de entrega do Codex Workflows Kit.

Em ciclos de desenvolvimento e manutenção assistidos por IA, a insistência míope em "correção mínima" frequentemente induz a soluções superficiais ("patches paliativos", ocultação de sintomas, acoplamento desordenado ou flags ad-hoc) que ignoram a causa estrutural do problema e geram retrabalho cumulativo.

O **Gate de Adequação da Correção** estabelece uma disciplina transversal e determinística para assegurar que qualquer intervenção corretiva seja:
1. **Suficiente**: atinja e elimine a causa-raiz comprovada, prevenindo recorrências do mesmo defeito;
2. **Sustentável**: preserve a integridade arquitetural e a manutenibilidade do código sem acumular débito técnico oculto;
3. **Delimitada**: respeite rigorosamente o raio de impacto (*blast radius*), o orçamento de mudanças pertencentes ao escopo aprovado e as salvaguardas de refatoração oportuna (`tn-paydown-gate`), mantendo o limite estrito de até 2 rodadas de reparo consolidado e o ledger de depuração anti-loops.

---

## 2. Não-Objetivos

Para preservar a segurança, estabilidade e arquitetura existente do kit, ficam formalmente estabelecidos os seguintes não-objetivos:

1. **Sem transporte poluído no SubAgents MCP / Daemon Bridge**: nenhuma regra de negócio de workflow, lógica de validação de qualidade ou portão de adequação é movida para o bridge. O bridge permanece estritamente um transporte neutro.
2. **Sem permissão de escrita em modos somente leitura**: modos sem escrita (`PLAN`, `PLAN.AUTO`, `P.DEEP`, `RESEARCH.DEEP`, `REWORK`, `REVIEW`, `BUG.INV`, `TN.SKILL`) e o estado implícito `ALINHAMENTO` continuam rigorosamente somente leitura (*no-write / read-only*). O gate de adequação nunca concede permissão de escrita nesses modos.
3. **Sem transição automática de modo**: o gate de adequação avalia e recomenda o próximo modo operacional adequado, mas **nunca altera o modo ativo automaticamente**. A transição de modo permanece prerrogativa exclusiva e explícita do usuário.
4. **Sem bypass de prova operacional**: nenhuma decisão de adequação flexibiliza ou substitui a prova operacional em tempo de execução (*operational/runtime proof*) quando acionada por gatilhos de risco (processos ativos, persistência/migração, concorrência, roteamento, integração externa ou escala/volume). Falha fechado (`BLOCKED`) se a prova for indisponível ou não-autorizada.
5. **Sem quebra de esquema JSON**: a chave JSON `required_fix` no schema estruturado de bloqueios (`blockers`) é integralmente preservada para garantir retrocompatibilidade com parsers e clientes existentes.
6. **Sem mutação não-autorizada no workspace**: o gate opera sem criar arquivos temporários, metadados espúrios ou estado no workspace, exceto pelo registro obrigatório do ledger em `.scratchpad/debug_ledger.md` sob defeitos reincidentes em modos de escrita.

---

## 3. Modelo de Dados da Decisão de Adequação

O resultado de uma avaliação pelo Gate de Adequação da Correção é encapsulado em uma estrutura conceitual determinística contendo:

```json
{
  "adequacy_decision": "LOCAL_FIX | ROBUST_FIX | REWORK | RESEARCH | RESEARCH_THEN_REWORK | BLOCKED",
  "evidence": "Evidência empírica observada (logs, saída de testes, stack traces, AST)",
  "confidence": "high | medium | low (com justificativa fundamentada)",
  "root_cause": "Causa-raiz identificada ou hipótese causal comprovada",
  "contradictions": [
    "Contradições identificadas entre documentação, contratos e comportamento real",
    "Lacunas materiais de premissas ou requisitos"
  ],
  "required_validation": "Validação determinística e prova operacional exigidas para comprovar sustentabilidade",
  "owned_scope": [
    "caminho/arquivo/componente estritamente pertencente ao escopo"
  ],
  "deferred_scope": [
    "Débitos preexistentes ou melhorias amplas postergadas para preservar o blast radius"
  ],
  "recommended_mode": "Modo explícito sugerido para o próximo passo (ex.: BUG.FIX, REWORK, RESEARCH.DEEP)"
}
```

### Taxonomia de Decisões:

1. **`LOCAL_FIX`**:
   - *Condição*: Causa-raiz totalmente contida em um único ponto, função ou componente local, sem impacto arquitetural ou efeitos colaterais contratuais.
   - *Ação*: Correção localizada no mesmo writer, mantendo padrões locais e validação direcionada.
   - *Modo Típico*: `BUG.FIX` ou `DEBUG`.

2. **`ROBUST_FIX`**:
   - *Condição*: O defeito requer tratamento sustentável da causa-raiz no componente (ex.: normalização defensiva, invariante explícito, proteção contra race condition local), ainda contido no blast radius aprovado.
   - *Ação*: Correção estruturada e sustentável; se envolver limpeza de débito técnico pré-existente causal, exige aprovação estrita no `tn-paydown-gate`.
   - *Modo Típico*: `BUG.FIX` ou `DEBUG`.

3. **`REWORK`**:
   - *Condição*: A causa-raiz é estrutural, decorre de premissas de design incorretas ou o módulo acumula acoplamento que torna qualquer fix paliativo uma degradação inaceitável.
   - *Ação*: Interrupção de edições pontuais no código; emissão de recomendação para o usuário acionar o modo `REWORK` para roadmap de reengenharia sustentável.
   - *Modo Típico*: Encaminhamento para `REWORK`.

4. **`RESEARCH`**:
   - *Condição*: Causa-raiz desconhecida, dependência de comportamento de biblioteca/API externa não documentada, ou evidência empírica inconclusiva/conflitante.
   - *Ação*: Coleta de evidências em fontes primárias e literatura técnica antes de qualquer tentativa de alteração de código.
   - *Modo Típico*: Encaminhamento para `RESEARCH.DEEP`.

5. **`RESEARCH_THEN_REWORK`**:
   - *Condição*: O problema envolve tanto incerteza técnica externa profunda quanto necessidade de redesenho arquitetural do subsistema afetado.
   - *Ação*: Pesquisa profunda de soluções consagradas seguida de planejamento estruturado de retrabalho.
   - *Modo Típico*: Encaminhamento inicial para `RESEARCH.DEEP` seguido de `REWORK`.

6. **`BLOCKED`**:
   - *Condição*: Violação de invariantes, ausência de prova operacional obrigatória sob gatilho de risco, necessidade de autorização explícita do usuário para operações sensíveis, ou impasse irredutível após 2 rodadas de reparo.
   - *Ação*: Paralisação de escrita imediata (falha fechado); comunicação clara das pendências e opções de decisão humana.

---

## 4. Eventos de Acionamento (Event-Triggered Hard Gates)

O Gate de Adequação da Correção **NUNCA** é acionado a cada turno conversacional (*no per-turn polling / zero turn chatter*). Ele atua exclusivamente em pontos de inflexão operacionais determinísticos:

1. **`pre-first-edit` (Antes da primeira edição em contexto de defeito)**:
   - Acionado imediatamente antes de modificar qualquer arquivo para corrigir um defeito ou bug reportado.
   - Objetivo: Impedir a aplicação impulsiva de soluções paliativas antes de verificar se o problema exige `LOCAL_FIX`, `ROBUST_FIX`, `RESEARCH` ou `REWORK`.

2. **`failure` (Falha inesperada durante ciclo de correção)**:
   - Acionado após falha de teste determinístico, quebra de build ou regressão observada após um patch corretivo.
   - Objetivo: Verificar o `.scratchpad/debug_ledger.md`, impedir repetição de abordagens idênticas/similares e reavaliar se a hipótese causal original estava errada.

3. **`structural-cause` (Descoberta de causa-raiz estrutural)**:
   - Acionado assim que a investigação empírica revela que o defeito decorre de modelo de dados inadequado, concorrência mal sincronizada, vazamento de abstração ou premissa contratual violada.
   - Objetivo: Evitar remendos locais e acionar o `replan-gate` para delimitar adequadamente o trabalho ou recomendar `REWORK`.

4. **`scope-expansion` (Necessidade de expansão de escopo/blast radius)**:
   - Acionado quando a correção do problema aparenta exigir alteração de arquivos ou contratos além dos caminhos originalmente atribuídos (*owned paths*).
   - Objetivo: Avaliar se o paydown é sustentável via `tn-paydown-gate` ou se a mudança deve ser adiada (`tn-defer`) ou planejada via `IMPL.PHASE` / `P.DEEP`.

5. **`pre-review` (Avaliação prévia ao congelamento do alvo para revisão)**:
   - Acionado após a conclusão da implementação e antes do cálculo do `target_id` determinístico e submissão ao revisor independente.
   - Objetivo: Certificar que a solução atinge os critérios de suficiência e sustentabilidade delimitada, preparando o pacote com a chave `required_fix` devidamente qualificada se bloqueios forem encontrados.

---

## 5. Hard Gates e Invariantes de Sustentabilidade

A substituição de "correção mínima" por "correção suficiente e sustentável/delimitada" reforça — em vez de enfraquecer — os seguintes limites e portões invariantes:

### 5.1. Limite Estrito de Blast Radius
- A correção deve atuar estritamente dentro do conjunto de caminhos aprovados (`owned_paths`).
- Proibida alteração de arquivos de configuração, scripts de infraestrutura ou módulos não relacionados a pretexto de "aproveitar a viagem".

### 5.2. Portão de Débito Técnico (`tn-paydown-gate`)
- O saneamento de débito causal pré-existente só é permitido se for bounded (delimitado), comprovadamente causal ao defeito, reversível e validado determinística e isoladamente antes e depois.
- Se qualquer critério falhar: aplicar `tn-defer` obrigatório.

### 5.3. Portão de Replanejamento (`replan-gate`)
- Se a correção sustentável exigir mudanças de arquitetura que extrapolam a capacidade do modo ativo, o executor deve parar no `replan-gate` e recomendar o modo apropriado (`REWORK`, `PLAN` ou `IMPL.PHASE`), proibindo categoricamente improvisações ad-hoc.

### 5.4. Ledger de Depuração Anti-Loop (`debug_ledger.md`)
- Antes de qualquer segunda tentativa de correção de um mesmo defeito, é obrigatório registrar e consultar `.scratchpad/debug_ledger.md` na tabela: `[Tentativa #N] | Causa Assumida | Hash/Sintaxe do Patch | Erro Obtido`.
- É expressamente proibido repetir soluções sintaticamente idênticas ou semanticamente similares às já fracassadas.

### 5.5. Limite Máximo de Duas Rodadas de Reparo
- Em revisões de entrega (`delivery review`), são permitidas no máximo **2 rodadas de reparo consolidado**.
- Se após a segunda rodada persistirem bloqueios, o sistema falha fechado (`fail closed / BLOCKED`) e encerra o pipeline para deliberação humana.

---

## 6. Matriz de Integração por Modo Operacional

O Gate de Adequação da Correção opera transversalmente nos fluxos, preservando a semântica de permissões e as garantias de cada modo:

| Modo | Permissão | Papel no Gate de Adequação |
|---|---|---|
| `ALINHAMENTO` | Somente Leitura | Discussão, refinamento de ideias e identificação de premissas. Zero mutação, zero metadados no workspace. Recomenda modo explícito se ação for necessária. |
| `PLAN` / `PLAN.AUTO` | Somente Leitura | Mapeia requisitos e premissas arquiteturais; sob incerteza ou complexidade estrutural, recomenda `RESEARCH.DEEP` ou `REWORK`. Proibido escrever. |
| `DEBUG` / `BUG.FIX` | Escrita | Diagnóstico de causa-raiz e implementação de correção suficiente e sustentável/delimitada (não paliativa), respeitando blast radius e ledger de debug. |
| `DELIVER` / `IMPL` | Escrita | Implementação de funcionalidades e correções com validação determinística, prova operacional quando acionada e gate de adequação pré-revisão. |
| `REWORK` | Somente Leitura | Elabora roteiro estruturado de redesenho, refatoração arquitetural e substituição sustentável. Proibido implementar diretamente no modo. |
| `RESEARCH.DEEP` | Somente Leitura | Investiga documentação canônica, literatura científica e repositórios para fundamentar decisões de adequação sem alterar código. |
| `COMMIT` | Git-Only | Classifica staged/unstaged/untracked e bloqueia sem alterar o index na presença de artefatos espúrios/locais/segredos. Não altera arquivos nem índices MCP. |

---

## 7. Estratégia de Subagentes: `critical` vs `worker`

A execução do Gate de Adequação da Correção integra-se à configuração de `subagent_strategy`:

### Sob `subagent_strategy = critical`:
- GPT e Gemini analisam independentemente o defeito, a causa-raiz e a proposta de correção.
- Ambos os modelos trocam formalmente evidências coletadas, identificando divergências, contradições e lacunas de cobertura.
- Síntese GPT mandatória conduzida pelo parent GPT antes de qualquer decisão de prosseguimento.
- Fencing estrito de escopo de arquivo e proibição absoluta de edição concorrente entre agentes.
- Pinned routing sem fallback silencioso de provedor ou modelo.
- Nunca concede permissão de escrita em modos somente leitura ou no ALINHAMENTO.

### Sob `subagent_strategy = worker` (padrão):
- O subagente worker executa o fluxo assistivo convencional subordinado ao parent GPT sob a política de delegação ativa (`balanced` ou `aggressive`).
- A avaliação de adequação da correção é realizada de forma pontual no ciclo de vida do worker (nos eventos de pre-first-edit, falha e pré-revisão), sem a rodada cruzada de contradições entre modelos distintos.

---

## 8. Fronteira do SubAgents MCP / Bridge

O SubAgents MCP e o bridge daemon operam estritamente como camada de **transporte neutro**:
1. **Reutilização de Contratos Existentes**:
   - `EvidenceBundle`: transporte estruturado de diffs, saídas de validação e hashes.
   - `ExecutionReceipt`: recibo determinístico de despacho e consumo de jobs.
   - `ProgressSnapshot`: acompanhamento de progresso semântico sem polling agressivo.
   - Heartbeat, lease e fence tokens: garantias de liveness e exclusão de stale writes.
   - Relações semânticas `correction` e `review`.
2. **Isolamento de Políticas**:
   - Nenhuma lógica do Gate de Adequação da Correção, regras de decisão (`LOCAL_FIX`, `ROBUST_FIX`, etc.) ou critérios de aprovação/rejeição residem no bridge.
   - Toda a inteligência de orquestração, avaliação de completude e veredito permanece concentrada no parent GPT e nas políticas locais versionadas (`skills/workflows/`).

---

## 9. Compatibilidade de Esquema e Semântica de `required_fix`

Para garantir compatibilidade regressiva total com parsers de revisão estruturada:
1. O campo `"required_fix"` permanece obrigatoriamente presente em cada entrada do array `"blockers"` no schema do pacote de revisão estruturado de `delivery-review.md`.
2. A semântica descritiva do campo é formalmente atualizada:
   - **Semântica Legada**: "correção mínima exigida" (mínimo patch viável para calar o teste).
   - **Semântica Atualizada**: "correção necessária para remover o bloqueio e satisfazer a adequação suficiente e sustentável/delimitada" (eliminação da causa-raiz de forma sustentável, sem remendos frágeis e respeitando o blast radius).

---

## 10. Validação e Critérios de Aceitação

A implementação deste design é comprovada pelos seguintes testes e verificações determinísticas:

1. **Test-Driven Development no Teste de Segurança (`scripts/test-safe-profile-gate.ps1`)**:
   - Introdução de asserções que falham comprovadamente contra os contratos legados baseados em "correção mínima" (RED).
   - Verificação de que a nova política é aprovada com sucesso após a atualização dos contratos (GREEN).
   - Cobertura de cenários de rejeição para:
     - Reintrodução de concessão de escrita no ALINHAMENTO ou em modos read-only;
     - Transições automáticas de modo sem comando explícito do usuário;
     - Aprovações de entrega sem prova operacional sob gatilhos de risco;
     - Delegação de autoridade decisória ou regras de workflow para o bridge MCP;
     - Remoção ou renomeação da chave JSON `required_fix`.
2. **Validador de Integridade (`scripts/validate.ps1`)**:
   - Reconhecimento dos novos termos de suficiência e sustentabilidade delimitada.
   - Rejeição contínua de terminologia obsoleta ou concessões indevidas de escrita.
   - Validação da perfeita sincronização entre as fontes e todos os espelhos instalados.
