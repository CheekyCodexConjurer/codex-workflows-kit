# Codex Workflows Kit

Kit local, Windows-first, para instalar uma única interface de workflow:
$workflows. Ele inclui a skill condicional evidence-first e um prompt pad
AutoHotkey opcional. O executor principal é o DeepSeek Sub-Agent MCP; o
parent GPT é o maestro que delega, integra e valida. Tudo parte de uma
worktree versionada, com backup antes de sobrescrever, dry-run, diagnóstico e
remoção segura.

> **Segurança primeiro.** Nunca instale por pipeline remoto. Clone ou baixe o
> repositório, revise os scripts em scripts/ e execute-os do seu próprio
> checkout. O kit não registra telemetria nem configura serviços externos.

Documentação: [Segurança](docs/security.md) ·
[Contribuição](CONTRIBUTING.md) · [Changelog](CHANGELOG.md).

## O que o kit instala

| Componente | Destino | Finalidade |
|---|---|---|
| skill workflows | ~/.agents/skills/workflows | única interface para os modos $workflows |
| skill evidence-first | ~/.agents/skills/evidence-first | verificação de claims materiais |
| codex/AGENTS.md | ~/.codex/AGENTS.md | regras globais universais |
| feature multi_agent | config.toml ([features]) | desliga a rota multi-agente embutida no perfil safe; reativável manualmente |
| prompt pad opcional | caminho escolhido pelo usuário | atalhos NUM para $workflows; atalho no Startup com -InstallAhk |
| scripts locais | checkout | instalação, validação, diagnóstico e remoção |

O contrato único e detalhado é skills/workflows/SKILL.md (ciclo de vida,
semântica das ferramentas MCP, modos pela tripla capacidades | permissão |
gate de pronto e auditoria final); skills/workflows/references/ contém apenas
referências especializadas abertas sob demanda (research, observability,
validation, commit e quality-ratchet).

## Requisitos

- Windows 10 ou 11;
- PowerShell 5.1+ ou PowerShell 7+;
- Codex (o perfil safe define `multi_agent = false` para orquestração
  exclusivamente via DeepSeek Sub-Agent MCP);
- opcionalmente, AutoHotkey v2 para o prompt pad.

Se a política de execução exigir, permita apenas o escopo do usuário depois de
revisar o conteúdo. Nunca use bypass nem pipelines remotos.

## Layout

~~~text
skills/workflows/         Skill canônica (SKILL.md) e referências especializadas
skills/evidence-first/    Verificação condicional de claims
codex/AGENTS.md           Regras globais universais
ahk/codex_prompt_pad.ahk  Atalhos opcionais
scripts/                  Instalação, validação, diagnóstico e remoção
docs/                     Documentação pública
~~~

## Instalação

| Perfil | Escopo |
|---|---|
| minimal | skills workflows e evidence-first |
| safe (padrão) | skills, regras globais (AGENTS.md) e defaults de runtime |

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
| -InstallAhk | instala o prompt pad e gerencia o atalho 'Codex Prompt Pad.lnk' no Startup: reusa o executável do AutoHotkey existente quando possível, faz backup binário do atalho anterior e o registra no estado |
| -CodexHome, -AgentsHome, -AhkDestination | substituem destinos padrão; informe o mesmo `-AhkDestination` ao desinstalar um prompt pad customizado |
| -Force | permite substituir um AGENTS.md não gerenciado após backup |
| -WhatIf | mostra as alterações sem tocar no disco |
| `validate.ps1 -SkipInstalled` | valida apenas o checkout, sem exigir espelhos instalados |
| `doctor.ps1 -Detailed` | inclui os caminhos registrados pelo estado instalado |

O instalador é idempotente. Ele registra hashes dos arquivos que gerencia,
faz backup antes de sobrescrever e preserva arquivos fora do seu estado.

O perfil safe também define `multi_agent = false` na tabela `[features]` do
config.toml do Codex, preservando as demais chaves e comentários: a
orquestração passa a ser exclusivamente via DeepSeek Sub-Agent MCP, e a rota
multi-agente embutida fica desligada. Você pode reativá-la manualmente quando
quiser; o valor anterior é registrado no estado de instalação e restaurado no
uninstall — somente se `multi_agent` ainda for `false`. Esse valor registrado
é o observado antes da primeira instalação do kit: reexecuções não o
sobrescrevem, para que o uninstall sempre restaure o estado pré-kit. Se você
o alterou, o kit avisa e preserva sua escolha. Estados de schema 3 existentes
continuam legíveis; execute `install.ps1 -Profile safe` uma vez para registrar
o gate.

### Migração segura

Na atualização, o kit só remove caminhos dentro dos destinos selecionados de
Codex e agents, além do destino explícito do prompt pad. Se um estado anterior
apontar para outro arquivo externo, ele é preservado e o comando avisa em vez
de apagá-lo. Revise esse arquivo manualmente; o desinstalador mantém o estado
enquanto houver esse pendente, para não perder sua trilha de propriedade. O
upgrade também registra o pendente no novo estado até que ele seja tratado.
O atalho 'Codex Prompt Pad.lnk' no Startup é tratado como destino explícito
quando instalado com -InstallAhk: o desinstalador só o remove quando o hash
registrado ainda corresponde, preservando atalhos modificados ou não gerenciados.

## Arquitetura

~~~mermaid
flowchart LR
    USER["Usuário"] --> WF["$workflows mode=<MODE>"]
    PAD["Prompt pad"] --> WF
    WF --> RULES["SKILL.md (política única)"]
    RULES --> MCP["DeepSeek Sub-Agent MCP"]
    MCP --> PARENT["parent GPT (maestro)"]
    PARENT --> GATE["diff + validação"]
~~~

O único prefixo de workflow é $workflows. Consulte skills/workflows/SKILL.md
para os 16 modos (tripla capacidades | permissão | gate de pronto) e o ciclo
de vida; referências especializadas são abertas sob demanda. O executor
principal é o DeepSeek Sub-Agent MCP; o parent GPT interpreta imagens,
integra, valida e decide.

## Primeiros passos

1. Instale o perfil seguro: .\scripts\install.ps1 -Profile safe.
2. Valide: .\scripts\validate.ps1.
3. Abra uma nova tarefa do Codex e envie:

~~~text
$workflows mode=PLAN.AUTO
~~~

O contrato do modo define as capacidades, a permissão de mudança, a validação
e o gate de pronto; o executor é o DeepSeek Sub-Agent MCP e o parent GPT
integra, valida e decide.

## Validação

~~~powershell
.\scripts\validate.ps1
git diff --check
~~~

Após alterar o contrato canônico, reinstale o perfil seguro antes de conferir
os espelhos instalados.
