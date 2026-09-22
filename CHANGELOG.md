# Changelog

Todas as mudanças notáveis do Codex Workflows Kit são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Added

- **Política única do Dev Router** (`scripts/dev-router-policy.json` +
  `scripts/dev-router-policy.mjs` + `scripts/dev-router-policy-cli.mjs`): o
  catálogo de modelos, os esforços suportados, o allow/deny de roteamento
  automático (Terra nunca é escolhido automaticamente), os conjuntos de opções
  por `target`, o parsing da escolha do Jev, `decideRoute` e a validação de lock
  passam a ter uma única fonte de verdade. O proxy Node importa o módulo e o
  PowerShell consome o mesmo módulo via CLI JSON, eliminando duas
  implementações que podiam divergir.
- **Sticky routing no proxy real**: lock por fronteira derivada de
  `conversation_id` / cadeia de `previous_response_id` / `session_id`,
  compartilhando o mesmo `dev-router-locks.json` do core. Uma continuação de
  ferramenta dentro do mesmo turno reutiliza a rota e NÃO chama o Jev de novo;
  uma fronteira nova permite nova decisão. Sem fronteira confiável o proxy
  preserva a rota ativa (ou falha fechado), nunca inventa.
- **`manual_base_model` / `manual_base_effort`** no estado do Dev Router, para
  separar a base concreta escolhida manualmente do alias `gpt-adaptive`.
- **`DEV_ROUTER_UPSTREAM_PATH`** e resolução correta do caminho upstream:
  bases que já carregam caminho (ex.: `https://chatgpt.com/backend-api/codex`,
  autenticação ChatGPT) recebem `/responses`, enquanto hosts nus mantêm
  `/v1/responses`.
- **`DEV_ROUTER_JEV_ENDPOINT` / `DEV_ROUTER_JEV_TIMEOUT_MS`** para permitir
  testes determinísticos com mock do Jev sem tocar a rede.
- `scripts/test-dev-router-proxy.ps1`: 39 asserções de conformidade do proxy
  real contra upstream e Jev mockados, incluindo guarda de alias, rota sticky,
  base ausente (fail-closed), Terra e caminho upstream com path.

### Fixed

- **`gpt-adaptive` nunca chega ao upstream**: guarda estrutural antes do
  encaminhamento; sem base concreta o proxy responde 400 local
  (`dev_router_missing_base`) sem contatar o upstream, em vez de reutilizar o
  alias ou inventar `Sol`.
- **`effort_only` funciona com modelo concreto**: um modelo selecionado
  manualmente (Sol/Astra/Luna) passa a ser roteado no esforço — antes o proxy só
  agia quando o modelo era exatamente `gpt-adaptive`.
- **Catálogo não inventa mais metadados oficiais**: `base_instructions` e
  `supports_parallel_tool_calls` vêm exclusivamente de
  `codex debug models --bundled`. Modelos do cache sem contraparte bundled
  (`gpt-6-astra`, `gpt-reserve` no codex-cli 0.145.0) são OMITIDOS com motivo
  registrado, em vez de receberem texto sintético que alteraria o comportamento
  do modelo. A entrada `gpt-adaptive` (alias local nosso) mantém texto neutro de
  roteamento e anuncia apenas os esforços realmente suportados pelos modelos
  concretos elegíveis.
- `scripts/test-dev-router.ps1` não vaza mais chamada live ao TypeSafe/Jev e o
  cenário end-to-end usa base concreta explícita.

### Fixed

- Catálogo de modelos do Dev Router (`model_catalog_json`) reescrito para o
  schema exigido pelo Codex CLI 0.145+: a raiz precisa ser uma **sequência de
  sequências** de objetos `ModelInfo`, cada um com os campos obrigatórios
  `slug`, `display_name`, `supported_reasoning_levels` (lista de
  `{ effort, description }`), `shell_type`, `visibility`, `supported_in_api`,
  `priority`, `base_instructions`, `support_verbosity`, `truncation_policy`,
  `supports_parallel_tool_calls` e `experimental_supported_tools` (array vazio,
  nunca `null`). O formato anterior (array plano com `id`,
  `supported_reasoning_efforts` e `default_reasoning_effort`) fazia o Codex
  falhar ao carregar QUALQUER configuração com
  `invalid type: map, expected a sequence`. As entradas do cache oficial agora
  são normalizadas para o schema atual em vez de repassadas verbatim (o cache
  não contém `base_instructions` nem `supports_parallel_tool_calls`), e um
  validador estrutural (`Test-DevRouterModelCatalogShape`) impede que um
  catálogo incompatível seja registrado: em caso de falha o arquivo anterior é
  restaurado e a exportação falha fechada.

- Artefatos JSON/TOML agora são gravados em UTF-8 **sem BOM**. O default do
  Windows PowerShell 5.1 (`[System.Text.Encoding]::UTF8`) emitia BOM e quebrava
  o carregamento de `model_catalog_json` no Codex e o `JSON.parse` do proxy
  Dev Router (`dev-router-state.json`). O proxy passou a tolerar BOM na leitura
  como defesa em profundidade.

