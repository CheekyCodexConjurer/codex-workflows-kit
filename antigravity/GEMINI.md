# Antigravity — Regras Globais

- Para roteamento, uso seguro e manutenção de Context7, CodeGraph e Serena, consulte a skill `mcp-foundation` (`skills/mcp-foundation/SKILL.md`).
- Context7: documentação externa em `resolve` -> `query`, perguntas atômicas e sem segredos.
- CodeGraph: somente se `.codegraph` existir no repositório; nunca auto-init; fallback para `rg`.
- Serena: símbolos e LSP com leitura concorrente segura; jamais use taskkill genérico.
- Para tarefas de MCP/PromptPad, o GEMINI.md é contexto obrigatório do host/bridge quando a tarefa envolver a interface do host.
- Doctor é somente leitura; manutenção de espelhos via hashes; nunca automatize kill, restart, upgrade nem init (exceção fail-closed para o daemon DeepSeek somente com autorização expressa do usuário, comando canônico 'dist/cli.js restart --config <known-config> --json', GET '/health' falho, ownership verificado, zero jobs ativos em 'bridge.sqlite' e bounded readiness; proibido reiniciar outros MCPs/hosts ou usar taskkill/Stop-Process).
- Sem comandos destrutivos, force-push ou vazamento de credenciais.
