# Codex Workflows Kit

Kit local, Windows-first, para instalar uma única interface de workflow:
$workflows. Ele inclui a skill condicional evidence-first, perfis nativos
opcionais de leitura (scout, researcher e reviewer) e um prompt pad AutoHotkey
opcional. O backend de sub-agentes é resolvido pelo sufixo
`subagents=mcp|native`: o padrão é MCP, e o backend native é opt-in explícito.
Tudo parte de uma worktree versionada, com backup antes de sobrescrever,
dry-run, diagnóstico e remoção segura.

> **Segurança primeiro.** Nunca instale por pipeline remoto. Clone ou baixe o
> repositório, revise os scripts em scripts/ e execute-os do seu próprio
> checkout. O kit não registra telemetria nem configura serviços externos.

Documentação: [Arquitetura](docs/architecture.md) ·
[Segurança](docs/security.md) ·
[Bootstrap](docs/agent-bootstrap-prompt.md) ·
[Contribuição](CONTRIBUTING.md) · [Changelog](CHANGELOG.md).

## O que o kit instala

| Componente | Destino | Finalidade |
|---|---|---|
| skill workflows | ~/.agents/skills/workflows | única interface para os modos $workflows |
| skill evidence-first | ~/.agents/skills/evidence-first | verificação de claims materiais |
| scout, researcher, reviewer | ~/.codex/agents | backend native opcional, read-only, em gpt-5.6-luna com esforço high |
| codex/AGENTS.md | ~/.codex/AGENTS.md | regras globais e matriz compacta de modos |
| prompt pad opcional | caminho escolhido pelo usuário | atalhos NUM para $workflows |
| scripts locais | checkout | instalação, validação, diagnóstico e remoção |

Os modos de workflow permanecem neutros de backend: o pedido resolve o backend
pelo sufixo `subagents=mcp|native` (padrão MCP; native é opt-in explícito). Os
perfis nativos continuam disponíveis como um backend opcional, somente
leitura, para coleta de evidência, pesquisa e revisão de diff congelado. O
ciclo de vida de sidecars, obrigações pendentes e o gate de conclusão seguem o
contrato canônico em `skills/workflows/references/backend-policy.md`.

## Requisitos

- Windows 10 ou 11;
- PowerShell 5.1+ ou PowerShell 7+;
- Codex com sub-agentes habilitados;
- opcionalmente, AutoHotkey v2 para o prompt pad.

Se a política de execução exigir, permita apenas o escopo do usuário depois de
revisar o conteúdo. Nunca use bypass nem pipelines remotos.

## Layout

~~~text
skills/workflows/         Skill canônica e referências dos modos
skills/evidence-first/    Verificação condicional de claims
agents/                   Perfis nativos opcionais (backend native read-only)
codex/AGENTS.md           Regras globais e biblioteca compacta de modos
ahk/codex_prompt_pad.ahk  Atalhos opcionais
scripts/                  Instalação, validação, diagnóstico e remoção
docs/                     Documentação pública
~~~

## Instalação

| Perfil | Escopo |
|---|---|
| minimal | skills workflows e evidence-first |
| safe (padrão) | skills, perfis nativos e AGENTS.md |

~~~powershell
.\scripts\install.ps1 -Profile safe
.\scripts\validate.ps1
.\scripts\doctor.ps1
.\scripts\uninstall.ps1 -WhatIf
~~~

### Flags

| Flag | Efeito |
|---|---|
| -Profile minimal\|safe | seleciona o escopo instalado |
| -InstallAhk | instala o prompt pad, com backup do destino existente |
| -CodexHome, -AgentsHome, -AhkDestination | substituem destinos padrão; informe o mesmo `-AhkDestination` ao desinstalar um prompt pad customizado |
| -Force | permite substituir um AGENTS.md não gerenciado após backup |
| -WhatIf | mostra as alterações sem tocar no disco |
| `validate.ps1 -SkipInstalled` | valida apenas o checkout, sem exigir espelhos instalados |
| `doctor.ps1 -Detailed` | inclui os caminhos registrados pelo estado instalado |

O instalador é idempotente. Ele registra hashes dos arquivos que gerencia,
faz backup antes de sobrescrever e preserva arquivos fora do seu estado.

### Migração segura

Na atualização, o kit só remove caminhos dentro dos destinos selecionados de
Codex e agents, além do destino explícito do prompt pad. Se um estado anterior
apontar para outro arquivo externo, ele é preservado e o comando avisa em vez
de apagá-lo. Revise esse arquivo manualmente; o desinstalador mantém o estado
enquanto houver esse pendente, para não perder sua trilha de propriedade. O
upgrade também registra o pendente no novo estado até que ele seja tratado.

## Arquitetura

~~~mermaid
flowchart LR
    USER["Usuário"] --> WF["$workflows mode=<MODE>"]
    PAD["Prompt pad"] --> WF
    WF --> RULES["AGENTS.md + referências"]
    RULES --> BACKEND["backend: MCP (padrão) | native (opt-in)"]
    BACKEND --> SIDE["scout | researcher | reviewer"]
    SIDE --> PARENT["orquestrador"]
    PARENT --> GATE["diff + validação"]
~~~

O único prefixo de workflow é $workflows. Consulte a matriz em
skills/workflows/references/mode-matrix.md para os 16 modos e seus gates; o
backend de sub-agentes é resolvido pelo sufixo `subagents=mcp|native` e o
ciclo de vida de delegação segue skills/workflows/references/backend-policy.md.
scout, researcher e reviewer são frentes de capacidade resolvidas pelo backend
do pedido: sob o padrão MCP elas não acionam os perfis nativos, que só se
aplicam com o opt-in explícito `subagents=native`.

## Primeiros passos

1. Instale o perfil seguro: .\scripts\install.ps1 -Profile safe.
2. Valide: .\scripts\validate.ps1.
3. Abra uma nova tarefa do Codex e envie:

~~~text
$workflows mode=PLAN.AUTO
~~~

O contrato do modo define quando coletar evidência via backend (MCP padrão ou
native opt-in), quando alterar e como validar. Para preparar uma tarefa antes
do primeiro pedido, copie o texto de docs/agent-bootstrap-prompt.md.

## Validação

~~~powershell
.\scripts\validate.ps1
git diff --check
~~~

Após alterar o contrato canônico, reinstale o perfil seguro antes de conferir
os espelhos instalados.
