# Antigravity — Regras Globais

- Para roteamento, uso seguro e manutenção de Context7, CodeGraph e Serena, consulte a skill `mcp-foundation` (`skills/mcp-foundation/SKILL.md`).
- Context7: documentação externa em `resolve` -> `query`, perguntas atômicas e sem segredos.
- CodeGraph: somente se `.codegraph` existir no repositório; nunca auto-init; fallback para `rg`.
- Serena: símbolos e LSP com leitura concorrente segura; jamais use taskkill genérico.
- Para tarefas de MCP/PromptPad, o GEMINI.md é contexto obrigatório do host/bridge quando a tarefa envolver a interface do host.
- Doctor é somente leitura; manutenção de espelhos via hashes; nunca automatize kill, restart, upgrade nem init; proibido reiniciar, fechar, logar ou deslogar Antigravity e nunca tocar auth, profile, cookies ou cache (exceção fail-closed para o daemon DeepSeek sob autorização permanente do usuário neste host, comando canônico 'dist/cli.js restart --config <known-config> --json', GET '/health' falho, ownership verificado, jobs com spool comprovado em 'bridge.sqlite', bounded readiness em tentativa única e sem fallback; proibido reiniciar outros MCPs/hosts ou usar taskkill/Stop-Process).
- Sem comandos destrutivos, force-push ou vazamento de credenciais.
