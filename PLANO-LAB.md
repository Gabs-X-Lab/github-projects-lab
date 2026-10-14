# Laboratório GitHub Projects + GitHub Actions

Plano de estudo e implementação de um Kanban no GitHub Projects (V2), com Issues como card principal, Pull Requests vinculados e automações via workflows nativos e GitHub Actions.

> Objetivo final: demonstrar o fluxo **Issue → Desenvolvimento → Draft PR → Review → Approval → Merge → Done** com o Project sendo atualizado automaticamente, e entender a arquitetura bem o suficiente para explicá-la.

---

## 1. Estado atual (análise inicial)

| Item | Situação |
|---|---|
| Diretório `C:\Repositorios\pixaflow\teste` | Vazio (apenas este plano) |
| Git | Não é um repositório: sem `.git`, remote, branches ou histórico |
| `.github/workflows` | Não existe |
| `git` | 2.56.0 instalado |
| `gh` (GitHub CLI) | 2.102.0, autenticado na conta pessoal (protocolo SSH) |
| Repositórios na conta | Nenhum listado |
| Organizations visíveis | Nenhuma |
| Escopos do token do `gh` | `repo`, `read:org`, `gist`, `admin:public_key`. **Falta `project`** |

Para habilitar os comandos `gh project`:

```bash
gh auth refresh -s project
```

---

## 2. Conceitos que orientam a arquitetura

### 2.1 Os workflows nativos atuam no card de quem gerou o evento

Os workflows nativos *Code review approved* e *Code changes requested* mudam o Status do **card do PR**, não da Issue vinculada.

Como queremos:

- a **Issue** como card principal;
- **sem** cards duplicados de PR (auto-add filtrado com `is:issue`),

os workflows nativos de review não têm card para mover. **Esse é o principal motivo para usar GitHub Actions** nos estados *Draft PR*, *In Review* e *Approved*.

### 2.2 "Done" é quase todo nativo

1. O PR contém `Closes #12` (ou `Fixes` / `Resolves`) e tem como alvo a **branch padrão**.
2. No merge, o GitHub fecha a Issue #12.
3. O workflow nativo *Item closed* move o card para **Done**.

Ressalva: *Item closed* não diferencia "fechada por merge" de "fechada como *not planned*". Vamos testar e decidir.

### 2.3 Encontrar a Issue vinculada ao PR

Vamos usar o campo GraphQL `PullRequest.closingIssuesReferences`, e não regex na descrição. Ele inclui:

- referências por palavra-chave (`Closes #N`, `Fixes #N`, `Resolves #N`);
- vínculos manuais feitos pela barra lateral **Development** do PR ou da Issue.

### 2.4 Diferença entre os objetos

| Objeto | O que é |
|---|---|
| **Project** | Quadro/planilha (Projects V2) que agrega itens de um ou mais repositórios. Pertence a um usuário ou a uma org, não a um repositório. |
| **Issue** | Tarefa/feature dentro de um repositório. Será o card principal. |
| **Draft Issue** | Item que existe **só no Project**, sem repositório. Útil para ideias e "Sugestão". Pode ser convertida em Issue. |
| **Pull Request** | Proposta de mudança de código. Vincula-se à Issue. |
| **Milestone** | Agrupador de Issues/PRs com data, **por repositório** (ex.: "v1.0"). |
| **Label** | Etiqueta livre por repositório (ex.: `bug`, `area:auth`). |
| **Iteration** | Campo do Project com ciclos de tempo (sprints). Existe **só no Project**. |

---

## 3. O que será configurado pela interface do GitHub

- Opções do campo **Status**: Sugestão, Backlog, To Do, In Progress, Draft PR, In Review, Approved, Done.
- **Workflows nativos do Project**:
  - Auto-add to project;
  - Item added to project;
  - Item closed;
  - Item reopened;
  - Pull request merged;
  - Auto-close issue;
  - Auto-archive items;
  - Pull request linked to issue (confirmar na interface atual).
- **Views**: Board, Table e Roadmap, com filtros e agrupamentos.
- **Ruleset/Branch protection** na `main`, exigindo PR com 1 aprovação.
- **Secrets e Variables** em *Settings → Secrets and variables → Actions*.
- Criação do **PAT** ou do **GitHub App**.

## 4. O que pode ser feito via CLI (`gh`)

| Comando | Uso |
|---|---|
| `gh auth status` | Ver a conta e os escopos do token |
| `gh repo create` | Criar o repositório remoto |
| `gh label create` | Criar labels |
| `gh api repos/{owner}/{repo}/milestones` | Criar milestones |
| `gh issue create` | Criar Issues |
| `gh pr create --draft` | Abrir um Draft PR |
| `gh pr ready` | Converter um Draft em Ready for Review |
| `gh pr review --approve` / `--request-changes` | Revisar um PR (com outra conta) |
| `gh pr merge` | Fazer o merge |
| `gh project create` / `list` / `view` | Gerenciar o Project |
| `gh project link` | Vincular o Project ao repositório |
| `gh project field-create` / `field-list` | Criar e listar campos |
| `gh project item-add` / `item-edit` | Adicionar e editar itens |
| `gh api graphql` | Explorar IDs e testar mutations do Projects V2 |

