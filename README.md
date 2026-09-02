# Codex Workflows Kit

Kit local, Windows-first, para instalar uma única interface de workflow:
$workflows. Ele inclui a skill condicional evidence-first e um prompt pad
AutoHotkey opcional. Possui dois seletores globais ortogonais para novas tarefas/sessões:
`subagent_backend` (`native` | `deepseek`) e `delegation_policy` (`balanced` | `aggressive`).
O parent GPT é o maestro que delega, integra, valida e decide. Tudo parte de uma
worktree versionada, com backup antes de sobrescrever, alternâncias transacionais com rollback,
diagnóstico e remoção segura.

O seletor global de backend define o executor de sub-agentes (`native` com `gpt-5.6-luna` ou `deepseek` via DeepSeek Sub-Agent MCP). A política de delegação define o equilíbrio operacional (`balanced` otimizando wall-clock time ou `aggressive` otimizando desoneração de tokens). Em modos de escrita, o módulo invariante de qualidade de entrega congela o alvo e exige revisão estruturada independente com veredito APPROVED antes do commit local fechado.

> **Segurança primeiro.** Nunca instale por pipeline remoto. Clone ou baixe o
> repositório, revise os scripts em scripts/ e execute-os do seu próprio
> checkout. O kit não registra telemetria nem configura serviços externos.

Documentação: [Segurança](docs/security.md) ·
[Contribuição](CONTRIBUTING.md) · [Changelog](CHANGELOG.md).

## O que o kit instala

| Componente | Destino | Finalidade |
|---|---|---|
| skill workflows | ~/.agents/skills/workflows, ~/.gemini/antigravity/skills/workflows, ~/.gemini/config/skills/workflows | única interface para os modos $workflows |
| skill evidence-first | ~/.agents/skills/evidence-first, ~/.gemini/antigravity/skills/evidence-first, ~/.gemini/config/skills/evidence-first | verificação de claims materiais |
| skill mcp-foundation | ~/.agents/skills/mcp-foundation, ~/.gemini/antigravity/skills/mcp-foundation, ~/.gemini/config/skills/mcp-foundation | roteamento, uso e manutenção segura de Context7, CodeGraph e Serena |
| codex/AGENTS.md | ~/.codex/AGENTS.md | regras globais universais e bloco de runtime ativo (Codex) |
| antigravity/GEMINI.md | ~/.gemini/config/GEMINI.md | regras globais universais (Antigravity) |
| matriz de backend | config.toml | impõe o backend de subagentes selecionado |
| prompt pad opcional | caminho escolhido pelo usuário | atalhos NUM para $workflows e controle de seletores; atalho no Startup com -InstallAhk |
| scripts locais | checkout | instalação, alternância de backend/política, validação, diagnóstico e remoção |

O contrato único e detalhado é skills/workflows/SKILL.md (ciclo de vida,
semântica das ferramentas MCP/nativas, modos pela tripla capacidades | permissão |
gate de pronto e auditoria final); skills/workflows/references/ contém apenas
referências especializadas abertas sob demanda (delegation, delivery-review, research, observability,
validation, commit e quality-ratchet).

## Requisitos

- Windows 10 ou 11;
- PowerShell 5.1+ ou PowerShell 7+;
- Codex (o perfil safe gerencia o seletor `subagent_backend` — `native` com `gpt-5.6-luna` ou `deepseek` via DeepSeek Sub-Agent MCP);
- opcionalmente, AutoHotkey v2 para o prompt pad.

Se a política de execução exigir, permita apenas o escopo do usuário depois de
revisar o conteúdo. Nunca use bypass nem pipelines remotos.

## Layout

~~~text
skills/workflows/         Skill canônica (SKILL.md) e referências especializadas
skills/evidence-first/    Verificação condicional de claims
skills/mcp-foundation/    Roteamento canônico de Context7, CodeGraph e Serena
codex/AGENTS.md           Regras globais universais (Codex)
antigravity/GEMINI.md     Regras globais universais (Antigravity: ~/.gemini/config/GEMINI.md)
ahk/codex_prompt_pad.ahk  Atalhos opcionais
scripts/                  Instalação, validação, diagnóstico e remoção
docs/                     Documentação pública
~~~

## Instalação

| Perfil | Escopo |
|---|---|
| minimal | skills workflows, evidence-first e mcp-foundation |
| safe (padrão) | skills, regras globais (AGENTS.md, GEMINI.md) e a imposição do backend selecionado |

O comportamento global em qualquer repositório é fornecido pelo perfil `safe`, que injeta as regras globais universais (`~/.codex/AGENTS.md` e `~/.gemini/config/GEMINI.md`). O perfil `minimal` instala apenas as skills e, por definição, não injeta as regras globais.

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
| -CodexHome, -AgentsHome, -AntigravityHome, -AhkDestination | substituem destinos padrão; informe o mesmo `-AhkDestination` ao desinstalar um prompt pad customizado |
| -Force | permite substituir um AGENTS.md não gerenciado após backup |
| -WhatIf | mostra as alterações sem tocar no disco |
| `validate.ps1 -SkipInstalled` | valida apenas o checkout, sem exigir espelhos instalados |
| `doctor.ps1 -Detailed` | inclui os caminhos registrados pelo estado instalado |

O instalador é idempotente. Ele registra hashes dos arquivos que gerencia,
faz backup antes de sobrescrever e preserva arquivos fora do seu estado.

