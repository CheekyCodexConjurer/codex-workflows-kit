# Changelog

Todas as mudanças notáveis do Codex Workflows Kit são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Changed

- O backend de sub-agentes é resolvido pelo sufixo `subagents=mcp|native` no
  pedido: padrão MCP, com native como opt-in explícito; os modos de workflow
  permanecem neutros de backend.
- O ciclo de vida de sidecars, obrigações pendentes e o gate de conclusão são
  centralizados em skills/workflows/references/backend-policy.md; a
  documentação pública referencia o contrato canônico em vez de duplicá-lo.
- scripts/validate.ps1 deixa de bloquear os conceitos mcp e deepseek, mantém
  os banimentos dos termos legados de roteamento e passa a provar a
  neutralidade de backend da matriz de modos, a cobertura completa dos nomes
  de ferramentas MCP e a referência nativa explícita.
- Perfis nativos (scout, researcher, reviewer) permanecem como um backend
  opcional, somente leitura, fixado em gpt-5.6-luna com esforço high.
- Instalação, diagnóstico, validação e documentação acompanham o policy
  backend-aware, mantendo o fluxo local de skills, perfis nativos e regras
  globais.
