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
  - Sob `aggressive`, o parent atua como arquiteto, decisor, integrador e gatekeeper (architect, decider, integrator, and gatekeeper).
  - Consome um pacote pequeno de evidência decisória (*decision evidence packet*: target/diff congelado, regiões críticas, evidências de testes/revisão, conflitos), sem refazer bulk delegado (*never redo delegated bulk*) nem duplicar trabalho material no contexto principal.
- **Estratégia de Execução**:
  - Todo trabalho material é delegado ao backend de subagentes selecionado.
  - **Trilhas Coesas e Persistentes**: Mantém uma trilha persistente por frente coesa (*one persistent track per cohesive front*) continuando a mesma sessão aberta via `deepseek_continue` (ou controle de sessão nativo), sem `allow_respawn`.
  - **Sem Microdelegação**: Proibida microdelegação (*no microdelegation*); abre nova trilha apenas para deliverable independentemente aceitável (*new track only for independently acceptable deliverable*) ou rejeitável.
  - **Fan-Out Antecipado em Lote**: Mapeia todas as frentes materiais independentes e as lança em lote (*batch spawn*) antes do primeiro comando de espera (`follow`/`wait`), maximizando a taxa de transferência.
  - **Fechamento e Timeouts**: Fatias são desenhadas para fechar terminalmente dentro da janela; após timeout ou ausência de fechamento, continua na mesma trilha pedindo inventário mínimo e fatias pequenas de fechamento (*closure slices pequenos*), sendo proibido repetir integralmente a frente ou abrir novo agente substituto.
  - O parent recebe e sintetiza apenas os resultados terminais estruturados para validar e tomar as decisões de roteamento e aceitação.

---

## 4. Delegação no Estado Implícito ALINHAMENTO

No ALINHAMENTO (estado implícito quando não há modo explícito de workflow ativo):
- **Conversa Simples e Sem Cerimônia**: Permanece direta no parent GPT sem spawn de subagentes, sem cerimônia de workflow (sem planos formais, specs, todo lists, gates ou classificação de delivery), sem narrar roteamento interno e sem inspeção do repositório a menos que haja dependência material real.
- **Delegação Condicional Somente Leitura**: Subagentes são autorizados condicionalmente exclusivamente para tarefas de inspeção somente leitura do repositório quando a resposta depender materialmente do repositório e a escala do repositório, frentes de busca concorrentes e independentes ou compressão volumosa de contexto trouxerem ganho material de velocidade ou qualidade.
- **Escopo e Restrições**: Devem utilizar estritamente o backend global selecionado (`subagent_backend`), capacidade estritamente `analyze`/`read`, sem fallback de backend, sem acionar ferramentas/ativações que criem metadados ou estado no workspace (falha fechado se a leitura exigir mutação), seguindo o ciclo normal de ledger de requisições, consumo e fechamento de lifecycle.
- **Estreitamento da Política**: Esta regra constitui um estreitamento delimitado e uma exceção à política `aggressive` apenas sob `ALINHAMENTO`; execuções sob modos explícitos de workflow retêm integralmente a política configurada (`balanced` ou `aggressive`).

---

## 5. Persistência de Sessão vs. Recuperação

- **Continuação Normal (Persistência de Trilha)**:
  - Uma trilha persistente continua normalmente o mesmo agente/sessão aberto com `deepseek_continue`, sem usar `allow_respawn`.
- **Recuperação Excepcional (`allow_respawn=true`)**:
  - O uso de `allow_respawn=true` é estritamente uma operação de recuperação pós-fechamento após um agente ter sido encerrado com um resultado terminal persistido válido.
  - Restrito ao mesmo pedido, escopo, cwd, ownership e modelo originais.
  - Nunca deve ser utilizado ou descrito como método rotineiro de persistência de sessão.
  - Recuperação de jobs `running`, abortados ou sem resultado terminal persistido permanece estritamente proibida.

---

## 6. Instalação e Escopo de Configuração

- A instalação global preserva/instala a flag selecionada como aggressive (ou balanced) na configuração de usuário (`~/.codex/config.toml`).
- Não injeta flags em repos consumidores: repositórios de trabalho e projetos dos usuários nunca recebem flags injetadas ou arquivos de configuração no workspace.

---

## 7. Matriz de Decisão Rápida

| Critério | `balanced` (Padrão) | `aggressive` |
| :--- | :--- | :--- |
| **Meta Principal** | Menor tempo total de entrega (*wall-clock time*) | Menor consumo de tokens do parent GPT (*token offload*) |
| **Papel do Parent** | Executor direto no caminho crítico e integrador | Arquiteto, decisor, integrador e gatekeeper |
| **Trabalho Sequencial/Coeso** | Executado diretamente pelo Parent GPT se eficiente | Delegado a subagente persistente por frente coesa |
| **Pesquisa e Exploração** | Híbrida: direta se concisa, delegada se ampla/volumosa | Sempre delegada |
| **Escrita e Edição** | Direta se linear/crítica, delegada se paralelizável | Sempre delegada (sem refazer bulk delegado) |
| **Revisão e Validação** | Validação determinística direta + revisão por modo | Validação e revisão via subagentes dedicados |
| **Backend de Execução** | Determinado por `subagent_backend` | Determinado por `subagent_backend` |
| **Fan-Out de Delegação** | Condicional (paralelismo real / risco / contexto) | Exaustivo em lote para frentes independentes |