O perfil safe não instala mais defaults gerenciados em `[agents]` do
config.toml do Codex: uma seção `[agents]` existente não gerenciada é
preservada, e blocos gerenciados antigos do kit são removidos na reexecução.
O perfil safe também gerencia o backend de subagentes na tabela `[features]` do
config.toml do Codex: impõe o backend selecionado (`native` ou `deepseek`) e
configura a matriz apropriada de 5 chaves no config.toml. Divergências ou drift na
projeção gerenciada de 5 chaves falham fechado; campos de configuração não relacionados
(fora da projeção gerenciada de backend) são preservados e reconciliados no ledger de
instalação. Você pode alternar os seletores a qualquer momento via scripts; o valor
anterior é registrado no estado de instalação e restaurado no uninstall. Se você o
alterou externamente, o kit avisa e preserva sua escolha. Estados de schema 3 e 4
existentes continuam legíveis; execute `install.ps1 -Profile safe` para atualizar o
estado ao schema 5.

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
    USER["Usuário"] -->|mensagem sem modo| ALIGN["ALINHAMENTO (discussão/leitura)"]
    USER -->|prefixo explícito| WF["$workflows mode=<MODE>"]
    PAD["Prompt pad"] --> WF
    ALIGN --> PARENT["parent GPT (maestro)"]
    WF --> RULES["SKILL.md (política única)"]
    RULES --> BACKEND["Backend Selecionado (native | deepseek)"]
    BACKEND --> PARENT
    PARENT --> GATE["diff + validação + frozen target"]
~~~

O único prefixo de workflow é $workflows. Sem modo ativo (`$workflows mode=<MODE>`),
vigora o estado implícito `ALINHAMENTO`: conversa direta e discussão somente leitura,
refinamento de ideias e dúvidas, sem cerimônia de workflow (sem planos formais, specs,
todo lists ou gates) e sem narrar roteamento interno; inspeção do repositório ocorre
apenas sob dependência material (sem ferramentas que criem metadados ou estado local)
e sem mutações ou edição de arquivos, onde verbos imperativos nunca inferem modo. Um
modo explícito ativo persiste através de esclarecimentos sem prefixo até seu gate de
conclusão ou cancelamento explícito, retornando ao ALINHAMENTO após o fechamento.
Consulte skills/workflows/SKILL.md para os 16 modos (tripla capacidades | permissão |
gate de pronto) e o ciclo de vida; referências especializadas são abertas sob
demanda. O executor de sub-agentes é governado pelo seletor `subagent_backend`
(`native` com `gpt-5.6-luna` ou `deepseek` via DeepSeek Sub-Agent MCP), sob a
estratégia de `delegation_policy` (`balanced` ou `aggressive`); o parent GPT
interpreta imagens, integra, valida e decide.

## Alternância de Backend e Política

O kit oferece comandos transacionais com verificação de drift (divergências na projeção gerenciada falham fechado; campos de configuração não relacionados são preservados e reconciliados), backups automáticos e rollback em caso de falha:

~~~powershell
# Alternar backend de subagentes (native ou deepseek)
.\scripts\switch-subagent-backend.ps1 -Backend native
.\scripts\switch-subagent-backend.ps1 -Backend deepseek

# Alternar política de delegação (balanced ou aggressive)
.\scripts\switch-subagent-policy.ps1 -Policy balanced
.\scripts\switch-subagent-policy.ps1 -Policy aggressive

# Consultar status ativo
.\scripts\switch-subagent-backend.ps1 -Status
.\scripts\switch-subagent-policy.ps1 -Status
~~~

### Prompt Pad (AutoHotkey)

Com o Prompt Pad ativado (`ScrollLock`), o teclado numérico oferece atalhos diretos para workflows e atalhos com modificador `Ctrl` para controle dos seletores:

| Atalho | Ação / Comando Injetado |
|---|---|
| `Numpad0` .. `Numpad9` | `$workflows mode=<MODE>` (Workflows canônicos) |
| `Ctrl + Numpad1` (`^Numpad1`) | `.\scripts\switch-subagent-backend.ps1 -Backend native` |
| `Ctrl + Numpad2` (`^Numpad2`) | `.\scripts\switch-subagent-backend.ps1 -Backend deepseek` |
| `Ctrl + Numpad4` (`^Numpad4`) | `.\scripts\switch-subagent-policy.ps1 -Policy balanced` |
| `Ctrl + Numpad5` (`^Numpad5`) | `.\scripts\switch-subagent-policy.ps1 -Policy aggressive` |
| `Ctrl + Numpad0` (`^Numpad0`) | `.\scripts\switch-subagent-backend.ps1 -Status` |

> [!NOTE]
> Os comandos de controle injetados pelo Prompt Pad assumem que o shell ativo está posicionado no diretório raiz do repositório (`checkout root`).

## Primeiros passos

1. Instale o perfil seguro: .\scripts\install.ps1 -Profile safe.
2. Valide: .\scripts\validate.ps1.
3. Abra uma nova tarefa do Codex e envie:

~~~text
$workflows mode=PLAN.AUTO
~~~

O contrato do modo define as capacidades, a permissão de mudança, a validação
e o gate de pronto; o executor de subagentes é governado pelo backend selecionado
e o parent GPT integra, valida e decide.

## Validação

~~~powershell
.\scripts\validate.ps1
git diff --check
~~~

Após alterar o contrato canônico, reinstale o perfil seguro antes de conferir
os espelhos instalados.
