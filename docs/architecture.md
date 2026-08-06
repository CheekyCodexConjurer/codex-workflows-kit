# Arquitetura do Codex Workflows Kit

Este documento resume os contratos que o instalador e
`scripts/validate.ps1` verificam. A fonte canônica da política de sub-agents é
`skills/workflows/references/backend-policy.md`; os demais arquivos apenas
explicam ou espelham esse contrato.

## Componentes

- `skills/workflows`: roteador dos modos `$workflows mode=<MODE>` e suas
  referências;
- `agents/opencode/*.md`: papéis OpenCode de leitura e escrita;
- `agents/*.toml`: perfis nativos, protegidos pelo guard de rota;
- `codex/AGENTS.md`: regras globais compactas;
- `plugins/mcp-foundation`: somente CodeGraph, Context7 e OpenAI Developer
  Docs;
- `scripts/`: instalação, validação, diagnóstico e remoção.

O perfil `safe` instala os assets, mas não configura MCP, OpenCode ou AHK. Essas
integrações continuam opt-in por flags do instalador.

## Rota de execução

```mermaid
flowchart LR
    USER["prompt $workflows mode=..."] --> GPT["GPT orquestrador"]
    GPT --> READ["leitura / diagnóstico"]
    READ --> MCP["opencode_worker MCP"]
    MCP --> READER["OpenCode reader"]
    GPT --> PREFLIGHT["claim-map + worktree limpa"]
    PREFLIGHT --> MCPW["opencode_worker MCP"]
    MCPW --> WRITER["OpenCode worker"]
    WRITER --> VERIFY["teste + revisão do diff"]
    VERIFY -->|passa| MERGE["merge mecânico"]
    VERIFY -->|falha| REPAIR["W2 reparo"]
    REPAIR --> VERIFY
    VERIFY -->|W2 falha| DIAG["GPT diagnóstico read-only"]
    DIAG --> W3["W3 writer novo"]
    W3 --> VERIFY
```

O GPT orquestrador é dono do plano, dos contratos, do diagnóstico, dos testes,
da revisão e da aprovação. Ele não escreve nem improvisa patch. Em uma entrega
autorizada, todo patch nasce no OpenCode `worker`; o GPT só pode aplicar
mecanicamente o diff aceito no gate de merge.

O ciclo de escrita é fixo:

```text
PREFLIGHT -> W1 -> VERIFY
VERIFY pass -> ACCEPT/MERGE
VERIFY fail -> W2 repair (erro + diff anterior + hipótese alterada)
W2 fail -> diagnóstico read-only do GPT -> W3 writer novo
W3 fail ou sem hipótese nova -> BLOCKED/REPLAN
```

Falha de transporte pode receber uma nova tentativa pela mesma rota. Isso não
é fallback de conteúdo: nunca se troca OpenCode por perfil nativo, CLI direta
ou patch do GPT silenciosamente.

## Papéis e permissões

Readers (`scout`, `researcher`, `reviewer`) são somente leitura: `edit: deny` e
`bash: deny`. Writers (`worker`) podem editar apenas o claim-map em uma
worktree isolada: `edit: allow`, `bash: deny`, `task: deny` e
`external_directory: deny`.

Quando um reader recebe duas ou mais frentes independentes, o prompt contém
`NESTED_REQUIRED=<frentes>`. Ele deve delegar uma tarefa read-only por frente,
aguardar e integrar todas as respostas. Se `task` não estiver disponível,
retorna `NESTED_DELEGATION=blocked`; não absorve silenciosamente todas as
frentes. Writers nunca delegam.

Antes de um writer, o GPT confirma uma worktree absoluta diferente do checkout
principal, `git status --porcelain` vazio e registra
`WRITER_BASELINE=<git rev-parse HEAD>`. Também envia
`WRITER_WORKTREE=<cwd>`. Diff fora do claim-map ou mutação do checkout
principal bloqueia a integração.

Os perfis nativos analíticos (`scout`, `researcher`, `reviewer`, `worker`)
retornam `NATIVE_ROUTE_BLOCKED` enquanto o backend for OpenCode. O `relay`
nativo não é analista nem writer; sua única exceção é transformar anexos visuais
em um bloco textual `[VISUAL_PACKET v1]`, sem paths, bytes, base64 ou data URLs.

## Jobs longos

Sidecars textuais usam diretamente o MCP `opencode_worker`. `run_agent` serve
para smoke bounded; `start_agent` inicia um job longo e devolve um `job_id`.
Depois de iniciar, o GPT continua trabalho local não sobreposto e consulta
`get_agent_status(job_id)` no primeiro checkpoint de espera prolongada ou de
decisão. Heartbeat vivo e `state=running` significam que deve aguardar; só
`result_available=true` ou estado terminal autoriza `get_agent_result`.

Heartbeat stale, processo ausente, erro MCP ou estado desconhecido exigem
diagnóstico e reparo/replanejamento; não autorizam espera cega, polling
contínuo, cancelamento ou relançamento sem nova decisão.

## Instalação e validação

`install.ps1` copia os assets com backup. `-Profile safe` instala a base;
`-ConfigureMcp` configura o MCP pinado; `-InstallAhk` instala o prompt pad.
Após mudanças nas fontes, execute `scripts/install.ps1 -Profile safe` antes de
validar os espelhos instalados.

`scripts/validate.ps1` verifica frontmatter, permissões, guard de rota,
exposição do MCP, contratos de nested delegation, ciclo de writers, paridade
dos destinos e higiene do diff. Health/config/hash não substituem smoke real:
quando solicitado, valide também a rota direta do MCP e o estado do job.
