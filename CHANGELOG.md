# Changelog

Todas as mudanças notáveis do Codex Workflows Kit são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Changed

- A interface pública de workflow é exclusivamente $workflows.
- Os perfis de sub-agentes são nativos, somente leitura e fixados em
  gpt-5.6-luna com esforço high.
- Sidecars obrigatórios agora exigem resposta final antes de síntese ou avanço;
  estados interrompido, erro, timeout ou ausente mantêm o gate aberto sem
  fallback silencioso.
- Instalação, diagnóstico, validação e documentação foram reduzidos ao fluxo
  local de skills, perfis nativos e regras globais.
