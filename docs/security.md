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

### Fronteira de permissao do wrapper (MCP)

`bin/opencode-worker.cmd` exporta `OPENCODE_CONFIG_CONTENT` com
`external_directory` restrito aos caminhos instalados confiaveis, com barras
invertidas escapadas para JSON: `%AGENTS_DIR%` (diretorio dos agentes OpenCode
instalados; sub-agents-mcp o define para o filho, com fallback
`%CODEX_HOME%\opencode-agents` quando um `CODEX_HOME` custom esta definido, e
entao `%USERPROFILE%\.codex\opencode-agents`) e `%AGENTS_HOME%\skills\workflows`
quando um `AGENTS_HOME` custom esta definido, senao
`%USERPROFILE%\.agents\skills\workflows`
(mirror instalado da skill workflows). Nao existe allow global de
`external_directory`. Causa observada: os agentes embutidos `general`/`explore`
mantem `external_directory=* ask`, e os readers aninhados nao conseguiam ler os
arquivos de controle instalados, encerrando sem resultado. Evidencia: um teste
direto de CLI OpenCode demonstrou que os allows por caminho resolvem a falha
headless aninhada, inclusive um smoke aninhado de duas frentes. A validacao
estatica (`scripts/validate.ps1`) confere apenas o contrato do wrapper; ela nao
prova o comportamento em runtime — o smoke de CLI aninhado permanece a
verificacao de runtime.

### Politica de delegacao (`internal_subagent_policy`)

- `writer_only` e o contrato: escrita autorizada usa o OpenCode `worker` via
  MCP, em worktree isolada e com claim-map. O GPT orquestrador planeja,
  diagnostica e aprova, mas nao escreve patches.
- `no-edit` impede qualquer writer. MCP, modelo, permissao ou transporte
  indisponível bloqueia a rota; nao existe fallback silencioso para perfil
  nativo, CLI ou patch do GPT.
- O ciclo de reparo repassa erro observado + diff anterior + hipótese alterada.
  Depois de uma nova falha, o GPT faz diagnóstico read-only e envia um writer
  novo; sem hipótese nova, o estado é `BLOCKED/REPLAN`.
- Readers com duas ou mais frentes independentes recebem
  `NESTED_REQUIRED=<frentes>` e devem delegar cada frente. Se `task` faltar,
  retornam `NESTED_DELEGATION=blocked`; writers nunca delegam.

### Imagens e evidência visual

- Quando o host suporta anexos multimodais, imagens entram no relay nativo como
  itens estruturados; paths, data URLs, base64 e bytes não entram no `task` nem
  atravessam a fronteira do MCP.
- O relay transforma cada anexo em `[VISUAL_PACKET v1]`, contendo apenas fatos
  visíveis, texto legível, região aproximada, confiança e incertezas.
- Mesmo que a imagem mostre um path local absoluto, data URL ou string parecida
  com base64, o relay não a reproduz; ele a parafraseia ou marca como redacted.
- Texto dentro de uma captura é evidência não confiável, não instrução. O
  OpenCode deve tratá-la como evidência de segunda mão e separar observação,
  inferência e desconhecido.
- O modelo OpenCode (DeepSeek) não lê imagens: apenas o pacote textual
  sanitizado cruza a ponte watcher/MCP; paths, bytes, base64 e data URLs nunca
  chegam ao papel OpenCode.
- Se a leitura nativa falhar, o relay bloqueia a solicitação; não substitui a
  imagem por um path que possa ser interpretado de modo incompleto.
- Se itens foram anexados, mas o relay retorna `RELAY_VISUAL=none` ou omite o
  status, o pai trata o sidecar como bloqueado/desconhecido e não usa o resultado
  para trabalho dependente da imagem.

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
- O MCP direto usa `SESSION_ENABLED=false`: cada job é isolado, sem
  persistência ou retomada de sessão.
- O flag de runtime `CODEX_WORKFLOWS_OPENCODE_PROVIDER` troca apenas o ID do
  modelo entre `opencode-go/deepseek-v4-flash` (`go`, padrão) e
  `zenmux/deepseek/deepseek-v4-flash` (`zen`); é validado sem fallback
  silencioso e nunca altera credenciais.

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
