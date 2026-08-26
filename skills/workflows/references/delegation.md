# Subagent Delegation Policies

Esta referência detalha as duas políticas de delegação globais ortogonais (`balanced` e `aggressive`) e sua interação com os seletores de backend (`native` e `deepseek`) para tarefas e sessões do Codex.

---

## 1. Princípios Gerais e Seletores Ortogonais

Existem dois seletores globais ortogonais e independentes:

1. **`subagent_backend` (`native` | `deepseek`)**:
   - Governa estritamente a família de ferramentas autorizada para delegação.
   - `native`: autoriza subagentes nativos do Codex (`multi_agent_v1__spawn_agent`/`spawn_agent`/`wait_agent`) com `model="gpt-5.6-luna"`, `reasoning_effort="max"` e modo default/normal (`fast_mode = false`); proíbe contato com o MCP DeepSeek. Não requer solicitação explícita prévia do usuário.
   - `deepseek`: autoriza as ferramentas MCP DeepSeek (`deepseek_spawn`, `deepseek_continue`, `deepseek_follow`); proíbe o uso de ferramentas nativas de trabalho pelo parent.
   - Fixação estrita de rota (*route pinning*): fallback silencioso entre backends é estritamente proibido.

2. **`delegation_policy` (`balanced` | `aggressive`)**:
   - Governa a estratégia de divisão de trabalho entre o parent GPT e os subagentes delegados.

### Invariantes Comuns a Ambas as Políticas:
- **Ciclo de Vida de Completude (*Completion Lifecycle*)**: Todo job delegado deve ser consumido com resposta terminal e resultado terminal antes de um gate dependente ou da resposta final.
- **Ledger Estável de Requisições**: O parent GPT mantém um ledger estruturado registrando `request_id`, frente de trabalho, identificador do agente/job, estado (`running`, `completed`, `failed`), status de consumo e encerramento explícito.
- **Permissões Estritas por Modo**: O papel e as capacidades do subagente subordinam-se estritamente à matriz de modos do Codex Workflows Kit.
- **Interpretação de Contexto Visual**: O parent GPT interpreta todo `visual_context` (imagens, capturas de tela, mockups) e sintetiza descrições textuais precisas para o subagente, nunca delegando interpretação visual cega.

---

## 2. Política `balanced` (Padrão)

**Foco Principal**: Otimização do tempo de relógio (*wall-clock time*) e eficiência de fluxo.

- **Comportamento do Parent GPT**:
  - Executa tarefas sequenciais, coesas, de integração e de caminho crítico diretamente no contexto principal quando o round-trip de delegação não traria ganho de tempo.
  - Não há fan-out obrigatório: frentes lineares simples permanecem coesas no parent.
  - Gerencia o fluxo crítico, o mapa de dependências e a síntese final.
- **Gatilhos para Delegação**:
  - **Paralelismo Concreto**: Quando duas ou mais frentes independentes podem ser executadas simultaneamente para reduzir o tempo total de resposta.
  - **Especialização Técnica**: Quando a análise de um subsistema isolado ou execução de diagnósticos se beneficia de contexto focado.
  - **Isolamento de Risco e Blast Radius**: Quando a exploração ou teste de caminhos alternativos deve ser contida sem poluir a árvore principal de trabalho.
  - **Compressão e Eficiência de Contexto**: Quando leituras volumosas de logs, traces ou documentação extensa consumiriam a janela de contexto do parent.

---

## 3. Política `aggressive`

**Foco Principal**: Desoneração máxima de tokens e carga cognitiva do Parent GPT (*token offload*).

- **Comportamento do Parent GPT**:
  - Atua estritamente como orquestrador, arquiteto e tomador de decisões.
  - Não executa trabalho material de leitura extensa, pesquisa, escrita de código, execução de testes ou revisão no contexto principal.
- **Estratégia de Execução**:
  - Todo trabalho material é delegado ao backend de subagentes selecionado.
  - **Trilhas Coesas e Persistentes**: Mantém um subagente persistente por trilha coesa de trabalho continuando a mesma sessão aberta via `deepseek_continue` (ou controle de sessão nativo), sem `allow_respawn`.
  - **Fan-Out Antecipado em Lote**: Mapeia todas as frentes materiais independentes e as lança em lote (*batch spawn*) antes do primeiro comando de espera (`follow`/`wait`), maximizando a taxa de transferência.
  - O parent recebe e sintetiza apenas os resultados terminais estruturados para validar e tomar as decisões de roteamento e aceitação.

---

## 4. Persistência de Sessão vs. Recuperação

- **Continuação Normal (Persistência de Trilha)**:
  - Uma trilha persistente continua normalmente o mesmo agente/sessão aberto com `deepseek_continue`, sem usar `allow_respawn`.
- **Recuperação Excepcional (`allow_respawn=true`)**:
  - O uso de `allow_respawn=true` é estritamente uma operação de recuperação pós-fechamento após um agente ter sido encerrado com um resultado terminal persistido válido.
  - Restrito ao mesmo pedido, escopo, cwd, ownership e modelo originais.
  - Nunca deve ser utilizado ou descrito como método rotineiro de persistência de sessão.
  - Recuperação de jobs `running`, abortados ou sem resultado terminal persistido permanece estritamente proibida.

---

## 5. Matriz de Decisão Rápida

| Critério | `balanced` (Padrão) | `aggressive` |
| :--- | :--- | :--- |
| **Meta Principal** | Menor tempo total de entrega (*wall-clock time*) | Menor consumo de tokens do parent GPT (*token offload*) |
| **Trabalho Sequencial/Coeso** | Executado diretamente pelo Parent GPT se eficiente | Delegado a subagente |
| **Pesquisa e Exploração** | Híbrida: direta se concisa, delegada se ampla/volumosa | Sempre delegada |
| **Escrita e Edição** | Direta se linear/crítica, delegada se paralelizável | Sempre delegada |
| **Revisão e Validação** | Validação determinística direta + revisão por modo | Validação e revisão via subagentes dedicados |
| **Backend de Execução** | Determinado por `subagent_backend` | Determinado por `subagent_backend` |
| **Fan-Out de Delegação** | Condicional (paralelismo real / risco / contexto) | Exaustivo em lote para frentes independentes |
