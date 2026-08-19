# Especificação de Design: Compatibilidade Superpowers no Codex Workflows PromptPad

- **Data**: 2026-08-19
- **Status**: Proposta em Revisão (Aguardando Aprovação do Usuário)
- **Autoridade**: Codex Workflows Kit Architecture
- **Alvo**: `codex-workflows-prompt-pad` (Codex & Antigravity)

---

## 1. Visão Geral e Objetivos

Este documento apresenta a proposta arquitetural para integrar métodos e técnicas comprovadas do ecossistema Superpowers ao `codex-workflows-prompt-pad`, preservando integralmente a soberania de governança, permissões e orquestração do kit `$workflows`.

O objetivo primário é disponibilizar métodos operacionais avançados (como TDD sistemático, decomposição estruturada de hipóteses e checklists rigorosos de verificação) sem inchar o contexto do modelo nem violar as regras de delegação via DeepSeek Sub-Agent MCP e integridade de repositório.

---

## 2. Autoridade e Precedência de Governança

O framework `$workflows` mantém precedência absoluta e atua como a **única autoridade de governança, permissões, delegação e operações Git** sempre que estiver presente.

```
+-------------------------------------------------------------------+
|                        $workflows (Autoridade)                    |
|  - 16 modos estritos (capabilities | permissão | gate de pronto)  |
|  - Orquestração única: DeepSeek Sub-Agent MCP                     |
|  - Gate de Git local / Commit series (nunca push)                 |
+---------------------------------+---------------------------------+
                                  | subordina / restringe
                                  v
+-------------------------------------------------------------------+
|                 Superpowers Methods (Operacional)                 |
|  - Técnicas de engenharia (TDD, Systematic Debug, Checklists)     |
|  - Roteamento just-in-time e referências sob demanda              |
+-----------------------------------+-------------------------------+
```

### Regras de Precedência:
1. **Soberania de Modos**: Nenhuma instrução do Superpowers pode conceder escrita em modos no-write (`PLAN`, `PLAN.AUTO`, `RESEARCH.DEEP`, `BUG.INV`, `REVIEW`, `REWORK`, `TN.SKILL`), nem autorizar comandos Git fora de `COMMIT` e dos modos write delivery.
2. **Delegação Exclusiva**: Toda execução de tarefas paralelas ou materiais passa obrigatoriamente pelas ferramentas do DeepSeek Sub-Agent MCP (`deepseek_spawn`, `deepseek_continue`, `deepseek_follow`). O uso de spawn nativo ou subagentes paralelos não gerenciados do Superpowers é expressamente proibido.
3. **Imutabilidade de Políticas**: O arquivo canônico `skills/workflows/SKILL.md` e as regras globais (`codex/AGENTS.md` e `antigravity/GEMINI.md`) sobrepõem qualquer heurística importada do Superpowers.

---

## 3. Roteador Automático Leve e Adaptador de Compatibilidade (`using-superpowers`)

Em vez de injetar dezenas de skills ou prompts extensos no contexto base do modelo, adota-se um **roteador automático leve** atuando como um **adaptador de compatibilidade** ao comportamento do upstream `using-superpowers`.

```mermaid
flowchart TD
    Prompt["Entrada da Tarefa (com ou sem $workflows)"] --> Router["Roteador Leve / Adaptador Superpowers"]
    Router --> CheckAuth{"$workflows presente?"}
    CheckAuth -->|Sim| EnforceWF["Aplica Governança e Restrições Estritas do Modo $workflows"]
    CheckAuth -->|Não| EnforceBase["Aplica Governança Padrão do Repositório / No-Bypass"]
    EnforceWF --> CheckIntegrity{"Espelhos Gerenciados Íntegros?"}
    EnforceBase --> CheckIntegrity
    CheckIntegrity -->|Sim (Hash OK)| RefLoader["Carrega Referência pontual (.md) sob demanda"]
    CheckIntegrity -->|Não (Ausente/Divergente)| FailClosed["Fail-Closed: Degradação Graciosa para Fluxo Normal"]
    RefLoader --> Execution["Execução via DeepSeek MCP / Host Local"]
    FailClosed --> ExecutionNormal["Execução Padrão sem Métodos Superpowers"]
```

