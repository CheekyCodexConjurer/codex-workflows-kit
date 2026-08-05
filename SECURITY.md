# Security Policy

## Supported versions

| Version | Suporte |
|---|---|
| 0.2.x (em desenvolvimento) | correcoes e novas funcionalidades |
| 0.1.x | correcoes de seguranca enquanto a 0.2 nao for publicada |
| Versoes anteriores | sem suporte |

## Escopo

Fazem parte do escopo desta politica:

- `scripts/` (instalador, validador, doctor e uninstall);
- `skills/` (workflows e evidence-first, incluindo referencias);
- `agents/` e `agents/opencode/` (perfis e guardrails de permissao);
- `plugins/mcp-foundation/` (allowlist, hook de auditoria e mantenedor);
- `ahk/` e `codex/AGENTS.md`.

Fora do escopo (deficiencias devem ser reportadas aos respectivos
mantenedores):

- Codex CLI, Google Antigravity e OpenCode CLI;
- servidores MCP remotos (Context7, OpenAI Developer Docs) e o pacote
  `sub-agents-mcp`.

## Reporting a vulnerability

Nao abra uma issue publica para vulnerabilidades. Reporte de forma privada
ao mantenedor, incluindo:

1. Versao afetada (commit ou release).
2. Descricao do problema e impacto potencial.
3. Passos de reproducao, se disponiveis.
4. Mitigacao sugerida, se houver.

Esperado do mantenedor:

- reconhecimento do reporte no prazo de alguns dias;
- avaliacao de impacto e resposta;
- correcao acompanhada de entrada no `CHANGELOG.md`;
- divulgacao coordenada apos a correcao estar disponivel.

## Praticas do projeto

- O kit nao registra telemetria e nao coleta dados do usuario.
- A instalacao e local e nao usa `irm | iex`; rode apenas o checkout revisado.
- O validador (`scripts/validate.ps1`) verifica contratos de permissao,
  allowlist de MCP e paridade de destinos instalados.
- Backups com timestamp sao criados antes de sobrescrever destinos.
- MCPs remotos exigem autenticacao unica explicita do usuario; o kit nunca
  instala credenciais por conta propria.
