#!/usr/bin/env bash
# Move o card de Issues no GitHub Project (V2) para um Status, resolvendo
# todos os IDs por nome via GraphQL.
#
# Uso:
#   scripts/project-status.sh --pr 12 --status "Draft PR" [--dry-run]
#   scripts/project-status.sh --pr 12 --auto [--dry-run]
#   scripts/project-status.sh --issue 4 --status "Backlog" [--dry-run]
#
# --auto calcula a coluna pelo estado atual do PR (consultado na API):
#   PR fechado/mergeado               → nada a fazer
#   rascunho                          → COL_DRAFT
#   reviewDecision APPROVED           → COL_APPROVED
#   reviewDecision CHANGES_REQUESTED  → COL_CHANGES
#   reviewDecision REVIEW_REQUIRED    → COL_REVIEW
#   reviewDecision ausente (sem regra de review): últimas reviews de quem tem Write
#     alguma CHANGES_REQUESTED → COL_CHANGES; alguma APPROVED → COL_APPROVED; senão COL_REVIEW
#
# Configuração (variáveis de ambiente):
#   PROJECT_OWNER      dono do Project (login do usuário ou da organização)  [obrigatória]
#   PROJECT_NUMBER     número do Project (ex.: 1)                             [obrigatória]
#   OWNER_TYPE         "user" (padrão) ou "organization"
#   GITHUB_REPOSITORY  "owner/repo" do PR/Issue (o Actions já define)         [obrigatória]
#   STATUS_FIELD       nome do campo de status (padrão: "Status")
#   LINK_RETRIES       tentativas quando o PR ainda não tem Issues vinculadas (padrão: 5)
#   LINK_RETRY_DELAY   segundos entre tentativas (padrão: 3)
#   COL_DRAFT / COL_REVIEW / COL_APPROVED / COL_CHANGES
#                      nomes das colunas do --auto (padrão: "Draft PR", "In Review",
#                      "Approved", "In Progress")
#
# Requer apenas o GitHub CLI (`gh`) autenticado, com acesso ao Project
# (escopo `project`). Usa o `--jq` embutido no gh; não depende de `jq`.

set -euo pipefail

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
log()   { echo "[project-status] $*"; }
fail()  { echo "[project-status] ERRO: $*" >&2; exit 1; }

PR="" ISSUE="" STATUS="" AUTO=0 DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)      PR="${2:-}"; shift 2 ;;
    --issue)   ISSUE="${2:-}"; shift 2 ;;
    --status)  STATUS="${2:-}"; shift 2 ;;
    --auto)    AUTO=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         fail "argumento desconhecido: $1" ;;
  esac
done

[ -n "$PR" ] || [ -n "$ISSUE" ] || fail "informe --pr ou --issue"
if [ "$AUTO" = 1 ]; then
  [ -z "$STATUS" ] || fail "use --status ou --auto, não os dois"
  [ -n "$PR" ]     || fail "--auto exige --pr"
else
  [ -n "$STATUS" ] || fail "--status (ou --auto) é obrigatório"
fi
: "${PROJECT_OWNER:?defina PROJECT_OWNER}"
: "${PROJECT_NUMBER:?defina PROJECT_NUMBER}"
: "${GITHUB_REPOSITORY:?defina GITHUB_REPOSITORY (owner/repo)}"
OWNER_TYPE="${OWNER_TYPE:-user}"
STATUS_FIELD="${STATUS_FIELD:-Status}"
LINK_RETRIES="${LINK_RETRIES:-5}"
LINK_RETRY_DELAY="${LINK_RETRY_DELAY:-3}"
REPO_OWNER="${GITHUB_REPOSITORY%%/*}"
REPO_NAME="${GITHUB_REPOSITORY##*/}"

case "$OWNER_TYPE" in
  user|organization) ;;
  *) fail "OWNER_TYPE deve ser 'user' ou 'organization'" ;;
esac

# --auto: decide a coluna pelo estado consolidado do PR.
if [ "$AUTO" = 1 ]; then
  COL_DRAFT="${COL_DRAFT:-Draft PR}"
  COL_REVIEW="${COL_REVIEW:-In Review}"
  COL_APPROVED="${COL_APPROVED:-Approved}"
  COL_CHANGES="${COL_CHANGES:-In Progress}"

  # Saída: estado<TAB>draft<TAB>reviewDecision<TAB>nº CHANGES_REQUESTED<TAB>nº APPROVED<TAB>reviews
  # latestOpinionatedReviews(writersOnly) = última review com opinião de cada pessoa com Write,
  # a mesma regra que o GitHub usa para a regra de review obrigatória.
  PR_STATE=$(gh api graphql -F owner="$REPO_OWNER" -F repo="$REPO_NAME" -F pr="$PR" -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          state isDraft reviewDecision
          latestOpinionatedReviews(first: 100, writersOnly: true) { nodes { state author { login } } }
        }
      }
    }' --jq '.data.repository.pullRequest | (.latestOpinionatedReviews.nodes) as $r |
      [.state, .isDraft, (.reviewDecision // ""),
       ([$r[] | select(.state == "CHANGES_REQUESTED")] | length),
       ([$r[] | select(.state == "APPROVED")] | length),
       ([$r[] | "\(.author.login)=\(.state)"] | join(","))] | @tsv')
  IFS=$'\t' read -r PR_STATUS IS_DRAFT DECISION N_CHANGES N_APPROVED REVIEWS <<< "$PR_STATE"
  log "PR #$PR: state=$PR_STATUS draft=$IS_DRAFT reviewDecision=${DECISION:-null} reviews=[${REVIEWS}]"

  if [ "$PR_STATUS" != "OPEN" ]; then
    log "PR #$PR está $PR_STATUS; --auto não altera PRs fechados/mergeados."
    exit 0
  elif [ "$IS_DRAFT" = "true" ]; then
    STATUS="$COL_DRAFT"
  else
    case "$DECISION" in
      APPROVED)          STATUS="$COL_APPROVED" ;;
      CHANGES_REQUESTED) STATUS="$COL_CHANGES" ;;
      REVIEW_REQUIRED)   STATUS="$COL_REVIEW" ;;
      *)  # sem regra de review obrigatória: reviewDecision vem null
        if   [ "$N_CHANGES" -gt 0 ];  then STATUS="$COL_CHANGES"
        elif [ "$N_APPROVED" -gt 0 ]; then STATUS="$COL_APPROVED"
        else                               STATUS="$COL_REVIEW"
        fi ;;
    esac
  fi
  log "--auto → '$STATUS'"
