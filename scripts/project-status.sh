#!/usr/bin/env bash
# Move o card de Issues no GitHub Project (V2) para um Status, resolvendo
# todos os IDs por nome via GraphQL.
#
# Uso:
#   scripts/project-status.sh --pr 12 --status "Draft PR" [--dry-run]
#   scripts/project-status.sh --pr 12 --auto [--dry-run]
#   scripts/project-status.sh --issue 4 --status "Backlog" [--dry-run]
#   scripts/project-status.sh --issue 4 --auto [--dry-run]
#
# --auto calcula a coluna de cada Issue (as vinculadas ao PR informado, ou a
# Issue informada) olhando TODOS os PRs abertos que fecham essa Issue:
#   coluna de um PR aberto:
#     rascunho                          → COL_DRAFT
#     reviewDecision APPROVED           → COL_APPROVED
#     reviewDecision CHANGES_REQUESTED  → COL_CHANGES
#     reviewDecision REVIEW_REQUIRED    → COL_REVIEW
#     reviewDecision ausente (sem regra de review): últimas reviews de quem tem Write
#       alguma CHANGES_REQUESTED → COL_CHANGES; alguma APPROVED → COL_APPROVED; senão COL_REVIEW
#   com vários PRs abertos, vale a coluna mais avançada:
#     COL_APPROVED > COL_REVIEW > COL_CHANGES > COL_DRAFT
#   sem nenhum PR aberto:
#     --pr: PR informado foi mergeado → nada a fazer (o workflow nativo "Item closed" leva a Done)
#           PR informado foi fechado sem merge → COL_NO_PR
#     --issue: Issue em coluna de PR (COL_DRAFT/COL_REVIEW/COL_APPROVED) → COL_NO_PR;
#              em qualquer outra coluna → não altera
#   Issues fechadas não são alteradas (ficam com os workflows nativos do Project).
#
# Configuração (variáveis de ambiente):
#   PROJECT_OWNER      dono do Project (login do usuário ou da organização)  [obrigatória]
#   PROJECT_NUMBER     número do Project (ex.: 1)                             [obrigatória]
#   OWNER_TYPE         "user" (padrão) ou "organization"
#   GITHUB_REPOSITORY  "owner/repo" do PR/Issue (o Actions já define)         [obrigatória]
#   STATUS_FIELD       nome do campo de status (padrão: "Status")
#   LINK_RETRIES       tentativas quando o PR ainda não tem Issues vinculadas (padrão: 5)
#   LINK_RETRY_DELAY   segundos entre tentativas (padrão: 3)
#   COL_DRAFT / COL_REVIEW / COL_APPROVED / COL_CHANGES / COL_NO_PR
#                      nomes das colunas do --auto (padrão: "Draft PR", "In Review",
#                      "Approved", "In Progress", "To Do")
#
# Requer apenas o GitHub CLI (`gh`) autenticado, com acesso ao Project
# (escopo `project`). Usa o `--jq` embutido no gh; não depende de `jq`.

set -euo pipefail

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit "${1:-1}"; }
log()   { echo "[project-status] $*" >&2; }
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
COL_DRAFT="${COL_DRAFT:-Draft PR}"
COL_REVIEW="${COL_REVIEW:-In Review}"
COL_APPROVED="${COL_APPROVED:-Approved}"
COL_CHANGES="${COL_CHANGES:-In Progress}"
COL_NO_PR="${COL_NO_PR:-To Do}"
REPO_OWNER="${GITHUB_REPOSITORY%%/*}"
REPO_NAME="${GITHUB_REPOSITORY##*/}"

case "$OWNER_TYPE" in
  user|organization) ;;
  *) fail "OWNER_TYPE deve ser 'user' ou 'organization'" ;;
esac