- `scripts/test-dev-router.ps1` não vaza mais uma chamada **live** ao
  TypeSafe/Jev: o teste end-to-end de proxy agora fixa o estado em `off` e
  limpa `TYPESAFE_API_KEY` durante a execução (restaurando ao final), tornando a
  suíte determinística e sem consumo de quota.

### Changed

- Continuidade automática após fechamento prematuro do writer: o writer
  permanece aberto até a revisão independente e as correções comprovadas, e
  a correção do mesmo trabalho não pede nova permissão. Se o próprio parent
  fechou cedo um writer com resultado terminal, a correção estritamente no
  mesmo request/escopo/cwd/ownership/rota-modelo retoma via
  `deepseek_continue` com `allow_respawn=true`, automaticamente; a
  recuperação cria sessão/agente novo com lineage, nunca continuação falsa,
  mantém o modelo/provedor da frente original (sem fallback) e é fail-closed:
  nunca para jobs running, resultado final ausente, abort explícito,
  divergência de request/escopo/cwd/ownership/modelo ou mudança material fora
  do pedido original. codex/AGENTS.md, skills/workflows/SKILL.md,
  scripts/validate.ps1 e scripts/test-safe-profile-gate.ps1 declaram e
  fiscalizam a regra (padrões obrigatórios/proibidos, self-check
  anti-adulteração e fixtures S10), mantendo o orçamento compacto do AGENTS.

- codex/AGENTS.md e skills/workflows/SKILL.md reforçam a orquestração sem
  citar rotas de modelo/provedor: antes de esperar, o parent mapeia frentes
  independentes, dependências e recursos exclusivos/compartilhados e lança
  todas as frentes materiais independentes em lote antes do primeiro follow;
  apenas trilhas com dependência real ou recurso compartilhado ficam seriais;
  enquanto aguarda, faz orquestração independente útil e mantém um ledger
  estável de request_id com frente, agente, job, estado, consumido e fechado,
  consumindo cada job e fechando cada agente após a integração. A cadeia serial
  writer → revisão independente → correções no mesmo writer é preservada, sem
  teto numérico artificial ou guarda de duplicação na mesma thread.
  scripts/validate.ps1 e scripts/test-safe-profile-gate.ps1 exigem as cláusulas
  de mapeamento, lote, serialidade e ledger, com fixtures anti-adulteração;
  o orçamento compacto de codex/AGENTS.md é mantido consolidando redação.

- Modos de entrega com escrita (`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`,
  `DELIVER.AUTO`, `BUG.FIX`, `DEBUG`, `R.A.F.V`) passam a fechar com uma
  série de commits locais validada, revisada e escopada — nunca push. A
  matriz de modos em skills/workflows/SKILL.md ganha a capacidade `commit`
  nesses modos e o gate de pronto declara a série local; o novo gate de
  entrega exige baseline e claim-map/ownership de caminhos, nunca inclui
  mudanças pré-existentes/staged/de outra frente, bloqueia por overlap
  ambíguo, segredos ou candidatos gerados/cache/local/ignorados, usa um
  commit-map coerente com validação direcionada e integrada mais `git diff
  --check`, revisão independente antes do commit e correções como commits
  novos (sem amend/rewrite). O modo `COMMIT` permanece git-only para
  worktrees sujos pré-existentes ou excepcionais; `REWORK` continua no-write
  (roadmap, nunca implementação). skills/workflows/references/commit.md e
  validation.md definem o gate; scripts/validate.ps1 sincroniza a matriz
  canônica, exige `commit` apenas sob permissões write/git-only e verifica o
  novo vocabulário do contrato.

- codex/AGENTS.md ganha o bloco canônico de roteamento: todo pedido não
  qualificado de sub-agentes, agentes, delegação, trabalho, leitura, escrita,
  exploração ou revisão — incluindo os aliases comuns `workers`, `readers`,
  `writers`, `explorers`, `reviewers` — usa
  `deepseek_spawn`/`deepseek_continue`/`deepseek_follow`, com ou sem
  `$workflows` (`$workflows` acrescenta ciclo e modos, mas não é condição
  para selecionar o MCP). As ferramentas nativas
  `multi_agent_v1__spawn_agent`/`spawn_agent`/`wait_agent` são proibidas,
  exceto pedido explícito de sub-agentes nativos do Codex. Consumo terminal,
  revisão independente, `visual_context` e fail-closed são preservados.
  scripts/validate.ps1 exige os aliases apenas no bloco canônico; a
  terminologia retirada continua proibida nos demais arquivos.
- scripts/install.ps1 (perfil safe) deixa de instalar o bloco gerenciado
  `[agents]` com defaults nativos; a reexecução remove blocos gerenciados
  antigos e preserva uma seção `[agents]` não gerenciada existente. O gate
  `multi_agent = false` em `[features]` continua.
- scripts/validate.ps1 e doctor.ps1 permitem o vocabulário canônico de
  roteamento em codex/AGENTS.md (nomes de ferramentas `native`/`deepseek_`)
  sem reativar superfícies legadas em outros arquivos; a validação do perfil
  safe instalado agora exige a ausência do bloco gerenciado de agents, e o
  doctor substitui o check de defaults gerenciados pelo de ausência. Os
  fixtures ganham o cenário de reinstall que remove o bloco legado e preserva
  `[agents]` não gerenciado (scripts/test-safe-profile-gate.ps1).
