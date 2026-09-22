# Codex Workflows Kit

Kit local para instalar a interface `$workflows`, a skill `evidence-first`
e um Prompt Pad opcional. Para novas tarefas, há dois seletores:
`subagent_backend` (`native` ou `deepseek`) e
`subagent_continuation` (`active_follow` ou `park_and_wake`).

A orquestração adaptativa é o padrão. O GPT decide por etapa entre execução
direta, reutilização de worker, delegação coesa ou frentes independentes em
paralelo, conforme permissão, dependências, capacidade e ganho de tempo.
Revisão independente e validação obrigatória permanecem separadas da decisão
de execução. Jev auxilia ambiguidades sem alterar backend ou aprovar código.
A instalação faz backup e oferece reversão. O bridge permanece transporte
neutro, e não há push automático.

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
| scripts locais | checkout | instalação, alternância de backend/continuação, validação, diagnóstico e remoção |

O contrato único e detalhado é skills/workflows/SKILL.md (ciclo de vida,
semântica das ferramentas MCP/nativas, modos pela tripla capacidades | permissão |
gate de pronto e auditoria final); skills/workflows/references/ contém apenas
referências especializadas abertas sob demanda (delegation, delivery-review, research, observability,
validation, commit, quality-ratchet, skill-routing e context-reranking).

## Requisitos

- Windows 10 ou 11;
- PowerShell 5.1+ ou PowerShell 7+ (totalmente suportado em ambas as versões de runtime para workflows, skill routing e context reranking);
- Codex (o perfil safe gerencia o seletor `subagent_backend` — `native` com `gpt-6-luna` ou `deepseek` via SubAgents MCP);
- opcionalmente, AutoHotkey v2 para o prompt pad;
- opcionalmente, chave `TYPESAFE_API_KEY` para otimização semântica via TypeSafe/Jev (skill routing e context reranking com fallbacks locais seguros).

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
Consulte `skills/workflows/SKILL.md` para os modos, permissões e gates.
O backend selecionado fixa as ferramentas: `native` usa subagentes Codex;
`deepseek` usa o SubAgents MCP com Gemini. A continuação governa espera e
retomada. O GPT conserva arquitetura, decisões difíceis e aprovação, enquanto
workers executam frentes delimitadas com ordem de serviço versionada e
resultado ligado a critérios de aceite.

## Alternância de backend e continuação

`active_follow` espera dentro da run; `park_and_wake` usa recibo armado e
retomada na mesma tarefa. `park_and_wake` retorna imediatamente com `ParkReceipt`
e só encerra a run como `SUSPENDED` quando a retomada estiver armada.
Um `active writer` representa entrega diferida durável (`deferred_active_writer`).

Os comandos preservam configuração não relacionada, verificam divergências e
fazem backup antes da troca. Estados antigos são migrados para o esquema atual
sem ativar políticas paralelas.

~~~powershell
.\scripts\switch-subagent-backend.ps1 -Backend native
.\scripts\switch-subagent-backend.ps1 -Backend deepseek
.\scripts\switch-subagent-continuation.ps1 -Continuation active_follow
.\scripts\switch-subagent-continuation.ps1 -Continuation park_and_wake
.\scripts\switch-subagent-backend.ps1 -Status
.\scripts\switch-subagent-continuation.ps1 -Status
~~~

### Prompt Pad (AutoHotkey)

Com o Prompt Pad ativado (`ScrollLock`), o teclado numérico oferece atalhos diretos para workflows e atalhos com modificador `Ctrl` para controle dos seletores:

| Atalho | Ação / Comando Injetado |
|---|---|
| `Numpad0` .. `Numpad9` | `$workflows mode=<MODE>` (Workflows canônicos) |
| `Ctrl + Numpad1` (`^Numpad1`) | `.\scripts\switch-subagent-backend.ps1 -Backend native` |
| `Ctrl + Numpad2` (`^Numpad2`) | `.\scripts\switch-subagent-backend.ps1 -Backend deepseek` |
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
