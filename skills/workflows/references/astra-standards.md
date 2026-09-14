# Diretrizes Normativas de Prompts e Skills (GPT-6 Astra)

Este documento estabelece o padrão arquitetural obrigatório para a criação e manutenção de skills, regras de agentes (`AGENTS.md` / `GEMINI.md`) e fluxos multi-agente no ecossistema Codex e Antigravity, fundamentado nas diretrizes oficiais da OpenAI para o modelo GPT-6 Astra (*Rethinking skills and prompts for GPT-6 Astra*).

---

## 1. Princípios Arquiteturais Fundamentais

### 1.1. Divulgação Progressiva (*Progressive Disclosure*)
- **Descrições Ultracuritas no Frontmatter**: O frontmatter YAML (`description`) de qualquer skill deve ser estritamente conciso (idealmente `< 200` caracteres), limitando-se ao gatilho operacional exato. Descrições longas sofrem truncamento pelo orquestrador e poluem o contexto de descoberta.
- **Isolamento em Referências sob Demanda**: Manuais extensos, esquemas detalhados e procedimentos de ciclo de vida devem residir exclusivamente no subdiretório `references/` da skill. Agentes devem consultar esses documentos contextualmente sob demanda, sendo proibida a injeção integral desses conteúdos no prompt raiz.

### 1.2. Prevenção de Sobrecarga e Paralisia por Regras (*Over-Constrained Rules*)
- **Rigor Literal do Astra**: Modelos avançados interpretam restrições negativas e limites de forma matemática e estrita. A sobreposição de proibições redundantes induz hesitação, recusa de ação ou paradas prematuras ("parei porque uma regra disse que...").
- **Orçamento Estrito de Linhas e Bytes**: O arquivo mestre (`AGENTS.md`) deve permanecer enxuto (teto rígido de 18.000 bytes e máximo de 45 linhas), contendo apenas invariantes inegociáveis de segurança e roteamento. Detalhes operacionais pertencem às referências das skills.

### 1.3. Permissão Expressa para Execução Autônoma de Testes Locais
- **Eliminação de Fricção em Testes**: O modelo deve receber autorização prévia expressa para executar suítes de teste locais, checagens estáticas e diagnósticos contra fixtures descartáveis e seguras, sem pausar para pedir autorização ao usuário a cada ciclo ou linha corrigida.

### 1.4. Persistência de Entrega e Fim de Jogo Claro (*Done Criteria*)
- **Proibição de Parada Prematura**: É expressamente proibido interromper a execução no primeiro esboço, rascunho ou implementação parcial para perguntar se o usuário "gostaria de continuar".
- **Critério de Fechamento**: O agente deve persistir de ponta a ponta até que:
  1. A implementação esteja concluída e rodando;
  2. Os testes determinísticos estejam verificados no verde;
  3. A revisão independente esteja satisfeita (zero bloqueios P0 a P2);
  4. O commit local esteja fechado.

### 1.5. Grafos Direcionados (DAG) vs. Ping-Pong Infinito
- **Fim dos Loops Conversacionais Abertos**: Arquiteturas de múltiplos agentes nunca devem operar como bate-papos livres ou debates sem fim. A delegação deve ser estruturada como um grafo acíclico dirigido (DAG) com papéis assimétricos e critérios objetivos de término.
- **Revisão em Rodada Única (*Single-Turn Review*)**: Revisões de código operam em rodada única baseada em evidência executável. A discussão subjetiva de estilo de código não tem poder de veto.

---

## 2. Taxonomia de Severidade de Defeitos (Régua P0 a P4)

Ao autorar ou revisar código nos fluxos de escrita, todo apontamento deve subordinar-se à seguinte régua determinística:

| Nível | Classificação | Critério Técnico | Efeito no Portão de Entrega |
| :--- | :--- | :--- | :--- |
| **P0** | Crítico / Showstopper | Crash fatal, quebra de build, perda de dados, falha crítica de segurança ou indisponibilidade do fluxo principal. | **Gera `blocker` / Veredito `BLOCKED`** |
| **P1** | Alto | Requisito planejado não implementado ou regressão grave em fluxo secundário sem contorno. | **Gera `blocker` / Veredito `BLOCKED`** |
| **P2** | Médio | Defeito de lógica comprovado, quebra de contrato de API/dados acordado ou caso limite com falha determinística. | **Gera `blocker` / Veredito `BLOCKED`** |
| **P3** | Baixo | Inconsistência estética menor, desvio cosmético não funcional ou oportunidade de refatoração opcional. | **Gera `advisory` / Veredito `APPROVED`** (não bloqueia) |
| **P4** | Cosmético | Preferência de estilo de código, nomes alternativos de variáveis/funções ou opiniões subjetivas de IA. | **Gera `advisory` / Veredito `APPROVED`** (não bloqueia) |

---

## 3. Checklist Obrigatório para Criação ou Edição de Skills / Regras

Antes de submeter alterações em `skills/*/SKILL.md`, `codex/AGENTS.md` ou `antigravity/GEMINI.md`, o agente deve verificar:

1. [ ] A descrição da skill no frontmatter possui menos de 200 caracteres e descreve apenas o trigger?
2. [ ] Manuais extensos ou esquemas foram isolados em `references/` em vez de ficarem no corpo principal?
3. [ ] Há autorização prévia expressa para execução e correção autônoma de testes locais seguros?
4. [ ] O critério de conclusão (*Done Criteria*) está explícito, proibindo paradas prematuras em esboços?
5. [ ] A régua de bloqueio restringe-se a falhas comprovadas P0 a P2, tratando P3/P4 como informativos?
6. [ ] No modo `swarm`, o trabalho linear permanece na mesma trilha, evitando micro-estilhaçamento?
7. [ ] O tamanho do `codex/AGENTS.md` permanece estritamente abaixo de 18.000 bytes e 45 linhas?
