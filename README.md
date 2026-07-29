# Codex Workflows Prompt Pad

Projeto local para versionar o fluxo de atalhos NUM do Codex:

- skill global `codex-workflows`;
- skill condicional `evidence-first` para claims materiais;
- agents customizados `scout`, `researcher`, `reviewer`, `worker`;
- plugin `mcp-foundation` para CodeGraph, Context7 e OpenAI Developer Docs;
- `AGENTS.md` global reduzido;
- AutoHotkey prompt pad.

## Layout

```text
skills/codex-workflows/   Codex skill instalavel em ~/.agents/skills
skills/evidence-first/    Grounding e verificacao condicional, sem atalho
agents/                   Perfis de subagents para ~/.codex/agents
codex/AGENTS.md           Instrucoes globais compactas
plugins/mcp-foundation/   MCPs allowlisted, hook de auditoria e manutencao
ahk/codex_prompt_pad.ahk  Prompt pad AutoHotkey
scripts/install.ps1       Reinstala os arquivos nos destinos reais
scripts/validate.ps1      Valida estrutura e AHK
```

## Instalar

```powershell
.\scripts\install.ps1
```

## Validar

```powershell
.\scripts\validate.ps1
```

## MCP foundation

`mcp-foundation` empacota apenas os MCPs allowlisted:

- CodeGraph para navegacao estrutural;
- Context7 para documentacao atual de bibliotecas;
- OpenAI Developer Docs para Codex e APIs OpenAI.

O instalador registra o marketplace local, instala o plugin, copia o mantenedor
para `~/.codex/maintenance/maintain-mcps.ps1` e reaproveita a tarefa semanal
existente sem encerrar processos MCP ativos. O hook de inicio faz somente uma
auditoria local com TTL de 24 horas. O Codex exige revisao unica do hook em
`/hooks`, e o Context7 remoto exige autenticacao unica em
**Settings > MCP servers > Authenticate**.

## Quality ratchet

Modos relacionados a código aplicam passivamente a filosofia TN no trecho
tocado: impedem dívida estrutural nova e permitem uma melhoria local quando ela
é relevante, reversível e validável. Contagem de linhas apenas inicia a
inspeção; nunca ordena um split. Refatorações amplas continuam exigindo
`P.DEEP`, `IMPL.PHASE`, `REWORK` ou a auditoria explícita `TN.SKILL`.

## Cadência proporcional

O workflow começa pelo menor caminho capaz de responder à dúvida ou provar o
comportamento pedido. Ele só amplia escopo ou profundidade quando uma evidência
existente ou um risco material revela incerteza, ou quando há um gate obrigatório
ainda aberto; paraleliza trabalho independente já aprovado somente quando isso economiza tempo. Antes de
repetir uma ação sem evidência nova, ele faz um checkpoint e, quando houver uma,
tenta uma única ação diferente e mais barata; se ela falhar ou não existir, e não
houver progresso ou fechamento de gate,
reporta bloqueio ou replaneja. Cada modo tem seu próprio critério de
encerramento; em entregas de código, o caminho do usuário precisa cumprir o
aceite. Melhorias sem relação causal ficam para depois. Não há prazo fixo para
interromper subagents ativos.

## Sincronização do plano no Codex App

A faixa de passos do App acompanha chamadas explícitas a `update_plan`; ela não
deduz progresso apenas porque arquivos mudaram ou testes rodaram. Em tarefas não
triviais com duas ou mais fases, o agente principal cria de 2 a 5 passos curtos e
observáveis: o primeiro começa em andamento e os demais ficam pendentes. Depois
de comprovar uma fase e antes do primeiro comando da próxima, marca a atual como
`completed`, a próxima como `in_progress` e as futuras como pendentes. Se o
escopo mudar, atualiza o plano antes de continuar. Ao provar a última fase,
marca todos os passos como concluídos e deixa nenhum passo em andamento. Não atualiza a lista depois de cada comando, não salta etapas sem prova e reconcilia
o plano antes de concluir. Tarefas simples ou de uma fase não recebem uma lista
artificial.

## Observability

Em tarefas de código, o workflow primeiro decide se realmente precisa de
instrumentação: por padrão, não cria log. Quando ela for necessária, exige uma
pergunta diagnóstica, caminho já existente no projeto, campos seguros, limite
de volume, retenção e acesso aplicados pelo destino, forma de desligar ou
remover e falha segura que não interrompe o fluxo principal, salvo
`contrato audit/compliance` explicitamente aprovado. Não instala coletor, hook,
exportador ou serviço externo sem escopo explícito.

## Atalhos

Os atalhos `$codex-workflows` e `$antigravity-workflows` selecionam apenas o modo. O contrato completo de
cada modo vive na skill, em `references/mode-matrix.md`, no quality ratchet e
na referência de observabilidade quando aplicável;
mudanças de comportamento não exigem alterar o AHK.

```text
NUM1         $antigravity-workflows mode=PLAN.AUTO
NUM2         $antigravity-workflows mode=DELIVER.AUTO
NUM3         $antigravity-workflows mode=COMMIT
NUM4         $antigravity-workflows mode=BUG.INV
NUM5         $antigravity-workflows mode=BUG.FIX
NUM6         $antigravity-workflows mode=DEBUG
NUM7         $antigravity-workflows mode=REWORK
NUM8         $antigravity-workflows mode=R.A.F.V
NUM9         $antigravity-workflows mode=TN.SKILL
NUM*         $antigravity-workflows mode=RESEARCH.DEEP

NUM0+1       $codex-workflows mode=PLAN.AUTO
NUM0+2       $codex-workflows mode=DELIVER.AUTO
NUM0+3       $codex-workflows mode=COMMIT
NUM0+4       $codex-workflows mode=BUG.INV
NUM0+5       $codex-workflows mode=BUG.FIX
NUM0+6       $codex-workflows mode=DEBUG
NUM0+7       $codex-workflows mode=REWORK
NUM0+8       $codex-workflows mode=R.A.F.V
NUM0+9       $codex-workflows mode=TN.SKILL
NUM0+*       $codex-workflows mode=RESEARCH.DEEP

Alt+NUM1     /goal
Alt+NUM2     /grill-me
Alt+NUM3     /browser
Alt+NUM4     /schedule
Alt+NUM5     /teamwork-preview
Alt+NUM6     /learn

Ctrl+NUM7     $audiobook-codex stage=MAP
Ctrl+NUM8     $audiobook-codex stage=TRANSCRIBE
Ctrl+NUM9     $audiobook-codex stage=RENDER
```
