# Especificação de Design: Rearchitetura de Workflows — Seletores Ortogonais e Módulo de Qualidade de Entrega

- **Data**: 2026-08-26
- **Status**: Aprovado
- **Autoridade**: Codex Workflows Kit Architecture
- **Alvo**: `codex-workflows-prompt-pad` (Codex & Antigravity)

---

## 1. Visão Geral e Objetivos

Esta especificação define a arquitetura dos dois seletores globais ortogonais para novas sessões do Codex (`subagent_backend` e `delegation_policy`), o desacoplamento do módulo invariante de qualidade de entrega (*delivery review gate*), a migração do estado de instalação para o Schema 5 e os contratos transacionais de alternância de políticas.

---

## 2. Seletores Globais Ortogonais

Existem dois seletores globais independentes e ortogonais que governam a execução de novas tarefas/sessões do Codex:

1. **`subagent_backend`**: `native` | `deepseek`
   - Define unicamente a família de ferramentas autorizada para delegação.
   - `native`: utiliza subagentes nativos do Codex (`multi_agent_v1__spawn_agent`, `spawn_agent`, `wait_agent`) com `model="gpt-5.6-luna"`, `reasoning_effort="max"` e modo default/normal (`fast_mode = false`). Autorizado diretamente pela seleção de backend sem exigir pedido explícito prévio do usuário. Proíbe contato com o MCP DeepSeek.
   - `deepseek`: utiliza as ferramentas MCP DeepSeek (`deepseek_spawn`, `deepseek_continue`, `deepseek_follow`). Proíbe o uso de ferramentas de trabalho nativas pelo parent. Continuação normal de trilhas utiliza `deepseek_continue` sobre o mesmo agente aberto sem `allow_respawn`. `allow_respawn=true` é restrito a recuperação pós-fechamento com resultado terminal persistido no mesmo pedido/escopo/cwd/ownership/modelo.
   - Gerenciado no `config.toml` (matriz de 5 chaves) e no ledger `install-state.json`. Sem fallback entre backends.

2. **`delegation_policy`**: `balanced` | `aggressive`
   - Define a estratégia de divisão de trabalho entre o parent GPT e os subagentes delegados.
   - `balanced` (padrão): otimiza tempo de relógio (*wall-clock time*). O parent GPT executa diretamente trabalho material sequencial, coeso e de caminho crítico quando o round-trip de delegação não traria ganho de tempo; delega para paralelismo concreto independente, especialização técnica, contenção de risco (*blast radius*) ou compressão de contexto volumoso. Sem fan-out obrigatório.
   - `aggressive`: otimiza desoneração de tokens do parent GPT (*token offload*). Todo trabalho material de leitura, pesquisa, escrita, teste e revisão é delegado ao backend selecionado, mantendo um subagente persistente por trilha coesa e lançando em lote todas as frentes materiais independentes.
   - Invariantes comuns a ambas as políticas: ciclo de vida de completude, ledger estável de `request_id`, fixação de rota (*route pinning*), proibição de fallback silencioso, permissões estritas por modo e interpretação de `visual_context` pelo parent.

### Armazenamento e Precedência:
- Os valores ativos dos seletores residem **exclusivamente** no bloco de runtime gerenciado do arquivo global instalado `~/.codex/AGENTS.md` (`# BEGIN CODEX-WORKFLOWS-KIT: runtime`).
- O arquivo fonte `codex/AGENTS.md` no repositório permanece um template/política estático sem valores de runtime ativos.
- O `config.toml` impõe unicamente o backend e não armazena a política de delegação.
- O arquivo `install-state.json` atua como ledger e base para rollback/desinstalação.
- Inconsistências entre o bloco de runtime, `config.toml` e `install-state.json` falham fechado (*fail-closed*).
- **Semântica de drift em projeções gerenciadas**: drift ou divergência nas projeções gerenciadas dos seletores (a matriz de 5 chaves do backend no `config.toml` ou as chaves do bloco de runtime em `AGENTS.md`) falha fechado (*fail-closed*). Campos de configuração não relacionados (fora da projeção gerenciada de backend do kit, como `model` de topo, `reasoning_effort` ou tabelas customizadas) são preservados e reconciliados no ledger com atualização do hash em operações gerenciadas bem-sucedidas.

---

## 3. Módulo Invariante de Qualidade de Entrega (*Delivery Review Gate*)

A verificação de qualidade de entrega é um módulo separado, invariante em relação ao backend e à política de delegação selecionados.

### Modos Aplicáveis:
`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`, `DEBUG`.

### Fluxo de Execução:
1. **Validação Determinística**: Execução dos testes unitários, testes de integração e verificações de integridade (`git diff --check`).
2. **Congelamento do Alvo (*Frozen Target*)**: Registro explícito do baseline, status de conteúdo relativo ao HEAD (`head_status`), diff integrado contra o HEAD (`diff_sha256`), mapa ordenado de hashes SHA256 dos arquivos do escopo (`file_sha256`) e evidências de validação determinística (`validation`). O `target_id` é um digest determinístico (SHA256) derivado dessa identidade composta; a identidade é estritamente **invariante a staging**, **invariante ao code page do host** e **sensível a conteúdo**, excluindo a colocação no index/stage do digest e normalizando como UTF-8 o stdout textual do Git incorporado ao diff. O estado de porcelain bruto (`raw_porcelain`) é registrado como evidência observacional externa ao digest. É estritamente proibido identificador baseado apenas em timestamp (`never timestamp-only`).
3. **Revisão Independente e os 5 Pilares Explícitos**: Avaliação do alvo congelado por revisor independente não-autor em contexto limpo de leitura (*fresh/read-only context*), cobrindo:
   - **P1: Requisitos e Completude**: conformidade com pedido e claim-map sem omissão de escopo.
   - **P2: Caminhos Primários, Alternativos e Compatibilidade Histórica**: corretude e robustez de caminhos alternativos e legados.
   - **P3: Casos Negativos, Falhas, Concorrência e Segurança**: tratamento robusto de erros, concorrência e segurança.
   - **P4: Robustez de Testes e Resistência a Falso-Verde**: asserções semânticas que falhariam em regressões reais.
   - **P5: Integração, Invariantes, Retrocompatibilidade e Escopo**: padrões locais, invariantes de arquitetura e ausência de ruído/resíduos.
