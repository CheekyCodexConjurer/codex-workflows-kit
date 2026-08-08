# Changelog

Todas as mudanças notáveis do Codex Workflows Kit são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Changed

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