### Princípios do Adaptador e Roteador:
- **Ativação Automática Universal**: O roteador é acionado automaticamente em tarefas relevantes **com ou sem** a invocação explícita de `$workflows`. Quando `$workflows` está presente, ele permanece como autoridade soberana sobre modos e permissões; na sua ausência, o roteador aplica as melhores práticas operacionais compatíveis preservando as salvaguardas gerais do repositório.
- **Camada Adaptadora (*Compatibility Adapter*)**: O roteador atua explicitamente como um adaptador para o comportamento do upstream `using-superpowers`. Suas expectativas de anúncios prévios ("using superpowers..."), mensagens de preâmbulo e despacho nativo de subagentes **não são importadas inalteradas**. O adaptador converte essas intenções em operações silenciosas, concisas e estritamente aderentes ao ambiente PromptPad e ao DeepSeek Sub-Agent MCP.
- **Carga por Referência sob Demanda**: O agente carrega apenas referências markdown pontuais (`skills/superpowers/references/<metodo>.md`) no instante da execução.
- **Zero Injeção Maciça**: O prompt base do host permanece limpo e livre de catálogos estáticos desnecessários.

---

## 4. Curadoria de Métodos, Exclusões e Adaptações

### 4.1 Métodos Aprovados (Curadoria Safe)
- **Test-Driven Development (TDD)**: Ciclo sistemático Red-Green-Refactor, adaptado para entrega em lote validada.
- **Systematic Debugging**: Isolamento de falhas, formulação de hipóteses refutáveis e teste de regressão antes do fix.
- **Verification Checklists**: Listas de verificação pré-commit para validar integridade, tipagem, lints e ausência de resíduos.
- **Structured Brainstorming & Root-Cause Analysis**: Análise estruturada de causa-raiz para modos diagnósticos (`BUG.INV`, `DEBUG`).

### 4.2 Exclusões Explícitas (Proibidos)
- **Spawns/Subagentes Nativos do Superpowers**: Proibido qualquer despachante de agentes que ignore o DeepSeek Sub-Agent MCP.
- **Anúncios Verbosos / Preâmbulos Desnecessários**: Proibida a emissão de mensagens de preâmbulo ou anúncios de ativação herdados do upstream.
- **Manipulação Autônoma de Branches/Worktrees**: Proibida criação, troca ou remoção de branches e worktrees fora do padrão do PromptPad.
- **Operações Remotas / Push Git**: Proibido push, pull, rebase remoto ou publicação automatizada.
- **Bypass de Gates**: Proibida conclusão de tarefa com gates abertos ou testes pulados.

### 4.3 Adaptações Necessárias
- **Worktree Compartilhada**: Operações adaptadas para respeitar worktrees compartilhadas (`shared strategy`), preservando alterações de terceiros.
- **Commit Series Delivery**: Finalizações de escrita devem produzir séries de commit atômicas e locais conforme `skills/workflows/references/commit.md`.

---

## 5. Origem Canônica, Espelhamento de Hosts e Resiliência Fail-Closed

A gestão de artefatos Superpowers segue o padrão rígido de integridade do Codex Workflows Kit:

```
[Upstream Superpowers Repo (Pinned Hash)]
                 |
                 v
  [Canônico: codex-workflows-prompt-pad/skills/superpowers/]
                 |
        +--------+-----------------------+
        |                                | (install.ps1 com SHA256)
        v                                v
[~/.agents/skills/]        +-------------+-------------+
                           |                           |
                           v                           v
            [~/.gemini/antigravity/skills/]  [~/.gemini/config/skills/]
```

### 5.1 Espelhamento Completo em Todos os Roots Gerenciados
A instalação e a validação espelham os artefatos canônicos em **todas as raízes de skills gerenciadas do Antigravity e Codex** requeridas pelo instalador (`scripts/install.ps1`, `scripts/validate.ps1`, `scripts/doctor.ps1`):
1. **Codex / Agents Root**: `~/.agents/skills/superpowers/`
2. **Antigravity Skills Root 1**: `~/.gemini/antigravity/skills/superpowers/`
3. **Antigravity Skills Root 2**: `~/.gemini/config/skills/superpowers/`
4. **Template de Configuração Antigravity**: `~/.gemini/config/GEMINI.md`

### 5.2 Comportamento Fail-Closed e Degradação Graciosa
Caso qualquer espelho gerenciado de skills esteja ausente, corrompido ou desatualizado (divergência de hash SHA256 contra o repositório canônico):
- O sistema adota comportamento estritamente **fail-closed** para as extensões do Superpowers, bloqueando o carregamento de referências e métodos externos adulterados ou inexistentes.
- **Preservação do Fluxo Normal**: Em vez de abortar com falha fatal ou recorrer a heurísticas inseguras, o sistema faz a degradação graciosa e **preserva integralmente o fluxo de trabalho padrão do host (Codex/Antigravity)** sem métodos Superpowers.
- O diagnóstico do `scripts/doctor.ps1` sinalizará a inconsistência para correção via `scripts/install.ps1`.

---

## 6. Paridade Comportamental Codex & Antigravity

A compatibilidade é idêntica em ambos os ambientes host por meio do alinhamento das regras universais:

