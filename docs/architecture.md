# Arquitetura

O Codex Workflows Kit mantém uma única superfície de workflow: $workflows.
Os arquivos canônicos vivem no checkout; o instalador copia-os para os
diretórios de skills e perfis do usuário.

## Componentes

- skills/workflows: roteador dos 16 modos e referências sob demanda;
- skills/evidence-first: verificação de claims materiais;
- agents/: perfis nativos opcionais (backend native read-only);
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
    DECIDE -->|"sim"| BACKEND["backend: MCP (padrão) | native (opt-in)"]
    BACKEND --> SIDE["scout | researcher | reviewer"]
    SIDE --> PARENT
    PARENT --> VERIFY["Mudança autorizada + validação"]
    VERIFY --> FREEZE["Diff integrado"]
    FREEZE --> REVIEW["Revisão quando exigida pelo modo"]
~~~

O backend de sub-agentes é resolvido pelo sufixo `subagents=mcp|native` do
pedido: o padrão é MCP e o backend native é opt-in explícito. Os modos de
workflow permanecem neutros de backend. Os perfis nativos continuam disponíveis
como um backend opcional, somente leitura, fixado em gpt-5.6-luna com esforço
high; não alteram arquivos nem iniciam novos agentes. scout, researcher e
reviewer são frentes de capacidade, não um compromisso com perfis nativos: sob
o padrão MCP elas são resolvidas pelo backend MCP, e os perfis nativos só
entram com o opt-in `subagents=native`.

O ciclo de vida de sidecars, obrigações pendentes e o gate de conclusão são
definidos no contrato canônico de skills/workflows/references/backend-policy.md.

## Fonte da verdade

codex/AGENTS.md é lido primeiro. As referências de
skills/workflows/references/ são abertas somente quando o modo ou um gate
precisa delas:

- research.md para RESEARCH.DEEP;
- observability.md para logs;
- backend-policy.md para delegação e ciclo de vida;
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
