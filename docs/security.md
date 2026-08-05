# Segurança do Codex Workflows Kit

Este documento descreve o modelo de ameaças do kit e as mitigacoes aplicadas.
A politica de reporte de vulnerabilidades esta em `SECURITY.md`.

## Resumo do modelo de ameacas

O kit instala scripts PowerShell, skills, perfis de agentes e um prompt pad
AutoHotkey nos diretorios do usuario (`~/.agents`, `~/.codex`). As superficies
de risco relevantes sao:

1. **Execucao de codigo local** — scripts do proprio checkout (instalador,
   validador, mantenedor MCP);
2. **Servidores MCP** — dois remotos (Context7, OpenAI Developer Docs) com
   autenticacao, um local (CodeGraph);
3. **Agentes com permissoes** — readers e writer com limites diferentes;
4. **Segredos e dados** — prompts, tokens e caminhos que passam pelo agente;
5. **Artefatos residuais** — backups `.bak` e tarefa semanal.

## Instalacao segura (nunca `irm | iex`)

- **Nunca instale com pipeline remoto.** `irm ... | iex` executa codigo nao
  revisado. O fluxo suportado e: clone/baixe o repositorio, revise `scripts/`
  e rode os comandos do checkout.
- Os perfis sem `-ConfigureMcp` copiam somente arquivos locais. Com
  `-ConfigureMcp`, o mantenedor pode chamar Codex CLI, npm e provedores externos
  para reparar a fundação MCP; revise esse escopo antes de executar.
- A politica de execucao recomendada e apenas `RemoteSigned` no escopo do
  usuario, nunca bypass.
- Antes de sobrescrever destinos existentes, o instalador cria backups
  versionados em `%CODEX_HOME%\backups\codex-workflows-kit` — use `-WhatIf`
  para pre-visualizar o que seria alterado.
- Os hooks e a tarefa agendada usam ExecutionPolicy Bypass apenas para invocar
  scripts locais da configuração já revisada; isso não autoriza pipeline remoto
  e pode ser proibido pela política da organização.

## Permissoes e limites por agente

O nivel MCP `AGENT_PERMISSION=yolo` e usado apenas porque `read-only` negaria
`task` e `external_directory` por padrao. **Isso nao transforma o MCP em
sandbox de nivel de sistema**; o limite efetivo e o frontmatter de cada
definicao OpenCode:

| Agente | edit | bash | task | external_directory | uso |
|---|---|---|---|---|---|
| reader (`scout`, `researcher`, `reviewer`) | deny | deny | allow | allow | somente leitura; podem usar sub-agents e ler fora do repo |
| writer (`worker`) | allow | deny | deny | deny | somente edicao no claim-map, em worktree isolada |

O writer nunca executa bash, nao delega, nao escreve fora da worktree isolada
e so recebe claim-map, worktree e baseline verificados pelo agente principal.
`question`, `skill`, `todowrite` e LSP continuam negados em todos os perfis.

Recomendacoes operacionais:

- Nao envie segredos em prompts.
- Use worktrees isoladas para qualquer trabalho de writer.
- Revise o diff e o guard de caminhos antes de integrar (o agente principal
  ja o faz por contrato).

## MCP foundation

- Allowlist estrita: `codegraph`, `context7`, `openaiDeveloperDocs`. Nenhum
  outro MCP e auto-instalado.
- `codegraph` e local (navegacao estrutural do proprio repositorio).
- `context7` e `openaiDeveloperDocs` sao remotos e exigem autenticacao unica
  explicita em **Settings > MCP servers > Authenticate**; o plugin nao instala
  credenciais por conta propria.
- O hook `SessionStart` executa somente uma auditoria local com TTL de 24
  horas (registra um "hook audit" local; nao coleta nem envia dados).
- O plugin nao define starter prompts e nao adiciona coletores, hooks,
  exportadores ou endpoints externos alem do allowlist.

## Segredos e dados

- O kit nao registra telemetria e nao coleta dados do usuario.
- Logs: o padrao e nenhuma instrumentacao nova; quando um log e necessario,
  exige pergunta diagnostica, campos allowlisted/redigidos, volume limitado,
  retencao e acesso definidos pelo destino, forma de desligar/remover e
  fail-open (nunca interrompe o fluxo principal) — salvo contrato
  audit/compliance explicitamente aprovado.
- O MCP de relay usa `SESSION_ENABLED=false`: cada conversa e isolada, sem
  persistencia ou retomada de sessao.

## Backups e artefatos

- Backups versionados ficam em
  `%CODEX_HOME%\backups\codex-workflows-kit`; revise e limpe backups antigos
  periodicamente, pois podem conter estado anterior das configs.
- A tarefa semanal de manutenção MCP só é criada com
  `-InstallScheduledTask`; quando criada, pode reutilizar a tarefa existente.

## Remocao

`uninstall.ps1` remove os arquivos gerenciados pelo kit e os blocos que ele
adicionou. Ele preserva registros MCP, marketplaces, tarefas agendadas,
backups, pacotes externos e o próprio checkout. Use `-WhatIf` para
pre-visualizar.

### Limpeza externa opcional

Depois de revisar o impacto, remova manualmente as tarefas
`Codex MCP Foundation Maintenance` e `CodeGraph Auto Update` caso não sejam
mais desejadas. Liste primeiro com `Get-ScheduledTask`; só então use
`Unregister-ScheduledTask` com confirmação explícita. Revise também os plugins
e marketplaces registrados pelo Codex e remova apenas os que apontarem para
este kit. O diretório `%CODEX_HOME%\maintenance` (incluindo logs e estado da
auditoria) também é preservado para evitar apagar evidência operacional. Os
backups permanecem recuperáveis em `%CODEX_HOME%\backups\codex-workflows-kit`.

## Limitações conhecidas

- Nao e um sandbox de sistema: permissoes sao cooperativas (frontmatter do
  agente) e validadas por `validate.ps1`, mas um agente comprometido pode
  tentar executar acoes dentro do que o runtime do host permitir.
- MCPs remotos dependem dos provedores (Context7, OpenAI); revise os terminos
  de cada servico antes de autenticar.
- O hook de auditoria e local e best-effort; nao e um mecanismo de compliance.
- Em instalações com `-CodexHome` não padrão, defina também `CODEX_HOME` no
  ambiente do runtime para que o hook `SessionStart` audite o mesmo destino.

## Reportando vulnerabilidades

Nao abra issue publica para vulnerabilidades. Siga o processo em
`SECURITY.md` (contato privado, passos de reproducao e divulgacao coordenada).