| Aspecto | Codex (`codex/AGENTS.md`) | Antigravity (`antigravity/GEMINI.md`) |
|---|---|---|
| **Ponto de Entrada** | Automático (com ou sem `$workflows`) | Automático (com ou sem `$workflows`) |
| **Autoridade Soberana** | `$workflows` (quando presente) | `$workflows` (quando presente) |
| **Ponte de Regras** | Regras globais via `AGENTS.md` | Regras globais via `GEMINI.md` |
| **Executor Principal** | DeepSeek Sub-Agent MCP | DeepSeek Sub-Agent MCP |
| **MCP Tools Permitidos** | Context7, CodeGraph, Serena | Context7, CodeGraph, Serena |
| **Raízes de Skills** | `~/.agents/skills/` | `~/.gemini/antigravity/skills/` e `~/.gemini/config/skills/` |
| **Comportamento em Falha de Espelho** | Fail-Closed (degradação para fluxo normal) | Fail-Closed (degradação para fluxo normal) |

---

## 7. Matriz de Testes Ciente de Modo (Positive / Negative Test Matrix)

A matriz a seguir define as validações positivas e as restrições negativas aplicadas a cada família de modos:

| Família de Modos | Modos Exemplos | Permissão Git/Disco | Métodos Superpowers Permitidos | Comportamentos Negativos Bloqueados (Fail-Closed) |
|---|---|---|---|---|
| **Planejamento & Pesquisa** | `PLAN`, `PLAN.AUTO`, `P.DEEP`, `RESEARCH.DEEP` | `no-write` (leitura apenas) | Decomposição de hipóteses, brainstorming estruturado, análise de arquitetura | Qualquer tentativa de escrita em arquivo, criação de mocks em disco ou commit |
| **Investigação & Diagnóstico** | `BUG.INV`, `DEBUG` (fase 1) | `no-write` / `write` restrito | Depuração sistemática, isolamento de causa-raiz | Alteração de código de produção antes da prova de reprodução da falha |
| **Implementação & Entrega** | `IMPL`, `IMPL.AUTO`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`, `R.A.F.V` | `write` (escrita + commit local) | TDD, refatoração orientada por testes, checklists de verificação | Pular revisão independente, tentar push remoto, comitar arquivos não pertencentes ao escopo |
| **Revisão & Auditoria** | `REVIEW`, `TN.SKILL` | `no-write` | Checklists de qualidade, análise estática e revisão por pares | Modificação direta de código durante a revisão |
| **Git Exclusivo** | `COMMIT` | `git-only` (apenas index Git) | Validação e formatação de mensagens de commit atômicas | Criação de código novo ou alteração estrutural fora do staging |

---

## 8. Fases de Rollout e Requisito Operacional

O plano de lançamento da proposta de compatibilidade Superpowers compreende 4 fases:

```
+-------------------+      +------------------+      +-------------------+      +-----------------+
| Fase 1: Proposta  | ---> | Fase 2: Curadoria| ---> | Fase 3: Validação | ---> | Fase 4: Release |
| (Em Revisão)      |      | & Adaptador Leve |      | & Scripts Doctor  |      | & Documentação  |
+-------------------+      +------------------+      +-------------------+      +-----------------+
```

1. **Fase 1 (Design & Proposta de Especificação)**: Proposta técnica formal em revisão e aguardando aprovação explícita do usuário.
2. **Fase 2 (Curadoria & Adaptador Leve)**: Curadoria de referências canônicas em `skills/superpowers/references/` e implementação do adaptador de compatibilidade.
3. **Fase 3 (Instalador, Manifestos & Doctor)**: Atualização de `scripts/install.ps1`, `scripts/validate.ps1` e `scripts/doctor.ps1` com manifestos SHA256 para todas as raízes gerenciadas.
4. **Fase 4 (Release & Habilitação)**: Disponibilização do perfil no kit e documentação de uso.

### Ressalva Operacional de Nova Sessão:
> **Importante**: Conforme a arquitetura dos hosts (Codex e Antigravity CLI), a instalação, remoção ou atualização de espelhos de skills e configurações de MCP **não requer reinicialização do sistema operacional**, mas **exige a abertura de uma nova tarefa ou nova sessão de chat** para que o host recarregue os manifests de skills atualizados.

---

## 9. Fronteiras de Escopo: Registro Futuro de Trabalho Durável (Beads)

O conceito de **Beads** (mecanismo persistente / ledger para rastreamento durável de estado e trabalho entre sessões longas) é reconhecido como uma necessidade arquitetural futura.

No entanto, **Beads fica estritamente fora do escopo desta especificação**. Qualquer modelagem de esquema, armazenamento transacional ou integração de ledger será tratada em um documento de design dedicado e autônomo.
