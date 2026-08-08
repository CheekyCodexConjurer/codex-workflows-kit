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