# ③ Project, campo e todas as opções — resolvidos por nome.
# 1ª linha: projectId<TAB>fieldId; demais linhas: nomeDaOpção<TAB>optionId
PROJECT_INFO=$(gh api graphql -F owner="$PROJECT_OWNER" -F number="$PROJECT_NUMBER" -F field="$STATUS_FIELD" -f query="
  query(\$owner: String!, \$number: Int!, \$field: String!) {
    $OWNER_TYPE(login: \$owner) {
      projectV2(number: \$number) {
        id
        field(name: \$field) { ... on ProjectV2SingleSelectField { id options { id name } } }
      }
    }
  }" --jq ".data.$OWNER_TYPE.projectV2 | \"\(.id)\t\(.field.id // \"\")\", ((.field.options // [])[] | \"\(.name)\t\(.id)\")")

IFS=$'\t' read -r PROJECT_ID FIELD_ID <<< "$(head -n 1 <<< "$PROJECT_INFO")"
OPTIONS=$(tail -n +2 <<< "$PROJECT_INFO")
[ -n "${PROJECT_ID:-}" ] && [ "$PROJECT_ID" != "null" ] || fail "Project $PROJECT_OWNER/$PROJECT_NUMBER não encontrado (ou sem acesso)"
[ -n "${FIELD_ID:-}" ] || fail "campo '$STATUS_FIELD' não encontrado no Project"

option_id() { awk -F '\t' -v name="$1" '$1 == name { print $2; exit }' <<< "$OPTIONS"; }

if [ "$AUTO" = 1 ]; then
  for col in "$COL_DRAFT" "$COL_REVIEW" "$COL_APPROVED" "$COL_CHANGES" "$COL_NO_PR"; do
    [ -n "$(option_id "$col")" ] || fail "opção '$col' não existe no campo '$STATUS_FIELD'"
  done
else
  [ -n "$(option_id "$STATUS")" ] || fail "opção '$STATUS' não existe no campo '$STATUS_FIELD'"
fi
log "Project $PROJECT_ID | campo $FIELD_ID"

# Coluna de um PR pelo seu estado na API. Saída: estado␟coluna (coluna vazia se o PR não está aberto).
# latestOpinionatedReviews(writersOnly) = última review com opinião de cada pessoa com Write,
# a mesma regra que o GitHub usa para a regra de review obrigatória.
pr_column() {
  local state draft decision n_changes n_approved reviews column=""
  IFS=$'\x1f' read -r state draft decision n_changes n_approved reviews <<< "$(
    gh api graphql -F owner="$REPO_OWNER" -F repo="$REPO_NAME" -F pr="$1" -f query='
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
         ([$r[] | "\(.author.login)=\(.state)"] | join(","))] | map(tostring) | join("\u001f")')"

  if [ "$state" = "OPEN" ]; then
    if [ "$draft" = "true" ]; then
      column="$COL_DRAFT"
    else
      case "$decision" in
        APPROVED)          column="$COL_APPROVED" ;;
        CHANGES_REQUESTED) column="$COL_CHANGES" ;;
        REVIEW_REQUIRED)   column="$COL_REVIEW" ;;
        *)  # sem regra de review obrigatória: reviewDecision vem null
          if   [ "$n_changes" -gt 0 ];  then column="$COL_CHANGES"
          elif [ "$n_approved" -gt 0 ]; then column="$COL_APPROVED"
          else                               column="$COL_REVIEW"
          fi ;;
      esac
    fi
  fi
  log "PR #$1: state=$state draft=$draft reviewDecision=${decision:-null} reviews=[$reviews] → '${column:-—}'"
  printf '%s\x1f%s\n' "$state" "$column"
}

# Ordem de "avanço" entre colunas, para escolher entre vários PRs abertos.
rank() {
  case "$1" in
    "$COL_APPROVED") echo 4 ;;
    "$COL_REVIEW")   echo 3 ;;
    "$COL_CHANGES")  echo 2 ;;
    "$COL_DRAFT")    echo 1 ;;
    *)               echo 0 ;;
  esac
}

TRIGGER_STATE="" TRIGGER_COLUMN=""
if [ "$AUTO" = 1 ] && [ -n "$PR" ]; then
  IFS=$'\x1f' read -r TRIGGER_STATE TRIGGER_COLUMN <<< "$(pr_column "$PR")"
fi