- scripts/install.ps1 (perfil safe) define `multi_agent = false` na tabela
  `[features]` do config.toml do Codex de forma idempotente e TOML-aware: sem
  cabeçalhos `[features]` ou chaves duplicadas, preservando chaves e
  comentários não gerenciados. O estado de instalação passa a schema 4 e
  registra o valor/presença anterior em `codexFeaturesPrior` (estados schema 3
  existentes permanecem legíveis; uma nova execução do instalador registra o
  gate). O valor registrado é o observado antes da primeira instalação do kit
  e é mantido intacto em reexecuções: o uninstall restaura esse valor pré-kit
  somente enquanto `multi_agent` ainda for `false`; se o usuário o alterou,
  avisa e preserva. O perfil minimal continua sem instalar política global e
  não altera a feature. scripts/doctor.ps1 falha quando o perfil safe está
  ativo e `multi_agent` não é `false`; scripts/validate.ps1 reforça o gate no
  modo completo e executa fixtures de comportamento (tabela ausente, valores
  true/false existentes, chaves não relacionadas, reexecução idempotente,
  migração de schema 3, restore no uninstall, override do usuário e arquivo
  pendente de schema 4 modificado pelo usuário preservado no uninstall).
- scripts/install.ps1, uninstall.ps1 e doctor.ps1 passam a tratar
  `pendingFiles` de estados schema 4 com a mesma regra de schema 3 (`>= 3`):
  o uninstall preserva arquivos pendentes modificados pelo usuário e retém o
  estado com o motivo para revisão; o instalador contabiliza os pendentes do
  estado anterior ao decidir o que remover, em vez de descartar a trilha de
  revisão ao reescrever o estado.
- codex/AGENTS.md é agora um template global compacto com regras universais
  apenas (skill `$workflows`, preservação de mudanças, Git não destrutivo,
  parent GPT como maestro, DeepSeek Sub-Agent MCP como executor principal,
  delegação obrigatória, consumo de jobs antes de gate dependente, revisão
  independente pós-writer e `visual_context`).
- skills/workflows/SKILL.md é a única política detalhada: lifecycle
  FRAME → FANOUT → COLLECT → ACT → VERIFY → REVIEW → DONE, semântica compacta
  das ferramentas MCP, modos pela tripla capacidades | permissão | gate de
  pronto (incluindo IMPL.AUTO com write) e auditoria final.
- Removidos o roteamento nativo e o contrato de backend: perfis agents/*.toml,
  scripts/native-profile-contract.ps1 e as referências backend-policy.md,
  subagents.md, mode-matrix.md e dictionary.md deixam de existir; nenhum texto
  ativo usa `subagents=` ou terminologia de backend.
- scripts/install.ps1, validate.ps1 e doctor.ps1 acompanham o novo layout; o
  instalador remove perfis nativos legados por hash/estado sem apagar arquivos
  modificados ou desconhecidos.
- docs/architecture.md e docs/agent-bootstrap-prompt.md (duplicavam a
  política) foram removidos; docs/security.md, README.md, CONTRIBUTING.md e
  SECURITY.md foram atualizados para o contrato MCP-only.
- O prompt pad segue colando apenas `$workflows mode=<MODE>` por tecla; o
  produto, o schema de estado e a lógica de backup/hashes permanecem
  compatíveis.
- codex/AGENTS.md e skills/workflows/SKILL.md usam vocabulário de capacidades
  (read, research, write, test, review, verify, index, commit) e permissões
  (no-write, write, git-only) na matriz de modos; nenhum perfil nativo
  (scout, researcher, writer, reviewer) permanece na política ativa. O parent
  GPT é explicitamente o cérebro, não a força de trabalho do repositório.
- scripts/validate.ps1 valida a matriz canônica de modos, o vocabulário de
  capacidades e os invariantes (IMPL.AUTO com read,write,test,review;
  no-write/git-only sem write; nenhum perfil nativo como capacidade), sem
  falsos positivos em CHANGELOG ou legado permitido.
- scripts/doctor.ps1 não trata mais o config.toml como falha de hash quando o
  bloco gerenciado está intacto e o Codex reescreveu o arquivo; adiciona
  checks read-only de escopo seguro: política única, AGENTS global vs
  template, contrato antigo instalado, perfis nativos legados, Prompt Pad com
  override/toggle e atalho no Startup apontando para a cópia gerenciada,
  referências removidas, registros MCP antigos, scheduled tasks relacionadas e
  presença do MCP atual deepseek-subagent.
- scripts/install.ps1 e uninstall.ps1: com -InstallAhk, o atalho
  'Codex Prompt Pad.lnk' no Startup é instalado (reusando o executável do
  AutoHotkey existente, com backup binário do atalho anterior), registrado no
  estado e removido no uninstall somente por hash/ownership; cópias antigas
  não gerenciadas não são apagadas.
- references/commit.md, research.md e validation.md alinham o vocabulário ao
  contrato de capacidades.
