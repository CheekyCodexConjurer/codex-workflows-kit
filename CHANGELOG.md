# Changelog

Todas as mudanças notáveis do Codex Workflows Kit são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Changed

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