# Saída de cada consulta: uma linha por Issue →
#   número␟estadoDaIssue␟itemId␟statusAtual␟PRs abertos que fecham a Issue (separados por vírgula)
# (itemId vazio = a Issue não está neste Project)
ITEM_JQ="[.number, .state,
  ([.projectItems.nodes[] | select(.project.id == \"$PROJECT_ID\")][0] // {} | .id // \"\", .status.name // \"\"),
  ([.closedByPullRequestsReferences.nodes[].number | tostring] | join(\",\"))] | map(tostring) | join(\"\u001f\")"
ITEM_FIELDS="number state
  projectItems(first: 20) { nodes { id project { id } status: fieldValueByName(name: \$field) { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
  closedByPullRequestsReferences(first: 20, includeClosedPrs: false) { nodes { number } }"

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
while IFS=$'\x1f' read -r NUMBER ISSUE_STATE ITEM_ID CURRENT OPEN_PRS; do
  [ -n "$NUMBER" ] || continue
  if [ -z "$ITEM_ID" ]; then
    log "#$NUMBER não está no Project; ignorando."
    continue
  fi

  if [ "$AUTO" = 1 ] && [ "$ISSUE_STATE" = "CLOSED" ]; then
    # Issue fechada fica com os workflows nativos (Item closed → Done; Item reopened → To Do).
    log "#$NUMBER está fechada; --auto não altera Issues fechadas."
    continue
  fi

  if [ "$AUTO" = 1 ]; then
    # Candidatos: o PR informado (se aberto) + os demais PRs abertos da Issue.
    TARGET="$TRIGGER_COLUMN"
    [ -z "$TARGET" ] || log "#$NUMBER: PR #$PR (informado) → '$TARGET'"
    for other in ${OPEN_PRS//,/ }; do
      [ "$other" = "$PR" ] && continue
      IFS=$'\x1f' read -r _ OTHER_COLUMN <<< "$(pr_column "$other")"
      if [ "$(rank "$OTHER_COLUMN")" -gt "$(rank "$TARGET")" ]; then
        TARGET="$OTHER_COLUMN"
      fi
    done
    if [ -z "$TARGET" ]; then
      if [ -n "$ISSUE" ]; then
        # Modo --issue: só corrige Issues paradas em coluna de PR sem nenhum PR aberto
        # (ex.: PR fechado com conflito, que não gera evento). COL_CHANGES (In Progress)
        # também é usado manualmente, por isso não entra.
        case "$CURRENT" in
          "$COL_DRAFT"|"$COL_REVIEW"|"$COL_APPROVED")
            TARGET="$COL_NO_PR"
            log "#$NUMBER: em '$CURRENT' sem nenhum PR aberto → '$TARGET'" ;;
          *)
            log "#$NUMBER: sem PR aberto e em '${CURRENT:-sem status}' (não é coluna de PR); nada a fazer."
            continue ;;
        esac
      elif [ "$TRIGGER_STATE" = "MERGED" ]; then
        log "#$NUMBER: PR #$PR mergeado e nenhum outro PR aberto; Done fica com o workflow nativo 'Item closed'."
        continue
      else
        TARGET="$COL_NO_PR"
        log "#$NUMBER: nenhum PR aberto (PR #$PR $TRIGGER_STATE) → '$TARGET'"
      fi
    fi
  else
    TARGET="$STATUS"
  fi

  if [ "$CURRENT" = "$TARGET" ]; then
    log "#$NUMBER já está em '$TARGET'; nada a fazer."
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] #$NUMBER: '${CURRENT:-sem status}' → '$TARGET' (item $ITEM_ID)"
    continue
  fi
  gh api graphql -f project="$PROJECT_ID" -f item="$ITEM_ID" -f field="$FIELD_ID" -f option="$(option_id "$TARGET")" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project, itemId: $item, fieldId: $field,
        value: { singleSelectOptionId: $option }
      }) { projectV2Item { id } }
    }' --silent
  log "#$NUMBER: '${CURRENT:-sem status}' → '$TARGET'"
done <<< "$ROWS"
