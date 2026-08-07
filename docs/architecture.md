# Arquitetura

O Codex Workflows Kit mantém uma única superfície de workflow: $workflows.
Os arquivos canônicos vivem no checkout; o instalador copia-os para os
diretórios de skills e perfis do usuário.

## Componentes

- skills/workflows: roteador dos 16 modos e referências sob demanda;
- skills/evidence-first: verificação de claims materiais;
- agents/: scout, researcher e reviewer nativos;
- codex/AGENTS.md: regras globais e biblioteca compacta de modos;
- scripts/: instalação, validação, diagnóstico e remoção;
- ahk/: prompt pad opcional.

## Rota de execução

~~~mermaid
flowchart TD
    USER["Pedido com $workflows mode=<MODE>"] --> AGENTS["AGENTS.md"]
    AGENTS --> MATRIX["Mode matrix"]
    MATRIX --> DECIDE{"Sidecar-gate?"}
    DECIDE -->|"não"| PARENT["Orquestrador"]
    DECIDE -->|"sim"| NATIVE["Sub-agente nativo read-only"]
    NATIVE --> PARENT
    PARENT --> VERIFY["Mudança autorizada + validação"]
    VERIFY --> FREEZE["Diff integrado"]
    FREEZE --> REVIEW["Revisão nativa quando exigida"]
~~~

Os três perfis nativos são fixados em gpt-5.6-luna, com esforço max e
read-only. Eles coletam evidência, pesquisam fontes ou revisam um resultado
congelado. Não alteram arquivos nem iniciam novos agentes.

## Fonte da verdade

codex/AGENTS.md é lido primeiro. As referências de
skills/workflows/references/ são abertas somente quando o modo ou um gate
precisa delas:

- research.md para RESEARCH.DEEP;
- observability.md para logs;
- backend-policy.md e subagents.md para sidecars nativos;
- validation.md para a entrega;
- mode-matrix.md e dictionary.md para ambiguidade;
- quality-ratchet.md para qualidade;
- commit.md para COMMIT.

## Instalação e estado

O perfil safe instala skills, perfis e regras globais. O instalador grava um
estado com hashes em %CODEX_HOME%\codex-workflows-kit\install-state.json.
Esse estado permite detectar espelhos alterados e remover apenas arquivos que
o kit reconhece como seus.

Após mudar o contrato, execute:

~~~powershell
.\scripts\install.ps1 -Profile safe
.\scripts\validate.ps1
~~~

doctor.ps1 é somente leitura. uninstall.ps1 -WhatIf mostra a remoção antes de
tocar em qualquer arquivo.