---

## 5. O que precisará de GitHub Actions

| Transição desejada | Nativo resolve? | Evento do Actions (validar na doc antes de implementar) |
|---|---|---|
| Issue criada → **Backlog** | ✅ Auto-add + Item added | não precisa |
| Issue atribuída → To Do / In Progress | ❌ | `issues: assigned` (a discutir) |
| Draft PR aberto → **Draft PR** | ❌ não existe workflow nativo para draft | `pull_request: opened` (com `draft == true`), `converted_to_draft` |
| Ready for Review → **In Review** | ❌ | `pull_request: ready_for_review` |
| Aprovado → **Approved** | ⚠️ só no card do PR | `pull_request_review: submitted` + `reviewDecision` |
| Changes requested / approval descartado | ⚠️ só no card do PR | `pull_request_review: submitted`, `dismissed` |
| Merge → **Done** | ✅ com keyword + branch padrão | `pull_request: closed` (reforço, se necessário) |
| PR fechado sem merge | ❌ | `pull_request: closed` com `merged == false` |
| PR reaberto | ❌ | `pull_request: reopened` |

### Proposta de arquitetura (para discutir na etapa de Actions)

Em vez de mapear "evento X → status Y", cada evento **recalcula o status** a partir do estado real do PR:

```
PR merged                       → Done (ou deixar o nativo agir)
PR fechado sem merge            → volta para In Progress / To Do (a definir)
PR draft                        → Draft PR
PR aberto + CHANGES_REQUESTED   → In Progress (ou In Review — a definir)
PR aberto + APPROVED            → Approved
PR aberto, aguardando review    → In Review
```

Isso torna a automação **idempotente** e trata melhor:

- múltiplos reviewers (o `reviewDecision` já consolida as reviews);
- aprovação descartada;
- várias PRs para a mesma Issue (usar o estado do PR "mais avançado");
- um PR que resolve várias Issues (iterar sobre `closingIssuesReferences`).

A implementação continuará **evento por evento**, como planejado.

---

## 6. Permissões e segurança

### 6.1 Tokens

| Credencial | Acessa Projects V2? | Quando usar |
|---|---|---|
| `GITHUB_TOKEN` | ❌ Não | Operações no próprio repositório (ler PR, comentar, labels) |
| PAT classic (`project` + `repo`) | ✅ Projects de usuário e de org | **Lab em conta pessoal** |
| Fine-grained PAT | ✅ Projects de org / ❌ Projects de usuário | Org, com escopo mínimo |
| GitHub App (*Organization projects: read/write*) | ✅ Projects de org / ❌ Projects de usuário | **Recomendado para a empresa**: não depende da conta de uma pessoa |

Regras:

- Nunca colocar tokens no código.
- Secrets ficam em *Settings → Secrets and variables → Actions*.
- Valores não sensíveis (owner e número do Project) ficam em **Variables**.

### 6.2 Conta pessoal × Organization

| Cenário | Observações |
|---|---|
| Repositório pessoal + Project pessoal | Exige PAT classic de uma pessoa. Bom para aprender, mas diferente da empresa. |
| Org repositories + Org Project | Permite GitHub App e fine-grained PAT. As permissões podem depender de aprovação de admin da org. |

### 6.3 Outras restrições do laboratório

- **O autor do PR não pode aprovar o próprio PR.** É necessária uma **segunda conta** como reviewer.
- **Repositório privado no plano Free não tem rulesets nem branch protection.** Sem review obrigatório, o `reviewDecision` pode vir `null`. Recomendação: repositório **público**.
- **PRs vindos de fork não recebem secrets.** No lab, usaremos branches do mesmo repositório.
- **A estratégia de IDs não deve ter IDs hardcoded.** Proposta: guardar só `PROJECT_OWNER` e `PROJECT_NUMBER` em Variables e resolver `projectId`, `fieldId` e `optionId` por nome em tempo de execução.

---

## 7. Plano em etapas

