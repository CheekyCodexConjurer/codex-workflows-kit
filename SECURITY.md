# Security Policy

## Supported versions

| Version | Suporte |
|---|---|
| 0.2.x | correções e novas funcionalidades |
| anteriores | sem suporte ativo |

## Escopo

Fazem parte do escopo desta política:

- scripts/;
- skills/;
- agents/;
- ahk/ e codex/AGENTS.md.

Fora do escopo estão o produto Codex e componentes instalados fora deste
checkout.

## Reporting a vulnerability

Não abra uma issue pública para vulnerabilidades. Envie ao mantenedor, de
forma privada:

1. versão ou commit afetado;
2. descrição e impacto potencial;
3. passos de reprodução, se disponíveis;
4. mitigação sugerida, se houver.

## Práticas do projeto

- O kit não registra telemetria e não coleta dados do usuário.
- A instalação é local; execute apenas o checkout revisado.
- Backups com timestamp são criados antes de sobrescrever destinos.
- Os perfis nativos têm sandbox read-only e não recebem permissão de escrita.