fi

# ③ Project, campo e opção — resolvidos por nome.
PROJECT_INFO=$(gh api graphql -F owner="$PROJECT_OWNER" -F number="$PROJECT_NUMBER" -F field="$STATUS_FIELD" -f query="
  query(\$owner: String!, \$number: Int!, \$field: String!) {
    $OWNER_TYPE(login: \$owner) {
      projectV2(number: \$number) {
        id
        field(name: \$field) { ... on ProjectV2SingleSelectField { id options { id name } } }
      }
    }
  }" --jq ".data.$OWNER_TYPE.projectV2 | [.id, .field.id, (.field.options[] | select(.name == \"$STATUS\") | .id)] | @tsv")

IFS=$'\t' read -r PROJECT_ID FIELD_ID OPTION_ID <<< "$PROJECT_INFO"
[ -n "${PROJECT_ID:-}" ] || fail "Project $PROJECT_OWNER/$PROJECT_NUMBER não encontrado (ou sem acesso)"
[ -n "${FIELD_ID:-}" ]   || fail "campo '$STATUS_FIELD' não encontrado no Project"
[ -n "${OPTION_ID:-}" ]  || fail "opção '$STATUS' não existe no campo '$STATUS_FIELD'"
log "Project $PROJECT_ID | campo $FIELD_ID | '$STATUS' = $OPTION_ID"

# Saída de cada consulta: uma linha por Issue →  número<TAB>itemId<TAB>statusAtual
# (itemId vazio = a Issue não está neste Project)
ITEM_JQ="[.number, ([.projectItems.nodes[] | select(.project.id == \"$PROJECT_ID\")][0] // {} | .id // \"\", .status.name // \"\")] | @tsv"
ITEM_FIELDS="number projectItems(first: 20) { nodes { id project { id } status: fieldValueByName(name: \$field) { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }"

if [ -n "$PR" ]; then
  # ① + ② PR → Issues vinculadas → Items, em uma consulta.
  # O vínculo (Closes #N) é processado de forma assíncrona: tenta de novo se vier vazio.
  for attempt in $(seq 1 "$LINK_RETRIES"); do
    ROWS=$(gh api graphql -F owner="$REPO_OWNER" -F repo="$REPO_NAME" -F pr="$PR" -F field="$STATUS_FIELD" -f query="
      query(\$owner: String!, \$repo: String!, \$pr: Int!, \$field: String!) {
        repository(owner: \$owner, name: \$repo) {
          pullRequest(number: \$pr) { closingIssuesReferences(first: 20) { nodes { $ITEM_FIELDS } } }
        }
      }" --jq ".data.repository.pullRequest.closingIssuesReferences.nodes[] | $ITEM_JQ")
    [ -n "$ROWS" ] && break
    if [ "$attempt" -lt "$LINK_RETRIES" ]; then
      log "PR #$PR ainda sem Issues vinculadas (tentativa $attempt/$LINK_RETRIES); aguardando ${LINK_RETRY_DELAY}s"
      sleep "$LINK_RETRY_DELAY"
    fi
  done
  [ -n "$ROWS" ] || { log "PR #$PR não fecha nenhuma Issue (sem 'Closes #N' nem vínculo manual). Nada a fazer."; exit 0; }
else
  ROWS=$(gh api graphql -F owner="$REPO_OWNER" -F repo="$REPO_NAME" -F issue="$ISSUE" -F field="$STATUS_FIELD" -f query="
    query(\$owner: String!, \$repo: String!, \$issue: Int!, \$field: String!) {
      repository(owner: \$owner, name: \$repo) { issue(number: \$issue) { $ITEM_FIELDS } }
    }" --jq ".data.repository.issue | $ITEM_JQ")
fi

# ④ Atualiza cada Item.
while IFS=$'\t' read -r NUMBER ITEM_ID CURRENT; do
  [ -n "$NUMBER" ] || continue
  if [ -z "$ITEM_ID" ]; then
    log "#$NUMBER não está no Project; ignorando."
    continue
  fi
  if [ "$CURRENT" = "$STATUS" ]; then
    log "#$NUMBER já está em '$STATUS'; nada a fazer."
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] #$NUMBER: '${CURRENT:-sem status}' → '$STATUS' (item $ITEM_ID)"
    continue
  fi
  gh api graphql -f project="$PROJECT_ID" -f item="$ITEM_ID" -f field="$FIELD_ID" -f option="$OPTION_ID" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project, itemId: $item, fieldId: $field,
        value: { singleSelectOptionId: $option }
      }) { projectV2Item { id } }
    }' --silent
  log "#$NUMBER: '${CURRENT:-sem status}' → '$STATUS'"
done <<< "$ROWS"
