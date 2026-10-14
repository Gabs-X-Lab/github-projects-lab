# Manual do Laboratório — GitHub Projects + GitHub Actions

> Documento vivo, atualizado a cada etapa do laboratório. É a base para o manual de uso que será proposto para o projeto da empresa.
>
> - Plano e decisões gerais: [`PLANO-LAB.md`](../PLANO-LAB.md)
> - Dados fictícios de roadmap: [`ROADMAP.md`](../ROADMAP.md)
> - Repositório: <https://github.com/Gabs-X-Lab/github-projects-lab>
> - Project: <https://github.com/orgs/Gabs-X-Lab/projects/1>

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Conceitos](#2-conceitos)
3. [Etapa 0 — Pré-requisitos](#3-etapa-0--pré-requisitos)
4. [Etapa 1 — Repositório e proteção da main](#4-etapa-1--repositório-e-proteção-da-main)
5. [Etapa 2 — Criar e configurar o Project](#5-etapa-2--criar-e-configurar-o-project)
6. [Etapa 3 — Labels, Milestones, Issues e ciclo manual](#6-etapa-3--labels-milestones-issues-e-ciclo-manual)
7. [Vínculo Issue ↔ Pull Request](#7-vínculo-issue--pull-request)
8. [Etapa 4 — Workflows nativos do Project](#8-etapa-4--workflows-nativos-do-project)
9. [Etapa 5 — GraphQL na mão](#9-etapa-5--graphql-na-mão)
10. [Etapa 6 — Credencial do Actions (GitHub App)](#10-etapa-6--credencial-do-actions-github-app)

**Apêndices**

- [A — Referência rápida de comandos `gh`](#apêndice-a--referência-rápida-de-comandos-gh)
- [B — Descobertas e pegadinhas](#apêndice-b--descobertas-e-pegadinhas)
- [C — Decisões](#apêndice-c--decisões)
- [D — Próximas etapas](#apêndice-d--próximas-etapas)

---

## 1. Visão geral

### Problema

O roadmap da empresa vive em um arquivo markdown no repositório. Ele precisa ser atualizado manualmente via Pull Request e fica desatualizado com facilidade.

### Proposta

- **GitHub Projects (V2)** como Kanban.
- **Issues** como card principal de cada funcionalidade.
- **Pull Requests** vinculados às Issues, sem gerar cards duplicados.
- **Workflows nativos + GitHub Actions** movendo os cards automaticamente conforme o trabalho acontece.

### Fluxo do Kanban

```
Sugestão → Backlog → To Do → In Progress → Draft PR → In Review → Approved → Done
```

### Quem move cada transição (estado atual do laboratório)

| Transição | Responsável | Situação |
|---|---|---|
| Issue criada → entra no Project em **Backlog** | Nativos *Auto-add to project* + *Item added to project* | ✅ funcionando |
| Issue reaberta → **To Do** | Nativo *Item reopened* | ✅ funcionando |
| PR vinculado → In Progress | Nativo *Pull request linked to issue* | ⚪ desligado na Etapa 4 (a Action decidirá pelo `isDraft`) |
| Draft PR → Draft PR | GitHub Actions | ⏳ Etapa 7a |
| Ready for review → In Review | GitHub Actions | ⏳ Etapa 7b |
| Aprovado → Approved | GitHub Actions | ⏳ Etapa 7c |
| Merge → Done | GitHub fecha a Issue + nativo *Item closed* | ✅ funcionando |

---

## 2. Conceitos

### 2.1 Objetos do GitHub

| Objeto | O que é | Onde vive |
|---|---|---|
| **Project (V2)** | Quadro/planilha que agrega itens de um ou mais repositórios | Usuário ou Organization (**não** pertence a um repositório) |
| **Issue** | Tarefa ou funcionalidade. É o card principal | Repositório |
| **Draft Issue** | Rascunho que existe **só no Project**. Sem número, sem repositório, sem notificações. Pode ser convertido em Issue | Project |
| **Pull Request** | Proposta de mudança de código, vinculada à Issue | Repositório |
| **Label** | Etiqueta livre. Uma Issue pode ter várias | Repositório |
| **Milestone** | Entrega com data. Uma Issue tem no máximo um. Mostra barra de progresso | Repositório |
| **Iteration** | Campo do Project com ciclos de tempo (sprints) | Project |

**Draft Issue × Issue**

| | Draft Issue | Issue |
|---|---|---|
| Número (#N) | ❌ | ✅ |
| Repositório | ❌ | ✅ |
| Labels / Milestone / Assignee no repo | ❌ | ✅ |
| Pode ser fechada por PR (`Closes #N`) | ❌ | ✅ |
| Campos do Project (Status, Priority...) | ✅ | ✅ |

Por isso a automação de PR só funciona com **Issues**. Draft Issues servem para ideias (coluna *Sugestão*).

### 2.2 Dois tipos de campo no Project

| Tipo | Exemplos | Onde o dado vive | Consequência |
|---|---|---|---|
| **Campos de sistema** | Title, Assignees, Labels, Milestone, Linked pull requests, Reviewers, Repository | Na própria Issue/PR | Editar no Project altera a Issue |
| **Campos do Project** | Status, Priority, Size, Iteration | Só no Project | A Issue não sabe em que coluna está; só a API de Projects altera |

Uma mesma Issue em dois Projects tem **um Status diferente em cada um**.

### 2.3 Hierarquia de IDs (Projects V2 / GraphQL)

```
Project        PVT_...     "qual quadro"         ex.: PVT_kwDOFGh-zs4Bm-j7
 ├─ Field      PVTSSF_...  "qual campo"          ex.: Status = PVTSSF_lADOFGh-zs4Bm-j7zhllRnk
 │   └─ Option 8 hex       "qual valor"          ex.: Draft PR = 067f21de
 └─ Item       PVTI_...    "qual card"           ex.: PVTI_... (gerado quando a Issue entra no Project)
                └─ content → a Issue/PR/Draft Issue de verdade
```

- **Item ≠ Issue.** O Item é a Issue **dentro de um Project específico**. Para mover um card, é preciso descobrir o Item ID daquela Issue naquele Project.
- Prefixos: `PVTSSF` = single select field, `PVTIF` = iteration field, `PVTF` = campo comum.
- Os IDs acima são **exemplos deste laboratório**. Automações não devem tê-los fixos no código: devem resolver por nome em tempo de execução (ver [Decisões](#apêndice-c--decisões)).

---

## 3. Etapa 0 — Pré-requisitos

### Ferramentas

```bash
git --version       # testado com 2.56
gh --version        # testado com 2.102
gh auth status      # conta e escopos do token
```

### Escopo `project` no `gh`

Sem ele, os comandos `gh project ...` falham com `missing required scopes [read:project]`.

```bash
gh auth refresh -h github.com -s project
```

- Precisa de **terminal interativo**: mostra um código de uso único e abre o navegador. Não funciona em shells não interativos (ex.: terminais embutidos em ferramentas/IDEs); use um terminal separado.
- O navegador precisa estar logado na **conta certa**.
- Para conferir os escopos reais do token:

  ```bash
  gh api -i user | grep -i x-oauth-scopes
  ```

### Decisões do laboratório

| Item | Escolha | Motivo |
|---|---|---|
| Dono | Organization `Gabs-X-Lab` (plano Free) | Reproduz o cenário de empresa: Project de organização e GitHub App |
| Conta principal | `Gabs-X` (owner da org) | Autora dos commits e PRs |
| Conta revisora | `Gabriel-Pixaflow` (member) | O autor de um PR não pode aprová-lo; uma segunda conta é necessária para testar aprovações |
| Visibilidade do repo | Público | No plano Free, rulesets/branch protection só existem em repositórios públicos |
| Visibilidade do Project | Público | Demonstração sem precisar conceder acesso |

> As etapas 0 a 5 foram executadas inicialmente em uma conta pessoal e depois migradas para a organização (ver [Migração para organização](#98-migração-para-organização)). Os comandos deste manual já estão no formato de organização.

**Várias contas no `gh`**

```bash
gh auth login -h github.com -s project,workflow,read:org   # adiciona uma conta (terminal interativo)
gh auth status                                            # lista as contas e qual está ativa
gh auth switch                                            # alterna a conta ativa
```

---

## 4. Etapa 1 — Repositório e proteção da main

### 4.1 Repositório local

```bash
git init -b main
# identidade só deste repositório (não altera o git global)
git config user.name  "Gabs-X"
git config user.email "85885152+Gabs-X@users.noreply.github.com"
git add . && git commit -m "chore: estrutura inicial"
```

**Por que o e-mail noreply?** Em repositório público, o e-mail dos commits fica visível para qualquer pessoa. O formato `ID+login@users.noreply.github.com` esconde o e-mail real e ainda atribui o commit à conta certa. Para descobrir o seu:

```bash
gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"'
```

### 4.2 Repositório remoto

```bash
gh repo create Gabs-X-Lab/github-projects-lab --public --source . --remote origin --description "..."
gh auth setup-git          # gh vira o credential helper do git (HTTPS sem senha)
git push -u origin main    # a primeira branch enviada vira a default branch
```

> Se o `gh` estiver configurado para SSH e a chave da máquina pertencer a outra conta (`Permission denied (publickey)`), troque o remote para HTTPS com `git remote set-url origin https://github.com/OWNER/REPO.git`.

### 4.3 Ruleset na `main`

*Settings → Rules → Rulesets*, ou via API:

```bash
gh api -X POST repos/OWNER/REPO/rulesets --input ruleset.json
```

```json
{
  "name": "Proteção da main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
    } }
  ]
}
```

| Regra | Efeito |
|---|---|
| `pull_request` com 1 aprovação | Merge bloqueado sem aprovação. Também faz o `reviewDecision` do PR ter valor (sem a regra, vem `null`) |
| `dismiss_stale_reviews_on_push` | Commit novo após a aprovação a descarta, gerando o evento `pull_request_review: dismissed` |
| `non_fast_forward` | Bloqueia `push --force` |
| `deletion` | Impede apagar a `main` |
| Bypass admin, modo `pull_request` | Admin não faz push direto, mas pode forçar o merge **de um PR** |

### Como testar

```bash
git commit --allow-empty -m "teste: push direto"
git push                      # esperado: GH013 Repository rule violations
git reset --hard origin/main  # desfaz o commit de teste
```

---

## 5. Etapa 2 — Criar e configurar o Project

### 5.1 Criar, tornar público e vincular ao repositório

```bash
gh project create --owner Gabs-X-Lab --title "Lab Kanban"
gh project edit 1 --owner Gabs-X-Lab --visibility PUBLIC --description "..."
gh project link 1 --owner Gabs-X-Lab --repo Gabs-X-Lab/github-projects-lab
```

- O **vínculo** faz o Project aparecer na aba *Projects* do repositório.
- O vínculo **não** adiciona Issues automaticamente. Isso é papel do workflow *Auto-add*.

### 5.2 Opções do Status (8 colunas)

Via GraphQL, reaproveitando os IDs das opções padrão (`Todo`, `In Progress`, `Done`):

```graphql
mutation($field: ID!) {
  updateProjectV2Field(input: {
    fieldId: $field
    singleSelectOptions: [
      { name: "Sugestão",    color: PINK,   description: "Ideia ainda não avaliada/priorizada" }
      { name: "Backlog",     color: GRAY,   description: "Aceita, aguardando priorização" }
      { id: "<id do Todo>",        name: "To Do",       color: BLUE,   description: "Priorizada, pronta para começar" }
      { id: "<id do In Progress>", name: "In Progress", color: YELLOW, description: "Em desenvolvimento" }
      { name: "Draft PR",    color: ORANGE, description: "PR em rascunho vinculado" }
      { name: "In Review",   color: PURPLE, description: "PR pronto, aguardando review" }
      { name: "Approved",    color: GREEN,  description: "PR aprovado, aguardando merge" }
      { id: "<id do Done>",        name: "Done",        color: GREEN,  description: "PR mergeado / Issue concluída" }
    ]
  }) { projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } }
}
```

> **Por que passar o `id`?** Sem ele, o GitHub cria opções novas com IDs novos. Os cards perdem o status e os workflows nativos (que apontam para o ID antigo do *Done*) param de funcionar.

Para descobrir os IDs atuais:

```bash
gh project field-list 1 --owner Gabs-X-Lab
```

### 5.3 Campos personalizados

| Campo | Tipo | Valores |
|---|---|---|
| Priority | Single select | 🔴 Alta, 🟡 Média, 🟢 Baixa |
| Size | Single select | P, M, G |
| Iteration | Iteration | Sprint 1 a 6, 14 dias, a partir de 2026-10-12 |

- Criados com `createProjectV2Field` (GraphQL), porque o `gh project field-create` não aceita cores, descrições nem o tipo Iteration.
- Criar um campo Iteration com `iterations: []` gera um campo **sem sprints**. Elas precisam ser informadas explicitamente com `updateProjectV2Field`, passando `iterationConfiguration.iterations: [{ title, startDate, duration }]`.

### 5.4 Views

| View | Layout | Filtro | Para quê |
|---|---|---|---|
| Kanban | Board | `-is:pr` | Quadro principal; exclui PRs e mantém Draft Issues |
| Sprint atual | Board | `-is:pr iteration:@current` | Só o sprint corrente (`@current` é dinâmico) |
| Tabela | Table | — | Visão completa e edição em massa |
| Roadmap | Roadmap | `-is:pr` | Linha do tempo; substituto visual do ROADMAP.md |

- A API (`createProjectV2View` / `updateProjectV2View`) aceita apenas nome, layout, filtro e campos visíveis.
- `createProjectV2View` **não aceita `filter`**: é preciso criar e depois aplicar o filtro com `updateProjectV2View`.
- Views **Roadmap não aceitam `visibleFieldIds`** (erro `Roadmap views do not support visible fields`).

**Ajustes somente pela interface** (seta ▾ ao lado do nome da view; depois clicar em **Save**):

1. Kanban → *Column by*: **Status**.
2. Roadmap → *Date fields*: **Iteration**; *Zoom*: **Quarter**; *Markers*: **Iteration** e **Milestones**.
3. Tabela → *Group by*: **Status**; *Sort by*: **Priority**.

> Alterações em views pela interface só valem depois de clicar em **Save**. Sem isso, ficam só na sua sessão.

### Como testar

1. Repositório → aba *Projects* → "Lab Kanban" aparece.
2. Kanban mostra as 8 colunas e mais *No Status*.
3. Criar um card, definir Iteration = sprint atual → aparece em *Sprint atual*.
   - Item **sem** Iteration não aparece nessa view (comportamento esperado do filtro).

---

## 6. Etapa 3 — Labels, Milestones, Issues e ciclo manual

### 6.1 Labels e Milestones

```bash
gh label create "area:auth" -R OWNER/REPO --color 1D76DB --description "Autenticação e contas"
# ... area:agenda, area:pacientes, area:notificacoes, area:dashboard, area:pagamentos, tech-debt

# gh não tem comando de milestone → REST API
gh api -X POST repos/OWNER/REPO/milestones \
  -f title="Q4 2026 — MVP" -f due_on="2026-12-31T23:59:59Z" -f description="..."
```

| Origem no ROADMAP.md | Vira |
|---|---|
| Trimestre (`## Q4 2026 — MVP`) | **Milestone** |
| Área (`### Autenticação`) | **Label** `area:*` |
| Prioridade (🔴🟡🟢) | Campo **Priority** |
| Tamanho (`P/M/G`) | Campo **Size** |
| Sprint | Campo **Iteration** |

### 6.2 Criar Issues já no Project e preencher campos

```bash
gh issue create -R OWNER/REPO --title "..." --label area:auth --milestone "Q4 2026 — MVP" \
  --assignee @me --project "Lab Kanban" --body "..."
```

`--project` adiciona a Issue ao Project (cria o **Item**), mas os campos do Project ficam vazios ou recebem o valor do workflow *Item added*.

**Preencher campos por nome** (mais legível; o `gh` resolve os IDs):

```bash
gh project item-edit 1 --owner OWNER --url https://github.com/OWNER/REPO/issues/4 --field Status   --value "Backlog"
gh project item-edit 1 --owner OWNER --url https://github.com/OWNER/REPO/issues/4 --field Priority --value "🔴 Alta"
```

**Preencher campos por ID** (obrigatório para Iteration; é o caminho que automações usam):

```bash
gh project item-edit --project-id PVT_... --id PVTI_... --field-id PVTIF_... --iteration-id 82ee3b9e
```

- Um campo por chamada. A API GraphQL tem a mesma regra: um `updateProjectV2ItemFieldValue` por campo.

### 6.3 Draft Issue

```bash
gh project item-create 1 --owner OWNER --title "..." --body "..."
```

Cria um item **só no Project**, sem número e sem repositório. Usado para a coluna *Sugestão*.

### 6.4 Ciclo manual completo (Issue #3 → PR #5)

```bash
# 1. branch vinculada à Issue (aparece em "Development" da Issue)
gh issue develop 3 --name docs/3-registro-progresso --base main --checkout

# 2. trabalho + commit (Refs apenas menciona; quem fecha é o PR)
git commit -m "docs: ...

Refs #3"
git push

# 3. Draft PR com palavra-chave de fechamento na descrição
gh pr create --draft --base main --title "..." --body "... Closes #3"

# 4. pronto para review
gh pr ready 5

# 5. merge (aqui com bypass de admin, pois não havia segundo revisor)
#    Interface: marcar "Merge without waiting for requirements to be met" → Squash and merge
gh pr merge 5 --squash --admin --delete-branch

# 6. atualizar o local (squash cria um commit novo → branch -d recusa; conferir e usar -D)
git checkout main && git pull --prune
git diff main docs/3-registro-progresso --stat   # vazio = idêntico
git branch -D docs/3-registro-progresso
```

**O que aconteceu com o card #3 em cada passo**

| # | Ação | Evento no GitHub | Card #3 | Quem moveu |
|---|---|---|---|---|
| 1 | Issue criada com `--project` | `issues: opened` | **To Do** | nativo *Item added to project* |
| 2 | Branch vinculada | `create` | To Do | ninguém |
| 3 | Commit + push | `push` | To Do | ninguém |
| 4 | Draft PR com `Closes #3` | `pull_request: opened` | **In Progress** | nativo *Pull request linked to issue* |
| 5 | Ready for review | `pull_request: ready_for_review` | In Progress | ❌ lacuna → Actions |
| 6 | Aprovação | `pull_request_review: submitted` | — | ❌ lacuna → Actions |
| 7 | Merge | `pull_request: closed` (merged) | **Done** | GitHub fecha a Issue → nativo *Item closed* |

**Conclusão:** os workflows nativos cobrem o **início** e o **fim** do fluxo. O **meio** (Draft PR, In Review, Approved) exige GitHub Actions.

---

## 7. Vínculo Issue ↔ Pull Request

| Onde / como | Vincula (aparece em *Development*) | Fecha a Issue no merge |
|---|---|---|
| `Closes`/`Fixes`/`Resolves #N` na **descrição** do PR, base = **branch padrão** | ✅ | ✅ |
| Mesma palavra-chave, mas PR com base em **outra branch** | ❌ | ❌ |
| Vínculo manual pela barra lateral *Development* | ✅ | ✅ |
| Palavra-chave na **mensagem de commit** | ❌ | ✅ quando o commit chega à branch padrão |
| `Refs #N`, `#N` ou palavra-chave em **comentário** | ❌ (só menção na timeline) | ❌ |

- Palavras aceitas: `close/closes/closed`, `fix/fixes/fixed`, `resolve/resolves/resolved`.
- Várias Issues: `Closes #3, closes #4`. A palavra-chave deve se repetir para cada uma.
- Outro repositório: `Closes owner/repo#3`.

### Descobrir o vínculo pela API (sem regex)

```bash
# PR → Issues que ele fecha (keyword + vínculo manual)
gh pr view 5 --json closingIssuesReferences

# Issue → PRs que a fecham
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO"){ issue(number:3){
  closedByPullRequestsReferences(first:5, includeClosedPrs:true){ nodes{ number isDraft state } } } } }'

# Issue → branches vinculadas (criadas por "gh issue develop" / "Create a branch")
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO"){ issue(number:3){
  linkedBranches(first:5){ nodes{ ref{ name } } } } } }'
```

> ⚠️ O vínculo é processado **de forma assíncrona**. Logo após criar o PR, `closingIssuesReferences` pode vir **vazio**; alguns segundos depois, aparece. Automações precisam de retry.

---

## 8. Etapa 4 — Workflows nativos do Project

Workflows nativos são automações **internas do Project**. Não usam GitHub Actions, não consomem minutos e não precisam de token.

### 8.1 Onde configurar

Menu **⋯** (canto superior direito do Project) → **Workflows**.

- Em cada workflow: **Edit** → alterar → **Save** (ou **Save and turn on workflow**).
- O interruptor **On/Off** no topo liga e desliga.

> A API permite **ler** se cada workflow está ligado, mas **não** permite ligá-lo, configurá-lo ou ver para qual Status ele aponta. Também não há mutation para isso (só `deleteProjectV2Workflow`). Configuração é **somente pela interface**.

```bash
gh api graphql -f query='{ user(login:"OWNER"){ projectV2(number:1){ workflows(first:20){ nodes{ name enabled updatedAt } } } } }'
```

> O `updatedAt` **não muda** ao editar o Status de destino de um workflow já ligado. Não use esse campo para auditar configuração.

### 8.2 Configuração adotada

| Workflow | Padrão em projeto novo | Configuração adotada | Motivo |
|---|---|---|---|
| **Auto-add to project** | desligado | 🟢 repo `github-projects-lab`, filtro `is:issue is:open` | Toda Issue nova entra no Kanban; PRs ficam de fora |
| **Item added to project** | 🟢 → *Todo* | 🟢 → **Backlog** | Issue nova = aceita, aguardando priorização |
| **Item reopened** | desligado | 🟢 (Issue) → **To Do** | Reaberta volta para a fila priorizada |
| **Item closed** | 🟢 → *Done* | 🟢 → **Done** (mantido) | Inclui *not planned*, decisão aceita |
| **Auto-close issue** | 🟢 | 🟢 (mantido) | Arrastar para Done fecha a Issue |
| **Auto-archive items** | desligado | 🟢 `is:closed updated:<@today-14d` | Done não cresce indefinidamente no Board |
| **Pull request linked to issue** | 🟢 → *In Progress* | ⚪ **desligado** | Não diferencia draft de pronto; a Action da Etapa 7 decide |
| **Pull request merged** | 🟢 → *Done* | 🟢 (mantido) | Sem efeito: PRs não viram card |
| **Auto-add sub-issues to project** | 🟢 | 🟢 (mantido) | Subtarefas entram junto com a Issue pai |
| Code review approved / changes requested | — | não usados | Movem o card **do PR**, que não existe neste modelo |

**Observações**

- O **Auto-add não é retroativo**: só considera Issues criadas ou atualizadas depois de ligado.
- O **Auto-add tem limite por plano** (no Free, poucos workflows de auto-add por Project). Um único workflow com filtro amplo atende este caso.
- Com o *PR linked* desligado, abrir um PR **não move** a Issue até a Etapa 7. Nesse intervalo, o card é movido à mão.

### 8.3 Testes executados (Issues #8 e #9)

| # | Teste | Como reproduzir | Esperado | Resultado |
|---|---|---|---|---|
| T1 | Auto-add + status inicial | Criar Issue **sem** escolher Project (`gh issue create` sem `--project` ou pela interface) | Card aparece em **Backlog** | ✅ #9 apareceu em Backlog ~5 s depois |
| T2 | PR não vira card | Abrir um PR / atualizar um PR | PR **não** aparece no Project | ✅ (PR desta etapa) |
| T3 | Fechar como concluída | *Close issue* | Card → **Done** | ✅ #8 |
| T4 | Reabrir | *Reopen issue* | Card → **To Do** | ✅ #8 |
| T5 | Fechar como *not planned* | *Close issue* ▾ → *Close as not planned* | Card → **Done**, ícone ⊘ | ✅ #8 |
| T6 | Auto-close | Reabrir e **arrastar o card** para Done | Issue fecha sozinha | ✅ #8 |
| T7 | PR linked desligado | Abrir PR com `Closes #9` | Issue **não** muda de coluna | ✅ (PR desta etapa) |
| T8 | Auto-archive | Prévia do filtro na tela do workflow | 0 itens hoje (tudo fechou há menos de 14 dias) | ✅ |

### 8.4 Auditoria pela timeline

```bash
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO"){ issue(number:8){
  timelineItems(first:50, itemTypes:[CLOSED_EVENT, REOPENED_EVENT]){ nodes{ __typename
    ... on ClosedEvent { createdAt actor{ login } stateReason }
    ... on ReopenedEvent { createdAt actor{ login } } } } } } }'
```

- Fechamentos e reaberturas aparecem com `stateReason` (`COMPLETED` / `NOT_PLANNED`).
- Os eventos de Project (`AddedToProjectV2Event`, `ProjectV2ItemStatusChangedEvent`) aparecem na **interface**, mas a API **não os retornou**. Não dá para auditar mudanças de Status por essa via.
- Quando o *Auto-close issue* fecha uma Issue, o fechamento é atribuído a **quem arrastou o card**, e não a um bot. Pela API, é indistinguível de um fechamento manual.

---

## 9. Etapa 5 — GraphQL na mão

Objetivo: executar pelo terminal, consulta por consulta, tudo o que a automação fará, antes de escrever qualquer GitHub Action.

```
evento do PR (número)
   │ ① closingIssuesReferences
   ▼
Issue(s) vinculada(s)
   │ ② projectItems (filtrado pelo Project)
   ▼
Item ID da Issue neste Project
   │ ③ project → field("Status") → option("Draft PR")
   ▼
IDs do campo e da opção
   │ ④ updateProjectV2ItemFieldValue
   ▼
card movido
```

### 9.1 Anatomia de uma chamada

```bash
gh api graphql -F owner=OWNER -F repo=REPO -F pr=10 -f query='
query($owner: String!, $repo: String!, $pr: Int!) { ... }'
```

| Parte | Significado |
|---|---|
| `query($pr: Int!)` | Declara variáveis e tipos (`!` = obrigatório). Evita montar a query concatenando texto |
| `-F` × `-f` | `-F` converte tipos (`10` → número); `-f` envia sempre como texto. Variável `Int!` exige `-F` |
| `status: fieldValueByName(...)` | **Alias**: renomeia o campo na resposta |
| `... on User { login }` | **Fragmento inline**: lê campos de um tipo concreto quando o campo é uma interface/união |
| Resposta | Sucesso em `data`; falhas em `errors` (às vezes com `data` parcial) |

> A query é **validada inteira antes de executar**. Um erro de schema não lê nem altera nada.

### 9.2 ① PR → Issues vinculadas

```graphql
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      number isDraft state reviewDecision
      closingIssuesReferences(first: 10) {
        nodes { number title state repository { nameWithOwner } }
      }
    }
  }
}
```

- Retorna keyword (`Closes #N`) **e** vínculo manual; ignora `Refs #N`.
- ⚠️ Um PR mergeado via **bypass** continua com `reviewDecision = REVIEW_REQUIRED`. Na lógica de status, verificar **merged antes** de aprovado.

### 9.3 ② Issue → Item no Project

```graphql
query($owner: String!, $repo: String!, $issue: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $issue) {
      projectItems(first: 10) {
        nodes {
          id
          project { id number title owner { ... on User { login } ... on Organization { login } } }
          status: fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
          }
        }
      }
    }
  }
}
```

- Uma Issue em vários Projects tem **um Item por Project**. Sempre filtrar por `project.id`.
- `owner` é a interface `ProjectV2Owner`; `login` só existe em `User`/`Organization`, por isso o fragmento (erro sem ele: `Field 'login' doesn't exist on type 'ProjectV2Owner'`).

### 9.4 ③ Project, campo e opção por nome

```graphql
query($owner: String!, $number: Int!) {
  user(login: $owner) {              # Organization: organization(login: $owner)
    projectV2(number: $number) {
      id
      field(name: "Status") {
        ... on ProjectV2SingleSelectField { id options { id name } }
      }
    }
  }
}
```

Só `owner` e `número` ficam configurados; o resto é descoberto. Renomear/recriar opções não quebra a automação — e, se a opção sumir, o erro é explícito.

### 9.5 ④ Mover o card

```graphql
mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $project
    itemId: $item
    fieldId: $field
    value: { singleSelectOptionId: $option }   # ou text / number / date / iterationId
  }) { projectV2Item { id } }
}
```

- Altera **um campo de um Item**. A Issue não muda: nada na timeline, nenhuma notificação.

### 9.6 Script `scripts/project-status.sh`

Encadeia ① a ④. Será chamado pelo workflow do Actions na Etapa 7.

```bash
export PROJECT_OWNER=Gabs-X-Lab OWNER_TYPE=organization PROJECT_NUMBER=1 GITHUB_REPOSITORY=Gabs-X-Lab/github-projects-lab
scripts/project-status.sh --pr 12 --status "Draft PR"           # Issues vinculadas ao PR
scripts/project-status.sh --issue 4 --status Backlog --dry-run  # uma Issue, sem alterar
```

| Comportamento | Motivo |
|---|---|
| IDs por nome; só `PROJECT_OWNER`/`PROJECT_NUMBER` (+ `OWNER_TYPE=organization` em org) | Estratégia de IDs |
| Retry quando o PR ainda não tem Issues vinculadas (`LINK_RETRIES`, `LINK_RETRY_DELAY`) | Vínculo é assíncrono |
| PR → Issues → Items em **uma** consulta | Menos chamadas |
| Item filtrado pelo Project | Issue pode estar em vários Projects |
| Pula se o status já é o desejado | Idempotente |
| Avisa e pula Issue fora do Project | Não cria cards por conta própria |
| `--dry-run` | Ver o plano sem alterar |
| Só depende do `gh` (`--jq` embutido) | Funciona igual no Windows e no runner |

**Testes executados**

| Cenário | Resultado |
|---|---|
| `--issue 4 --status Backlog --dry-run` (card em Draft PR) | `[dry-run] #4: 'Draft PR' → 'Backlog'` |
| `--pr 10 --status Done` (#9 já em Done) | `#9 já está em 'Done'; nada a fazer.` |
| Opção inexistente | `ERRO: opção 'Em teste' não existe no campo 'Status'`, exit 1 |
| Sem `--status` | `ERRO: --status é obrigatório`, exit 1 |
| Project inexistente | `gh: Could not resolve to a ProjectV2 with the number 99`, exit 1 |
| `--issue 4 --status Backlog` real, 2× | 1ª: `'Draft PR' → 'Backlog'`; 2ª: `já está em 'Backlog'` |
| `--pr 12 --status "Draft PR"` logo após abrir o PR #12 (simulação da Etapa 7a) | `#11: 'Backlog' → 'Draft PR'`, **sem precisar de retry** (a resolução do Project deu tempo ao vínculo). O caminho do retry ainda não foi exercitado → Etapa 8 |

### 9.7 `.gitattributes`

```
*.sh  text eol=lf
*.yml text eol=lf
```

No Windows o git converte finais de linha para CRLF; um `\r` no fim das linhas quebra o bash do runner Linux. Este arquivo força LF em scripts e workflows.

### 9.8 Migração para organização

As etapas 0 a 5 foram feitas primeiro com um Project de **usuário**. Para reproduzir o cenário de empresa, o laboratório foi migrado para a organização `Gabs-X-Lab`. É o mesmo roteiro para levar a solução a uma organização real.

**1. Organização e contas** (interface)

- github.com → **+** → *New organization* → plano **Free** → *My personal account*.
- *People* → *Invite member* → conta revisora com papel **Member**.
- `gh auth login` com a conta owner (ver [Etapa 0](#3-etapa-0--pré-requisitos)).

**2. Copiar o Project**

```bash
ORG_ID=$(gh api graphql -f query='{ organization(login:"ORG"){ id } }' --jq '.data.organization.id')
gh api graphql -f project=PVT_ORIGEM -f owner="$ORG_ID" -f query='
mutation($project: ID!, $owner: ID!) {
  copyProjectV2(input: { projectId: $project, ownerId: $owner, title: "Lab Kanban", includeDraftIssues: true }) {
    projectV2 { id number url }
  }
}'
gh project edit 1 --owner ORG --visibility PUBLIC   # a cópia nasce privada
```

| Copiado | Não copiado |
|---|---|
| Campos e opções (Status, Priority, Size, Iteration com as sprints) | **Auto-add to project** (aponta para um repositório; refazer) |
| Views com filtros | Cards de Issues/PRs (pertencem ao repositório de origem) |
| Workflows nativos **com o estado ligado/desligado** | Visibilidade (a cópia nasce privada) |
| Draft Issues (com `includeDraftIssues: true`) | Vínculo com repositório |

> Na cópia, os **IDs de Project e de campos mudam** (`PVT_kwHO...` de usuário → `PVT_kwDO...` de org), mas os **IDs das opções** de single select são preservados. Automações que resolvem IDs por nome não precisam de nenhuma alteração.

**3. Repositório com histórico novo**

O repositório da organização começou com histórico novo, com a identidade da conta owner, em vez de transferir o repositório da conta pessoal. Os números de Issues e PRs citados nas etapas 3 a 5 (#3, #4, #5...) referem-se a essa primeira execução.

**4. Script em modo organização**

```bash
export PROJECT_OWNER=Gabs-X-Lab OWNER_TYPE=organization PROJECT_NUMBER=1 GITHUB_REPOSITORY=Gabs-X-Lab/github-projects-lab
```

Única diferença para o modo usuário: a raiz da consulta, `organization(login:)` em vez de `user(login:)`.

**5. Reconfigurar o Auto-add** (interface): *Workflows* → *Auto-add to project* → repositório da org, filtro `is:issue is:open` → *Save and turn on workflow*.

**Testes após a migração**

| Cenário | Resultado |
|---|---|
| Issue #1 criada sem `--project` | Entrou no Project em **Backlog** ~5 s depois (Auto-add + Item added) |
| Script sem `OWNER_TYPE` (padrão `user`) em Project de org | `gh: Could not resolve to a User with the login of 'Gabs-X-Lab'`, exit 1 |
| `--issue 1 --status "To Do" --dry-run` com `OWNER_TYPE=organization` | `[dry-run] #1: 'Backlog' → 'To Do'` |
| Mudança real → To Do → Backlog | `'Backlog' → 'To Do'`, depois `'To Do' → 'Backlog'` |
| Repetição → Backlog | `#1 já está em 'Backlog'; nada a fazer.` |

O script funcionou **sem nenhuma alteração** no Project copiado, que tem IDs novos.

---

## 10. Etapa 6 — Credencial do Actions (GitHub App)

O `GITHUB_TOKEN` automático do Actions **não acessa Projects V2**. É preciso outra credencial.

### 10.1 Opções de credencial

| | PAT classic | Fine-grained PAT | **GitHub App** |
|---|---|---|---|
| Pertence a | Uma pessoa | Uma pessoa | **A organização** |
| Se a pessoa sai | Automação quebra | Automação quebra | Continua funcionando |
| Permissões | Escopos amplos | Granulares | Granulares, por repositório instalado |
| Validade do token | Longa | Longa | **1 hora**, gerado a cada execução e revogado ao fim do job |
| Autor das ações | A pessoa | A pessoa | Bot (`nome-do-app[bot]`) |
| Projects de usuário | ✅ | ❌ | ❌ |
| Projects de organização | ✅ | ✅ | ✅ |

**Escolha:** GitHub App (Project de organização). PAT classic só faz sentido para Project de **usuário**.

```
Secret (chave privada .pem) + Variable (Client ID)
        │  actions/create-github-app-token
        ▼
token de instalação (1 h, só nos repositórios onde o App está instalado)
        │  GH_TOKEN=<token>
        ▼
scripts/project-status.sh → GraphQL → Project
```

### 10.2 Criar e instalar o App (owner da organização, interface)

1. *Settings* da org → *Developer settings* → *GitHub Apps* → **New GitHub App**.
2. Preencher:

   | Campo | Valor |
   |---|---|
   | Name | `gabs-x-lab-kanban-bot` (único no GitHub) |
   | Homepage URL | URL do repositório |
   | Webhook → Active | **Desmarcado** (quem dispara são os eventos do Actions) |
   | Where can this GitHub App be installed? | **Only on this account** |

3. Permissões (menor privilégio):

   | Permissão | Nível | Para quê |
   |---|---|---|
   | Repository → Issues | Read-only | `projectItems` das Issues |
   | Repository → Pull requests | Read-only | `closingIssuesReferences`, `isDraft`, `reviewDecision` |
   | Repository → Metadata | Read-only | Obrigatória |
   | Organization → **Projects** | **Read and write** | Ler o Project e mover cards |

4. **Create GitHub App** → anotar o **Client ID** (e o App ID) → *Private keys* → **Generate a private key** (baixa um `.pem`).
5. **Install App** → org → **Only select repositories** → o repositório do Kanban.

Conferência pela API (sem expor segredos):

```bash
gh api orgs/ORG/installations --jq '.installations[] | {app_slug, repository_selection, permissions}'
gh api apps/SLUG --jq '{id, client_id}'
```

### 10.3 Secret e Variables

| Nome | Tipo | Valor | Quem cadastra |
|---|---|---|---|
| `PROJECT_APP_PRIVATE_KEY` | **Secret** | Conteúdo completo do `.pem` (com as linhas `BEGIN`/`END`) | Owner, **pela interface** (o valor nunca passa por terminal) |
| `PROJECT_APP_CLIENT_ID` | Variable | Client ID do App (`Iv23...`) | `gh variable set` |
| `PROJECT_OWNER` | Variable | `Gabs-X-Lab` | `gh variable set` |
| `PROJECT_NUMBER` | Variable | `1` | `gh variable set` |
| `OWNER_TYPE` | Variable | `organization` | `gh variable set` |

- **Secret**: mascarado nos logs (`***`) e não pode ser lido de volta. No workflow: `${{ secrets.NOME }}`.
- **Variable**: visível em *Settings* e nos logs; pode ser alterada sem mexer no código. No workflow: `${{ vars.NOME }}`.
- Depois de cadastrar, apagar o `.pem` local (ou guardar em gerenciador de senhas). Se vazar: revogar a chave na página do App e gerar outra.
- Em organização com vários repositórios, o mesmo Secret/Variable pode ser criado **no nível da org** e liberado para repositórios selecionados.

### 10.4 Validação da action na documentação

Consultado direto no repositório oficial (release mais recente e `action.yml`):

```bash
gh api repos/actions/create-github-app-token/releases/latest --jq .tag_name
gh api "repos/actions/create-github-app-token/contents/action.yml?ref=TAG" -H "Accept: application/vnd.github.raw"
```

| Achado | Consequência |
|---|---|
| Versão atual: `v3.3.0` (runtime `node24`) | Versão usada |
| `app-id` está **obsoleto** (*"Use 'client-id' instead."*) | Usar `client-id` → Variable `PROJECT_APP_CLIENT_ID` |
| Entradas `permission-<nome>` | O token pode ser emitido com **menos** permissões que o App tem |
| Saídas: `token`, `installation-id`, `app-slug` | `token` vai para `GH_TOKEN` |
| Passo *post* da action | Revoga o token ao fim do job |

### 10.5 Workflow de teste de fumaça

`.github/workflows/project-smoke-test.yml`: gera o token do App **somente leitura** e roda o script em `--dry-run`.

| Gatilho | Quando | O que testa |
|---|---|---|
| `pull_request` com `paths:` (script ou o próprio workflow) | PR que altera esses arquivos | Modo `--pr`: PR → Issue vinculada → card |
| `workflow_dispatch` | Botão *Run workflow* (só com o arquivo na branch padrão) | Modo `--issue 1` |

**Boas práticas aplicadas**

| Prática | Motivo |
|---|---|
| `permissions: contents: read` | `GITHUB_TOKEN` padrão só com leitura |
| `permission-issues/pull-requests/organization-projects: read` no token | O teste não precisa escrever, mesmo o App podendo |
| Actions fixadas por **SHA** com a versão em comentário (`@3d3c42e... # v7.0.1`) | Tags podem ser movidas; SHA não. Proteção contra ataque de cadeia de suprimentos |
| Script executado direto (`scripts/project-status.sh`) | Valida o bit executável e o LF do `.gitattributes` no runner Linux |

Para descobrir o SHA de uma versão:

```bash
gh api repos/actions/checkout/git/ref/tags/v7.0.1 --jq '.object.sha'
```

> ⚠️ Em PRs vindos de **fork**, secrets não são entregues ao workflow (o teste falharia). Neste laboratório as branches são todas do mesmo repositório.

### 10.6 Resultado (PR #5)

O workflow disparou sozinho ao abrir o PR #5 e passou em todos os passos:

```
✓ Checkout
✓ Gerar token do GitHub App (somente leitura)
✓ Ler o Project (dry-run)
    [project-status] Project PVT_kwDOFGh-zs4Bm-j7 | campo PVTSSF_lADOFGh-zs4Bm-j7zhllRnk | 'Draft PR' = 067f21de
    [project-status] [dry-run] #4: 'Backlog' → 'Draft PR' (item PVTI_lADOFGh-zs4Bm-j7zhApnsQ)
✓ Post Gerar token do GitHub App (revoga o token)
```

Para acompanhar pelo terminal:

```bash
gh run list --limit 3
gh run watch <id> --exit-status
gh run view <id> --log
```

### 10.7 Permissão de quem revisa

Ao aprovar o PR #3 com a conta revisora, o merge continuou bloqueado (`reviewDecision = REVIEW_REQUIRED`), mesmo com a review `APPROVED` registrada.

**Causa:** membros de uma org nova têm permissão base **Read**. Em repositório público qualquer pessoa consegue *enviar* uma aprovação, mas a regra de review **só conta aprovações de quem tem Write**.

**Correção** (menor privilégio: só neste repositório, sem mudar a base da org):

```bash
gh api repos/ORG/REPO/collaborators/LOGIN/permission --jq .role_name   # read
gh api -X PUT repos/ORG/REPO/collaborators/LOGIN -f permission=push
```

A aprovação já existente passou a contar imediatamente (`APPROVED` / `mergeState=CLEAN`), sem precisar aprovar de novo.

### 10.8 Checklist para o owner da organização da empresa

- [ ] Criar o GitHub App com as permissões de 10.2 e instalar **só** nos repositórios do piloto
- [ ] Cadastrar o Secret `PROJECT_APP_PRIVATE_KEY` e as Variables de 10.3
- [ ] Garantir **Write** para quem revisa PRs (senão a aprovação não conta)
- [ ] Copiar o Project do laboratório (`copyProjectV2`) ou criar um novo e reconfigurar o Auto-add
- [ ] Confirmar o consumo de minutos do Actions (repositório privado)

---

## Apêndice A — Referência rápida de comandos `gh`

| Comando | Para quê |
|---|---|
| `gh auth status` | Conta ativa e escopos |
| `gh auth refresh -h github.com -s project` | Adicionar escopo (terminal interativo) |
| `gh auth setup-git` | Usar o `gh` como credencial do git em HTTPS |
| `gh repo create NOME --public --source . --remote origin` | Criar o repo a partir da pasta local |
| `gh label create` / `gh label list` | Labels |
| `gh api -X POST repos/O/R/milestones -f title=...` | Milestones |
| `gh issue create ... --project "Nome"` | Criar Issue já no Project |
| `gh issue develop N --name BRANCH --checkout` | Branch vinculada à Issue |
| `gh issue close N --reason "not planned"` | Fechar sem concluir |
| `gh pr create --draft` / `gh pr ready N` | Draft PR / pronto para review |
| `gh pr view N --json isDraft,reviewDecision,closingIssuesReferences` | Estado do PR para automação |
| `gh pr merge N --squash --delete-branch` | Merge |
| `gh project create` / `edit` / `link` | Gerenciar o Project |
| `gh project field-list N --owner O` | Campos e IDs das opções |
| `gh project item-list N --owner O --format json` | Itens e seus campos |
| `gh project item-create N --owner O --title ...` | Draft Issue |
| `gh project item-edit ... --field X --value Y` | Alterar campo por nome |
| `gh api graphql -f query='...'` | Qualquer operação GraphQL |

**Dicas**

- Use `--jq` do próprio `gh` para filtrar JSON (não depende do `jq` instalado).
- Introspecção do schema GraphQL, para descobrir o que a API suporta:

  ```bash
  gh api graphql -f query='{ __type(name:"UpdateProjectV2FieldInput"){ inputFields{ name } } }'
  ```

  A API limita cada campo de introspecção a 2 usos por requisição (`INTROSPECTION_LIMIT_EXCEEDED`).

---

## Apêndice B — Descobertas e pegadinhas

| # | Descoberta | Impacto |
|---|---|---|
| 1 | `gh auth refresh` / `gh auth login` exigem terminal interativo | Rodar em um terminal separado |
| 2 | E-mail do git global fica público em repo público | Usar noreply com config local |
| 3 | `GITHUB_TOKEN` não acessa Projects V2 | Actions precisará de PAT classic (conta pessoal) ou GitHub App (org) |
| 4 | Editar opções do Status sem `id` recria as opções | Sempre reenviar os IDs existentes |
| 5 | Iteration criado via API nasce sem sprints | Informar `iterations` explicitamente |
| 6 | Roadmap view não aceita campos visíveis; `createProjectV2View` não aceita filtro | Criar e depois atualizar |
| 7 | Ajustes de view na interface exigem **Save** | Sem isso, não persistem |
| 8 | Projeto novo já vem com 6 workflows nativos ligados | Revisar antes de testar automações |
| 9 | *Item closed* manda *not planned* para Done | Decisão pendente |
| 10 | *Pull request linked to issue* não diferencia draft | Decisão pendente |
| 11 | `closingIssuesReferences` é preenchido de forma assíncrona | Retry na Action do evento `opened` |
| 12 | Sem regra de review obrigatório, `reviewDecision` = `null` | Ruleset é pré-requisito do status *Approved* |
| 13 | `item-list` pode não refletir um item recém-criado | Considerar consistência eventual em scripts |
| 14 | Squash merge faz `git branch -d` recusar a branch local | Conferir com `git diff` e usar `-D` |
| 15 | Merge com bypass (`gh pr merge --admin`) pula a regra de review | Deve ser decisão humana explícita; nunca delegar a automações |
| 16 | Autor do PR não pode aprovar o próprio PR | Segunda conta necessária para a Etapa 7c |
| 17 | Configuração de workflows nativos só pela interface; a API só lê `enabled` | Documentar telas; conferir visualmente |
| 18 | `updatedAt` do workflow não muda ao editar o Status de destino | Não serve para auditar configuração |
| 19 | Eventos de Project não vêm na timeline via API | Auditoria de Status precisa de outro meio (ex.: log da Action) |
| 20 | Auto-close atribui o fechamento a quem arrastou o card | Indistinguível de fechamento manual |
| 21 | Auto-add leva alguns segundos e não é retroativo | Scripts/Actions devem tolerar o atraso |
| 22 | PR mergeado via bypass mantém `reviewDecision = REVIEW_REQUIRED` | Lógica de status: checar merged antes de aprovado |
| 23 | `ProjectV2Owner` é interface: `login` exige `... on User` / `... on Organization` | Usar fragmentos inline |
| 24 | Única diferença user × org nas consultas é a raiz (`user(login:)` × `organization(login:)`) | Script parametrizado por `OWNER_TYPE` |
| 25 | Mover card não gera evento na Issue nem notificação | Mudança de Status é "silenciosa" para quem acompanha a Issue |
| 26 | `copyProjectV2` copia campos, views e workflows (com estado), mas não o Auto-add nem a visibilidade | Refazer Auto-add e tornar público após copiar |
| 27 | Na cópia, IDs de Project e campos mudam; IDs de opções são preservados | Reforça a estratégia de IDs por nome |
| 28 | Project de org consultado como usuário falha com `Could not resolve to a User` | `OWNER_TYPE=organization` é obrigatório em org |
| 29 | Aprovação de quem tem só **Read** é registrada, mas não conta para a regra de review | Revisores precisam de Write no repositório |
| 30 | Membros de org nova têm permissão base **Read** | Dar Write por repositório (menor privilégio), não na base da org |
| 31 | `app-id` da `create-github-app-token` está obsoleto na v3 | Usar `client-id` |
| 32 | O token do App pode ser emitido com menos permissões que o App tem (`permission-*`) | Cada workflow pede só o que usa |

---

## Apêndice C — Decisões

### Tomadas

| Decisão | Escolha | Motivo |
|---|---|---|
| Card principal | Issue | PR vinculado, sem card duplicado |
| PRs no Project | Não adicionar | Views filtram `-is:pr`; auto-add usará `is:issue` |
| Estratégia de IDs | Resolver por nome em tempo de execução; apenas `PROJECT_OWNER`/`PROJECT_NUMBER` em Variables | Renomear/recriar opções não quebra a automação |
| Merge | Squash | Um commit por Issue na `main` |
| Branches | `gh issue develop` | Vínculo detectável por API (`linkedBranches`) |
| Status inicial de Issue nova (Etapa 4) | **Backlog** | Sugestões entram como Draft Issue, criadas à mão |
| *Pull request linked to issue* (Etapa 4) | **Desligado** | Não diferencia draft de pronto; a Action decide pelo `isDraft` |
| *Not planned* em Done (Etapa 4) | **Aceitar + Auto-archive (14 dias)** | O ícone da Issue mostra o motivo; o Board não acumula itens fechados |

---

## Apêndice D — Próximas etapas

- [x] Etapa 4 — Workflows nativos
- [x] Etapa 5 — GraphQL na mão
- [x] Etapa 6 — Credencial (GitHub App) e Secrets
- [ ] Etapa 7 — Actions: Draft PR, In Review, Approved, Merge/Closed
- [ ] Etapa 8 — Casos de borda
- [ ] Etapa 9 — Detectar início de desenvolvimento
- [ ] Etapa 10 — Migração do ROADMAP.md
- [ ] Etapa 11 — Demo
