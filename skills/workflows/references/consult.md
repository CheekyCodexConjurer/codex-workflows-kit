# External Consultation

Use only for `mode=CONSULT`.

## Contract

- Mode: `CONSULT`
- Capabilities: `read`
- Change permission: `no-write` (strictly read-only; no file creation, modification, deletion, build, test execution, or git mutations).
- Done gate: `external consultation prompt delivered` (single copy-pasteable markdown code block).
- Treat trailing text as additional context or the explicit technical question.

## Context Collection

Before generating the consultation prompt, collect:

1. **Repository Identity**: Remote GitHub repository URL (`git remote get-url origin`), current branch name (`git branch --show-current`), and current commit hash (`git rev-parse --short HEAD`).
2. **Local In-Flight State**: Status of uncommitted or unpushed changes (`git status --porcelain`). If dirty files or local commits exist, generate a compact summary or diff so the external model understands the exact local delta not yet on GitHub.
3. **The Core Dilemma**: The pending question, technical trade-off, architectural choice, or ambiguity raised in the conversation.
4. **Environment & Constraints**: Language, framework versions, and project-specific constraints.

## Output Format

The output must consist of a **single markdown code block** containing the complete, ready-to-paste prompt for the external LLM. Do not surround the code block with conversational filler or lengthy preamble.

### Prompt Template

````markdown
```markdown
Você é um Arquiteto de Software Sênior e Consultor Técnico. Estou desenvolvendo um projeto localmente e preciso da sua recomendação técnica para uma decisão arquitetural.

### Contexto do Repositório
- Repositório GitHub: <GITHUB_REPO_URL>
- Branch Ativa: <BRANCH_NAME>
- Commit Base: <COMMIT_HASH>

### Estado Local (Alterações ainda não enviadas ao GitHub)
<RESUMO_OU_DIFF_DO_ESTADO_LOCAL_OU_NENHUMA_ALTERACAO_PENDENTE>

### O Impasse Técnico / Pergunta
<DESCRICAO_CLARA_DO_DILEMA_OU_PERGUNTA_FEITA_PELA_LLM_LOCAL>

### Opções em Análise
1. Opção A: <DESCRICAO_E_PRÓS_CONTRAS>
2. Opção B: <DESCRICAO_E_PRÓS_CONTRAS>

### Regras do Projeto
Este projeto utiliza o framework de workflows codex-workflows-kit:
https://github.com/CheekyCodexConjurer/codex-workflows-kit

Se a resposta exigir investigação aprofundada de código ou dependências externas, recomende o uso de:
`mode=RESEARCH.DEEP <tópico>`

### Formato de Resposta Solicitado
Responda de forma direta e concisa:
1. Sua decisão/recomendação fundamentada.
2. A justificativa técnica essencial (prós, contras e riscos mitigados).
3. O comando ou instrução exata para eu colar de volta no chat do meu editor (por exemplo: `mode=IMPL ...` ou `mode=RESEARCH.DEEP ...`).
```
````