| Etapa | Conteúdo | Como validar |
|---|---|---|
| **0. Pré-requisitos** | Decisões da seção 8, escopo `project` no `gh`, segunda conta | `gh auth status` mostra `project` |
| **1. Repositório** | `git init`, README, branch `main`, criar remote, push, ruleset (PR + 1 aprovação) | Push direto na `main` é bloqueado |
| **2. Project V2** | Criar o Project, vincular ao repo, opções de Status, campos (Priority, Size, Iteration, Area), Views Board/Table/Roadmap | Board com as 8 colunas |
| **3. Conceitos na prática** | Issue × Draft Issue × PR × Label × Milestone × Iteration; `Closes` × `Refs`; vínculo pela barra Development; fluxo completo **manual** | Fluxo executado à mão, entendendo cada objeto |
| **4. Workflows nativos** | Auto-add (`is:issue`), Item added → Backlog, Item closed → Done, Item reopened, Auto-close, Auto-archive; documentar o que **não** cobrem | Issue nova cai em Backlog; merge leva para Done sem Actions |
| **5. GraphQL na mão** | Descobrir os IDs com `gh api graphql`, testar `closingIssuesReferences` e `updateProjectV2ItemFieldValue`, definir a estratégia de IDs | Mover um card pelo terminal |
| **6. Credencial** | Criar o PAT ou o App, cadastrar o Secret e as Variables | Workflow de teste lê o Project |
| **7a. Actions: Draft PR** | `pull_request: opened` / `converted_to_draft` | Draft PR move a Issue para **Draft PR** |
| **7b. Actions: Ready** | `pull_request: ready_for_review` | Issue vai para **In Review** |
| **7c. Actions: Review** | `pull_request_review: submitted` / `dismissed` | Aprovação → **Approved**; changes requested / dismiss → status definido |
| **7d. Actions: Fechamento** | `pull_request: closed` / `reopened` | Merge → **Done**; fechado sem merge não vai para Done |
| **8. Casos de borda** | Múltiplos reviewers, várias PRs → 1 Issue, 1 PR → várias Issues, PR reaberto | Matriz de testes preenchida |
| **9. "Desenvolvimento iniciado"** | Comparar atribuição, branch criada pela Issue (`linkedBranches`), Draft PR cedo e mudança manual | Decisão documentada |
| **10. ROADMAP.md → migração** | Script: parse do markdown → Issues → Project → campos/status. **Só migração, sem sincronização bidirecional.** | Issues criadas a partir do arquivo |
| **11. Demo** | Roteiro de demonstração + diagrama da arquitetura | Demo de ponta a ponta |

### Roteiro de teste de referência (fluxo completo)

```
Criar Issue
  → verificar card em Backlog (auto-add)
  → criar branch a partir da Issue
  → commit + push
  → abrir Draft PR com "Closes #N"        → verificar "Draft PR"
  → gh pr ready                            → verificar "In Review"
  → segunda conta aprova                   → verificar "Approved"
  → merge                                  → verificar Issue fechada + "Done"
```

---

## 8. Decisões (tomadas antes da Etapa 1)

- [x] **Conta pessoal ou Organization gratuita?** Começou em conta pessoal; após a Etapa 5, migrado para a org gratuita `Gabs-X-Lab` (Org Project + GitHub App, como na empresa).
- [x] **Repositório público ou privado?** **Público**, para ter ruleset com review obrigatório no plano Free.
- [x] **Segunda conta GitHub** para aprovar PRs: `Gabriel-Pixaflow` (member da org); owner e autora: `Gabs-X`.
- [x] **Nomes**: repositório `github-projects-lab`, Project "Lab Kanban".

---

## 9. Registro de progresso

| Etapa | Status | Data | Observações |
|---|---|---|---|
| Análise inicial | ✅ Concluída | 2026-10-14 | Diretório vazio, sem git, `gh` sem escopo `project` |
| 0. Pré-requisitos | ✅ Concluída | 2026-10-14 | Conta pessoal, repo público. Escopo `project` via `gh auth refresh -h github.com -s project` (precisa de terminal interativo) |
| 1. Repositório | ✅ Concluída | 2026-10-14 | Commits com e-mail noreply (config local). Remote HTTPS + `gh auth setup-git` (SSH negado para a conta). Ruleset "Proteção da main": PR + 1 aprovação, dismiss stale reviews, bypass de admin só via PR |
| 2. Project V2 | ✅ Concluída | 2026-10-14 | Status com 8 opções (IDs de Todo/In Progress/Done preservados). Campos Priority, Size, Iteration (6 sprints). Views Kanban, Sprint atual, Tabela, Roadmap. Group by/sort/datas do Roadmap só pela interface |
| 3. Conceitos na prática | ✅ Concluída | 2026-10-14 | Labels `area:*`, milestones por trimestre, Issues #3/#4, Draft Issue. Ciclo manual #3 → PR #5: nativos cobrem início (Item added, PR linked) e fim (Item closed); Draft PR/In Review/Approved exigem Actions. Detalhes em `docs/MANUAL-LAB.md` |
| 4. Workflows nativos | ✅ Concluída | 2026-10-14 | Auto-add (`is:issue is:open`) + Item added → Backlog, Item reopened → To Do, Auto-archive 14 dias, *PR linked* desligado. Testes T1–T8 com as Issues #8 e #9 |
| 5. GraphQL na mão | ✅ Concluída | 2026-10-14 | Consultas ①–④ executadas manualmente; `scripts/project-status.sh` (IDs por nome, retry, idempotente, `--dry-run`); `.gitattributes` com LF |
| 5.5 Migração para org | 🚧 Em andamento | 2026-10-14 | Org `Gabs-X-Lab` (Free); Project copiado com `copyProjectV2`; repositório com histórico novo |
| 6. Credencial | ⏳ Pendente | | ALTERAÇÃO DE TESTE PARA GERAR CONFLITO |
| 7. Actions (a–d) | ⏳ Pendente | | |
| 8. Casos de borda | ⏳ Pendente | | |
| 9. Desenvolvimento iniciado | ⏳ Pendente | | |
| 10. Migração do ROADMAP | ⏳ Pendente | | |
| 11. Demo | ⏳ Pendente | | |
