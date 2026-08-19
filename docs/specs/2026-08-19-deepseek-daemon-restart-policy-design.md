# Especificação de Design: Política Fail-Closed de Reinicialização do Daemon DeepSeek

- **Data**: 2026-08-19
- **Status**: Aprovado e Implementado
- **Autoridade**: Codex Workflows Kit Architecture
- **Alvo**: `codex-workflows-prompt-pad` (Codex & Antigravity)

---

## 1. Visão Geral e Contexto

Este documento formaliza a política de permissão fail-closed para recuperação do daemon do DeepSeek Sub-Agent no ambiente `codex-workflows-prompt-pad`.

Por padrão, a automatização de comandos de encerramento, reinício ou atualização de processos MCP permanece expressamente proibida. Este design estabelece uma **exceção estritamente delimitada e condicional**, autorizada pelo usuário, para restabelecer o daemon local do DeepSeek em caso de indisponibilidade comprovada da ponte.

---

## 2. Contrato da Política e Gates Obrigatórios (Fail-Closed)

A recuperação do daemon só é permitida quando **todos os gates** a seguir forem verificados cumulativamente:

1. **Autorização Expressa do Usuário**: A recuperação deve ser aprovada de forma explícita pelo operador humano. É proibido inferir permissão ou executar reinícios autônomos.
2. **Falha Comprovada de Probe**: Uma sondagem GET `/health` recente no endpoint canônico da ponte (sempre `/health`) falha de modo demonstrável (conexão recusada, timeout ou payload corrompido).
3. **Comando Canônico de Ciclo de Vida**: A execução é restrita ao comando oficial do pacote canônico:
   `dist/cli.js restart --config <known-config> --json`
4. **Verificação de Ownership**: O PID do processo, linha de comando e diretório de dados pertencem à sessão do usuário e à instalação canônica.
5. **Ausência de Jobs Ativos**: Consulta somente leitura no banco `bridge.sqlite` comprova que não existem jobs ativos ou pendentes em execução.
6. **Espera Limitada de Prontidão (Bounded Readiness)**: Após a emissão do comando canônico, realiza-se uma espera limitada até que o probe GET `/health` responda com sucesso.
7. **Aborto Fail-Closed**: Caso qualquer gate falhe ou seja inconclusivo, a recuperação é abortada imediatamente e o diagnóstico é reportado.

---

## 3. Não-Gatilhos e Proibições Estritas

- **Proibido disparar por**: `AntigravityProcessError`, falha de job de ferramentas, erros genéricos de provedor/modelo ou respostas HTTP isoladas.
- **Proibido reiniciar outros componentes**: Nunca reiniciar Codex, Antigravity, Serena, CodeGraph, Context7 ou outros servidores MCP.
- **Proibido usar comandos genéricos**: Jamais usar `taskkill`, `Stop-Process`, `kill-all` ou encerramentos por varredura de processos.
- **Sem fallbacks ou retries opacos**: Proibido adicionar fallback para outros modelos ou repetição cega de payloads.

---

## 4. Rastreabilidade de Superfícies

As regras normativas e referências estão distribuídas nas seguintes superfícies canônicas:
- [mcp-foundation SKILL.md](../../skills/mcp-foundation/SKILL.md)
- [mcp-foundation lifecycle.md](../../skills/mcp-foundation/references/lifecycle.md)
- [codex AGENTS.md](../../codex/AGENTS.md)
- [antigravity GEMINI.md](../../antigravity/GEMINI.md)