4. **Pacote Estruturado de Revisão**: Emissão de pacote estruturado com `target_id` determinístico invariante a staging, `target_evidence` (baseline, head_status, `diff_sha256`, `file_sha256`, validation, raw_porcelain externo), veredito `APPROVED` | `BLOCKED`, checagem por pilar (`pillar_checks`), bloqueios detalhados (`id`, `claim`, `path`, `evidence`, `reproduction`, `required_fix`) e `advisories`.
5. **Ciclo de Reparo Consolidado (se BLOCKED)**:
   - Apontamentos enviados em lote único consolidado ao executor original.
   - Aplicação de correções mínimas e revalidação determinística.
   - Registro de novo alvo congelado com `target_id` determinístico invariante a staging e re-revisão delta focada nos bloqueios e no raio de impacto afetado (*affected blast radius*), revalidando a identidade completa do alvo e os invariantes de integração.
   - Máximo de **duas rodadas de reparo**; persistindo bloqueios, falha fechado (*fail closed*).
6. **Commit de Entrega**: Realizado apenas com veredito `APPROVED`, zero bloqueios (`zero blockers`), correspondência exata do `target_id` antes do staging, e recomputação do `target_id` invariante a staging imediatamente antes do commit exigindo igualdade exata com o alvo aprovado, mais verificação de que o conjunto de arquivos no stage (*staged path set*) corresponde exatamente ao conjunto de caminhos aprovados e cada *staged blob* coincide com o conteúdo aprovado após normalização do Git.
7. **Modo `R.A.F.V`**: Permanece um modo explícito acionado sob demanda pelo usuário, nunca invocado automaticamente como etapa pós-entrega. Sem expansão inventada de acrônimo.

---

## 4. Auditoria Final Atualizada

Antes da resposta final, o agente comprova e reporta:
- Todo job obrigatório consumido com estado terminal.
- Validação determinística executada com sucesso.
- Registro exato do alvo congelado (diff integrado, status relativo ao HEAD, hashes e target_id invariante a staging).
- Evidência de revisão de entrega aprovada (`APPROVED`) com zero bloqueios pendentes.
- Revalidação de eventuais apontamentos reparados.
- Série de commits locais fechada sem push.
- Riscos remanescentes documentados.

---

## 5. Schema 5 do Estado de Instalação (`install-state.json`)

O schema do estado de instalação avança para a versão 5:
- `schemaVersion`: `5`
- `product`: `'codex-workflows-kit'`
- `profile`: `'safe'` | `'minimal'`
- `installedAtUtc`: timestamp ISO 8601
- `files`: array de `{ path, sha256 }`
- `pendingFiles`: array de `{ path, sha256, reason }`
- `codexFeaturesPrior`: registro do valor prévio de `multi_agent`
- `codexBackend`: `@{ version = 1; selected = 'native'|'deepseek'; prior = @(...) }`
- `codexDelegation`: `@{ version = 1; selected = 'balanced'|'aggressive' }`

Na migração de schemas 1..4 para o schema 5, `codexDelegation` é inicializado com `balanced`, preservando o backend previamente configurado e as configurações capturadas.

---

## 6. Scripts e Interface do Usuário

1. `scripts/switch-subagent-backend.ps1 -Backend native|deepseek [-Status]`:
   - Alterna o backend no `config.toml`, atualiza o bloco de runtime em `~/.codex/AGENTS.md` e grava no `install-state.json`.
   - Preserva a política de delegação ativa.
2. `scripts/switch-subagent-policy.ps1 -Policy balanced|aggressive [-Status]`:
   - Alterna a política de delegação no bloco de runtime em `~/.codex/AGENTS.md` e no `install-state.json`.
   - Preserva o backend ativo e deixa o `config.toml` intacto.
3. Operação transacional:
   - Criação prévia de backups de todos os arquivos afetados.
   - Detecção de drift pré-execução: drift nas projeções gerenciadas falha fechado; campos de configuração não relacionados são preservados e reconciliados no ledger em operações bem-sucedidas.
   - Rollback automático e completo caso ocorra qualquer erro de escrita ou validação pós-escrita.
   - Idempotência garantida.
4. Prompt Pad e README: atuam como frontends finos sem armazenar estados ativos. O Prompt Pad fornece atalhos com modificador Ctrl (`^Numpad1`, `^Numpad2`, `^Numpad4`, `^Numpad5`, `^Numpad0`) para alternâncias rápidas e status assumindo execução na raiz do checkout, mantendo o teclado numérico direto (`Numpad0`..`Numpad9`) para os workflows.
